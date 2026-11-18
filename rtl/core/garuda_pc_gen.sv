// ============================================================================
// GARUDA SoC - Block I: Processor Core
// Module      : garuda_pc_gen
// Description : PC Generator - the speculative fetch pointer (`fetch_pc`).
// Spec Ref    : AERO-GARUDA-DS-001 Rev 1.0, Sec.6.2
// ============================================================================
//
// `fetch_pc` - speculative pointer driving the I-port. Advances each time
//              the AHB master accepts a new address phase.
//
// On redirect (branch/JALR/trap/MRET) it reloads with the target address
// (Sec.6.2, Sec.6.5). The address of the instruction entering ID travels with
// it from the prefetch buffer (its pc tag). Until 2026-11-16 this module also
// kept an "architectural pc" register advanced on every pop; nothing read it
// (HAL UNCONN), so it was removed with its commit inputs (zero-waiver F4).
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
    output reg [WORD_W-1:0] fetch_pc_o
);
    timeunit 1ns;
    timeprecision 1ps;

    always_ff @(posedge gclk or negedge core_rst_n) begin : p_fetch_pc
        if (!core_rst_n) begin
            fetch_pc_o <= RESET_VECTOR;
        end else if (redirect_i) begin
            fetch_pc_o <= redirect_pc_i;
        end else if (fetch_issue_i) begin
            fetch_pc_o <= WORD_W'(fetch_pc_o + 32'd4);  // wraps by design
        end
    end

endmodule
