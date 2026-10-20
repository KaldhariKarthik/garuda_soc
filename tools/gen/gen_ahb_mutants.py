#!/usr/bin/env python3
"""gen_ahb_mutants.py -- bus plan B1 A9 (Karthik's recipe R10): the AHB interconnect
planted-defect run.

    python3 tools/gen/gen_ahb_mutants.py      (writes tb/ahb/mut/*_mut_<id>.v + tb/ahb/run/ahb_mut.toml)

Each mutant is one realistic defect applied to a copy of one rtl/ahb file (the pattern
must match exactly once, so a mutant follows the RTL as it changes): the reverts of
the four interconnect errata AHB-1..AHB-4 plus defects in every sub-module. Each runs
tb_ahb_env +TEST=mut: every directed test in one run, no random phase (the kill rule
of the plan), with the bound properties, the conservation scoreboard and the five
AHB-Lite checkers. A kill counts only when a NAMED check fires (fail_reason: a
[FAIL] line or an ahb_ic_props_a assertion); a timeout or crash is not a kill.
Rows are PLANTED in tb/ahb/run/xfail.tsv; a mutant that passes is an XPASS error and
gets an analysis, or is listed EQUIVALENT below with the argument and not run.
Run: make -f flow/mk/track_a_run.mk ahb_mut
"""
import os

R = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
KILL = r"^\[FAIL\] |Assertion failed in \S*u_ahb_props_a\."
# id, file, pattern, replacement, what it models
MUTANTS = [
 ("A01", "ahb_master_mux.v", "case (dph_master_i)", "case (grant_i)", "AHB-1 reverted: HWDATA follows the address-phase grant"),
 ("A02", "ahb_master_port.v", "wire capture = dph_own_i && !granted_i && presenting && hready_shared_i;",
  "wire capture = 1'b0;", "AHB-2 reverted: no response hold for a preempted master"),
 ("A03", "ahb_arbiter.v", "assign seq_break_o = ~last_owner_v || (last_owner_r != grant_o);", "assign seq_break_o = 1'b0;",
  "AHB-3 reverted: an interrupted SEQ is not re-opened as NONSEQ"),
 ("A04", "ahb_master_port.v", "assign hready_o = pending ? (hready_shared_i && entitled) : 1'b1;",
  "assign hready_o = hready_shared_i && entitled;", "AHB-4 reverted: the hold rule gates an idle master too"),
 ("A05", "ahb_arbiter.v", "    wire [1:0] winner = req[`AHB_M_DMA]   ? `AHB_M_DMA   :\n                        req[`AHB_M_SBA]   ? `AHB_M_SBA   :",
  "    wire [1:0] winner = req[`AHB_M_SBA]   ? `AHB_M_SBA   :\n                        req[`AHB_M_DMA]   ? `AHB_M_DMA   :", "priority: SBA above DMA"),
 ("A06", "ahb_arbiter.v", "                        req[`AHB_M_SBA]   ? `AHB_M_SBA   :\n                        req[`AHB_M_DPORT] ? `AHB_M_DPORT :",
  "                        req[`AHB_M_DPORT] ? `AHB_M_DPORT :\n                        req[`AHB_M_SBA]   ? `AHB_M_SBA   :", "priority: D-port above SBA"),
 ("A07", "ahb_decoder.v", "`AHB_RGN_DSRAM : hsel_o[`AHB_S_DSRAM ] = 1'b1;", "4'h3           : hsel_o[`AHB_S_DSRAM ] = 1'b1;",
  "decode: DSRAM decoded at nibble 3"),
 ("A08", "ahb_decoder.v", "`AHB_RGN_BRIDGE: hsel_o[`AHB_S_BRIDGE] = 1'b1;", "4'h5          : hsel_o[`AHB_S_BRIDGE] = 1'b1;",
  "decode: the bridge decoded at nibble 5"),
 ("A09", "ahb_arbiter.v", "assign grant_o = hold_r ? grant_r : winner;", "assign grant_o = winner;",
  "grant freeze removed: the grant moves under a waited address phase"),
 ("A10", "ahb_arbiter.v", "            dph_valid_o  <= granted_htrans[1];", "            dph_valid_o  <= 1'b1;",
  "data-phase tracker: an IDLE cycle counts as a data phase"),
 ("A11", "ahb_arbiter.v", "        end else if (hready_i) begin\n            dph_valid_o  <= granted_htrans[1];",
  "        end else begin\n            dph_valid_o  <= granted_htrans[1];", "data-phase tracker updated in wait states"),
 ("A12", "ahb_default_slave.v", "S_ERR1:  begin hreadyout_o = 1'b0; hresp_o = `AHB_RESP_ERROR; end",
  "S_ERR1:  begin hreadyout_o = 1'b1; hresp_o = `AHB_RESP_ERROR; end", "default slave: one-cycle ERROR"),
 ("A13", "ahb_default_slave.v", "wire accept = hsel_i && hready_i && htrans_i[1];", "wire accept = 1'b0;",
  "default slave: an undecoded access answers OKAY"),
 ("A14", "ahb_slave_mux.v", "        else if (hready_o)\n            dph_sel_o <= hsel_i;", "        else\n            dph_sel_o <= hsel_i;",
  "slave mux: the data-phase select moves in a wait state"),
 ("A15", "ahb_master_port.v", "assign hresp_o  = hold_valid ? hold_resp :\n                      dph_own_i  ? hresp_shared_i : `AHB_RESP_OKAY;",
  "assign hresp_o  = hold_valid ? hold_resp : hresp_shared_i;", "HRESP broadcast to every master"),
 ("A16", "ahb_master_port.v", "assign hrdata_o = hold_valid ? hold_data :\n                      dph_own_i  ? hrdata_shared_i : 32'h0000_0000;",
  "assign hrdata_o = dph_own_i ? hrdata_shared_i : hold_data;", "a held read is overridden by the live bus"),
 ("A17", "ahb_master_port.v", "wire entitled = granted_i || (dph_own_i && !presenting);", "wire entitled = granted_i || dph_own_i;",
  "a presenting data-phase owner sees HREADY: its next address phase is wrongly accepted"),
 ("A18", "ahb_master_port.v", "        end else if (hold_valid && hready_o) begin", "        end else if (1'b0) begin",
  "a held response is never released (replayed forever)"),
 ("A19", "ahb_master_mux.v", "if (seq_break_i && (htrans_sel == `AHB_TRANS_SEQ))", "if (seq_break_i && (htrans_sel == `AHB_TRANS_NONSEQ))",
  "AHB-3 rewrite inverted: a NONSEQ after an owner change becomes NONSEQ->NONSEQ, a SEQ passes"),
 ("A20", "ahb_interconnect.v", "assign hmaster_is_sba_o = (grant == `AHB_M_SBA);", "assign hmaster_is_sba_o = (grant == `AHB_M_DMA);",
  "SBA indication marks the DMA (ISRAM lock bypassed for the wrong master)"),
 ("A21", "ahb_master_mux.v", "hprot_o    = `AHB_HPROT_DMA;   // Sec. 7.6 substitution", "hprot_o    = 4'b0001;   // Sec. 7.6 substitution",
  "DMA HPROT substitution wrong"),
 ("A22", "ahb_master_mux.v", "            `AHB_M_SBA: begin\n                haddr_o    = s_haddr_i;",
  "            `AHB_M_SBA: begin\n                haddr_o    = d_haddr_i;", "SBA address phase carries the D-port's address"),
]
# Mutants proven equivalent (not run; each keeps a formal proof in tb/ahb/formal/ahb.toml):
#  A10 dph_valid set after an IDLE cycle: the "phantom" data phase points at a slave that
#      has no data phase, which answers HREADY high + OKAY, so HREADY, HRESP and the
#      return to every master that has a transfer outstanding are unchanged; a phantom
#      capture is delivered only in the cycle the master's own address phase is accepted,
#      when no data is due. equiv_a10 PROVES every property except a_hold_not_owner (which
#      a phantom owner breaks by construction).
#  A16 hold vs live read-data priority swapped: equivalent because a held response and
#      data-phase ownership never overlap -- a_hold_not_owner, PROVEN in ahb_prove;
#      equiv_a16 PROVES every property with the mutant.
EQUIVALENT = ["A10", "A16"]


def main():
    os.makedirs(os.path.join(R, "tb/ahb/mut"), exist_ok=True)
    rows = []
    for mid, f, pat, rep, what in MUTANTS:
        if mid in EQUIVALENT:
            continue
        src = open(os.path.join(R, "rtl/ahb", f)).read()
        n = src.count(pat)
        if n != 1:
            sys.exit(f"{mid}: pattern matches {n} times in rtl/ahb/{f}")
        out = f"tb/ahb/mut/{f[:-2]}_mut_{mid.lower()}.v"
        open(os.path.join(R, out), "w").write(f"// MUTANT {mid} (bus plan B1 A9): {what}\n" + src.replace(pat, rep))
        rows.append((mid, f, out, what))
    with open(os.path.join(R, "tb/ahb/run/ahb_mut.toml"), "w") as m:
        m.write("# Bus plan B1 A9 / recipe R10: AHB interconnect planted defects. GENERATED by\n"
                "# tools/gen/gen_ahb_mutants.py -- do not edit by hand. Every row must FAIL for a\n"
                "# NAMED check (PLANTED in tb/ahb/run/xfail.tsv). Run: make -f flow/mk/track_a_run.mk ahb_mut\n"
                "[suite]\nblock = \"ahb\"\nname  = \"ahb_mut\"\nkind  = \"sim\"\nxfail = \"tb/ahb/run/xfail.tsv\"\n\n"
                "[defaults]\nmarker  = '^RESULT: PASSED'\ntimeout = 1800\n")
        for mid, f, out, what in rows:
            m.write(f'\n# {mid}: {what}\n[[test]]\nname = "mut_{mid.lower()}"\nflist = "tb/ahb/env/filelist_ahb_env.f"\n'
                    f'top = "tb_ahb_env"\nplusargs = ["+TEST=mut"]\nreplace = {{ "rtl/ahb/{f}" = "{out}" }}\n'
                    f"fail_reason = '{KILL}'\n")
    xf = os.path.join(R, "tb/ahb/run/xfail.tsv")
    keep = [l for l in open(xf) if not l.startswith("ahb_mut\t")]
    with open(xf, "w") as x:
        x.writelines(keep)
        for mid, f, out, what in rows:
            x.write(f"ahb_mut\tmut_{mid.lower()}\tFAIL\tPLANTED\t{what}\n")
    print(f"gen_ahb_mutants: {len(rows)} mutants, manifest tb/ahb/run/ahb_mut.toml")


if __name__ == "__main__":
    import sys
    main()
