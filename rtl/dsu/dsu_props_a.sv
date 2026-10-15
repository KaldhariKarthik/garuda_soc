// =============================================================================
// dsu_props_a.sv -- bound properties of the DSU (vPlan tb/dsu/GARUDA_DSU_vplan.csv,
// rows "SVA in rtl/dsu/dsu_props_a.sv"; Karthik's plan 5.11 / recipe R6). Checked in
// simulation (DSU bench, every core program) and proven with SBY
// (tb/dsu/formal/dsu.toml). Portable subset (H4): boolean asserts and helper
// flops, no |->.
//
// Implemented (14): F03.CHK1 a_other_acc_unchanged, F10.CHK4 a_ovf_from_49,
// F11.CHK1 a_ovf_sticky, F11.CHK2 a_ovf_set_beats_clear, F12.CHK1
// a_accsel3_illegal, F12.CHK2 a_accsel3_no_effect, F14.CHK1
// a_inert_when_disabled, F15.CHK1 a_single_cycle, F16.CHK1 a_interlock_fires,
// F17.CHK1 a_interlock_per_acc, F19.CHK1 a_flush_no_accumulate, F23.CHK1
// a_taps_live, plus F06/F09 by the bench against the oracles.
// NOT implemented, pending a D0 ruling: F10.CHK1/CHK2 a_saturate_pos/neg and
// F10.CHK3 a_never_wraps state that a 48-bit overflow SATURATES; the RTL and
// both oracles (tools/golden/DSU_Golden.py) WRAP and set the sticky flag (only
// MACSAT clamps, to +-2^31). The vPlan rows and the spec disagree with the
// design; the owner rules which one changes.
// =============================================================================
`timescale 1ns/1ps

`ifdef FORMAL
  `define GARUDA_DSU_SVA
`elsif SYNTHESIS
`elsif __ICARUS__   // Icarus has no bind / assert property (same rule as the *_sva.sv files on main)
`else
  `define GARUDA_DSU_SVA
`endif

`ifdef GARUDA_DSU_SVA
`include "dsu_defs.vh"

// ---- one accumulator ---------------------------------------------------------
module mac_unit_sva (
    input wire        clk, rst_n,
    input wire        en, sat_writeback_en, flush, pending, acc_we, overflow, is_accum,
    input wire        prod_en, my_sat, my_load, my_clear,
    input wire [47:0] acc
);
    reg [47:0] acc_q;
    reg        touch_q, live_q;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin acc_q <= 48'd0; touch_q <= 1'b0; live_q <= 1'b0; end
        else begin
            acc_q <= acc; touch_q <= en | sat_writeback_en | pending; live_q <= 1'b1;
        end
    // F03.CHK1: an accumulator changes only after an instruction addressed to IT
    // (en / its saturate write-back) or its own pending stage-2 fold
    a_other_acc_unchanged: assert property (@(posedge clk) disable iff (!rst_n)
        !live_q || (acc == acc_q) || touch_q)
        else $error("[SVA-FAIL] DSU F03: an accumulator changed without being addressed");
    // F19.CHK1: nothing is accumulated, loaded, cleared or saturated under flush
    a_flush_no_accumulate: assert property (@(posedge clk) disable iff (!rst_n)
        !(flush && (prod_en || my_sat || my_load || my_clear)))
        else $error("[SVA-FAIL] DSU F19: a flushed instruction changed an accumulator");
    // F10.CHK4: overflow is flagged only by the fold of a pending accumulate
    a_ovf_from_49: assert property (@(posedge clk) disable iff (!rst_n)
        !overflow || (pending && is_accum))
        else $error("[SVA-FAIL] DSU F10: overflow flagged outside an accumulate fold");
    c_fold:     cover property (@(posedge clk) disable iff (!rst_n) pending && is_accum);
`ifndef FORMAL
    // reached in simulation (t_cov_dsu, the clamp walk); a 48-bit overflow is
    // ~65000 cycles from reset, beyond any bounded formal cover
    c_overflow: cover property (@(posedge clk) disable iff (!rst_n) overflow);
`endif
endmodule

// ---- the DSU as a whole --------------------------------------------------------
module dsu_top_sva (
    input wire        clk, rst_n, flush, dsu_en,
    input wire [31:0] instr,
    input wire        csr_clear_overflow,
    input wire        dsu_busy, dsu_rd_valid, dsu_overflow, illegal_instr,
    input wire [`MAC_CTRL_W-1:0] control,
    input wire        sat_op, shift_op, rd_lo_op, rd_hi_op,
    input wire [1:0]  acc_sel,
    input wire [2:0]  mac_overflow,
    input wire        sat_overflow,
    input wire [47:0] dbg_acc_0, dbg_acc_1, dbg_acc_2, acc0, acc1, acc2
);
    wire custom0 = dsu_en && (instr[6:0] == 7'b0001011);
    wire rtype   = custom0 && (instr[14:12] == 3'b000);
    wire itype   = custom0 && (instr[14:12] == 3'b001);
    wire [4:0] f5 = instr[31:27];
    // an instruction whose result lands in its accumulator a cycle later
    // (the RTL also counts MACRD_LO / MACRD_HI / MACSAT as two-cycle)
    wire two_cycle = rtype && (f5 == `FUNCT5_MAC_SEL || f5 == `FUNCT5_MACSUB || f5 == `FUNCT5_MACABS ||
                               f5 == `FUNCT5_MACDOT || f5 == `FUNCT5_MACRD_LO || f5 == `FUNCT5_MACRD_HI ||
                               f5 == `FUNCT5_MACSAT);
    wire reads_acc = (rtype && (f5 == `FUNCT5_MACRD_LO || f5 == `FUNCT5_MACRD_HI || f5 == `FUNCT5_MACSAT)) || itype;

    // the previous instruction that left the DSU (not held, not flushed)
    reg       p2, busy_q, hold_q, set_q;
    reg [1:0] pacc;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            p2 <= 1'b0; pacc <= 2'd0; busy_q <= 1'b0; hold_q <= 1'b0; set_q <= 1'b0;
        end else begin
            busy_q <= dsu_busy;
            hold_q <= dsu_overflow & ~csr_clear_overflow;
            set_q  <= (|mac_overflow) | sat_overflow;
            if (flush)          begin p2 <= 1'b0; busy_q <= 1'b0; end
            else if (!dsu_busy) begin p2 <= two_cycle; pacc <= acc_sel; end
        end

    // "an effect" below = the MAC enable (EN) or a saturate / shift / read-back /
    // register write. The CLEAR / LOAD / ABS / DOT control bits only qualify EN:
    // a mac_unit acts on them only with its EN (my_clear = clear & en & ~flush),
    // so the decoder may leave them set on a word it rejects.
    // F12.CHK1 / CHK2: accumulator select 11 is illegal and has no effect
    a_accsel3_illegal: assert property (@(posedge clk) disable iff (!rst_n)
        !(rtype && instr[26:25] == 2'b11) || illegal_instr)
        else $error("[SVA-FAIL] DSU F12: accumulator select 3 not flagged illegal");
    a_accsel3_no_effect: assert property (@(posedge clk) disable iff (!rst_n)
        !illegal_instr || !(control[`MAC_CTRL_EN] || sat_op || shift_op || rd_lo_op || rd_hi_op || dsu_rd_valid))
        else $error("[SVA-FAIL] DSU F12: an illegal DSU instruction had an effect (ctrl=%b sat=%b shift=%b rdlo=%b rdhi=%b rdv=%b instr=%08x)",
                    control, sat_op, shift_op, rd_lo_op, rd_hi_op, dsu_rd_valid, instr);
    // F14.CHK1: with the enable low the DSU is inert
    a_inert_when_disabled: assert property (@(posedge clk) disable iff (!rst_n)
        dsu_en || !(dsu_busy || dsu_rd_valid || illegal_instr || control[`MAC_CTRL_EN] || sat_op))
        else $error("[SVA-FAIL] DSU F14: the DSU acted with dsu_en low (busy=%b rdv=%b ill=%b ctrl=%b sat=%b instr=%08x)",
                    dsu_busy, dsu_rd_valid, illegal_instr, control, sat_op, instr);
    // F15 / F16 / F17: the interlock -- one cycle, exactly for a read of the
    // accumulator the previous two-cycle instruction addressed, never across
    // accumulators
    a_single_cycle: assert property (@(posedge clk) disable iff (!rst_n)
        !(dsu_busy && busy_q))
        else $error("[SVA-FAIL] DSU F15: busy held for two cycles");
    a_interlock_fires: assert property (@(posedge clk) disable iff (!rst_n)
        !(reads_acc && p2 && pacc == acc_sel && !busy_q && !flush) || dsu_busy)
        else $error("[SVA-FAIL] DSU F16: read of a pending accumulator not interlocked");
    a_interlock_per_acc: assert property (@(posedge clk) disable iff (!rst_n)
        !dsu_busy || (p2 && pacc == acc_sel && reads_acc))
        else $error("[SVA-FAIL] DSU F17: busy without a pending write to the same accumulator");
    // F11.CHK1 / CHK2: the overflow flag is sticky, and a set beats a clear
    a_ovf_sticky: assert property (@(posedge clk) disable iff (!rst_n)
        !hold_q || dsu_overflow)
        else $error("[SVA-FAIL] DSU F11: the overflow flag dropped without a clear");
    a_ovf_set_beats_clear: assert property (@(posedge clk) disable iff (!rst_n)
        !set_q || dsu_overflow)
        else $error("[SVA-FAIL] DSU F11: an overflow in the clear cycle was lost");
    // F23.CHK1: the debug taps are the accumulators, every cycle
    a_taps_live: assert property (@(posedge clk) disable iff (!rst_n)
        dbg_acc_0 == acc0 && dbg_acc_1 == acc1 && dbg_acc_2 == acc2)
        else $error("[SVA-FAIL] DSU F23: a debug tap differs from its accumulator");

    c_busy:         cover property (@(posedge clk) disable iff (!rst_n) dsu_busy);
    c_accsel3:      cover property (@(posedge clk) disable iff (!rst_n) rtype && instr[26:25] == 2'b11);
    c_set_and_clear: cover property (@(posedge clk) disable iff (!rst_n)
                         ((|mac_overflow) | sat_overflow) && csr_clear_overflow);
endmodule

bind mac_unit mac_unit_sva u_mac_sva (
    .clk(clk), .rst_n(rst_n), .en(en), .sat_writeback_en(sat_writeback_en), .flush(flush),
    .pending(pending), .acc_we(acc_we), .overflow(overflow), .is_accum(is_accum),
    .prod_en(prod_en), .my_sat(my_sat), .my_load(my_load), .my_clear(my_clear), .acc(acc)
);
bind dsu_top dsu_top_sva u_dsu_props_a (
    .clk(clk), .rst_n(rst_n), .flush(flush), .dsu_en(dsu_en), .instr(instr),
    .csr_clear_overflow(csr_clear_overflow), .dsu_busy(dsu_busy), .dsu_rd_valid(dsu_rd_valid),
    .dsu_overflow(dsu_overflow), .illegal_instr(illegal_instr), .control(control),
    .sat_op(sat_op), .shift_op(shift_op), .rd_lo_op(rd_lo_op), .rd_hi_op(rd_hi_op), .acc_sel(acc_sel),
    .mac_overflow(mac_overflow), .sat_overflow(sat_overflow),
    .dbg_acc_0(dbg_acc_0), .dbg_acc_1(dbg_acc_1), .dbg_acc_2(dbg_acc_2),
    .acc0(u_cluster.u_mac0.acc), .acc1(u_cluster.u_mac1.acc), .acc2(u_cluster.u_mac2.acc)
);
`endif
