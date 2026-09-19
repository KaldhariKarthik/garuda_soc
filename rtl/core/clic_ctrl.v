`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block I: Processor Core
// clic_ctrl.v - CLIC interrupt take and wake conditions
// Spec: GARUDA-CORE-SPEC-001 Rev 3.0 §7.5, GARUDA-CLIC-SPEC-001 Rev 2.0 §7.4
//
// Core runs CLIC-mode (mtvec.MODE = 3). Block 10 presents the winning source
// as {valid, id[4:0], level[7:0]}; the take decision is made here, next to the
// CSRs it reads ([N-1.1] of the CLIC spec).
//
// Take condition (both level compares strictly >):
//   valid & MIE & (level > mintthresh) & (level > mintstatus.mil)
// Wake condition (MIE-independent): valid. WFI wakes on it even if MIE=0.
//
// Rev 4.0 removes the SHV/mtvt vectoring, the acknowledge handshake and the
// 12-bit id of the Rev 1.1 interface: every source is level-triggered and is
// cleared in its own peripheral, and every trap enters at mtvec BASE (D-15).
// =============================================================================

module clic_ctrl #(
    parameter ID_W = 5
)(
    // external CLIC interface (GARUDA-CLIC-SPEC-001 §5): winning id + level,
    // level-triggered - there is no acknowledge and no SHV in Rev 4.0.
    input  wire            clic_irq_valid_i,
    input  wire [ID_W-1:0] clic_irq_id_i,
    input  wire [7:0]      clic_irq_level_i,

    // from csr_file
    input  wire            mstatus_mie_i,
    input  wire [7:0]      mintthresh_i,
    input  wire [7:0]      mintstatus_mil_i,
    input  wire [31:0]     mtvec_i,          // BASE, 4-byte aligned

    // to trap_ctrl
    output wire            take_cond_o,      // CORE [N-7.15]
    output wire            wake_cond_o,      // CORE [N-7.27], MIE-independent
    output wire [ID_W-1:0] irq_id_o,
    output wire [7:0]      irq_lvl_o,
    output wire [31:0]     vector_target_o
);
    // Both comparisons strictly greater ([N-7.16]).
    wire lvl_gt_thresh = (clic_irq_level_i > mintthresh_i);
    wire lvl_gt_active = (clic_irq_level_i > mintstatus_mil_i);

    assign take_cond_o = clic_irq_valid_i & mstatus_mie_i & lvl_gt_thresh & lvl_gt_active;
    assign wake_cond_o = clic_irq_valid_i;

    assign irq_id_o    = clic_irq_id_i;
    assign irq_lvl_o   = clic_irq_level_i;

    // Non-vectored: every trap enters at mtvec BASE (D-15, erratum T-5). The
    // handler reads mcause[4:0] for the source id.
    assign vector_target_o = mtvec_i;
endmodule
`default_nettype wire
