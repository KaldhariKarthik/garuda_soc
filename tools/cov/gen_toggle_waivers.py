#!/usr/bin/env python3
"""gen_toggle_waivers.py -- toggle waivers from a RULE TABLE (H5).

    python3 tools/cov/gen_toggle_waivers.py core|dsu|dma

Reads the block's merged coverage (tb/<blk>/cov/cov.toml), takes every design
toggle point that was never hit, and explains it with exactly one rule below
(category + reason + evidence: a PROVEN property or a literal RTL line). The
waivers are written per file with the EXACT uncovered points (signal[bit] and
direction), replacing the generated section of tb/<blk>/cov/<blk>_waivers.toml.
Holes no rule explains are printed: they need a test or a decision, never a
blanket waiver. cov_report.py then fails if any generated waiver matches a
covered point, so a rule that is too wide cannot hide a hole.
"""
import sys, os, re, json, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cov_report as cr, tomllib
BLOCK = sys.argv[1] if len(sys.argv) > 1 else "core"
cfg = tomllib.load(open(os.path.join(cr.ROOT, f"tb/{BLOCK}/cov/cov.toml"), "rb"))
runs, _ = cr.load_runs(cfg)
pts = {}
for _, _, dat in runs:
    for kv, c in cr.read_dat(os.path.join(cr.ROOT, dat)):
        if cr.metric_of(kv) != "toggle": continue
        f = cr.rel(kv.get("f", "?"))
        if not cr.in_scope(f, cfg["design"]): continue
        k = (kv.get("page").split("/",1)[-1], f, kv.get("o"))
        pts[k] = pts.get(k, 0) + c
holes = collections.defaultdict(set)          # (mod, file, sig) -> {bits}
labels = collections.defaultdict(list)        # (mod, file, sig) -> exact uncovered labels
for (mod, f, o), c in pts.items():
    m = re.match(r"^(.*?)(?:\[(\d+)\])?:(0->1|1->0)$", o or "")
    if m and c == 0:
        holes[(mod, f, m.group(1))].add(int(m.group(2)) if m.group(2) else 0)
        labels[(mod, f, m.group(1))].append(o)
P_AL = "PROVEN fv_cov cov_prove: a_pc_aligned / a_iport_pc_aligned / a_mepc_aligned (tb/core/formal/cov_const_sva.sv), after the BUS-E fix"
CORE_RULES = [
 # (rule id, modules regex, signal regex, allowed bits, category, reason, evidence)
 ("PCALIGN", r".*", r"^(i_haddr_o|if_pc|fd_pc|id_pc|xe_pc|em_pc|mem_exc_pc|tr_pc|csr_mepc|data_pc|instr_pc_o|addr_pc|data_pc_o|outstanding_pc|fifo_pc\[\d\]|wr_pc_i|commit_pc_i|pc_i|pc_o|if_id_pc_i|pc|link|fallthrough|mem_exception_pc_o|idex_pc_i|mem_exc_pc_i|mepc_i|trap_pc_o|trap_pc_i|mepc_o|mepc_r)$", {0,1}, "constant",
  "Word-aligned PC: no C extension (IALIGN 32), every redirect source clears bit 0, misaligned targets trap in EX (T-1) and, since BUS-E, are never fetched; mepc is WARL-aligned. Bits [1:0] of this PC copy are constant 0.", P_AL),
 ("PCBIT0", r".*", r"^(fetch_pc|fetch_pc_i|fetch_pc_o|redirect_pc_i|id_redir_t|pc_if_redir_pc|id_redirect_target_o|id_redirect_target_i|if_redirect_pc_o|branch_target|jal_target|jalr_target|imm_b_i|imm_j_i|imm_b_w|imm_j_w|imm_b_f|imm_b_o|imm_j_f|imm_j_o)$", {0}, "constant",
  "Bit 0 of every fetch / redirect address is 0: JAL / branch immediates have bit 0 = 0 by encoding (imm_gen.v:33-37 ... 1'b0}), JALR clears it, mtvec / mepc are aligned. (Bit 1 of these DOES toggle: misaligned targets reach pc_gen and are trapped.)",
  "PROVEN a_redir_pc_bit0 / a_pc_aligned (fv_cov); literal 1'b0 in rtl/core/imm_gen.v:34,37"),
 ("MTVECBASE", r".*", r"^(mtvec_o|csr_mtvec|clic_vec_target|clic_vector_target_i|vector_target_o|mtvec_i|mtvec_base|trap_redirect_target_o|trap_redirect_target_i|tr_redir_t)$", {0,1}, "constant",
  "The trap vector is mtvec BASE = {mtvec[31:2], 2'b00} (mode bits read as 3 but are not part of the target); the trap redirect target (BASE or mepc) is word-aligned.",
  "literal rtl/core/csr_file.v mtvec_o = {mtvec_r[31:2], 2'b00}; PROVEN a_trap_redir_aligned (fv_cov)"),
 ("FENCEI", r"^branch_predict$", r"^fencei_target$", {0,1}, "constant", "fencei_target = pc + 4 of a word-aligned PC.", "rtl/core/branch_predict.v:54 + PROVEN a_pc_aligned"),
 ("IBUS", r"^(garuda_core_top|garuda_if_stage_top|garuda_iport_ahb_master)$", r"^(i_hburst_o|i_hprot_o|i_hsize_o|i_hwdata_o|i_hwrite_o)$", set(range(32)), "constant",
  "I-port attributes are literals: INCR bursts of words, opcode-fetch HPROT, read only.", "literal rtl/core/garuda_iport_ahb_master.v:89-92 (hsize 3'b010, hprot 4'b0010, hwrite 0, hwdata 0), :109 (hburst 3'b001)"),
 ("DBUS", r"^(garuda_core_top|mem_stage|d_port_ahb_master|load_store_unit)$", r"^(d_hburst_o|d_hprot_o|d_hsize_o|hsize_i|hsize_o|hsize_w|d_htrans_o)$", None, "constant",
  "D-port attributes: SINGLE transfers (hburst 0), data-access HPROT, size <= word (hsize[2] = 0), HTRANS only IDLE / NONSEQ (bit 0 = 0).",
  "literal rtl/core/mem_stage.v:140-141; rtl/core/load_store_unit.v:32 hsize_o = {1'b0, size}; d_port_ahb_master.v:101,106 HTRANS_NONSEQ / HTRANS_IDLE"),
 ("CAUSE", r".*", r"^(tr_cause|trap_cause_o|trap_cause_i)$", set(range(5, 31)), "constant",
  "Exception and interrupt codes are < 32 (5-bit CLIC id, cause <= 11); bits 30:5 are 0, bit 31 is the interrupt flag (T-12 puts mpil in mcause[23:16] in csr_file, not on this bus).", "PROVEN a_cause_field (fv_cov)"),
 ("MEMCAUSE", r".*", r"^(mem_exc_cause|mem_exception_cause_o|mem_exc_cause_i)$", {3}, "constant",
  "MEM-stage causes are 5 and 7 only (4-bit field, bit 3 = 0).", "literal rtl/core/mem_stage.v:184 (4'd5 / 4'd7 / 0); PROVEN a_mexc_cause_bit3"),
 ("CSRLAYOUT", r"^csr_file$", r"^(mstatus_val|misa_val|mintstatus_val|mintstatus_std_val|mip_val)$", None, "constant",
  "Read-value layouts with fixed fields: mstatus (only MIE, MPIE stored; MPP = 11), misa constant, mintstatus {24'b0, mil}, mintstatus_std {mil, 24'b0}, mip {24'b0, MTIP, 7'b0}.", "literal rtl/core/csr_file.v:144-156"),
 ("MIEWARL", r"^csr_file$", r"^mie_r$", set(range(32)) - {7}, "constant", "mie is WARL: only MTIE (bit 7) is stored.", "PROVEN a_mie_only_mtie (fv_cov); csr_file.v:303 & 32'h0000_0080"),
 ("IMMENC", r"^imm_gen$", r"^(imm_u_f|imm_csr_f)$", None, "constant", "U-immediate bits 11:0 and the zero-extended CSR immediate bits 31:5 are literal 0.", "literal rtl/core/imm_gen.v:35 {.., 12'b0}, :38 {27'b0, ..}"),
 ("IPCOUNT", r"^garuda_iport_ahb_master$", r"^(inflight|occ_after_pop|occ_plus_landing|projected_occ)$", {2,3}, "constant",
  "At most 2 transfers are in flight and occupancy + in flight <= 6: the top bits of these 4-bit sums never set.", "PROVEN a_inflight_le2, a_occ_pop_lt8, a_occ_land_lt8, a_proj_occ_lt8 (fv_cov)"),
]
DSU_RULES = [
 ("CARRY0", r"^(csa_3to2__W31|csa_3to2|mac_unit|kogge_stone_49)$", r"^(carry|csa1_carry|csa2_carry|carry_reg|b|c)$", {0}, "constant",
  "Bit 0 of a carry-save carry vector is 0: carry = (majority) << 1. It feeds csa2's c (carry_reg) and the final adder's b.",
  "literal rtl/dsu/csa_3to2.v:12 (<< 1); carry_reg loads csa1_carry or 0 (mac_unit.v:129-141)"),
 ("CIN", r"^kogge_stone_49$", r"^cin$", {0}, "constant", "The final adder's carry-in is tied to 0.", "literal rtl/dsu/mac_unit.v:159 .cin(1'b0)"),
 ("SUBK", r"^mac_unit$", r"^sub_k$", set(range(49)) - {1}, "constant",
  "sub_k = {47'b0, add_sub, 1'b0}: the two's-complement +2 correction term; only bit 1 (add_sub) varies.", "literal rtl/dsu/mac_unit.v:87"),
 ("SATABS", r"^operand_router$", r"^(rs1_lo_abs|rs2_lo_abs)$", {15}, "constant",
  "abs16 SATURATES: |-32768| gives 0x7FFF, every other negative x gives ~x+1 <= 0x7FFF and a positive x is < 0x8000, so bit 15 of the absolute value is never set.",
  "literal rtl/dsu/operand_router.v:14-19 (if x == 16'h8000 abs16 = 16'h7FFF); the DSU oracle saturates the same way (MACABS vectors pass)"),
 ("SATBOUNDS", r"^saturation_unit$", r"^(sat_pos|sat_neg)$", None, "constant",
  "The MACSAT clamp values are constants (+2^31-1 and -2^31 in 48 bits).", "literal rtl/dsu/saturation_unit.v:19-20"),
]
def _per_ch(lo, hi):            # bits lo..hi of each of the six 32-bit channel fields
    return {32 * n + b for n in range(6) for b in range(lo, hi + 1)}
P_DMA = "PROVEN fv_dma_cov cov_prove (tb/dma/formal/cov_unreach.toml, tb/dma/formal/dma_cov_sva.sv)"
DMA_RULES = [
 ("CNTHI", r"^(dma_apb_slave|dma_chan|dma_top)$", r"^(cnt_i|cnt_o|cnt)$", _per_ch(16, 31) | set(range(16, 32)), "constant",
  "CNT is a 16-bit register read as a 32-bit word: bits 31:16 of every channel's CNT bus are literal 0.", "literal rtl/dma/dma_chan.v:150 assign cnt_o = {16'd0, cnt_q}"),
 ("CRRSV", r"^(dma_apb_slave|dma_chan|dma_top)$", r"^(cr_i|cr_o|cr)$", _per_ch(9, 31) | set(range(9, 32)), "constant",
  "CR bits 31:9 are reserved and read as 0 ([N-6.1]).", "literal rtl/dma/dma_chan.v:147 assign cr_o = {23'd0, ...}"),
 ("STATHI", r"^(dma_apb_slave|dma_chan|dma_top)$", r"^(stat_i|stat_o|stat)$", _per_ch(21, 31) | set(range(21, 32)), "constant",
  "STAT bits 31:22 are reserved (literal 0); bit 21 is ERRPHASE[2], and ERRPHASE takes only 0, 1 (read) and 2 (write).",
  "literal rtl/dma/dma_chan.v:151 assign stat_o = {10'd0, errph_q, ...}; bit 21: " + P_DMA + " a_cov_errph_bit2"),
 ("ERRPH2", r"^(dma_chan|dma_engine|dma_top)$", r"^(err_phase_i|errph_q|err_phase_o|err_phase)$", {2}, "constant",
  "ERRPHASE is loaded with 3'd1 (read) or 3'd2 (write) only: bit 2 is never set.", P_DMA + " a_cov_errph_bit2; rtl/dma/dma_engine.v err_phase_o <= 3'd1 / 3'd2"),
 ("GSTATRSV", r"^dma_apb_slave$", r"^gstat_v$", {6, 7, 14, 15} | set(range(22, 32)), "constant",
  "GSTAT holds ACTIVE[5:0], COMPLETE[13:8] and ERROR[21:16] of six channels; the other bits are 0.", "literal rtl/dma/dma_apb_slave.v:90-94 (gstat_v = 0, then bits n, 8+n, 16+n for n < 6)"),
 ("PREADY", r"^(dma_apb_slave|dma_top)$", r"^pready_o$", {0}, "constant",
  "The APB slave has no wait states: PREADY is tied high.", "literal rtl/dma/dma_apb_slave.v:122 assign pready_o = 1'b1"),
 ("STEP", r"^dma_chan$", r"^step$", set(range(3, 32)), "constant",
  "The address step is 1, 2 or 4 (SIZE 3 is refused, F03): bits 31:3 are 0.", "literal rtl/dma/dma_chan.v:76"),
 ("HBURST", r"^(dma_engine|dma_top)$", r"^hburst_o$", {0, 1, 2}, "constant",
  "The DMA master issues SINGLE transfers only: HBURST is 000.", "literal rtl/dma/dma_engine.v:87 assign hburst_o = 3'b000"),
 ("HSIZE2", r"^(dma_engine|dma_top)$", r"^hsize_o$", {2}, "constant",
  "HSIZE = {0, SIZE} (at most a word): bit 2 is 0.", "literal rtl/dma/dma_engine.v:95,124,148 hsize_o <= 3'b010 / {1'b0, size}"),
 ("HTRANS0", r"^(dma_engine|dma_top)$", r"^htrans_o$", {0}, "constant",
  "HTRANS is only IDLE (00) or NONSEQ (10): bit 0 is 0.", "literal rtl/dma/dma_engine.v:94,122,129,146,154 htrans_o <= 2'b00 / 2'b10"),
 ("ACKCNT", r"^dma_engine$", r"^ack_cnt$", {1}, "constant",
  "With the shipped ACK_CYCLES = 2 the ack stretch counter loads ACK_CYCLES - 1 = 1 at most: bit 1 stays 0 (DMA-12: values outside 1..4 are a separate bug).",
  P_DMA + " a_cov_ackcnt_bit1; rtl/dma/dma_top.v:21 ACK_CYCLES = 2"),
]
AHB_RULES = [
 ("SIZE2", r"^(ahb_interconnect|ahb_master_mux)$", r"^((i|d|s|m)_hsize_i|hsize_o)$", {2}, "constant",
  "The AHB is 32 bits wide: HSIZE <= word (byte/half/word), so HSIZE[2] is 0 from every GARUDA master and on the shared bus.",
  "literal rtl/core/garuda_iport_ahb_master.v:89 (3'b010); rtl/core/load_store_unit.v:32 {1'b0, size}; rtl/debug/sba_master.v:42 (3'b010); rtl/dma/dma_engine.v hsize_o <= {1'b0, size}"),
 ("BURST21", r"^(ahb_interconnect|ahb_master_mux)$", r"^(i_hburst_i|hburst_o)$", {1, 2}, "constant",
  "Only SINGLE (000) and INCR (001) bursts exist on GARUDA's bus ([N-5.4]): HBURST[2:1] is 0 from every master.",
  "literal rtl/core/garuda_iport_ahb_master.v:109 (3'b001); rtl/core/mem_stage.v:140, rtl/debug/sba_master.v:43, rtl/dma/dma_engine.v:87 (3'b000)"),
 ("SINGLEONLY", r"^(ahb_interconnect|ahb_master_mux)$", r"^(d|s|m)_hburst_i$", {0, 1, 2}, "constant",
  "The D-port, the SBA and the DMA issue SINGLE transfers only ([N-5.3]): HBURST = 000 on those ports.",
  "literal rtl/core/mem_stage.v:140, rtl/debug/sba_master.v:43, rtl/dma/dma_engine.v:87 (3'b000)"),
 ("NONSEQONLY", r"^ahb_interconnect$", r"^((d|s|m)_htrans_i|htrans_bus)$", {0, 2, 4, 6}, "constant",
  "A SINGLE-only master drives HTRANS IDLE (00) or NONSEQ (10), never SEQ/BUSY: bit 0 is 0 on the D-port, SBA and DMA ports (htrans_bus bits 2, 4, 6 are those bits; bit 0 of the I-port toggles with its SEQ beats).",
  "literal rtl/core/d_port_ahb_master.v:101,106; rtl/debug/sba_master.v:58,62; rtl/dma/dma_engine.v:122,129,146,154"),
 ("IPORTLIT", r"^ahb_interconnect$", r"^i_(hsize_i|hwrite_i|hwdata_i|hprot_i)$", None, "constant",
  "The I-port is a word-read-only fetch port with a fixed opcode-fetch HPROT: HSIZE = 010, HWRITE = 0, HWDATA = 0, HPROT = 0010.",
  "literal rtl/core/garuda_iport_ahb_master.v:89-92"),
 ("IPORTALIGN", r"^ahb_interconnect$", r"^i_haddr_i$", {0, 1}, "constant",
  "Fetch addresses are word-aligned (no C extension; misaligned targets trap and are never fetched since BUS-E): I-port HADDR[1:0] = 0.",
  "PROVEN fv_cov a_iport_pc_aligned (tb/core/formal/cov_const_sva.sv); literal (fetch_pc_i[1:0] == 2'b00) gate in rtl/core/garuda_iport_ahb_master.v:204"),
 ("DPROT", r"^ahb_interconnect$", r"^d_hprot_i$", None, "constant",
  "The D-port's HPROT is the fixed data-access value 0011.", "literal rtl/core/mem_stage.v:141 assign d_hprot_o = 4'b0011"),
 ("HPROTOUT", r"^ahb_interconnect$", r"^hprot_o$", {1, 2, 3}, "constant",
  "HPROT on the shared bus is 0010 (I-port), 0011 (D-port) or the SBA/DMA substitution 0011 ([N-5.2]): bit 1 is always 1 and bits 3:2 always 0; bit 0 toggles.",
  "literals above + rtl/ahb/ahb_defs.vh `AHB_HPROT_DMA / `AHB_HPROT_SBA 4'b0011; property a_hprot_const PROVEN (fv_ahb)"),
 ("DFRDATA", r"^(ahb_default_slave|ahb_interconnect)$", r"^(hrdata_o|hrdata_df)$", None, "constant",
  "The default slave returns no data: its HRDATA is the literal 0.", "literal rtl/ahb/ahb_default_slave.v assign hrdata_o = 32'h0000_0000"),
]
RULES = {"dsu": DSU_RULES, "dma": DMA_RULES, "ahb": AHB_RULES}.get(BLOCK, CORE_RULES)
# holes already explained by a hand-written waiver (not generated) are left alone
_wfile = os.path.join(cr.ROOT, f"tb/{BLOCK}/cov/{BLOCK}_waivers.toml")
_hand = [w for w in tomllib.load(open(_wfile, "rb")).get("waiver", [])
         if w.get("metric") == "toggle" and not str(w.get("id", "")).startswith("CT-")] if os.path.exists(_wfile) else []
def _hand_covers(f, labs):
    return any(fnmatch.fnmatch(f, w["file"]) and all(re.search(w["match"], l) for l in labs) for w in _hand)
import fnmatch
waivers = collections.defaultdict(list)    # (rule, file) -> [(sig, bits)]
unexplained = []
for (mod, f, sig), bits in sorted(holes.items()):
    if _hand_covers(f, labels[(mod, f, sig)]):
        continue
    done = False
    for rid, mrx, srx, allowed, cat, reason, ev in RULES:
        if re.search(mrx, mod) and re.search(srx, sig) and (allowed is None or bits <= allowed):
            waivers[(rid, f)].append((sig, bits, sorted(labels[(mod, f, sig)]))); done = True; break
    if not done:
        unexplained.append((mod, f, sig, sorted(bits)))
rinfo = {r[0]: r for r in RULES}
out = ["", "# " + "=" * 77, "# CODE: toggle (generated from a rule table by tools/cov/gen_toggle_waivers.py;", "# every hole below is explained by its rule's evidence)", "# " + "=" * 77]
n = 0
for (rid, f), lst in sorted(waivers.items()):
    _, _, _, _, cat, reason, ev = rinfo[rid]
    # exact uncovered points only (signal[bit]:direction): a constant-1 bit's
    # single 0->1 at start-up is covered and must not be claimed
    alts = [re.escape(lab) for _, _, labs in lst for lab in labs]
    n += 1
    mod = os.path.splitext(os.path.basename(f))[0]
    out.append("[[waiver]]")
    for k, v in (("id", f"CT-{rid}-{mod}"), ("metric", "toggle"), ("file", f),
                 ("match", "^(" + "|".join(alts) + ")$"), ("category", cat), ("reason", reason),
                 ("evidence", ev), ("reviewer", "pending: Sreyesh")):
        out.append(f"{k:<8} = {json.dumps(v)}")
    out.append("")
p = os.path.join(cr.ROOT, f"tb/{BLOCK}/cov/{BLOCK}_waivers.toml")
s = open(p).read()
s = s.split("\n# " + "=" * 77 + "\n# CODE: toggle")[0].rstrip("\n") + "\n"
open(p, "w").write(s + "\n".join(out) + "\n")
print(f"toggle waivers: {n} (rules {sorted(set(r for r,_ in waivers))})")
print("UNEXPLAINED holes (need a test or a decision):")
for u in unexplained: print("  ", u)
