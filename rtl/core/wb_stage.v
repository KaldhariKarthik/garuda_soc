// ============================================================================
// GARUDA SoC — Block I: Processor Core
// wb_stage.v — Write-Back Stage (§5, §10.3)
// Document: AERO-GARUDA-DS-001 Rev 1.0
//
// Function:
//   1. wb_mux  — selects between load data and EX result
//   2. Drives register file write port (rd, wb_data, we)
//   3. WB→ID bypass is handled inside register_file.v
//
// Inputs from MEM/WB register:
//   wb_result     — EX result (ALU / MUL / DSU / CSR / link PC)
//   wb_load_data  — formatted load data from load_formatter
//   wb_rd         — destination register index
//   wb_reg_write  — write enable
//   wb_mem_to_reg — 1 = select load data, 0 = select EX result
//
// Outputs to register file:
//   rf_we         — write enable
//   rf_rd         — destination register index
//   rf_wdata      — value to write
// ============================================================================
`include "garuda_defs.vh"

module wb_stage (
    // ── Inputs from MEM/WB register ─────────────────────────────────────
    input  wire [31:0] wb_result,       // EX result (ALU/MUL/DSU/CSR/link)
    input  wire [31:0] wb_load_data,    // formatted load data (LB/LH/LW/LBU/LHU)
    input  wire [4:0]  wb_rd,           // destination register index
    input  wire        wb_reg_write,    // write enable from control
    input  wire        wb_mem_to_reg,   // mux select: 1=load, 0=EX result

    // ── Outputs to register file write port ──────────────────────────────
    output wire        rf_we,           // register file write enable
    output wire [4:0]  rf_rd,           // register file destination index
    output wire [31:0] rf_wdata         // register file write data
);

    // ====================================================================
    // wb_mux — select write-back value (§10.3)
    //
    // mem_to_reg = 1  → load instruction  → use load_formatter output
    // mem_to_reg = 0  → everything else   → use EX result
    //
    // Loads: formatted by load_formatter (sign/zero extended byte/half/word)
    // Everything else: ALU, MUL, DSU MACRD, CSR rdata, JAL/JALR link PC
    // ====================================================================
    assign rf_wdata = wb_mem_to_reg ? wb_load_data : wb_result;

    // ====================================================================
    // Register file write enable
    // x0 write guard: rf_we can be high but register_file.v discards
    // writes to x0 internally. No need to gate here.
    // ====================================================================
    assign rf_we = wb_reg_write;

    // ====================================================================
    // Destination register passthrough
    // ====================================================================
    assign rf_rd = wb_rd;

endmodule
