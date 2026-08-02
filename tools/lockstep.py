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


def parse_spike(path, limit=0):
    out = []
    with open(path, errors="replace") as f:
        for line in f:
            m = SPIKE_COMMIT.match(line)
            if not m:
                continue                      # disassembly / exception lines
            pc = int(m.group(2), 16) & 0xFFFFFFFF
            tail = m.group(4)
            rd, val = 0, 0
            rm = SPIKE_REGWR.search(tail)
            if rm:
                r = int(rm.group(1))
                if r != 0:                    # x0 writes are not architectural
                    rd = r
                    val = int(rm.group(2), 16) & 0xFFFFFFFF
            out.append((pc, rd, val))
            if limit and len(out) >= limit:
                break
    return out


def parse_rtl(path, limit=0):
    out = []
    with open(path, errors="replace") as f:
        for line in f:
            p = line.split()
            if len(p) != 3:
                continue
            try:
                out.append((int(p[0], 16), int(p[1], 10), int(p[2], 16)))
            except ValueError:
                continue
            if limit and len(out) >= limit:
                break
    return out


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
    ap.add_argument("--isa", default="rv32im_zicsr")
    ap.add_argument("--base", default="0x10000000")
    ap.add_argument("--size", default="0x40000")
    ap.add_argument("--max", type=int, default=5, help="divergences to print")
    ap.add_argument("--limit", type=int, default=0, help="max instrs compared")
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
               f"--pc={args.base}",          # no boot ROM without the dtb
               "--log-commits", "-l", args.elf]
        with open(spike_log, "w") as f:
            subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=f, timeout=600)

    if not spike_log:
        sys.exit("lockstep: need --elf or --spike-log")

    gold = truncate_at_selfloop(parse_spike(spike_log, args.limit))
    rtl = truncate_at_selfloop(parse_rtl(args.rtl, args.limit))

    if not gold:
        sys.exit(f"lockstep: no commits parsed from {spike_log}")
    if not rtl:
        sys.exit(f"lockstep: no commits parsed from {args.rtl}")

    n = min(len(gold), len(rtl))
    diverge = [i for i in range(n) if gold[i] != rtl[i]]

    if not args.quiet:
        print(f"lockstep: spike={len(gold)} rtl={len(rtl)} compared={n}")

    if not diverge:
        # A shorter RTL log is expected: tb_boot terminates on the tohost bus
        # write, which lands a cycle or two before that store's own retirement.
        tail = len(gold) - len(rtl)
        if tail > 3:
            print(f"MISMATCH: RTL log ends {tail} instructions early "
                  f"(last common pc={rtl[-1][0]:08x}) - core stopped retiring")
            return 1
        print(f"MATCH: {n} instructions identical")
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
