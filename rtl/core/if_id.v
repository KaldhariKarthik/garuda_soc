`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block I: Processor Core
// if_id.v - IF/ID Pipeline Register (Sec. 5.2)
// Document: AERO-GARUDA-DS-001 Rev 1.1
//
// Carries {instr, pc, valid, fault} from IF to ID. On a bubble, valid=0 and
// instr=NOP (0x13); id_stage already qualifies decode with valid, so a bubble
// is inert. fault travels with the faulting fetch to be raised in ID (Sec.6.4).
//
// stall_i = hold (load-use / DSU hold / D-port wait); flush_i = bubble
// (mispredict / trap / redirect). flush strictly wins over stall (Sec. 11.4).
// Reset => bubble.
// =============================================================================
module if_id (
    input  wire        clk_i,
    input  wire        rst_n_i,
    input  wire        stall_i,
    input  wire        flush_i,

    input  wire [31:0] instr_i,         // if_stage_top.instr_o
    input  wire [31:0] pc_i,            // if_stage_top.instr_pc_o
    input  wire        valid_i,         // if_stage_top.instr_valid_o
    input  wire        fault_i,         // if_stage_top.instr_fault_o

    output reg  [31:0] instr_o,
    output reg  [31:0] pc_o,
    output reg         valid_o,
    output reg         fault_o
);
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i || flush_i) begin
            instr_o<=32'h0000_0013; pc_o<=32'd0; valid_o<=1'b0; fault_o<=1'b0;
        end else if (stall_i) begin
            // hold
        end else begin
            instr_o<=instr_i; pc_o<=pc_i; valid_o<=valid_i; fault_o<=fault_i;
        end
    end
endmodule
`default_nettype wire
