#!/usr/bin/env python3
"""rvfi_check.py -- plan 5.1 acceptance: the RVFI port agrees with the probe.

    python3 tools/rvfi_check.py <commit.log> <rvfi.log>

The commit log written by tb_boot's probe and the one written from the core's
RVFI port (tb_boot built with GARUDA_RVFI, +RVFI_LOG) must agree line for line
on retirements ("<pc> <rd> <wdata>") and stores ("MEM <addr> <size> <data>"),
and the RVFI trap records ("TRAPREC <pc> <insn>") must be as many as the
probe's TRAP lines, at the same PCs. RVFI emits one cycle after the
retirement and the run stops at the tohost store, so the RVFI log may lack the
last record(s) at the very end (at most 2); anything else is a mismatch.
Exit 0 on agreement.
"""
import sys


def load(path):
    ret, trap = [], []
    for ln in open(path):
        ln = ln.strip()
        if not ln or ln.startswith("#") or ln.startswith("CSR"):
            continue
        if ln.startswith("TRAP "):          # TRAP <cause> <pc> <tval>
            if int(ln.split()[1], 16) & 0x80000000:
                continue                    # an interrupt: no RVFI trap record (the
                                            # interrupted instruction is not executed)
            trap.append(ln.split()[2])
        elif ln.startswith("TRAPREC "):     # TRAPREC <pc> <insn>
            trap.append(ln.split()[1])
        else:
            ret.append(ln)
    return ret, trap


def main():
    a_ret, a_trap = load(sys.argv[1])
    b_ret, b_trap = load(sys.argv[2])
    n = min(len(a_ret), len(b_ret))
    for i in range(n):
        if a_ret[i] != b_ret[i]:
            print(f"MISMATCH at record {i}: probe '{a_ret[i]}'  rvfi '{b_ret[i]}'")
            return 1
    if len(b_ret) > len(a_ret) or len(a_ret) - len(b_ret) > 2:
        print(f"MISMATCH: probe {len(a_ret)} records, rvfi {len(b_ret)}")
        return 1
    if a_trap[:len(b_trap)] != b_trap or len(a_trap) - len(b_trap) > 1:
        print(f"MISMATCH: traps probe {a_trap[:8]}... ({len(a_trap)}) rvfi {b_trap[:8]}... ({len(b_trap)})")
        return 1
    print(f"RVFI MATCH: {n} records identical, {len(b_trap)} trap records at the probe's trap PCs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
