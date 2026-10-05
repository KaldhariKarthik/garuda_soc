#!/usr/bin/env python3
"""
lockstep.py -- compare a GARUDA RTL commit log against Spike, instruction by
instruction, and report the FIRST divergence with context.

WHY A NORMALIZER EXISTS AT ALL
------------------------------
Spike's -l --log-commits output and tb_boot's commit log describe the same
events in different alphabets. Diffing them raw produces thousands of
mismatches on the first run, all of them formatting, and the real bug is
invisible inside the noise. Both sides are therefore reduced to one canonical
tuple per retired instruction:

    (pc, rd, value)

with rd=0/value=0 for any instruction that makes no architectural GPR write.
Everything else Spike emits is deliberately discarded:

  - the disassembly lines (no leading privilege digit)
  - the instruction word: PC plus the image determines it, and the RTL has no
    trace port carrying it
  - CSR write side-effects (c768_mstatus etc): the RTL log has no CSR channel,
    so including them would guarantee a mismatch on every trap
  - memory write records (mem 0x...): stores show up as rd=0 on both sides
  - x0 writes: the RTL suppresses them at the regfile, Spike logs them

The first divergence is the only one that matters. Everything after it is
downstream of the same bug, so the tool stops describing after --max.

STORES, CSRS AND TRAPS (commit log version 2)
---------------------------------------------
A version 2 RTL log (first line "# garuda-commit-log 2") also carries MEM, CSR
and TRAP records; see the header of tb/soc/tb_boot.v. Each kind is compared
with Spike as an ordered stream, after the instruction compare has passed:

  stores   (address, bytes, data) of every store, in program order
  traps    (cause, epc, tval) of every trap taken
  CSRs     for every CSR instruction, the value the CSR holds afterwards -
           compared where Spike logged a write (it logs nothing for a pure
           read) and where the bench has a view of that CSR

They are streams, not fields of the instruction tuple, because the RTL
records are written when the event happens - a store completes one cycle
before its instruction retires, a CSR instruction acts two cycles before -
so the last few records can belong to instructions the RTL log never
retired (the test ends on the tohost store). The RTL may therefore have up
to TAIL records more than Spike at the end of a stream, never fewer.

CSR_MASK lists the bits compared for a CSR where GARUDA differs from Spike
by specification, each with its reason. A CSR not listed is compared whole.
"""
import argparse
import re
import subprocess
import sys
import os

# Spike commit line WITH the privilege digit, e.g.
#   core   0: 3 0x10000000 (0x00040117) x2  0x10040000
SPIKE_COMMIT = re.compile(
    r"^core\s+\d+:\s+(\d)\s+0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)(.*)$")
SPIKE_REGWR = re.compile(r"\bx\s*(\d+)\s+0x([0-9a-fA-F]+)")


SPIKE_STORE = re.compile(r"\bmem\s+0x([0-9a-fA-F]+)\s+0x([0-9a-fA-F]+)")
SPIKE_CSRWR = re.compile(r"\bc(\d+)_\w+\s+0x([0-9a-fA-F]+)")
SPIKE_EXC   = re.compile(r"^core\s+\d+:\s+exception\s+(\w+),\s+epc\s+0x([0-9a-fA-F]+)")
SPIKE_TVAL  = re.compile(r"^core\s+\d+:\s+tval\s+0x([0-9a-fA-F]+)")

# Spike's exception names -> mcause
CAUSE = {"trap_instruction_address_misaligned": 0, "trap_instruction_access_fault": 1,
         "trap_illegal_instruction": 2, "trap_breakpoint": 3,
         "trap_load_address_misaligned": 4, "trap_load_access_fault": 5,
         "trap_store_address_misaligned": 6, "trap_store_access_fault": 7,
         "trap_user_ecall": 8, "trap_supervisor_ecall": 9, "trap_machine_ecall": 11}

# Bits compared, per CSR, where GARUDA and Spike differ by specification.
CSR_MASK = {
    # mtvec: GARUDA is CLIC-only, MODE reads 3 whatever is written (CORE 6.1);
    # Spike keeps the written mode. The base is compared.
    0x305: 0xFFFFFFFC,
}


class Streams:
    """Stores, CSR instructions and traps, each tagged with the number of
    instruction lines that came before it in its log."""
    def __init__(self):
        self.mem, self.csr, self.trap = [], [], []


def parse_spike(path, limit=0, tohost=None):
    """tohost: stop reading at the first non-zero store to this address. A
    program that ends in a loop around that store leaves a long tail in
    Spike's log that nothing compares."""
    out, st = [], Streams()
    with open(path, errors="replace") as f:
        for line in f:
            m = SPIKE_COMMIT.match(line)
            if not m:
                e = SPIKE_EXC.match(line)
                if e:
                    st.trap.append([len(out), CAUSE.get(e.group(1), e.group(1)),
                                    int(e.group(2), 16) & 0xFFFFFFFF, None])
                else:
                    t = SPIKE_TVAL.match(line)
                    if t and st.trap and st.trap[-1][3] is None:
                        st.trap[-1][3] = int(t.group(1), 16) & 0xFFFFFFFF
                continue                      # disassembly lines
            pc = int(m.group(2), 16) & 0xFFFFFFFF
            insn = int(m.group(3), 16)
            tail = m.group(4)
            rd, val = 0, 0
            rm = SPIKE_REGWR.search(tail)
            if rm:
                r = int(rm.group(1))
                if r != 0:                    # x0 writes are not architectural
                    rd = r
                    val = int(rm.group(2), 16) & 0xFFFFFFFF
            sm = SPIKE_STORE.search(tail)
            if sm:                            # "mem addr data"; a load has no data
                st.mem.append((len(out), int(sm.group(1), 16) & 0xFFFFFFFF,
                               len(sm.group(2)) // 2, int(sm.group(2), 16)))
                if tohost is not None and st.mem[-1][1] == tohost and st.mem[-1][3] != 0:
                    out.append((pc, rd, val))
                    break
            if (insn & 0x7F) == 0x73 and ((insn >> 12) & 3) != 0:   # a CSR instruction
                addr, v = insn >> 20, None
                for cm in SPIKE_CSRWR.finditer(tail):
                    if int(cm.group(1)) == addr:
                        v = int(cm.group(2), 16) & 0xFFFFFFFF
                st.csr.append((len(out), addr, v))
            out.append((pc, rd, val))
            if limit and len(out) >= limit:
                break
    return out, st


def parse_rtl(path, limit=0):
    out, st, v2 = [], Streams(), False
    with open(path, errors="replace") as f:
        for line in f:
            p = line.split()
            if not p:
                continue
            if p[0] == "#":
                v2 = v2 or p[1:] == ["garuda-commit-log", "2"]
                continue
            try:
                if p[0] == "MEM":
                    st.mem.append((len(out), int(p[1], 16), int(p[2]), int(p[3], 16)))
                elif p[0] == "TRAP":
                    st.trap.append([len(out), int(p[1], 16), int(p[2], 16), int(p[3], 16)])
                elif p[0] == "CSR":
                    st.csr.append((len(out), int(p[1], 16),
                                   None if p[2].startswith("-") else int(p[2], 16)))
                elif len(p) == 3:
                    out.append((int(p[0], 16), int(p[1], 10), int(p[2], 16)))
            except (ValueError, IndexError):
                continue
            if limit and len(out) >= limit:
                break
    return out, (st if v2 else None)


def truncate_at_selfloop(seq, runs=3):
    """Cut the log at a terminal self-branch (`j hang`).

    tb_boot stops on the tohost bus write. Spike cannot: its HTIF needs the
    device tree, and the device tree cannot be enabled because spike's NS16550
    is hard-wired at 0x10000000 -- exactly GARUDA's reset vector. So spike runs
    on into the post-tohost spin loop and the two logs end at different places
    for a completely uninteresting reason.

    Both sides are therefore cut at the first PC that retires `runs` times in a
    row, which is the spin loop and nothing else: no forward-progressing code
    retires the same PC consecutively.
    """
    for i in range(len(seq) - runs + 1):
        pc = seq[i][0]
        if all(seq[i + k][0] == pc for k in range(runs)):
            return seq[:i]
    return seq


TAIL = 2      # records the RTL may hold for instructions it never retired


def compare_stream(name, gold, rtl, n, show, same=None):
    """gold/rtl: lists whose first element is the instruction count before the
    record. Returns (number compared, error text or None)."""
    g = [x for x in gold if x[0] < n]
    r = [x for x in rtl if x[0] <= n]
    same = same or (lambda a, b: tuple(a[1:]) == tuple(b[1:]))
    for k in range(min(len(g), len(r))):
        if not same(g[k], r[k]):
            return k, (f"DIVERGE in {name}: record {k}\n"
                       f"  spike  {show(g[k])}   (instruction {g[k][0]})\n"
                       f"  rtl    {show(r[k])}   (before instruction {r[k][0]})")
    if len(r) < len(g):
        return len(r), (f"DIVERGE in {name}: Spike has {len(g)}, the RTL log has {len(r)}\n"
                        f"  first one missing: {show(g[len(r)])}   (instruction {g[len(r)][0]})")
    if len(r) > len(g) + TAIL:
        return len(g), (f"DIVERGE in {name}: the RTL log has {len(r)}, Spike has {len(g)}\n"
                        f"  first extra one: {show(r[len(g)])}   (before instruction {r[len(g)][0]})")
    return len(g), None


def trap_same(g, r):
    # Spike prints a tval line only for traps that carry one; for the others
    # (ecall, ebreak) it writes mtval = 0, so "no line" is compared as 0.
    return g[1] == r[1] and g[2] == r[2] and (g[3] or 0) == r[3]


def csr_same(g, r):
    if g[1] != r[1]:
        return False                          # a different CSR: the streams are out of step
    if g[2] is None or r[2] is None:
        return True                           # pure read, or a CSR the bench cannot see
    m = CSR_MASK.get(g[1], 0xFFFFFFFF)
    return (g[2] & m) == (r[2] & m)


def fmt(t):
    if t is None:
        return "  <end of log>"
    pc, rd, val = t
    return f"  pc={pc:08x}  " + (f"x{rd}={val:08x}" if rd else "(no gpr write)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl", required=True, help="tb_boot commit log")
    ap.add_argument("--spike-log", help="pre-existing spike log")
    ap.add_argument("--elf", help="ELF to run spike on (generates the log)")
    ap.add_argument("--spike", default=os.path.expanduser(
        "~/external/spike-inst/bin/spike"))
    # Zicsr must be explicit: spike's --isa=rv32im does NOT imply it, so every
    # CSR instruction decodes as illegal in the golden model and the whole trap
    # suite "diverges" against a core that is behaving correctly.
    # Every extension GARUDA implements must be named, or spike raises illegal
    # on instructions the core executes correctly and the whole test "diverges":
    #   zicsr    - CSR instructions (rv32im alone does NOT imply it)
    #   zifencei - FENCE.I (ERRATUM C-3)
    #   zicntr   - cycle/instret/cycleh/instreth shadows (ERRATUM C-4)
    ap.add_argument("--isa", default="rv32im_zicsr_zifencei_zicntr")
    ap.add_argument("--base", default="0x10000000")
    ap.add_argument("--size", default="0x40000")
    ap.add_argument("--max", type=int, default=5, help="divergences to print")
    ap.add_argument("--limit", type=int, default=0, help="max instrs compared")
    ap.add_argument("--tohost", help="address of tohost: Spike's log is cut at the "
                    "first non-zero store to it, where the RTL bench stops")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    spike_log = args.spike_log
    if args.elf:
        spike_log = args.spike_log or (args.elf + ".spike.log")
        cmd = [args.spike, f"--isa={args.isa}",
               f"-m{args.base}:{args.size}",
               "--disable-dtb",              # spike's NS16550 sits at 0x10000000
               # GARUDA implements M-mode ONLY. Spike defaults to MSU, so the
               # env's `csrwi mstatus,0` (MPP=0) + `mret` drops it to U-mode and
               # every M-mode CSR access then traps as illegal -- against a core
               # that never left M-mode. Without this the whole trap suite
               # "diverges" on correct RTL.
               "--priv=m",
               # GARUDA has no PMP and no debug triggers; without these two
               # Spike has their CSRs and an access that traps on GARUDA does
               # not trap on Spike (seen with riscv-dv's illegal-CSR stream).
               # The full map of which CSRs exist on each: tools/csr_map.py.
               "--pmpregions=0", "--triggers=0",
               f"--pc={args.base}",          # no boot ROM without the dtb
               "--log-commits", "-l", args.elf]
        if args.tohost:
            # A program that ends in a loop around the tohost store (riscv-dv)
            # never stops Spike by itself: bound it by the length of the RTL log.
            # Spike runs in slices of 5000 instructions, and a trap ends the slice
            # it is in but is charged the whole slice. The bound therefore allows
            # one slice per trap in the RTL log; a smaller one makes Spike stop at
            # the first trap (seen: 84 instructions logged of a 241-instruction run).
            nrtl = ntrap = 0
            with open(args.rtl, errors="replace") as f:
                for line in f:
                    w = line.split()
                    if w and w[0] == "TRAP":
                        ntrap += 1
                    elif len(w) == 3 and w[0] != "CSR":
                        nrtl += 1
            cmd.insert(1, f"--instructions={nrtl + 5000 * (ntrap + 2)}")
        with open(spike_log, "w") as f:
            subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=f, timeout=600)

    if not spike_log:
        sys.exit("lockstep: need --elf or --spike-log")

    gold, gst = parse_spike(spike_log, args.limit, int(args.tohost, 16) if args.tohost else None)
    rtl, rst = parse_rtl(args.rtl, args.limit)
    gold, rtl = truncate_at_selfloop(gold), truncate_at_selfloop(rtl)
    if args.tohost:
        th = int(args.tohost, 16)
        end = [m[0] for m in gst.mem if m[1] == th and m[3] != 0]
        if end:
            gold = gold[:end[0] + 1]

    if not gold:
        sys.exit(f"lockstep: no commits parsed from {spike_log}")
    if not rtl:
        sys.exit(f"lockstep: no commits parsed from {args.rtl}")

    n = min(len(gold), len(rtl))
    diverge = [i for i in range(n) if gold[i] != rtl[i]]

    if not args.quiet:
        print(f"lockstep: spike={len(gold)} rtl={len(rtl)} compared={n}")

    if not diverge and len(rtl) > len(gold) + 3:
        # The other way round is not a match either: instructions the RTL retired
        # were never compared, because Spike stopped or its log was cut short.
        print(f"MISMATCH: Spike's log ends {len(rtl) - len(gold)} instructions before the RTL's "
              f"(last common pc={gold[-1][0]:08x}) - {len(rtl) - len(gold)} RTL instructions not compared")
        return 1

    if not diverge:
        # A shorter RTL log is expected: tb_boot terminates on the tohost bus
        # write, which lands a cycle or two before that store's own retirement.
        tail = len(gold) - len(rtl)
        if tail > 3:
            print(f"MISMATCH: RTL log ends {tail} instructions early "
                  f"(last common pc={rtl[-1][0]:08x}) - core stopped retiring")
            return 1
        if rst is None:                       # a version 1 log: nothing more to compare
            print(f"MATCH: {n} instructions identical")
            return 0
        hx = lambda v: "--------" if v is None else f"{v:08x}"
        nm, e1 = compare_stream("stores", gst.mem, rst.mem, n,
                                lambda x: f"[{x[1]:08x}] <- {x[3]:0{2 * x[2]}x} ({x[2]} bytes)")
        nt, e2 = compare_stream("traps", gst.trap, rst.trap, n,
                                lambda x: f"cause={x[1] if isinstance(x[1], str) else format(x[1], '08x')} "
                                          f"epc={x[2]:08x} tval={hx(x[3])}", trap_same)
        nc, e3 = compare_stream("CSR instructions", gst.csr, rst.csr, n,
                                lambda x: f"csr {x[1]:03x} = {hx(x[2])}", csr_same)
        for e in (e1, e2, e3):
            if e:
                print(e)
                return 1
        g = [x for x in gst.csr if x[0] < n]
        r = [x for x in rst.csr if x[0] <= n]
        valued = sum(1 for k in range(nc) if g[k][2] is not None and r[k][2] is not None)
        print(f"MATCH: {n} instructions identical; {nm} stores, {nt} traps, "
              f"{nc} CSR instructions ({valued} with a value) identical")
        return 0

    print(f"\nDIVERGE at instruction {diverge[0]} of {n}")
    for i in diverge[:args.max]:
        print(f"\n--- instruction {i} ---")
        for k in range(max(0, i - 3), i):
            print(f"  ok   {fmt(gold[k])[2:]}")
        print(f"  spike{fmt(gold[i])}")
        print(f"  rtl  {fmt(rtl[i])}")
    if len(diverge) > args.max:
        print(f"\n... and {len(diverge) - args.max} more "
              f"(all downstream of the first - fix that one and re-run)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
