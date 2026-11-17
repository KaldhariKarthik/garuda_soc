// ============================================================================
// GARUDA SoC - Block I: Processor Core
// Module      : garuda_pc_gen
// Description : PC Generator - maintains the architectural PC (`pc`) and the
//               speculative fetch pointer (`fetch_pc`).
// Spec Ref    : AERO-GARUDA-DS-001 Rev 1.0, Sec.6.2
// ============================================================================
//
// `pc`       - address of the instruction currently entering ID. Advances
//              when the prefetch buffer pops an entry to the pipeline.
// `fetch_pc` - speculative pointer driving the I-port. Advances each time
//              the AHB master accepts a new address phase. Runs ahead of
//              `pc` by up to the buffer depth.
//
// On redirect (branch/JALR/trap/MRET), both pointers reload with the
// target address in the same cycle (Sec.6.2, Sec.6.5).
// ============================================================================

module garuda_pc_gen
    import garuda_pkg::*;
#(
    // Boot ROM (GARUDA_RESET_VECTOR)
    parameter [31:0] RESET_VECTOR = 32'h1000_0000
) (
    input wire gclk,
    input wire core_rst_n,
    // Redirect (from redirect mux, external to IF)
    input wire redirect_i,
    input wire [WORD_W-1:0] redirect_pc_i,
    // From I-port AHB master: pulse when a new address phase is accepted
    // this cycle using the CURRENT fetch_pc_o value.
    input wire fetch_issue_i,
    // From prefetch buffer: pulse when an entry is popped to the pipeline,
    // plus the PC tag of that popped entry (pc advances to popped_pc + 4).
    input wire commit_i,
    input wire [WORD_W-1:0] commit_pc_i,
    output reg [WORD_W-1:0] pc_o,
    output reg [WORD_W-1:0] fetch_pc_o
);
    timeunit 1ns;
    timeprecision 1ps;

    always_ff @(posedge gclk or negedge core_rst_n) begin : p_pc
        if (!core_rst_n) begin
            pc_o <= RESET_VECTOR;
            fetch_pc_o <= RESET_VECTOR;
        end else if (redirect_i) begin
            pc_o <= redirect_pc_i;
            fetch_pc_o <= redirect_pc_i;
        end else begin
            if (commit_i) begin
                pc_o <= commit_pc_i + 32'd4;
            end
            if (fetch_issue_i) begin
                fetch_pc_o <= fetch_pc_o + 32'd4;
            end
        end
    end

endmodule
