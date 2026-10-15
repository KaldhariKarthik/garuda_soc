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
B, F, X = "ahb2apb_bridge.v", "ahb2apb_apb_fsm.v", "ahb2apb_fabric.v"
MUTANTS = [
 ("P01", B, "                H_IDLE, H_OK, H_ERR2: begin", "                H_IDLE: begin", "BRG-1 reverted: a new transfer is accepted only from H_IDLE"),
 ("P02", B, "    wire       win_ok  = WINDOW_MASK[win] && (haddr_i[27:16] == 12'h000);", "    wire       win_ok  = WINDOW_MASK[win];",
  "APB-2 reverted: no aperture check"),
 ("P03", B, "    wire       word_ok = (hsize_i == 3'b010);", "    wire       word_ok = 1'b1;", "sub-word accesses passed to APB"),
 ("P04", F, "                    end else if (to_cnt == TIMEOUT - 1) begin", "                    end else if (to_cnt == TIMEOUT - 2) begin",
  "timeout one sample early (15)"),
 ("P05", F, "                    end else if (to_cnt == TIMEOUT - 1) begin", "                    end else if (to_cnt == TIMEOUT) begin",
  "timeout one sample late (17)"),
 ("P06", F, "                        psel_o   <= 12'd1 << win_i;", "                        psel_o   <= 12'd1 << (win_i ^ 4'd1);", "PSEL on the neighbouring window"),
 ("P07", F, "                        psel_o   <= 12'd1 << win_i;\n                        state    <= P_SETUP;",
  "                        psel_o   <= 12'd1 << win_i;\n                        penable_o <= 1'b1;\n                        state    <= P_SETUP;",
  "PENABLE with PSEL (no SETUP cycle)"),
 ("P08", B, "    assign hreadyout_o = prst_ok_q &&", "    assign hreadyout_o = 1'b1 &&", "[N-9.2] gate removed: HREADYOUT while PRESET is asserted"),
 ("P09", B, "                H_ERR1:  hstate <= H_ERR2;", "                H_ERR1:  hstate <= H_IDLE;", "one-cycle ERROR (no second cycle)"),
 ("P10", B, "                        hrdata_o <= apb_rdata;", "                        hrdata_o <= 32'd0;", "read data not returned"),
 ("P11", B, "                    if (write_cap) wdata_cap <= hwdata_i;", "                    if (write_cap) wdata_cap <= wdata_cap;",
  "write data not captured (the previous write's data goes out)"),
 ("P12", F, "                    div_cnt   <= div_load;", "                    div_cnt   <= 3'd0;", "APB_DIV ignored: every window /1"),
 ("P13", F, "                        err_o     <= pslverr_sel_i;", "                        err_o     <= 1'b0;", "PSLVERR ignored: an erroring target answers OKAY"),
 ("P14", X, "    assign pslverr_o = |(psel_i & pslverr_i);", "    assign pslverr_o = |pslverr_i;", "fabric: PSLVERR from any window, not the selected one"),
 ("P15", F, "                default: state <= P_IDLE;                // P_DONE: one idle pclk",
  "                default: begin state <= P_IDLE; ack_tgl_o <= ~ack_tgl_o; end   // P_DONE: one idle pclk",
  "a second acknowledge toggle after DONE (one request, two responses)"),
 ("P16", B, "                        if (!win_ok || !word_ok) begin", "                        if (!word_ok) begin",
  "absent / out-of-aperture windows passed to APB (only sub-word rejected)"),
]


UNIT_FABRIC = {"P14"}


def main():
    os.makedirs(os.path.join(R, "tb/ahb2apb/mut"), exist_ok=True)
    rows = []
    for mid, f, pat, rep, what in MUTANTS:
        src = open(os.path.join(R, "rtl/ahb2apb", f)).read()
        n = src.count(pat)
        if n != 1:
            sys.exit(f"{mid}: pattern matches {n} times in rtl/ahb2apb/{f}")
        out = f"tb/ahb2apb/mut/{f[:-2]}_mut_{mid.lower()}.v"
        open(os.path.join(R, out), "w").write(f"// MUTANT {mid} (bus plan B2): {what}\n" + src.replace(pat, rep))
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
