#!/usr/bin/env python3
"""garuda_dv_gen.py -- riscv-dv (pygen) random programs for GARUDA (plan 5.5).

    garuda_dv_gen.py --test <name> --seed N --out DIR [-- <extra pygen options>]

Runs the pinned riscv-dv pygen generator (~/tools/src/riscv-dv, PINS) with the
GARUDA target in tb/core/riscv_dv/pygen_overlay/pygen_src/target/garuda.
pygen_src and pygen_src.target are namespace packages, so putting the overlay
on sys.path merges the GARUDA target in (the checkout stays untouched).
Writes DIR/<test>_s<seed>.S. The tests and their generator options are the
ones of the existing xrun flow (tb/core/riscv_dv/testlist, `make riscv_dv`):
one list for both generators, the SV options `+opt=val` passed to pygen as
`--opt=val`. The program is built with tb/core/riscv_dv/link.ld and run in
tb_boot under Spike co-simulation (tools/gen/build_riscv_dv.py writes the manifest).
"""
import argparse, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
DV = os.environ.get("RISCV_DV", os.path.expanduser("~/tools/src/riscv-dv"))
OVERLAY = os.path.join(ROOT, "tb", "core", "riscv_dv", "pygen_overlay")

sys.path.insert(0, HERE)
ap = argparse.ArgumentParser()
ap.add_argument("--test", required=True)
ap.add_argument("--seed", type=int, required=True)
ap.add_argument("--out", required=True)
a, extra = ap.parse_known_args()
from garuda_dv_gen_list import load_testlist  # noqa: E402

TESTS = load_testlist()


out = os.path.abspath(a.out)
os.makedirs(out, exist_ok=True)
gen, opts = TESTS[a.test]
# pygen (riscv-dv 0d71c2b) lacks parts of the SV generator: sub-programs
# (riscv_asm_program_gen.callstack_gen), the streams below (not ported, or
# riscv_loop_instr: constraints never solve), an EBREAK template, and a usable
# riscv_rand_instr_test (its constructor forces 5 sub-programs). Those options
# are dropped here and listed in the program header; the full list runs on the
# SV generator (xrun flow, `make riscv_dv`).
PYGEN_UNSUPPORTED_STREAMS = {"riscv_loop_instr", "riscv_multi_page_load_store_instr_stream",
                             "riscv_hazard_instr_stream", "riscv_mem_region_stress_test"}
dropped, kept = [], []
if gen == "riscv_rand_instr_test":
    dropped.append("gen_test=riscv_rand_instr_test (run as riscv_instr_base_test)")
    gen = "riscv_instr_base_test"
for o in opts:
    k, _, v = o[2:].partition("=")
    if k == "num_of_sub_program" and v != "0":
        dropped.append(o); kept.append("--num_of_sub_program=0")
    elif k.startswith("directed_instr_") and v.split(",")[0] in PYGEN_UNSUPPORTED_STREAMS:
        dropped.append(o)
    elif k == "no_ebreak" and v == "0":
        dropped.append(o)
    elif k == "illegal_instr_ratio":          # pyvsc never solves riscv_illegal_instr
        dropped.append(o)
    else:
        kept.append(o)
if not any(o.startswith("--num_of_sub_program") for o in kept):
    kept.append("--num_of_sub_program=0")       # sub-programs need callstack_gen
# GARUDA: no compressed code; the trap vector 64-byte aligned (CLIC mtvec base)
opts = ["--disable_compressed_instr=1", "--tvec_alignment=6"] + kept + [x for x in extra if x != "--"]
sys.argv = ([f"{gen}.py", "--target=garuda", f"--gen_test={gen}",
             "--num_of_tests=1", "--start_idx=0", f"--seed={a.seed}",
             f"--asm_file_name={out}/{a.test}_s{a.seed}",
             f"--log_file_name={out}/{a.test}_s{a.seed}.gen.log"] + opts)
# pygen sometimes emits `la zero, <label>` (x0 as a load/store base; the SV
# generator excludes x0 there), which no assembler accepts. Such a program is
# regenerated with the next generator seed (seed + 100000 * k), recorded in the
# header, so the program still reproduces from its name. pygen runs in a child
# Python (cwd = the riscv-dv checkout, overlay first on sys.path).
gseed, src = a.seed, f"{out}/{a.test}_s{a.seed}_0.S"
for k in range(4):
    gseed = a.seed + 100000 * k
    argv = [x if not x.startswith("--seed=") else f"--seed={gseed}" for x in sys.argv]
    r = subprocess.run([sys.executable, "-c",
                        "import runpy,sys; sys.argv=%r; sys.path[:0]=%r; "
                        "runpy.run_path(%r, run_name='__main__')" %
                        (argv, [os.path.join(DV, "pygen"), OVERLAY],
                         os.path.join(DV, "pygen", "pygen_src", "test", f"{gen}.py"))], cwd=DV)
    if r.returncode or not os.path.exists(src):
        sys.exit(f"generator failed (seed {gseed})")
    if not re.search(r"^\s*la\s+zero\s*,", open(src).read(), re.M):
        break
    os.remove(src)
else:
    sys.exit("generator kept emitting `la zero` (4 seeds)")
body = open(src).read()
hdr = (f"# riscv-dv pygen, GARUDA target: test {a.test} ({gen}), seed {a.seed}"
       + (f" (generator seed {gseed}: `la zero` retry)" if gseed != a.seed else "") + "\n"
       f"# options: {' '.join(opts)}\n"
       f"# dropped (pygen limits): {' '.join(dropped) if dropped else 'none'}\n")
open(f"{out}/{a.test}_s{a.seed}.S", "w").write(hdr + body)
os.remove(src)
print(f"wrote {out}/{a.test}_s{a.seed}.S" + (f" (dropped: {' '.join(dropped)})" if dropped else ""))
