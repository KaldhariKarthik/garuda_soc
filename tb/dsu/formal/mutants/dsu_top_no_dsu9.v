// MUTANT dsu_no_dsu9: rtl/dsu/dsu_top.sv with ONE fix reverted (DSU-9: busy not gated by dsu_en).
// Regenerated 2026-11-16 from the current RTL; it differs from it by this change only. Formal negative control: must FAIL. (tb/dsu/formal/dsu.toml dsu_no_dsu9)
//dsu_top.v

module dsu_top
    import garuda_pkg::*;
    import dsu_pkg::*;
(
    input wire gclk,
    input wire core_rst_n,
    input wire flush,
    input wire dsu_en,
    input wire [WORD_W-1:0] instr,
    input wire [WORD_W-1:0] rs1_val,
    input wire [WORD_W-1:0] rs2_val,
    input wire csr_clear_overflow,
    output wire dsu_busy,
    output wire [WORD_W-1:0] dsu_rd_data,
    output wire dsu_rd_valid,
    output wire [REG_IDX_W-1:0] dsu_rd_addr,
    output wire dsu_overflow,
    // an accumulate folds this cycle: dsu_overflow may still change (DSU-14)
    output wire ovf_pending,
    output wire illegal_instr,
    output wire [ACC_W-1:0] dbg_acc_fx,
    output wire [ACC_W-1:0] dbg_acc_fy,
    output wire [ACC_W-1:0] dbg_acc_mag
);
    timeunit 1ns;
    timeprecision 1ps;

    wire [MAC_CTRL_W-1:0] control;
    wire [ACC_SEL_W-1:0]             acc_sel;
    wire                   sat_op;
    wire [SHAMT_W-1:0]             shift_amt;
    wire                   shift_dir;
    wire [ACC_SEL_W-1:0]             shift_acc_sel;
    wire [RES_SRC_W-1:0]             result_src;
    wire                   writes_regfile;
    wire [REG_IDX_W-1:0]             rd_addr_w;
    wire [FUNCT5_W-1:0]             funct5_w;
    wire [FUNCT3_W-1:0]             funct3_w;
    wire                   is_custom0_w;

    dsu_decoder u_decoder (
        .instr (instr),
        .dsu_en (dsu_en),
        .flush (flush),
        .control (control),
        .acc_sel (acc_sel),
        .sat_op (sat_op),
        .shift_amt (shift_amt),
        .shift_dir (shift_dir),
        .shift_acc_sel (shift_acc_sel),
        .result_src (result_src),
        .writes_regfile (writes_regfile),
        .rd_addr (rd_addr_w),
        .illegal_instr (illegal_instr),
        .funct5_fld (funct5_w),
        .funct3_fld (funct3_w),
        .is_custom0 (is_custom0_w)
    );

    wire [ACC_W-1:0] cluster_out;
    wire [ACC_W-1:0] sat_writeback;
    wire sat_overflow;

    // ERRATUM DSU-12 (proposed; found by sw/tests/t_dsu_b2b.S bit 2)
    // ------------------------------------------------------------
    // MACSAT behind a MAC on the same accumulator is held for one cycle by the
    // interlock (dsu_busy), precisely because the accumulator does not yet
    // include that MAC's product. But sat_op was not gated by dsu_busy, so the
    // saturation unit ran in the held cycle anyway: it clamped the STALE
    // accumulator, its write-back outranked the pending fold in mac_unit, and
    // the product was thrown away - and the sticky overflow flag was raised
    // for a value that never architecturally existed. Every other DSU output
    // already waits for ~dsu_busy (dsu_rd_valid); the saturate now does too.
    wire dsu_busy_w;
    // the gated MACSAT is also the write enable (F4 took the saturation
    // unit's copy of it, a feedthrough)
    wire sat_writeback_en = sat_op & ~dsu_busy_w;
    saturation_unit u_sat (
        .cluster_out (cluster_out),
        .sat_op (sat_writeback_en),
        .sat_writeback (sat_writeback),
        .sat_overflow (sat_overflow)
    );

    wire [NUM_ACC-1:0] mac_overflow;
    wire [NUM_ACC-1:0] mac_pending;
    assign ovf_pending = |mac_pending;

    mac_cluster u_cluster (
        .gclk (gclk),
        .core_rst_n (core_rst_n),
        .rs1_val (rs1_val),
        .rs2_val (rs2_val),
        .control (control),
        .acc_sel (acc_sel),
        .sat_writeback (sat_writeback),
        .sat_writeback_en (sat_writeback_en),
        .cluster_out (cluster_out),
        .overflow (mac_overflow),
        .pending (mac_pending),
        .dbg_acc_fx (dbg_acc_fx),
        .dbg_acc_fy (dbg_acc_fy),
        .dbg_acc_mag (dbg_acc_mag)
    );

    reg [ACC_W-1:0] shift_input;
    always_comb begin : c_shift_input
        case (shift_acc_sel)
            ACC_FX: shift_input = dbg_acc_fx;
            ACC_FY: shift_input = dbg_acc_fy;
            ACC_MAG: shift_input = dbg_acc_mag;
            default : shift_input
                = 48'b000000000000000000000000000000000000000000000000;
        endcase
    end

     wire [WORD_W-1:0] shift_result;
     barrel_shifter u_shifter (
        .cluster_out (shift_input),
        .shift_amt (shift_amt),
        .shift_dir (shift_dir),
        .shift_result (shift_result)
     );

    wire [WORD_W-1:0] rd_lo_data;
    wire [WORD_W-1:0] rd_hi_data;

    readback_mux u_rbmux (
        .cluster_out (cluster_out),
        .rd_lo_data (rd_lo_data),
        .rd_hi_data (rd_hi_data)
    );

    result_selector u_rsel (
        .result_src (result_src),
        .rd_lo_data (rd_lo_data),
        .rd_hi_data (rd_hi_data),
        .shift_result (shift_result),
        .dsu_rd_data (dsu_rd_data)
    );

    overflow_flag u_ovf (
        .gclk (gclk),
        .core_rst_n (core_rst_n),
        .mac_overflow (mac_overflow),
        .sat_overflow (sat_overflow),
        .csr_clear_overflow (csr_clear_overflow),
        .dsu_overflow (dsu_overflow)
    );

    // a custom-0 instruction the DSU is enabled for
    wire dsu_custom0 = is_custom0_w;  // MUTANT: DSU-9 fix reverted

    dsu_stall u_stall (
        .gclk (gclk),
        .core_rst_n (core_rst_n),
        .flush (flush),
        .funct5_fld (funct5_w),
        .funct3_fld (funct3_w),
        // ERRATUM DSU-9 -- dsu_busy was the ONE DSU output not gated by
        // dsu_en. Every other output carries `& dsu_en` (sat_op, shift_op,
        // rd_lo_op, rd_hi_op, writes_regfile, illegal_instr, mac_en), but
        // is_custom0 is a bare opcode compare, so with dsu_en low a Custom-0
        // word could still assert the interlock - stalling the pipeline for a
        // unit that is doing nothing. Gated here rather than inside dsu_stall:
        // the interlock is that module's job, whether the DSU is enabled at
        // all is the top level's.
        .is_custom0 (dsu_custom0),
        .acc_sel (acc_sel),
        .dsu_busy (dsu_busy_w)
    );
    assign dsu_busy = dsu_busy_w;

    assign dsu_rd_valid = writes_regfile & ~dsu_busy;
    assign dsu_rd_addr  = rd_addr_w;

endmodule
