`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block I: Processor Core
// wb_stage.v - Write-Back Stage (Sec. 5, Sec. 10.3)
// Document: AERO-GARUDA-DS-001 Rev 1.1
//
// Under the mux-in-MEM contract (Sec. 5.2 / Sec. 10.3), the mem_to_reg mux
// is done in MEM, so wb_data arrives ALREADY FINAL (load-formatted value
// for loads, EX result for everything else: ALU / MUL / DSU MACRD / CSR
// rdata / JAL-JALR link). WB therefore holds no datapath logic - it is a
// named structural boundary (matching the Sec. 5 block diagram) that drives
// the register-file write port. It is the reserved insertion point for any
// future WB-side logic; today it is a pass-through.
//
// x0-write guard lives in the register file (regfile.v), not here.
// The WB->ID bypass also lives in regfile.v; these rf_* signals feed it.
// =============================================================================

module wb_stage (
    // From MEM/WB register
    input  wire [31:0] wb_data_i,      // final writeback value
    input  wire [4:0]  rd_i,           // destination register index
    input  wire        reg_write_i,    // writeback enable

    // To register-file write port (regfile.v: wb_reg_write_i/wb_rd_i/wb_data_i)
    output wire        rf_we_o,
    output wire [4:0]  rf_rd_o,
    output wire [31:0] rf_wdata_o
);

    assign rf_we_o    = reg_write_i;
    assign rf_rd_o    = rd_i;
    assign rf_wdata_o = wb_data_i;

endmodule
