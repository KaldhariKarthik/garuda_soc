`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block I: Processor Core
// ex_mem.v - EX/MEM Pipeline Register (Sec. 5.2)
// Document: AERO-GARUDA-DS-001 Rev 1.1
//
// Datapath register feeding mem_stage. Field list matches mem_stage's inputs
// exactly (no adapter). Corrections vs original Sec. 5.2 table:
//   - pc     : CARRIED (was omitted) - mepc source for MEM-stage access faults
//              (causes 5/7), sourced from id_ex.pc around ex_stage.
//   - funct3 : carried from id_ex.funct3 (ex_stage does not re-emit it) - drives
//              d_hsize / load-format in MEM.
// EX->CONTROL signals (redirect, mispredict, dsu_busy, exceptions, csr_*) are
// EX-cycle signals consumed combinationally by CONTROL/hazard; they are NOT
// registered here.
//
// stall_i = hold (D-port wait upstream leg); flush_i = bubble (mispredict/trap).
// flush strictly wins over stall (Sec. 11.4). Reset => bubble.
// =============================================================================
module ex_mem (
    input  wire        clk_i,
    input  wire        rst_n_i,
    input  wire        stall_i,
    input  wire        flush_i,

    input  wire [31:0] ex_result_i,     // ex_stage.ex_result
    input  wire [31:0] store_data_i,    // ex_stage.store_data  -> mem_stage.rs2_data
    input  wire [2:0]  funct3_i,        // id_ex.funct3 (around EX)
    input  wire [4:0]  rd_i,            // ex_stage.rd_out
    input  wire [31:0] pc_i,            // id_ex.pc (around EX) - mepc
    input  wire        mem_read_i,      // ex_stage.mem_read_out
    input  wire        mem_write_i,     // ex_stage.mem_write_out
    input  wire        mem_to_reg_i,    // ex_stage.mem_to_reg_out
    input  wire        reg_write_i,     // ex_stage.reg_write_out

    output reg  [31:0] ex_result_o,
    output reg  [31:0] store_data_o,
    output reg  [2:0]  funct3_o,
    output reg  [4:0]  rd_o,
    output reg  [31:0] pc_o,
    output reg         mem_read_o,
    output reg         mem_write_o,
    output reg         mem_to_reg_o,
    output reg         reg_write_o
);
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i || flush_i) begin
            ex_result_o<=32'd0; store_data_o<=32'd0; funct3_o<=3'd0; rd_o<=5'd0; pc_o<=32'd0;
            mem_read_o<=1'b0; mem_write_o<=1'b0; mem_to_reg_o<=1'b0; reg_write_o<=1'b0;
        end else if (stall_i) begin
            // hold: retain all outputs
        end else begin
            ex_result_o<=ex_result_i; store_data_o<=store_data_i; funct3_o<=funct3_i;
            rd_o<=rd_i; pc_o<=pc_i; mem_read_o<=mem_read_i; mem_write_o<=mem_write_i;
            mem_to_reg_o<=mem_to_reg_i; reg_write_o<=reg_write_i;
        end
    end
endmodule
`default_nettype wire
