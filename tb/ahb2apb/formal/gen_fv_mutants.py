#!/usr/bin/env python3
"""gen_fv_mutants.py -- cut the bridge's FORMAL negative controls (tb/ahb2apb/formal/mutants/, suite
fv_apb) from the CURRENT rtl/ahb2apb/ahb2apb_bridge.v. The simulation mutants have their own
generator (tools/gen/gen_apb_mutants.py, run by `make apb_mut`). Rerun after any change to the
bridge RTL. Each edit must match exactly once and change the text, or the script stops
(2026-11-01, APB-4: these copies were hand-made and had drifted from the RTL)."""
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
RTL = "rtl/ahb2apb/ahb2apb_bridge.v"
ACCEPT = "                H_IDLE, H_OK, H_ERR2: begin"
WIN = "    wire       win_ok  = WINDOW_MASK[win] && (haddr_i[27:16] == 12'h000);"
WORD = "    wire       word_ok = (hsize_i == 3'b010);"
ILLEGAL = "                            hstate <= prst_ok_q ? H_ERR1 : H_EWAIT;"

FV = "tb/ahb2apb/formal/mutants/ahb2apb_bridge_mut_{}.v"
MUTANTS = [
    (FV.format("apb2"), "MUTANT apb2 (bus plan B2 negative control): APB-2 revert: no aperture check",
     WIN, "    wire       win_ok  = WINDOW_MASK[win];"),
    (FV.format("brg1"), "MUTANT brg1 (bus plan B2 negative control): BRG-1 revert: a new transfer is accepted only from H_IDLE (back-to-back drops one)",
     ACCEPT, "                H_IDLE: begin"),
    (FV.format("subword"), "MUTANT subword (bus plan B2 negative control): sub-word accesses passed to APB",
     WORD, "    wire       word_ok = 1'b1;"),
    (FV.format("apb4"), "MUTANT apb4 (APB-4 negative control): an illegal access in the [N-9.2] window goes to ERROR at once",
     ILLEGAL, "                            hstate <= H_ERR1;"),
]


def main():
    src = open(os.path.join(ROOT, RTL)).read()
    for out, why, a, b in MUTANTS:
        if src.count(a) != 1:
            sys.exit(f"{out}: edit does not match exactly once in {RTL}: {a.strip()[:60]!r}")
        if a == b:
            sys.exit(f"{out}: the edit changes nothing")
        open(os.path.join(ROOT, out), "w").write(f"// {why} (GENERATED, gen_bridge_mutants.py)\n" + src.replace(a, b))
        print("wrote", out)


if __name__ == "__main__":
    main()
