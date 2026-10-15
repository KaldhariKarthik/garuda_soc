`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - DSU : functional coverage of the DSU
// dsu_cov.sv
//
// From GARUDA-DSU-SPEC-001 (the ten Custom-0 instructions, the accumulators,
// saturation, overflow, the stall). Bound to dsu_top, so it samples in the DSU
// bench, in the core benches with the real DSU and in every chip run.
// One sample per DSU instruction that reaches the decoder (dsu_en, opcode
// Custom-0, not flushed). The coverpoints are the decisions of the decoder,
// the operand router, the MAC cluster, the barrel shifter, the saturation
// unit, the readback mux and the result selector, taken where they are made.
// Not for synthesis, not under Icarus or Verilator.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
`ifndef VERILATOR
module dsu_cov (
    input wire        clk, rst_n, flush, dsu_en, dsu_busy, dsu_overflow, csr_clear_overflow,
    input wire [31:0] instr, rs1, rs2,
    input wire        illegal_instr,
    input wire [47:0] acc0, acc1, acc2,
    input wire        sat_overflow
);
    typedef enum {MAC, MACSUB, MACABS, MACDOT, MACLOAD, MACCLEAR, MACSAT, RD_LO, RD_HI, MACSHIFT, ILLEGAL} op_e;
    typedef enum {ZERO, ONE, MINUS_ONE, POS, NEG, MAX_POS, MIN_NEG} cls_e;
    wire is_custom0 = instr[6:0] == 7'b0001011;
    wire [2:0] f3 = instr[14:12];
    wire [4:0] f5 = instr[31:27];
    wire [1:0] acc_sel = (f3 == 3'd1) ? instr[27:26] : instr[26:25];
    op_e op; cls_e c1, c2; reg [47:0] acc_now;
    function automatic cls_e cls(input [15:0] v);
        if (v == 16'h0000) cls = ZERO; else if (v == 16'h0001) cls = ONE; else if (v == 16'hFFFF) cls = MINUS_ONE;
        else if (v == 16'h7FFF) cls = MAX_POS; else if (v == 16'h8000) cls = MIN_NEG;
        else if (v[15]) cls = NEG; else cls = POS;
    endfunction
    always @(*) begin
        if (illegal_instr) op = ILLEGAL;
        else if (f3 == 3'd1) op = MACSHIFT;
        else case (f5) 5'd0: op = MAC; 5'd1: op = MACSUB; 5'd2: op = MACABS; 5'd3: op = MACDOT; 5'd4: op = MACLOAD;
                       5'd5: op = MACCLEAR; 5'd6: op = MACSAT; 5'd7: op = RD_LO; 5'd8: op = RD_HI; default: op = ILLEGAL; endcase
        c1 = cls(rs1[15:0]); c2 = cls(rs2[15:0]);
        acc_now = (acc_sel == 2'd0) ? acc0 : (acc_sel == 2'd1) ? acc1 : acc2;
    end
    wire take = rst_n && dsu_en && is_custom0 && !flush;

    covergroup cg_instr @(posedge clk iff take);
        option.per_instance = 1;
        cp_op: coverpoint op;
        cp_acc: coverpoint acc_sel { bins acc[] = {[0:2]}; bins reserved = {3}; }
        cp_rs1: coverpoint c1;
        cp_rs2: coverpoint c2;
        // the accumulator the instruction works on: empty, positive, negative, at the edge of saturation
        cp_acc_state: coverpoint acc_now {
            bins zero = {48'd0}; bins neg = {[48'h8000_0000_0000:48'hFFFF_FFFF_FFFF]};
            bins small_pos = {[48'd1:48'h0000_7FFF_FFFF]}; bins above_32bit = {[48'h0000_8000_0000:48'h7FFF_FFFF_FFFF]};
        }
        cp_shift_amt: coverpoint instr[25:20] iff (op == MACSHIFT) { bins zero = {0}; bins short_ = {[1:15]}; bins mid = {[16:31]}; bins long_ = {[32:47]}; }
        cp_shift_dir: coverpoint instr[28] iff (op == MACSHIFT);
        // why an encoding is illegal
        cp_illegal_why: coverpoint {f3 > 3'd1, (f3 == 3'd0) && (f5 > 5'd8), acc_sel == 2'd3, (f3 == 3'd1) && (instr[25:20] >= 6'd48)} iff (op == ILLEGAL) {
            bins bad_funct3 = {4'b1000}; bins unknown_funct5 = {4'b0100}; bins reserved_acc = {4'b0010}; bins shift_too_far = {4'b0001};
        }
        x_op_acc: cross cp_op, cp_acc { ignore_bins na = binsof(cp_op) intersect {ILLEGAL} || binsof(cp_acc.reserved); }
        // the arithmetic instructions against operand corners (16-bit lanes)
        x_arith_operands: cross cp_op, cp_rs1, cp_rs2 { ignore_bins na = !binsof(cp_op) intersect {MAC, MACSUB, MACABS, MACDOT}; }
        x_op_accstate: cross cp_op, cp_acc_state { ignore_bins na = binsof(cp_op) intersect {ILLEGAL, MACLOAD, MACCLEAR}; }
        x_shift: cross cp_shift_amt, cp_shift_dir;
    endgroup

    // overflow and saturation, flush and stall
    reg ovf_d = 1'b0;
    always @(posedge clk) ovf_d <= dsu_overflow;
    covergroup cg_events @(posedge clk iff rst_n);
        option.per_instance = 1;
        cp_overflow_rise: coverpoint (dsu_overflow && !ovf_d);
        cp_sat_clamped: coverpoint sat_overflow iff (take && op == MACSAT);
        cp_clear: coverpoint csr_clear_overflow iff (dsu_overflow);
        cp_flush_busy: coverpoint {flush, dsu_busy} { bins flush_while_busy = {2'b11}; bins flush_idle = {2'b10}; bins busy = {2'b01}; }
        cp_back_to_back: coverpoint (take && dsu_busy);
    endgroup
    cg_instr ci = new(); cg_events ce = new();
endmodule

bind dsu_top dsu_cov u_dsu_cov (
    .clk(clk), .rst_n(rst_n), .flush(flush), .dsu_en(dsu_en), .dsu_busy(dsu_busy),
    .dsu_overflow(dsu_overflow), .csr_clear_overflow(csr_clear_overflow),
    .instr(instr), .rs1(rs1), .rs2(rs2), .illegal_instr(illegal_instr),
    .acc0(dbg_acc_0), .acc1(dbg_acc_1), .acc2(dbg_acc_2), .sat_overflow(sat_overflow));
`endif
`endif
`endif
