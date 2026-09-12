#!/usr/bin/env python3
"""
mini_rv32_asm.py - a deliberately tiny RV32I assembler.

WHY THIS EXISTS
---------------
The real software flow is sw/Makefile + tools/elf2hex.py and needs
riscv32-unknown-elf-gcc. That toolchain is not installed on every machine the
RTL gets worked on, and the SoC integration testbench needs a real instruction
stream in ROM to be worth anything at all - a testbench that configures the DMA
from a TB-side APB master proves that the DMA works, not that the CPU can
reach it through the D-port, the interconnect and the bridge.

So this covers exactly the instruction subset tb/soc/tb_soc_ahb.sv needs and
nothing more. It is a STOPGAP, not a second toolchain:

  - no macros, no pseudo-ops beyond li/j/nop/mv, no .data, no linker
  - no relaxation, no relocations, no ELF
  - one section, origin fixed by --base

When riscv-gcc is available, build the .S with the real flow instead and delete
the generated .hex. The .S file this assembles is written in plain GNU as
syntax on purpose so that it builds either way.

Usage:
    python tools/gen/mini_rv32_asm.py sw/tests/soc_dma_smoke.S \
           -o tb/soc/soc_dma_smoke.hex --base 0x10000000 [--listing]
"""

import argparse
import re
import sys

REGS = {f"x{i}": i for i in range(32)}
REGS.update({
    "zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4,
    "t0": 5, "t1": 6, "t2": 7, "s0": 8, "fp": 8, "s1": 9,
    "a0": 10, "a1": 11, "a2": 12, "a3": 13, "a4": 14, "a5": 15,
    "a6": 16, "a7": 17,
    "s2": 18, "s3": 19, "s4": 20, "s5": 21, "s6": 22, "s7": 23,
    "s8": 24, "s9": 25, "s10": 26, "s11": 27,
    "t3": 28, "t4": 29, "t5": 30, "t6": 31,
})

R_OPS = {  # name: (funct7, funct3)
    "add": (0x00, 0x0), "sub": (0x20, 0x0), "sll": (0x00, 0x1),
    "slt": (0x00, 0x2), "sltu": (0x00, 0x3), "xor": (0x00, 0x4),
    "srl": (0x00, 0x5), "sra": (0x20, 0x5), "or": (0x00, 0x6),
    "and": (0x00, 0x7),
    "mul": (0x01, 0x0), "mulh": (0x01, 0x1), "div": (0x01, 0x4),
    "rem": (0x01, 0x6),
}
I_OPS = {"addi": 0x0, "slti": 0x2, "sltiu": 0x3, "xori": 0x4,
         "ori": 0x6, "andi": 0x7}
SH_OPS = {"slli": (0x00, 0x1), "srli": (0x00, 0x5), "srai": (0x20, 0x5)}
L_OPS = {"lb": 0x0, "lh": 0x1, "lw": 0x2, "lbu": 0x4, "lhu": 0x5}
S_OPS = {"sb": 0x0, "sh": 0x1, "sw": 0x2}
B_OPS = {"beq": 0x0, "bne": 0x1, "blt": 0x4, "bge": 0x5,
         "bltu": 0x6, "bgeu": 0x7}


class AsmError(Exception):
    pass


def reg(tok):
    t = tok.strip().lower()
    if t not in REGS:
        raise AsmError(f"unknown register '{tok}'")
    return REGS[t]


def imm(tok, symbols, pc=None):
    t = tok.strip()
    if t in symbols:
        return symbols[t]
    try:
        return int(t, 0)
    except ValueError:
        raise AsmError(f"cannot evaluate '{tok}'")


def enc_r(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def enc_i(im, rs1, f3, rd, op):
    return ((im & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def enc_s(im, rs2, rs1, f3, op):
    return (((im >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (f3 << 12) | ((im & 0x1F) << 7) | op


def enc_b(im, rs2, rs1, f3, op):
    return (((im >> 12) & 1) << 31) | (((im >> 5) & 0x3F) << 25) | \
           (rs2 << 20) | (rs1 << 15) | (f3 << 12) | \
           (((im >> 1) & 0xF) << 8) | (((im >> 11) & 1) << 7) | op


def enc_u(im, rd, op):
    return ((im & 0xFFFFF) << 12) | (rd << 7) | op


def enc_j(im, rd, op):
    return (((im >> 20) & 1) << 31) | (((im >> 1) & 0x3FF) << 21) | \
           (((im >> 11) & 1) << 20) | (((im >> 12) & 0xFF) << 12) | \
           (rd << 7) | op


def split_operands(s):
    # "x1, 8(x2)" -> ["x1", "8(x2)"]
    return [p.strip() for p in s.split(",") if p.strip() != ""]


def split_mem(tok):
    m = re.match(r"^\s*(-?[\w()+*-]*?)\s*\(\s*(\w+)\s*\)\s*$", tok)
    if not m:
        raise AsmError(f"expected offset(reg), got '{tok}'")
    off = m.group(1) if m.group(1) != "" else "0"
    return off, m.group(2)


def expand(mnem, ops):
    """Expand pseudo-instructions into a list of (mnem, ops) pairs.

    Returns None for instructions that are not pseudo-ops. The expansion is
    length-stable (li is always two words) so that a single-pass symbol table
    stays correct - this assembler does not relax.
    """
    if mnem == "nop":
        return [("addi", ["x0", "x0", "0"])]
    if mnem == "mv":
        return [("addi", [ops[0], ops[1], "0"])]
    if mnem == "j":
        return [("jal", ["x0", ops[0]])]
    if mnem == "li":
        # Always two instructions, even when one would do. A variable-length
        # li would need a second pass to settle branch targets, and that is
        # exactly the kind of subtlety a stopgap should not have.
        return [("__li_hi", [ops[0], ops[1]]), ("__li_lo", [ops[0], ops[1]])]
    return None


def assemble(lines, base):
    # ---- pass 1: expand pseudo-ops and collect labels ----
    items = []           # (addr, mnem, ops, source_line)
    symbols = {}
    addr = base

    for raw in lines:
        line = raw.split("#")[0].split("//")[0].rstrip()
        if not line.strip():
            continue
        # labels (possibly several, possibly followed by an instruction)
        while True:
            m = re.match(r"^\s*([.\w]+)\s*:\s*(.*)$", line)
            if not m:
                break
            symbols[m.group(1)] = addr
            line = m.group(2)
        if not line.strip():
            continue
        if line.strip().startswith("."):
            d = line.strip().split()
            if d[0] in (".word", ".4byte"):
                items.append((addr, "__word", [d[1]], raw))
                addr += 4
                continue
            if d[0] in (".globl", ".global", ".text", ".align", ".option",
                        ".type", ".size", ".section"):
                continue
            raise AsmError(f"unsupported directive: {line.strip()}")
        parts = line.strip().split(None, 1)
        mnem = parts[0].lower()
        ops = split_operands(parts[1]) if len(parts) > 1 else []
        ex = expand(mnem, ops)
        if ex is None:
            items.append((addr, mnem, ops, raw))
            addr += 4
        else:
            for m2, o2 in ex:
                items.append((addr, m2, o2, raw))
                addr += 4

    # ---- pass 2: encode ----
    words = []
    listing = []
    for (a, mnem, ops, raw) in items:
        w = encode(a, mnem, ops, symbols)
        words.append(w)
        listing.append(f"{a:08x}: {w:08x}   {raw.strip()}")
    return words, listing, symbols


def encode(addr, mnem, ops, symbols):
    if mnem == "__word":
        return imm(ops[0], symbols) & 0xFFFFFFFF

    if mnem in ("__li_hi", "__li_lo"):
        v = imm(ops[1], symbols) & 0xFFFFFFFF
        v_s = v - (1 << 32) if v & 0x80000000 else v
        hi = (v_s + 0x800) >> 12
        lo = v_s - (hi << 12)
        if mnem == "__li_hi":
            return enc_u(hi & 0xFFFFF, reg(ops[0]), 0x37)          # lui
        return enc_i(lo, reg(ops[0]), 0x0, reg(ops[0]), 0x13)      # addi

    if mnem in R_OPS:
        f7, f3 = R_OPS[mnem]
        return enc_r(f7, reg(ops[2]), reg(ops[1]), f3, reg(ops[0]), 0x33)

    if mnem in I_OPS:
        return enc_i(imm(ops[2], symbols), reg(ops[1]), I_OPS[mnem],
                     reg(ops[0]), 0x13)

    if mnem in SH_OPS:
        f7, f3 = SH_OPS[mnem]
        sh = imm(ops[2], symbols) & 0x1F
        return enc_i((f7 << 5) | sh, reg(ops[1]), f3, reg(ops[0]), 0x13)

    if mnem == "lui":
        return enc_u(imm(ops[1], symbols), reg(ops[0]), 0x37)
    if mnem == "auipc":
        return enc_u(imm(ops[1], symbols), reg(ops[0]), 0x17)

    if mnem in L_OPS:
        off, rs1 = split_mem(ops[1])
        return enc_i(imm(off, symbols), reg(rs1), L_OPS[mnem],
                     reg(ops[0]), 0x03)

    if mnem in S_OPS:
        off, rs1 = split_mem(ops[1])
        return enc_s(imm(off, symbols) & 0xFFF, reg(ops[0]), reg(rs1),
                     S_OPS[mnem], 0x23)

    if mnem in B_OPS:
        target = imm(ops[2], symbols)
        return enc_b((target - addr) & 0x1FFF, reg(ops[1]), reg(ops[0]),
                     B_OPS[mnem], 0x63)

    if mnem == "jal":
        target = imm(ops[1], symbols)
        return enc_j((target - addr) & 0x1FFFFF, reg(ops[0]), 0x6F)

    if mnem == "jalr":
        off, rs1 = split_mem(ops[1]) if "(" in ops[1] else ("0", ops[1])
        return enc_i(imm(off, symbols), reg(rs1), 0x0, reg(ops[0]), 0x67)

    if mnem == "ecall":
        return 0x00000073
    if mnem == "ebreak":
        return 0x00100073
    if mnem == "wfi":
        return 0x10500073

    raise AsmError(f"unsupported instruction '{mnem}'")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("source")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--base", default="0x10000000")
    ap.add_argument("--words", type=int, default=0,
                    help="pad the image to this many words")
    ap.add_argument("--listing", action="store_true")
    args = ap.parse_args()

    base = int(args.base, 0)
    with open(args.source) as f:
        lines = f.readlines()

    try:
        words, listing, symbols = assemble(lines, base)
    except AsmError as e:
        print(f"{args.source}: {e}", file=sys.stderr)
        return 1

    if args.words and len(words) < args.words:
        words = words + [0] * (args.words - len(words))

    with open(args.output, "w") as f:
        f.write(f"// generated by tools/gen/mini_rv32_asm.py from {args.source}\n")
        f.write(f"// base = 0x{base:08x}, {len(words)} words\n")
        for w in words:
            f.write(f"{w:08x}\n")

    if args.listing:
        for l in listing:
            print(l)
        print("\nsymbols:")
        for k, v in sorted(symbols.items(), key=lambda kv: kv[1]):
            print(f"  {k:20s} 0x{v:08x}")

    print(f"wrote {args.output}: {len(words)} words", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
