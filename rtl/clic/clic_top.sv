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
//   pending[n] = irq_src_i[n]        combinational ([N-7.1]); ID SWI_ID (23)
//                is CLICSWI[0], the software interrupt ([N-6.9])
//   cand[n]    = pending[n] & CLICIE[n]
//   winner     = max {level, ~id} over cand ([N-7.5])
//
// The ID map is applied by the SoC top (irq_src_i is positioned per the
// generated GARUDA_CLIC_ID_* constants, [N-5.2]). irq_src_i[0] must be tied
// low (ID 0 is the sentinel, [N-7.12]).
// =============================================================================

module clic_top
    import garuda_pkg::*;
#(
    parameter integer NUM_SRC       = 32'd32,
    parameter [31:0]  IE_MASK = 32'h00FF_FF7E,
    // = GARUDA_CLIC_ID_SOFTWARE, checked in clic_sva
    parameter integer SWI_ID  = 32'd23
)(
    input wire pclk,
    input wire preset_n,
    // ---- APB slave, window 10 ----------------------------------------------
    input wire psel_i,
    input wire penable_i,
    input wire pwrite_i,
    input wire [PADDR_W-1:0] paddr_i,
    input wire [WORD_W-1:0] pwdata_i,
    output wire [WORD_W-1:0] prdata_o,
    output wire pready_o,
    output wire pslverr_o,
    // ---- sources (hclk domain, level) ---------------------------------------
    input wire [NUM_SRC - 1:0] irq_src_i,
    // ---- to the core --------------------------------------------------------
    output wire clic_irq_valid_o,
    output wire [CLIC_ID_W-1:0] clic_irq_id_o,
    output wire [CLIC_LVL_W-1:0] clic_irq_level_o
);
    timeunit 1ns;
    timeprecision 1ps;

    wire [NUM_SRC-1:0]   ie;
    wire [NUM_SRC*CLIC_LVL_W-1:0] level;
    wire           swi;
    // The software interrupt joins the sources inside this block; the SoC ties
    // irq_src_i[SWI_ID] low. It is then a level source like any other.
    wire [NUM_SRC - 1:0] src = irq_src_i
        |({{(NUM_SRC - 1) {1'b0}}, swi} << SWI_ID);

    clic_apb #(.NUM_SRC(NUM_SRC), .IE_MASK(IE_MASK)) u_apb (
        .pclk(pclk), .preset_n(preset_n),
        .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i),
        .paddr_i(paddr_i), .pwdata_i(pwdata_i), .prdata_o(prdata_o),
        .pready_o(pready_o), .pslverr_o(pslverr_o),
        .pending_i(src), .ie_o(ie), .level_o(level), .swi_o(swi));

    // the candidates: pending and enabled
    wire [NUM_SRC - 1:0] cand = src & ie;

    clic_select #(.NUM_SRC(NUM_SRC)) u_sel (
        .cand_i(cand), .level_i(level),
        .valid_o(clic_irq_valid_o), .id_o(clic_irq_id_o),
            .level_o(clic_irq_level_o));


endmodule
