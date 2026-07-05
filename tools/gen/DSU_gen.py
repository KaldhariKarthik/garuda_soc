"""
gen_dsu_tests.py  --  test generator for the GARUDA DSU.

WHAT IT DOES
------------
Makes up instructions (curated corner cases + random ones), runs each through
the golden model to get the right answer, and writes two plain-hex files:

    dsu_stim.mem      -- what the testbench drives INTO the RTL
    dsu_expected.mem  -- what the RTL should produce, per the golden model

Both are read with Verilog's $readmemh. One 32-bit hex value per line.

FILE FORMAT  (fixed-size records, so the TB reads them in a simple loop)
------------------------------------------------------------------------
STIMULUS  = 4 words per test:
    [0] instr[31:0]
    [1] rs1[31:0]
    [2] rs2[31:0]
    [3] {31'b0, csr_clear_overflow}

EXPECTED  = 8 words per test:
    [0] rd_data[31:0]
    [1] acc_FX[31:0]      [2] {16'b0, acc_FX[47:32]}
    [3] acc_FY[31:0]      [4] {16'b0, acc_FY[47:32]}
    [5] acc_MAG[31:0]     [6] {16'b0, acc_MAG[47:32]}
    [7] flags = {24'b0, rd_addr[4:0], illegal, rd_valid, overflow}
                 bit0=overflow  bit1=rd_valid  bit2=illegal  bits[7:3]=rd_addr

THE PIPELINE CAVEAT (FLAG-2)
----------------------------
The golden model gives the accumulator value immediately; the real MAC is a
couple of cycles behind. So by default we insert one settling op (MAC_SEL 0*0,
which adds nothing) after a compute before reading it, so the RTL value has
landed and the compare is fair. Run with --no-drain to remove the settle and
deliberately create the compute->read hazard you want to probe.

usage:  python gen_dsu_tests.py [--count N] [--seed S] [--no-drain]
"""

import os, sys, random, argparse

# find the golden model (sits in ../golden)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "golden"))
from DSU_Golden import (DSU, asm, asm_shift,
                        MAC_SEL, MACSUB, MACABS, MACDOT, MACLOAD,
                        MACCLEAR, MACSAT, MACRD_LO, MACRD_HI, MACSHIFT,
                        ACC_FX, ACC_FY, ACC_MAG, MASK32, MASK48)

# values worth hammering: extremes and sign boundaries
CORNERS16 = [0x0000, 0x0001, 0xFFFF, 0x7FFF, 0x8000, 0x8001, 0x00FF, 0x0100]


def rand_word(rng):
    """A 32-bit operand, biased so corner 16-bit patterns show up often."""
    if rng.random() < 0.5:
        lo = rng.choice(CORNERS16); hi = rng.choice(CORNERS16)
        return (hi << 16) | lo
    return rng.randint(0, MASK32)


def directed_tests():
    """Curated corner cases, each a (instr, rs1, rs2, csr_clear, note) tuple."""
    t = []
    # one basic run of every instruction
    t += [(asm(MAC_SEL,  ACC_FX), 3, 4, 0, "MAC_SEL basic 3*4"),
          (asm(MACSUB,   ACC_FX), 2, 5, 0, "MACSUB basic -2*5"),
          (asm(MACABS,   ACC_FY), 0x8000, 1, 0, "MACABS |0x8000|*1 -> clamp"),
          (asm(MACDOT,   ACC_MAG), 0x00020003, 0x00040005, 0, "MACDOT 3*5+2*4"),
          (asm(MACLOAD,  ACC_FX), 0x80000000, 0, 0, "MACLOAD sign-extend neg"),
          (asm(MACCLEAR, ACC_FX), 0, 0, 0, "MACCLEAR zero FX"),
          (asm(MACRD_LO, ACC_MAG, rd=10), 0, 0, 0, "MACRD_LO -> x10"),
          (asm(MACRD_HI, ACC_MAG, rd=11), 0, 0, 0, "MACRD_HI -> x11")]
    # extreme products
    t += [(asm(MAC_SEL, ACC_FY), 0x7FFF, 0x7FFF, 0, "max * max"),
          (asm(MAC_SEL, ACC_FY), 0x8000, 0x8000, 0, "min * min")]
    # push toward accumulator overflow (49th bit)
    for _ in range(6):
        t.append((asm(MAC_SEL, ACC_MAG), 0x7FFF, 0x7FFF, 0, "accumulate toward ovf"))
    # saturation: load a big value then clamp; boundary must NOT clamp
    t += [(asm(MACLOAD, ACC_FX), 0x7FFFFFFF, 0, 0, "load +int32 max (boundary)"),
          (asm(MACSAT,  ACC_FX), 0, 0, 0, "MACSAT boundary -> no clamp"),
          (asm(MAC_SEL, ACC_FX), 0x7FFF, 0x7FFF, 0, "nudge over +int32 max"),
          (asm(MACSAT,  ACC_FX), 0, 0, 0, "MACSAT -> positive clamp")]
    # sticky flag clear
    t += [(asm(MACRD_LO, ACC_FX, rd=1), 0, 0, 1, "csr_clear_overflow pulse")]
    # shifts: right-arith on a negative, left, amt=0, oversize amt (FLAG-3)
    t += [(asm(MACLOAD, ACC_FY), 0xFFFF0000, 0, 0, "load negative for shift"),
          (asm_shift(ACC_FY, amt=4, left=0, rd=12), 0, 0, 0, "MACSHIFT ASR 4"),
          (asm_shift(ACC_FY, amt=4, left=1, rd=13), 0, 0, 0, "MACSHIFT LSL 4"),
          (asm_shift(ACC_FY, amt=0, left=0, rd=14), 0, 0, 0, "MACSHIFT amt=0"),
          (asm_shift(ACC_FY, amt=63, left=0, rd=15), 0, 0, 0, "MACSHIFT amt=63 (FLAG-3)")]
    # illegal ones -- must be rejected, state untouched
    t += [(asm(MAC_SEL, acc_sel=3), 1, 1, 0, "illegal acc_sel=3"),
          ((0x1F << 27) | 0x0B, 1, 1, 0, "illegal unknown funct5"),
          ((0x0B | (2 << 12)), 1, 1, 0, "illegal bad funct3")]
    return t


def is_compute(instr):
    op = instr & 0x7F; f3 = (instr >> 12) & 7; f5 = (instr >> 27) & 0x1F
    return op == 0x0B and f3 == 0 and f5 in (MAC_SEL, MACSUB, MACABS, MACDOT)

def acc_of(instr):
    return (instr >> 25) & 0x3


def random_tests(rng, n):
    out = []
    compute = [MAC_SEL, MACSUB, MACABS, MACDOT]
    ops = compute + [MACLOAD, MACCLEAR, MACSAT, MACRD_LO, MACRD_HI, MACSHIFT]
    for _ in range(n):
        f5 = rng.choice(ops)
        sel = rng.randint(0, 2) if rng.random() < 0.9 else 3   # 10% illegal acc_sel
        if f5 == MACSHIFT:
            instr = asm_shift(sel & 0x3, amt=rng.randint(0, 63),
                              left=rng.randint(0, 1), rd=rng.randint(1, 31))
        else:
            instr = asm(f5, acc_sel=sel, rd=rng.randint(1, 31))
        out.append((instr, rand_word(rng), rand_word(rng), 0, f"random {f5}"))
    return out


def w(x):                       # 32-bit value -> 8-digit hex line
    return f"{x & MASK32:08x}"

def expected_words(st):
    """Turn a golden-model result + accumulator snapshot into the 8-word record."""
    def split(acc):
        u = acc & MASK48
        return u & MASK32, (u >> 32) & 0xFFFF
    a0l, a0h = split(st["acc"][0]); a1l, a1h = split(st["acc"][1]); a2l, a2h = split(st["acc"][2])
    flags = (st["overflow"] & 1) | ((st["rd_valid"] & 1) << 1) \
            | ((st["illegal"] & 1) << 2) | ((st["rd_addr"] & 0x1F) << 3)
    return [st["rd_data"], a0l, a0h, a1l, a1h, a2l, a2h, flags]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=0, help="random tests (default: match directed count)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--no-drain", action="store_true", help="omit settle op -> provoke FLAG-2 hazard")
    ap.add_argument("--outdir", default=".")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    directed = directed_tests()
    n_rand = args.count if args.count else len(directed)      # even mix by default
    program = directed + random_tests(rng, n_rand)

    dsu = DSU()
    stim, exp = [], []
    count = 0
    for instr, rs1, rs2, clr, note in program:
        r = dsu.step(instr, rs1, rs2, clr)
        stim += [w(instr), w(rs1), w(rs2), w(clr)]
        exp  += [w(v) for v in expected_words({**r, "acc": dsu.acc})]
        stim[-4] = stim[-4] + f"   // #{count}: {note}"       # annotate first line of record
        count += 1

        # settle the pipeline after a real compute (unless probing FLAG-2)
        if is_compute(instr) and not args.no_drain:
            settle = asm(MAC_SEL, acc_of(instr))              # MAC_SEL 0*0 -> same acc
            r = dsu.step(settle, 0, 0, 0)
            stim += [w(settle) + f"   // #{count}: settle (drain pipeline)", w(0), w(0), w(0)]
            exp  += [w(v) for v in expected_words({**r, "acc": dsu.acc})]
            count += 1

    os.makedirs(args.outdir, exist_ok=True)
    hdr = "// generated by gen_dsu_tests.py -- do not edit by hand\n"
    with open(os.path.join(args.outdir, "dsu_stim.mem"), "w") as f:
        f.write(hdr); f.write("\n".join(stim) + "\n")
    with open(os.path.join(args.outdir, "dsu_expected.mem"), "w") as f:
        f.write(hdr); f.write("\n".join(exp) + "\n")

    print(f"wrote {count} tests  ({len(directed)} directed + {n_rand} random"
          f"{'' if args.no_drain else ' + settle ops'})")
    print(f"  dsu_stim.mem      : {len(stim)} lines (4 words/test)")
    print(f"  dsu_expected.mem  : {len(exp)} lines (8 words/test)")
    print(f"  seed={args.seed}  drain={'off' if args.no_drain else 'on'}")


if __name__ == "__main__":
    main()