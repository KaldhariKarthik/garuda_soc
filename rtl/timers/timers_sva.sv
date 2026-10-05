`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 11 : properties for the timers and the watchdog
// timers_sva.sv
//
// Spec: GARUDA-TIMERS-SPEC-001 section 10 and decision D-17. Plan:
// tb/timers/GARUDA_TIMERS_vplan.csv; each property names its feature.
// Bound to timers_top, so the properties run in the block bench, in the UVM
// environment and in every chip simulation. Not compiled for synthesis or lint.
// =============================================================================
`ifndef SYNTHESIS
module timers_sva (
    input wire        hclk_i,
    input wire        hreset_n_i,
    input wire        ext_rst_n_i,
    input wire        pclk_i,
    input wire        preset_n_i,
    input wire        psel_i,
    input wire        penable_i,
    input wire        pwrite_i,
    input wire [11:0] paddr_i,
    input wire [31:0] prdata_o,
    input wire        pready_o,
    input wire        pslverr_o,
    input wire        mtip_o,
    input wire        wdt_warn_irq_o,
    input wire        wdt_rst_req_o,
    // strobes and state inside the block
    input wire        wr_lo, wr_hi, wr_clo, wr_chi, rd_lo, wr_ctl, wr_load, wr_kick, wr_warn,
    input wire [31:0] wdata,
    input wire [63:0] mtime_q, cmp_q,
    input wire [31:0] shadow_q,
    input wire        en_q, warnen_q,
    input wire [31:0] ctr_q, load_q, warn_q
);
    localparam [31:0] KICK_MAGIC = 32'h5A5A_C3C3;
    wire any_wr = wr_lo | wr_hi | wr_clo | wr_chi | wr_ctl | wr_load | wr_kick | wr_warn;
    wire kick   = wr_kick && (wdata == KICK_MAGIC);
    // the register map of TIMERS section 6: nine word registers at 0x00 to 0x20
    wire mapped = (paddr_i[11:8] == 4'h0) && (paddr_i[1:0] == 2'b00) && (paddr_i[7:2] <= 6'd8);

    // Every property that looks one cycle back takes the SAMPLED reset in its
    // antecedent: in the cycle the reset is released the flops still see it, and
    // an attempt started on that edge would compare against a value that did not move.

    // ---- F13, F14: mtime counts every cycle; a write replaces one half -------
    a_mtime_monotonic: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hreset_n_i && !(wr_lo || wr_hi)) |=> (mtime_q == $past(mtime_q) + 64'd1))
        else $error("[SVA-FAIL] a_mtime_monotonic");
    a_mtime_write_lo: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hreset_n_i && wr_lo) |=> (mtime_q == {$past(mtime_q[63:32]), $past(wdata)}))
        else $error("[SVA-FAIL] a_mtime_write_lo");
    a_mtime_write_hi: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hreset_n_i && wr_hi && !wr_lo) |=> (mtime_q == {$past(wdata), $past(mtime_q[31:0])}))
        else $error("[SVA-FAIL] a_mtime_write_hi");

    // ---- F17, F18, F19, F21: mtip is the registered unsigned compare ----------
    a_mtip_correct: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        hreset_n_i |=> (mtip_o == ($past(mtime_q) >= $past(cmp_q))))
        else $error("[SVA-FAIL] a_mtip_correct: mtip=%b", mtip_o);
    a_mtip_level: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        $fell(mtip_o) |-> ($past(wr_lo | wr_hi | wr_clo | wr_chi, 2) || ($past(mtime_q, 2) == {64{1'b1}})))
        else $error("[SVA-FAIL] a_mtip_level: mtip fell with no write to mtime or mtimecmp");
    a_mtimecmp_reset: assert property (@(posedge hclk_i)
        !hreset_n_i |-> (cmp_q == {64{1'b1}} && !mtip_o))
        else $error("[SVA-FAIL] a_mtimecmp_reset");

    // ---- F01, F02: the shadow changes only on an MTIME_LO read ----------------
    a_shadow_latch: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hreset_n_i && rd_lo) |=> (shadow_q == $past(mtime_q[63:32])))
        else $error("[SVA-FAIL] a_shadow_latch");
    a_shadow_holds: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hreset_n_i && !rd_lo) |=> $stable(shadow_q))
        else $error("[SVA-FAIL] a_shadow_holds");

    // ---- F02, F16: MTIME_HI returns the shadow, never the live high word -------
    a_hi_returns_shadow: assert property (@(posedge hclk_i) disable iff (!hreset_n_i || !preset_n_i)
        (psel_i && penable_i && !pwrite_i && paddr_i == 12'h004) |-> (prdata_o == shadow_q))
        else $error("[SVA-FAIL] a_hi_returns_shadow: prdata=%h shadow=%h", prdata_o, shadow_q);

    // ---- F04, F26: EN is sticky --------------------------------------------------
    a_wdt_en_sticky: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hreset_n_i && en_q) |=> en_q)
        else $error("[SVA-FAIL] a_wdt_en_sticky");

    // ---- F22, F23, F24: the counter's next value ----------------------------------
    a_wdt_stopped: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hreset_n_i && !en_q) |=> (ctr_q == $past(load_q)))
        else $error("[SVA-FAIL] a_wdt_stopped");
    a_wdt_magic_reloads: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hreset_n_i && en_q && kick) |=> (ctr_q == $past(load_q)))
        else $error("[SVA-FAIL] a_wdt_magic_reloads");
    a_wdt_count: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hreset_n_i && en_q && !kick) |=> (ctr_q == (($past(ctr_q) != 0) ? $past(ctr_q) - 32'd1 : 32'd0)))
        else $error("[SVA-FAIL] a_wdt_count");
    a_wdt_magic_only: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hreset_n_i && en_q && !kick) |=> (ctr_q <= $past(ctr_q)))
        else $error("[SVA-FAIL] a_wdt_magic_only: the counter rose without the magic value");

    // ---- F27, F28: early warning (decision D-17) ------------------------------------
    a_wdt_warn_at_thresh: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        wdt_warn_irq_o == (en_q && warnen_q && (ctr_q <= warn_q)))
        else $error("[SVA-FAIL] a_wdt_warn_at_thresh");
    a_wdt_warn_before_reset: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        ($rose(wdt_rst_req_o) && $past(warnen_q)) |-> $past(wdt_warn_irq_o))
        else $error("[SVA-FAIL] a_wdt_warn_before_reset");

    // ---- F29, F30: the reset request -------------------------------------------------
    a_wdt_req_at_zero: assert property (@(posedge hclk_i) disable iff (!hreset_n_i || !ext_rst_n_i)
        $rose(wdt_rst_req_o) |-> $past(en_q && ctr_q == 32'd0))
        else $error("[SVA-FAIL] a_wdt_req_at_zero");
    a_wdt_req_survives_hreset: assert property (@(posedge hclk_i) disable iff (!ext_rst_n_i)
        ($fell(hreset_n_i) && $past(wdt_rst_req_o)) |-> wdt_rst_req_o)
        else $error("[SVA-FAIL] a_wdt_req_survives_hreset: the request was cleared by the reset it caused");
    a_wdt_req_cleared_only_by_ctrl: assert property (@(posedge hclk_i) disable iff (!ext_rst_n_i)
        $fell(wdt_rst_req_o) |-> $past(!hreset_n_i))
        else $error("[SVA-FAIL] a_wdt_req_cleared_only_by_ctrl");

    // ---- F10, F11: the register port ---------------------------------------------------
    a_pready: assert property (@(posedge pclk_i) disable iff (preset_n_i !== 1'b1) pready_o)
        else $error("[SVA-FAIL] a_pready");
    a_prdata_stable: assert property (@(posedge hclk_i) disable iff (!preset_n_i)
        (psel_i && penable_i && $past(psel_i && penable_i)) |-> $stable(prdata_o))
        else $error("[SVA-FAIL] a_prdata_stable");
    a_one_strobe_per_write: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hreset_n_i && any_wr) |=> !any_wr)
        else $error("[SVA-FAIL] a_one_strobe_per_write");
    a_err_no_change: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (psel_i && penable_i && pwrite_i && pslverr_o) |-> !any_wr)
        else $error("[SVA-FAIL] a_err_no_change");

    // ---- F09: an offset that does not exist, or an alias of one that does, has no effect
    a_unmapped_no_strobe: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (psel_i && !mapped) |-> !(any_wr || rd_lo))
        else $error("[SVA-FAIL] a_unmapped_no_strobe: paddr=%h", paddr_i);

    // ---- each implication must be seen to trigger (sign-off criterion 4) ----
    c_mtip_rise:   cover property (@(posedge hclk_i) hreset_n_i && $rose(mtip_o));
    c_mtip_fall:   cover property (@(posedge hclk_i) hreset_n_i && $fell(mtip_o));
    c_carry:       cover property (@(posedge hclk_i) hreset_n_i && mtime_q[31:0] == 32'hFFFF_FFFF && !wr_lo);
    c_kick:        cover property (@(posedge hclk_i) hreset_n_i && en_q && kick);
    c_wrong_kick:  cover property (@(posedge hclk_i) hreset_n_i && en_q && wr_kick && !kick);
    c_warn:        cover property (@(posedge hclk_i) hreset_n_i && $rose(wdt_warn_irq_o));
    c_req:         cover property (@(posedge hclk_i) $rose(wdt_rst_req_o));
    c_alias:       cover property (@(posedge hclk_i) hreset_n_i && psel_i && penable_i && pwrite_i && (paddr_i[11:8] != 4'h0) && (paddr_i[7:0] == 8'h1C) && (wdata == KICK_MAGIC));
    c_req_survive: cover property (@(posedge hclk_i) $fell(hreset_n_i) && wdt_rst_req_o);
endmodule

bind timers_top timers_sva u_timers_sva (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .ext_rst_n_i(ext_rst_n_i),
    .pclk_i(pclk_i), .preset_n_i(preset_n_i),
    .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i), .paddr_i(paddr_i),
    .prdata_o(prdata_o), .pready_o(pready_o), .pslverr_o(pslverr_o),
    .mtip_o(mtip_o), .wdt_warn_irq_o(wdt_warn_irq_o), .wdt_rst_req_o(wdt_rst_req_o),
    .wr_lo(wr_lo), .wr_hi(wr_hi), .wr_clo(wr_clo), .wr_chi(wr_chi), .rd_lo(rd_lo),
    .wr_ctl(wr_ctl), .wr_load(wr_load), .wr_kick(wr_kick), .wr_warn(wr_warn), .wdata(wdata),
    .mtime_q(u_mtime.mtime_q), .cmp_q(u_mtime.cmp_q), .shadow_q(u_mtime.shadow_q),
    .en_q(u_wdt.en_q), .warnen_q(u_wdt.warnen_q), .ctr_q(u_wdt.ctr_q),
    .load_q(u_wdt.load_q), .warn_q(u_wdt.warn_q));
`endif
