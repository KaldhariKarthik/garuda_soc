#!/usr/bin/env python3
"""gen_dma_mutants.py -- DMA plan D8 (Karthik's recipe R10): the DMA planted-defect run.

    python3 tools/gen/gen_dma_mutants.py      (writes tb/dma/mut/*_mut_<id>.v + tb/dma/run/dma_mut.toml)

Each mutant is one realistic defect applied to a copy of one rtl/dma file (the
pattern must match exactly once, so a mutant follows the RTL as it changes). The
population is M01-M25 of the team's DMA bench comparison (~/garuda_soc/local/dma/
cmp/mut/mutants.py, read-only; anchors adapted to today's RTL, M21 is now the
AUD-13 revert) plus the reverts of every DMA fix. Each runs on the bench whose
checks should catch it:
  env   tb_dma_env +TEST=mut: every directed test + random iterations (model and
        scoreboard, pin-level beat checker, dma_sva, AHB-Lite and D-21 checkers)
  regs  tb_dma_regs: the register tests generated from Design_Docs/regs/dma.rdl
  block tb_dma_top: the team's directed bench (R-9 refusals, steps 10 and 13)
A kill counts only when a NAMED check fires (fail_reason: a [FAIL] check line or an
[SVA-FAIL]); a timeout or a crash is KILLED-OTHER and does not count. Rows are
PLANTED in tb/dma/run/xfail.tsv; a mutant that passes is an XPASS error and gets an
analysis. EQUIVALENT mutants are listed here with the argument and not run.
Evidence: tools/gen/gen_dma_mutants.py --summary -> logs/dma/evidence/dma_mut_<date>.txt
Run: make -f flow/mk/track_a.mk dma_mut
"""
import json, os, re, sys, datetime

R = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ENV, REGS, BLOCK = "env", "regs", "block"
# a named check; on the block bench the open DMA-10 detector fires on today's RTL by
# design (known in tb/dma/run/dma.toml), so it never counts as a kill
KILL = r"^\[FAIL\] |\[SVA-FAIL\] (?!a_no_read_before_refusal\b)"
E_WD_ERR = ("if (hresp_i) begin\n                            beat_err_o[ch] <= 1'b1; err_phase_o <= 3'd2;",
            "if (hresp_i) begin\n                            beat_err_o[ch] <= 1'b1; err_phase_o <= 3'd1;")
# id, file, pattern, replacement, bench, what it models
MUTANTS = [
 ("M01", "dma_chan.v", "if (hw_clr_en || (en_q && rem_q == 16'd0 && !wr_cr_i))",
  "if (!wr_cr_i && (hw_clr_en || (en_q && rem_q == 16'd0)))", ENV, "D-2 reverted: a software CR write beats the hardware EN clear"),
 ("M02", "dma_chan.v", "else if (beat_done_i) taken_q <= 1'b1;", "else if (beat_done_i || beat_err_i) taken_q <= 1'b1;", ENV,
  "DMA-8 reverted: a failed beat consumes the request"),
 ("M03", "dma_chan.v", "else if (beat_done_i) taken_q <= 1'b1;", "else if (1'b0) taken_q <= 1'b1;", ENV,
  "one beat per request lost: a request still high gives another beat"),
 ("M04", "dma_chan.v", "if (wdata_i[0] && !(beat_done_i && last)) comp_q <= 1'b0;", "if (wdata_i[0]) comp_q <= 1'b0;", ENV,
  "set-beats-clear reverted: ICLR beats a same-cycle COMPLETE set (completion lost)"),
 ("M05", "dma_chan.v", "(size_q == 2'd1) ? 32'd2 : 32'd4", "(size_q == 2'd1) ? 32'd1 : 32'd4", ENV, "halfword address step 1 instead of 2"),
 ("M06", "dma_chan.v", "if (wdata_i[2:1] != 2'b11) mode_q <= wdata_i[2:1];", "mode_q <= wdata_i[2:1];", REGS, "MODE = 3 accepted"),
 ("M07", "dma_chan.v", "assign error_irq_o    = err_q  & iee_q;", "assign error_irq_o    = err_q  & iec_q;", ENV,
  "error interrupt gated by IE_COMP instead of IE_ERR"),
 ("M08", "dma_chan.v", "if (wdata_i[1] && !beat_err_i) begin err_q <= 1'b0; errph_q <= 3'd0; end",
  "if (wdata_i[1] && !beat_err_i) begin err_q <= 1'b0; end", ENV, "ICLR ERROR leaves ERRPHASE set"),
 ("M09", "dma_chan.v", "if (last) comp_q <= 1'b1;", "if (rem_q == 16'd2) comp_q <= 1'b1;", ENV, "COMPLETE one beat early (D-1 shape)"),
 ("M10", "dma_chan.v", "else if (beat_done_i && sinc_q) sar_q <= sar_q + step;",
  "else if ((beat_done_i || beat_err_i) && sinc_q) sar_q <= sar_q + step;", ENV, "SAR advances on a failed beat (no freeze, [N-7.15])"),
 ("M11", "dma_arbiter.v", "PRIO[3*n +: 3] > best", "PRIO[3*n +: 3] < best", ENV, "priority inverted: the lowest priority wins"),
 ("M13", "dma_engine.v", "if (dar_bad) begin", "if (1'b0) begin", BLOCK, "R-9 DAR check removed: writes to ISRAM / Boot ROM"),
 ("M14", "dma_engine.v", "ack_cnt         <= ACK_CYCLES - 1;", "ack_cnt         <= 2'd0;", ENV, "DMA-7 reverted: dma_ack one hclk wide"),
 ("M15", "dma_engine.v", "if (grant_valid_i && beat_done_o == 6'd0 && beat_err_o == 6'd0) begin", "if (grant_valid_i) begin", ENV,
  "ENG-1 reverted: regrant before the channel has counted the beat"),
 ("M16", "dma_engine.v", E_WD_ERR[0], E_WD_ERR[1], ENV, "write ERROR reported as ERRPHASE = read"),
 ("M17", "dma_engine.v", "wire [7:0]  rd_byte = hrdata_i >> (8 * sar[1:0]);", "wire [7:0]  rd_byte = hrdata_i[7:0];", ENV,
  "byte beats always take lane 0"),
 ("M18", "dma_engine.v", "if (hresp_i) begin\n                            beat_err_o[ch] <= 1'b1; err_phase_o <= 3'd1;",
  "if (1'b0) begin\n                            beat_err_o[ch] <= 1'b1; err_phase_o <= 3'd1;", ENV, "read ERROR ignored: the beat writes garbage"),
 ("M19", "dma_engine.v", "if (htrans_o[1] && hready_i) htrans_o <= 2'b00;    // address accepted",
  "if (htrans_o[1]) htrans_o <= 2'b00;    // address accepted", ENV, "read address dropped while HREADY is low (AHB violation)"),
 ("M20", "dma_apb_slave.v", "wire wstb = acc_wr & ~acc_wr_q;", "wire wstb = acc_wr;", REGS, "every APB write applied twice (two strobes)"),
 ("M21", "dma_apb_slave.v", "assign pslverr_o = psel_i & penable_i & ~hit;",
  "assign pslverr_o = psel_i & penable_i & (~hit | (pwrite_i & (gstat | (chan_rgn & reg_ == 3'd4))));", REGS,
  "AUD-13 reverted: a write to read-only STAT / GSTAT answers PSLVERR"),
 ("M22", "dma_apb_slave.v", "gstat_v[8 + n]  = stat_i[32*n + 17];", "gstat_v[8 + n]  = stat_i[32*n + 18];", REGS, "GSTAT COMPLETE bits show ERROR"),
 ("M23", "dma_apb_slave.v", "(ch < 3'd6)", "(ch < 3'd5)", REGS, "channel 5 registers not decoded"),
 ("M24", "dma_apb_slave.v", "assign wr_cnt_o  = {6{wstb && reg_ == 3'd3}} & chsel;", "assign wr_cnt_o  = {6{wstb && reg_ == 3'd2}} & chsel;", REGS,
  "a DAR write also lands in CNT; CNT never writable"),
 ("M25", "dma_top.v", ".complete_irq_o(dma_complete_o[n]), .error_irq_o(dma_error_o[n])",
  ".complete_irq_o(dma_error_o[n]), .error_irq_o(dma_complete_o[n])", ENV, "completion and error interrupt lines swapped"),
]
EQUIVALENT = [
 ("M12", "dma_arbiter.v: PRIO[3*n +: 3] > best -> >= best (a tie goes to the higher index)",
  "No two channels share a priority in the shipped map (dma_top.v:20: 5, 3, 1, 2, 4, 0), so > and >= pick the same "
  "channel for every eligible set. Proven: fv_dma_arb arb_mut_tie_high_shipped (the mutant, shipped-map a_grant only) "
  "passes at depth 2 = all 64 eligible values of the combinational arbiter. Killed under maps with ties: "
  "arb_mut_tie_high FAILS u_equal.a_grant and u_pairs.a_grant (XFAIL PLANTED)."),
]
BENCH = {ENV: ('tb/dma/env/filelist_dma_env.f', 'tb_dma_env', ["+TEST=mut", "+ITER=10"]),
         REGS: ('tb/dma/filelist_dma_regs.f', 'tb_dma_regs', []),
         BLOCK: ('tb/dma/filelist_dma_top.f', 'tb_dma_top', [])}

def generate():
    q = json.dumps
    rows = ['''# DMA plan D8 / recipe R10: DMA planted defects. GENERATED by tools/gen/gen_dma_mutants.py
# -- do not edit by hand. Every row must FAIL for a NAMED check (PLANTED in
# tb/dma/run/xfail.tsv). Run: make -f flow/mk/track_a.mk dma_mut
[suite]
block = "dma"
name  = "dma_mut"
kind  = "sim"
xfail = "tb/dma/run/xfail.tsv"

[defaults]
marker  = '^RESULT: PASSED'
timeout = 1800
''']
    xf = []
    for mid, f, pat, rep, bench, what in MUTANTS:
        src = open(f"{R}/rtl/dma/{f}").read()
        n = src.count(pat)
        if n != 1:
            raise SystemExit(f"{mid}: pattern found {n} times in rtl/dma/{f}")
        out = f"tb/dma/mut/{f[:-2]}_mut_{mid.lower()}.v"
        open(f"{R}/{out}", "w").write(f"// MUTANT dma_mut/{mid} (GENERATED by tools/gen/gen_dma_mutants.py): {what}\n"
                                       + src.replace(pat, rep))
        fl, top, pa = BENCH[bench]
        rows.append(f"# {mid}: {what}\n[[test]]\nname = {q('mut_' + mid.lower())}\nflist = {q(fl)}\ntop = {q(top)}\n"
                    f"plusargs = {q(pa)}\nreplace = {{ {q('rtl/dma/' + f)} = {q(out)} }}\nfail_reason = {q(KILL)}\n")
        xf.append(f"dma_mut\tmut_{mid.lower()}\tFAIL\tPLANTED\t{what}")
    open(f"{R}/tb/dma/run/dma_mut.toml", "w").write("\n".join(rows))
    # keep the hand rows of xfail.tsv, replace the generated dma_mut block
    p = f"{R}/tb/dma/run/xfail.tsv"
    keep = [l for l in open(p).read().splitlines() if not l.startswith("dma_mut\t")]
    open(p, "w").write("\n".join(keep + xf) + "\n")
    print(f"{len(MUTANTS)} mutants -> tb/dma/run/dma_mut.toml; {len(EQUIVALENT)} equivalent (not run)")

def summary():
    """classify each row of the last run from its log: the first named check that fired"""
    tsv = f"{R}/logs/dma/summary/dma_mut.tsv"
    lines = [l.rstrip("\n").split("\t") for l in open(tsv)]
    head = lines[1]
    rows = {dict(zip(head, l))["test"]: dict(zip(head, l)) for l in lines[2:]}
    out = [f"DMA planted-defect run (DMA plan D8, recipe R10), {datetime.date.today()}",
           f"source: {os.path.relpath(tsv, R)}; generator tools/gen/gen_dma_mutants.py; kill = a named check ({KILL})", ""]
    tally = {}
    for mid, f, _, _, bench, what in MUTANTS:
        r = rows.get("mut_" + mid.lower(), {})
        log = f"{R}/logs/dma/raw/dma_mut/sim_mut_{mid.lower()}_s1.log"
        first = ""
        if os.path.exists(log):
            for ln in open(log, errors="replace"):
                if re.search(KILL, ln):
                    first = ln.strip()[:150]; break
        cls = r.get("class", "NOT-RUN")
        verdict = ("KILLED-BY-CHECK" if cls.startswith("XFAIL") and first else
                   "KILLED-OTHER" if r.get("verdict") == "FAIL" else
                   "SURVIVOR" if r.get("verdict") == "PASS" else "TOOL-FAIL")
        tally[verdict] = tally.get(verdict, 0) + 1
        out.append(f"{mid:4} {verdict:16} {bench:5} {f:16} {what}")
        if first:
            out.append(f"     first check: {first}")
    for mid, what, why in EQUIVALENT:
        tally["EQUIVALENT"] = tally.get("EQUIVALENT", 0) + 1
        out.append(f"{mid:4} {'EQUIVALENT':16} -     {what}")
        out.append(f"     {why}")
    out += ["", "totals: " + ", ".join(f"{k} {v}" for k, v in sorted(tally.items()))]
    p = f"{R}/logs/dma/evidence/dma_mut_{datetime.date.today()}.txt"
    open(p, "w").write("\n".join(out) + "\n")
    print("\n".join(out[-1:]), "->", os.path.relpath(p, R))

if __name__ == "__main__":
    summary() if "--summary" in sys.argv else generate()
