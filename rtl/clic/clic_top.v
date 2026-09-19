`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 10 : Core-Local Interrupt Controller
// clic_top.v
//
// Spec: GARUDA-CLIC-SPEC-001 Rev 2.0 (Rev 4.0 set); ADR-0009, ADR-0010
//
// Aggregates 32 level-triggered sources into one winning {id, level} for the
// core's clic_ctrl, which makes the take decision against mstatus.MIE,
// mintthresh and mintstatus.mil ([N-1.1]). This block has no threshold input,
// no acknowledge, no edge detection and no vectoring - Rev 2.0 of this
// document removed all four, and the Rev 2.0-set RTL that had them is gone.
//
//   pending[n] = irq_src_i[n]        combinational ([N-7.1])
//   cand[n]    = pending[n] & CLICIE[n]
//   winner     = max {level, ~id} over cand ([N-7.5])
//
// The ID map is applied by the SoC top (irq_src_i is positioned per the
// generated GARUDA_CLIC_ID_* constants, [N-5.2]). irq_src_i[0] must be tied
// low (ID 0 is the sentinel, [N-7.12]).
// =============================================================================

module clic_top #(
    parameter integer N       = 32,
    parameter [31:0]  IE_MASK = 32'h007F_9FFE
)(
    input  wire          hclk_i,
    input  wire          hreset_n_i,
    input  wire          pclk_i,
    input  wire          preset_n_i,

    // ---- APB slave, window 10 ----------------------------------------------
    input  wire          psel_i,
    input  wire          penable_i,
    input  wire          pwrite_i,
    input  wire [11:0]   paddr_i,
    input  wire [31:0]   pwdata_i,
    output wire [31:0]   prdata_o,
    output wire          pready_o,
    output wire          pslverr_o,

    // ---- sources (hclk domain, level) ----------------------------------------
    input  wire [N-1:0]  irq_src_i,

    // ---- to the core ------------------------------------------------------------
    output wire          clic_irq_valid_o,
    output wire [4:0]    clic_irq_id_o,
    output wire [7:0]    clic_irq_level_o
);

    wire [N-1:0]   ie;
    wire [N*8-1:0] level;

    clic_apb #(.N(N), .IE_MASK(IE_MASK)) u_apb (
        .pclk_i(pclk_i), .preset_n_i(preset_n_i),
        .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i),
        .paddr_i(paddr_i), .pwdata_i(pwdata_i), .prdata_o(prdata_o),
        .pready_o(pready_o), .pslverr_o(pslverr_o),
        .pending_i(irq_src_i), .ie_o(ie), .level_o(level));

    clic_select #(.N(N)) u_sel (
        .cand_i(irq_src_i & ie), .level_i(level),
        .valid_o(clic_irq_valid_o), .id_o(clic_irq_id_o), .level_o(clic_irq_level_o));

    wire _unused = |{hclk_i, hreset_n_i};

endmodule

`default_nettype wire
