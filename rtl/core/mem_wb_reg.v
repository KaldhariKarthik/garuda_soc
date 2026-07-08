// ============================================================================
// GARUDA SoC — Block I: Processor Core
// mem_wb_reg.v — MEM/WB Pipeline Register (§5.2)
// Document: AERO-GARUDA-DS-001 Rev 1.0
//
// Carried fields per spec §5.2:
//   wb_data  — EX result or load data (selected in WB)
//   ctrl     — reg_write, mem_to_reg
//   rd       — destination register index
//
// Controls:
//   hold  — D-port wait state holds MEM stage
//   flush — trap flush discards this instruction
// ============================================================================
`include "garuda_defs.vh"

module mem_wb_reg (
    input  wire        clk,
    input  wire        rst_n,

    // ── Pipeline controls ────────────────────────────────────────────────
    input  wire        hold,            // D-port wait — retain contents
    input  wire        flush,           // trap flush — force bubble

    // ── MEM stage inputs ─────────────────────────────────────────────────
    input  wire [31:0] mem_result,      // EX result forwarded through MEM
    input  wire [31:0] mem_load_data,   // formatted load result
    input  wire [4:0]  mem_rd,          // destination register index
    input  wire        mem_reg_write,   // register write enable
    input  wire        mem_mem_to_reg,  // mux select: 1=load, 0=ex result

    // ── WB stage outputs ─────────────────────────────────────────────────
    output reg  [31:0] wb_result,
    output reg  [31:0] wb_load_data,
    output reg  [4:0]  wb_rd,
    output reg         wb_reg_write,
    output reg         wb_mem_to_reg
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            // Reset / flush → bubble (no writeback)
            wb_result     <= 32'd0;
            wb_load_data  <= 32'd0;
            wb_rd         <= 5'd0;
            wb_reg_write  <= 1'b0;   // write enable LOW = no WB
            wb_mem_to_reg <= 1'b0;
        end else if (!hold) begin
            // Normal advance
            wb_result     <= mem_result;
            wb_load_data  <= mem_load_data;
            wb_rd         <= mem_rd;
            wb_reg_write  <= mem_reg_write;
            wb_mem_to_reg <= mem_mem_to_reg;
        end
        // else: hold — retain current contents (D-port wait state)
    end

endmodule
