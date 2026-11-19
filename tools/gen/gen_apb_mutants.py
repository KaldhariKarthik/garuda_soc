#!/usr/bin/env python3
"""gen_apb_mutants.py -- bus plan B2 (Karthik's recipe R10): the AHB-to-APB bridge
planted-defect run.

    python3 tools/gen/gen_apb_mutants.py      (writes tb/ahb2apb/mut/*_mut_<id>.v + tb/ahb2apb/run/apb_mut.toml)

Each mutant is one realistic defect applied to a copy of one rtl/ahb2apb file (the
pattern must match exactly once, so a mutant follows the RTL as it changes): the BRG-1
and APB-2 reverts plus defects in every sub-module (hclk FSM, pclk FSM, fabric). Each
runs tb_apb_env +TEST=mut: every directed test in one run, no random phase, with the
bound properties (ahb2apb_sva), the scoreboard and twelve APB checkers. P14 (a fabric defect that only shows with a target driving PSLVERR while not
selected, which APB recommends against but allows) runs on the fabric's own unit bench,
tb_apb_units +UNIT=fabric, which drives every window's PSLVERR at random. A kill counts
only when a NAMED check fires (fail_reason: a [FAIL] line or an ahb2apb_sva assertion);
a timeout or crash is not a kill. Rows are PLANTED in tb/ahb2apb/run/xfail.tsv; a
survivor is an XPASS error and gets an analysis or an equivalence proof.
Run: make -f flow/mk/track_a_run.mk apb_mut
"""
import os, sys

R = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
KILL = r"^\[FAIL\] |Assertion failed in \S*u_apb_sva\.|\[SVA-FAIL\]"
B, F, X = "ahb2apb_bridge.sv", "ahb2apb_apb_fsm.sv", "ahb2apb_fabric.sv"
H, P = "brg_ahb_fsm.sv", "apb_phase_fsm.sv"  # the two state machines (F4, 2026-11-17)
MUTANTS = [
 ("P01", H, "                end else if (xfer_i) begin", "                end else if (xfer_i && hstate == H_IDLE) begin",
  "BRG-1 reverted: a new transfer is accepted only from H_IDLE"),
 ("P02", B, "    wire       win_ok  = WINDOW_MASK[win] && ~|haddr_i[27:16];", "    wire       win_ok  = WINDOW_MASK[win];",
  "APB-2 reverted: no aperture check"),
 ("P03", B, "    wire       word_ok = (hsize_i == 3'b010);", "    wire       word_ok = 1'b1;", "sub-word accesses passed to APB"),
 ("P04", F, "    wire to_last = (to_cnt == TO_CNT_W'(TIMEOUT - 32'd1));", "    wire to_last = (to_cnt == TO_CNT_W'(TIMEOUT - 32'd2));",
  "timeout one sample early (15)"),
 ("P05", F, "    wire to_last = (to_cnt == TO_CNT_W'(TIMEOUT - 32'd1));", "    wire to_last = (to_cnt == TO_CNT_W'(TIMEOUT));",
  "timeout one sample late (17)"),
 ("P06", F, "        assign win_hot[k] = (win_i == APB_WIN_W'(k));", "        assign win_hot[k] = ((win_i ^ 4'd1) == APB_WIN_W'(k));",
  "PSEL on the neighbouring window"),
 ("P07", F, "            psel_o <= win_hot;\n", "            psel_o <= win_hot;\n            penable_o <= 1'b1;\n",
  "PENABLE with PSEL (no SETUP cycle)"),
 ("P08", H, "                hreadyout_o = prst_ok_i;", "                hreadyout_o = 1'b1;", "[N-9.2] gate removed: HREADYOUT while PRESET is asserted"),
 ("P09", H, "                hresp_o = 1'b1;\n                hstate_next = H_ERR2;", "                hresp_o = 1'b1;\n                hstate_next = H_IDLE;",
  "one-cycle ERROR (no second cycle)"),
 ("P10", B, "            hrdata_o <= apb_rdata;", "            hrdata_o <= 32'd0;", "read data not returned"),
 ("P11", B, "            wdata_cap <= hwdata_i;", "            wdata_cap <= wdata_cap;",
  "write data not captured (the previous write's data goes out)"),
 ("P12", F, "            div_cnt <= div_load;", "            div_cnt <= 3'd0;", "APB_DIV ignored: every window /1"),
 ("P13", F, "            err_o <= done_ok ? pslverr_sel_i : 1'b1;", "            err_o <= done_ok ? 1'b0 : 1'b1;",
  "PSLVERR ignored: an erroring target answers OKAY"),
 ("P14", X, "    assign pslverr_o = |(psel_i & pslverr_i);", "    assign pslverr_o = |pslverr_i;", "fabric: PSLVERR from any window, not the selected one"),
 ("P15", P, "            default: begin  // P_DONE: one idle pclk\n                state_next = P_IDLE;",
  "            default: begin  // P_DONE: one idle pclk\n                done_ok_o = 1'b1;\n                state_next = P_IDLE;",
  "a second acknowledge toggle after DONE (one request, two responses)"),
 ("P16", B, "    wire       allowed = win_ok && word_ok;", "    wire       allowed = word_ok;",
  "absent / out-of-aperture windows passed to APB (only sub-word rejected)"),
 # unit-bench negative control (tb/ahb2apb/run/units.toml): written, not in the mutation run
 ("RDY", X, "    assign pready_o  = |(psel_i & pready_i);", "    assign pready_o  = |({psel_i[10:0], psel_i[11]} & pready_i);",
  "PREADY taken from the neighbouring window"),
]
UNIT_ONLY = ["RDY"]


UNIT_FABRIC = {"P14"}


def main():
    os.makedirs(os.path.join(R, "tb/ahb2apb/mut"), exist_ok=True)
    rows = []
    for mid, f, pat, rep, what in MUTANTS:
        src = open(os.path.join(R, "rtl/ahb2apb", f)).read()
        n = src.count(pat)
        if n != 1:
            sys.exit(f"{mid}: pattern matches {n} times in rtl/ahb2apb/{f}")
        out = f"tb/ahb2apb/mut/{f[:-3]}_mut_{mid.lower()}.v"
        open(os.path.join(R, out), "w").write(f"// MUTANT {mid} (bus plan B2): {what}\n" + src.replace(pat, rep))
        if mid not in UNIT_ONLY:
            rows.append((mid, f, out, what))
    with open(os.path.join(R, "tb/ahb2apb/run/apb_mut.toml"), "w") as m:
        m.write("# Bus plan B2 / recipe R10: AHB-to-APB bridge planted defects. GENERATED by\n"
                "# tools/gen/gen_apb_mutants.py -- do not edit by hand. Every row must FAIL for a\n"
                "# NAMED check (PLANTED in tb/ahb2apb/run/xfail.tsv). Run: make -f flow/mk/track_a_run.mk apb_mut\n"
                "[suite]\nblock = \"ahb2apb\"\nname  = \"apb_mut\"\nkind  = \"sim\"\nxfail = \"tb/ahb2apb/run/xfail.tsv\"\n\n"
                "[defaults]\nmarker  = '^RESULT: PASSED'\ntimeout = 1800\n")
        for mid, f, out, what in rows:
            if mid in UNIT_FABRIC:
                bench = ('flist = "tb/ahb2apb/units/filelist_apb_units.f"\ntop = "tb_apb_units"\n'
                         'plusargs = ["+UNIT=fabric", "+CYCLES=5000"]\n')
            else:
                bench = ('flist = "tb/ahb2apb/env/filelist_apb_env.f"\ntop = "tb_apb_env"\n'
                         'plusargs = ["+TEST=mut"]\ndefines = ["APB_ENV_DIV=24\'hE4E4E4"]\n')
            m.write(f'\n# {mid}: {what}\n[[test]]\nname = "mut_{mid.lower()}"\n{bench}'
                    f'replace = {{ "rtl/ahb2apb/{f}" = "{out}" }}\nfail_reason = \'{KILL}\'\n')
    xf = os.path.join(R, "tb/ahb2apb/run/xfail.tsv")
    keep = [l for l in open(xf) if not l.startswith("apb_mut\t")]
    with open(xf, "w") as x:
        x.writelines(keep)
        for mid, f, out, what in rows:
            x.write(f"apb_mut\tmut_{mid.lower()}\tFAIL\tPLANTED\t{what}\n")
    print(f"gen_apb_mutants: {len(rows)} mutants, manifest tb/ahb2apb/run/apb_mut.toml")


if __name__ == "__main__":
    main()
