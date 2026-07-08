`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block I: Processor Core - ID Stage, Sub-block 3/5
// Register File  (Verilog)
//
// Spec reference: AERO-GARUDA-DS-001 Rev 1.0, Sec. 5.3, Sec. 7.4
//
// Architectural register file: 32x32-bit (x0-x31), x0 hardwired to zero.
// Write is synchronous, read is combinational. Two read ports (rs1, rs2),
// one write port (WB). A third read port is NOT implemented - the DSU
// never reads back through the register file (Sec. 5.3).
//
// Read-during-write returns the new value via a WB->ID bypass, removing a
// structural hazard on back-to-back dependent ops (Sec. 7.4). x0 writes are
// discarded; x0 reads return 0.
// =============================================================================

module regfile (
    input  wire         clk_i,
    input  wire         rst_n_i,

    input  wire [4:0]  rs1_idx_i,
    input  wire [4:0]  rs2_idx_i,

    input  wire         wb_reg_write_i,
    input  wire [4:0]  wb_rd_i,
    input  wire [31:0] wb_data_i,

    output wire [31:0] rs1_data_o,
    output wire [31:0] rs2_data_o
);

    reg [31:0] mem [1:31];   // x0 not stored - reads as 0 by construction
    wire [31:0] rs1_raw, rs2_raw;

    always @(posedge clk_i) begin
        if (wb_reg_write_i && (wb_rd_i != 5'd0)) begin
            mem[wb_rd_i] <= wb_data_i;
        end
    end

    assign rs1_raw = (rs1_idx_i == 5'd0) ? 32'd0 : mem[rs1_idx_i];
    assign rs2_raw = (rs2_idx_i == 5'd0) ? 32'd0 : mem[rs2_idx_i];

    // WB->ID bypass: same-cycle write and read to the same nonzero register
    // forwards the new value instead of the stale array read (Sec. 7.4).
    assign rs1_data_o = (wb_reg_write_i && (wb_rd_i != 5'd0) && (wb_rd_i == rs1_idx_i))
                           ? wb_data_i : rs1_raw;
    assign rs2_data_o = (wb_reg_write_i && (wb_rd_i != 5'd0) && (wb_rd_i == rs2_idx_i))
                           ? wb_data_i : rs2_raw;

endmodule

`default_nettype wire
