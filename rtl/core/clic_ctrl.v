`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block I: Processor Core
// clic_ctrl.v - CLIC interrupt take-condition, vectoring, ack (Sec. 14.3/14.5)
// Document: AERO-GARUDA-DS-001 Rev 1.1
//
// Core runs CLIC-mode (mtvec.mode=3). The external CLIC presents the winning
// source on clic_irq_i/_id_i/_lvl_i/_shv_i; the core's only outputs back are
// the one-cycle ack pulse (clic_irq_ack_o / clic_irq_id_ack_o).
//
// Take condition (Sec. 14.3, all ANDed; both level compares strictly >):
//   irq & MIE & (lvl > mintthresh) & (lvl > mintstatus.mil)
// Wake condition (Sec. 14.5, MIE-independent): irq present. WFI wakes on this
// even if MIE=0; whether it then TAKES the interrupt is the take condition.
//
// Vector target: SHV -> mtvt table entry (base + id*4); non-SHV -> mtvec.base.
// Both bases are 64-byte aligned in CLIC mode ({x[31:6],6'b0}).
//   NOTE: for SHV, this is the mtvt *table-entry address*. If the table holds
//   handler pointers requiring a hardware dereference (load), trap_ctrl issues
//   that vector fetch; if it holds jump instructions, fetch lands here directly.
//   Flagged for reconciliation with the SHV memory-model decision.
//
// take_i (from trap_ctrl) = "core is entering this interrupt now" -> emits the
// one-cycle ack with the taken id.
// =============================================================================
module clic_ctrl #(
    parameter ID_W = 12
)(
    // external CLIC interface
    input  wire            clic_irq_i,
    input  wire [ID_W-1:0] clic_irq_id_i,
    input  wire [7:0]      clic_irq_lvl_i,
    input  wire            clic_irq_shv_i,
    output wire            clic_irq_ack_o,
    output wire [ID_W-1:0] clic_irq_id_ack_o,

    // from csr_file
    input  wire            mstatus_mie_i,
    input  wire [7:0]      mintthresh_i,
    input  wire [7:0]      mintstatus_mil_i,
    input  wire [31:0]     mtvec_i,
    input  wire [31:0]     mtvt_i,

    // to trap_ctrl
    output wire            take_cond_o,       // Sec.14.3 take condition met
    output wire            wake_cond_o,       // Sec.14.5 wake (MIE-independent)
    output wire [ID_W-1:0] irq_id_o,
    output wire [7:0]      irq_lvl_o,
    output wire [31:0]     vector_target_o,

    // from trap_ctrl: this interrupt is being entered this cycle
    input  wire            take_i
);
    wire lvl_gt_thresh = (clic_irq_lvl_i > mintthresh_i);
    wire lvl_gt_active = (clic_irq_lvl_i > mintstatus_mil_i);

    assign take_cond_o = clic_irq_i & mstatus_mie_i & lvl_gt_thresh & lvl_gt_active;
    assign wake_cond_o = clic_irq_i;                       // MIE-independent (Sec.14.5)

    assign irq_id_o    = clic_irq_id_i;
    assign irq_lvl_o   = clic_irq_lvl_i;

    wire [31:0] mtvec_base = {mtvec_i[31:6], 6'b0};
    wire [31:0] mtvt_base  = {mtvt_i[31:6],  6'b0};
    wire [31:0] mtvt_entry = mtvt_base + ({20'd0, clic_irq_id_i} << 2);
    assign vector_target_o = clic_irq_shv_i ? mtvt_entry : mtvec_base;

    assign clic_irq_ack_o    = take_i;
    assign clic_irq_id_ack_o = clic_irq_id_i;
endmodule
`default_nettype wire
