`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - DSU : properties of the DSU's control
// dsu_sva.sv
//
// Spec: GARUDA-DSU-SPEC-001. The DSU's arithmetic is checked result by result
// against DSUModel in tb_dsu_top (make test_dsu); these properties are the control
// rules a data comparison does not see: what an illegal encoding, a flush or a
// stall may and may not do, which accumulator an instruction may touch, and the
// overflow flag. Bound to dsu_top, so they run in the DSU bench, in the core
// benches with the real DSU and in every chip program. Property set of
// flow/formal/dsu/dsu_fpv.tcl. Not for synthesis, not under Icarus (TOOL-B2).
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module dsu_sva (
    input wire        clk, rst_n, flush, dsu_en, csr_clear_overflow,
    input wire [31:0] instr,
    input wire        dsu_busy, dsu_rd_valid, dsu_overflow, illegal_instr,
    input wire [4:0]  dsu_rd_addr,
    input wire [47:0] acc0, acc1, acc2,
    input wire [6:0]  control,
    input wire [1:0]  acc_sel,
    input wire        sat_writeback_en, writes_regfile,
    input wire [2:0]  mac_overflow,
    input wire        sat_overflow
);
    wire is_c0  = instr[6:0] == 7'b0001011;
    wire [2:0] f3 = instr[14:12];
    wire [4:0] f5 = instr[31:27];
    wire issued = rst_n && dsu_en && is_c0;
    wire any_ovf = (|mac_overflow) | sat_overflow;

    // ---- decode: what is illegal (DSU spec section 5) -------------------------------
    a_illegal_funct3: assert property (@(posedge clk) disable iff (!rst_n)
        (issued && f3 > 3'd1) |-> illegal_instr )
        else $error("[SVA-FAIL] a_illegal_funct3: a Custom-0 funct3 other than 0 and 1 was accepted");
    a_illegal_funct5: assert property (@(posedge clk) disable iff (!rst_n)
        (issued && f3 == 3'd0 && f5 > 5'd8) |-> illegal_instr )
        else $error("[SVA-FAIL] a_illegal_funct5: an unknown R-type funct5 was accepted");
    a_illegal_acc3: assert property (@(posedge clk) disable iff (!rst_n)
        (issued && f3 == 3'd0 && instr[26:25] == 2'b11 && f5 <= 5'd8) |-> illegal_instr )
        else $error("[SVA-FAIL] a_illegal_acc3: accumulator 3 (reserved) was accepted");
    a_illegal_shift: assert property (@(posedge clk) disable iff (!rst_n)
        (issued && f3 == 3'd1 && instr[25:20] >= 6'd48) |-> illegal_instr )
        else $error("[SVA-FAIL] a_illegal_shift: a shift by 48 or more was accepted");
    a_illegal_only_custom0: assert property (@(posedge clk) disable iff (!rst_n)
        illegal_instr |-> (dsu_en && is_c0) )
        else $error("[SVA-FAIL] a_illegal_only_custom0: an illegal-instruction report for a non-DSU instruction");
    // an illegal encoding has no effect: no accumulator change, no register write
    a_illegal_no_effect: assert property (@(posedge clk) disable iff (!rst_n)
        illegal_instr |-> (!control[6] && !dsu_rd_valid) )
        else $error("[SVA-FAIL] a_illegal_no_effect: an illegal encoding enabled the MAC or a register write");
    a_illegal_acc_unchanged: assert property (@(posedge clk) disable iff (!rst_n)
        (illegal_instr && !(sel0_d || sel1_d || sel2_d)) |=> $stable({acc0, acc1, acc2}) )
        else $error("[SVA-FAIL] a_illegal_acc_unchanged: an illegal encoding changed an accumulator");

    // ---- flush: a squashed instruction leaves no trace ----------------------------------
    a_flush_acc_unchanged: assert property (@(posedge clk) disable iff (!rst_n)
        (flush && !(sel0_d || sel1_d || sel2_d)) |=> $stable({acc0, acc1, acc2}) )
        else $error("[SVA-FAIL] a_flush_acc_unchanged: a flushed DSU instruction changed an accumulator");
    a_flush_no_write: assert property (@(posedge clk) disable iff (!rst_n)
        (flush && !dsu_busy) |-> !(dsu_rd_valid && !writes_regfile) )
        else $error("[SVA-FAIL] a_flush_no_write: inconsistent register write under flush");

    // ---- only the selected accumulator changes ----------------------------------------------
    // The MAC is a two-stage pipeline (mac_unit.v, DSU-4): an instruction presented in cycle t
    // writes its accumulator at the end of t or t+1. An accumulator may change only when it was
    // selected by a legal, unflushed DSU instruction in this cycle or the one before.
    wire sel0 = issued && !illegal_instr && acc_sel == 2'd0;
    wire sel1 = issued && !illegal_instr && acc_sel == 2'd1;
    wire sel2 = issued && !illegal_instr && acc_sel == 2'd2;
    reg  sel0_d = 1'b0, sel1_d = 1'b0, sel2_d = 1'b0;
    always @(posedge clk) begin sel0_d <= sel0; sel1_d <= sel1; sel2_d <= sel2; end
    a_only_acc0: assert property (@(posedge clk) disable iff (!rst_n)
        !(sel0 || sel0_d) |=> $stable(acc0) )
        else $error("[SVA-FAIL] a_only_acc0: accumulator 0 changed without an instruction selecting it");
    a_only_acc1: assert property (@(posedge clk) disable iff (!rst_n)
        !(sel1 || sel1_d) |=> $stable(acc1) )
        else $error("[SVA-FAIL] a_only_acc1: accumulator 1 changed without an instruction selecting it");
    a_only_acc2: assert property (@(posedge clk) disable iff (!rst_n)
        !(sel2 || sel2_d) |=> $stable(acc2) )
        else $error("[SVA-FAIL] a_only_acc2: accumulator 2 changed without an instruction selecting it");

    // ---- the stall (DSU spec: a read or saturate right after a compute on the same accumulator) --
    a_stall_one_cycle: assert property (@(posedge clk) disable iff (!rst_n)
        (dsu_busy && !flush) |=> !dsu_busy )
        else $error("[SVA-FAIL] a_stall_one_cycle: the DSU stalled for more than one cycle");
    a_stall_needs_dsu: assert property (@(posedge clk) disable iff (!rst_n)
        dsu_busy |-> issued )
        else $error("[SVA-FAIL] a_stall_needs_dsu: busy without a DSU instruction");
    a_no_result_when_busy: assert property (@(posedge clk) disable iff (!rst_n)
        dsu_rd_valid |-> !dsu_busy )
        else $error("[SVA-FAIL] a_no_result_when_busy: a result while the DSU stalls");
    a_rd_addr: assert property (@(posedge clk) disable iff (!rst_n)
        dsu_rd_valid |-> dsu_rd_addr == instr[11:7] )
        else $error("[SVA-FAIL] a_rd_addr: the result goes to a register other than rd");

    // ---- the overflow flag: set by any overflow, sticky until the CSR clears it -----------------------
    a_ovf_set: assert property (@(posedge clk) disable iff (!rst_n)
        any_ovf |=> dsu_overflow )
        else $error("[SVA-FAIL] a_ovf_set: an overflow did not set the flag");
    a_ovf_sticky: assert property (@(posedge clk) disable iff (!rst_n)
        (dsu_overflow && !csr_clear_overflow) |=> dsu_overflow )
        else $error("[SVA-FAIL] a_ovf_sticky: the overflow flag dropped without a clear");
    a_ovf_clear: assert property (@(posedge clk) disable iff (!rst_n)
        (csr_clear_overflow && !any_ovf) |=> !dsu_overflow )
        else $error("[SVA-FAIL] a_ovf_clear: the CSR clear did not clear the flag");
    a_ovf_cause: assert property (@(posedge clk) disable iff (!rst_n)
        $rose(dsu_overflow) |-> $past(any_ovf) )
        else $error("[SVA-FAIL] a_ovf_cause: the overflow flag rose with no overflow");

    c_stall:      cover property (@(posedge clk) dsu_busy);
    c_flush_busy: cover property (@(posedge clk) flush && dsu_busy);
    c_illegal:    cover property (@(posedge clk) illegal_instr);
    c_overflow:   cover property (@(posedge clk) $rose(dsu_overflow));
    c_sat:        cover property (@(posedge clk) sat_writeback_en);
endmodule

bind dsu_top dsu_sva u_dsu_sva (
    .clk(clk), .rst_n(rst_n), .flush(flush), .dsu_en(dsu_en), .csr_clear_overflow(csr_clear_overflow),
    .instr(instr), .dsu_busy(dsu_busy), .dsu_rd_valid(dsu_rd_valid), .dsu_overflow(dsu_overflow),
    .illegal_instr(illegal_instr), .dsu_rd_addr(dsu_rd_addr),
    .acc0(dbg_acc_0), .acc1(dbg_acc_1), .acc2(dbg_acc_2), .control(control), .acc_sel(acc_sel),
    .sat_writeback_en(sat_writeback_en), .writes_regfile(writes_regfile),
    .mac_overflow(mac_overflow), .sat_overflow(sat_overflow));
`endif
`endif
