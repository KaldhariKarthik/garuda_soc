`timescale 1ns/1ps
`default_nettype none
//=============================================================================
// dsu_top_stub.v -- COMPILE-ONLY STUB. DO NOT SYNTHESIZE. DO NOT COMMIT
//                   TO rtl/. Delete from any filelist that includes the
//                   real dsu_top.v (duplicate module definition).
//
// Port list transcribed 1:1 from AERO-GARUDA-DS-001 Section 9.2 (which is
// itself the frozen dsu_top.v boundary). Exists only so ex_stage.v elaborates
// standalone under iverilog/xrun before the real DSU is dropped in.
// Behavior: everything inert.
//=============================================================================

module dsu_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        flush,
    input  wire        dsu_en,
    input  wire [31:0] instr,
    input  wire [31:0] rs1,
    input  wire [31:0] rs2,
    input  wire        csr_clear_overflow,
    output wire        dsu_busy,
    output wire [31:0] dsu_rd_data,
    output wire        dsu_rd_valid,
    output wire [4:0]  dsu_rd_addr,
    output wire        dsu_overflow,
    output wire        illegal_instr,
    output wire [47:0] dbg_acc_0,
    output wire [47:0] dbg_acc_1,
    output wire [47:0] dbg_acc_2
);

    assign dsu_busy      = 1'b0;
    assign dsu_rd_data   = 32'b0;
    assign dsu_rd_valid  = 1'b0;
    assign dsu_rd_addr   = 5'b0;
    assign dsu_overflow  = 1'b0;
    assign illegal_instr = 1'b0;
    assign dbg_acc_0     = 48'b0;
    assign dbg_acc_1     = 48'b0;
    assign dbg_acc_2     = 48'b0;

endmodule

`default_nettype wire
