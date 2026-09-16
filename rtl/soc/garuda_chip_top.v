`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - chip boundary
// garuda_chip_top.v - garuda_soc_top + Block 22 (clock) + Block 23 (reset)
//
// Specs: GARUDA-CRG-SPEC-001 Rev 2.0 (Blocks 22/23) plus everything inside
//        garuda_soc_top.
//
// =============================================================================
// WHY THIS IS A SEPARATE LEVEL FROM garuda_soc_top
// =============================================================================
// This is the level where the chip generates its own clocks and resets, so its
// inputs are what actually arrives on a pin: one reference clock, one
// active-low reset, and a static mode strap. Everything below it receives
// hclk/pclk/hreset_n/preset_n as ordinary inputs.
//
// Keeping the split means a testbench can drive garuda_soc_top's clocks and
// resets directly - which is what almost every block- and SoC-level test wants,
// because it can then inject reset at an arbitrary phase, run at 1:1 for speed,
// or hold one domain in reset deliberately. A reset controller buried inside
// the thing it resets makes all three of those impossible, and the CRG then
// only ever gets exercised as a side effect of something else.
//
// It also matches the pin budget: the TRM allocates one CLK pin (200 MHz) and
// one active-low RST pin out of 40, and nothing else in the clock/reset group.
//
// =============================================================================
// THE STARTUP SEQUENCE THIS FILE REALISES (CRG Sec. 3.4)
// =============================================================================
//   1. Power ramps; por_n_i is low. Every flop in the SoC is held
//      asynchronously.
//   2. clk_ref_i becomes valid and stable at 200 MHz.
//   3. por_n_i releases. The divider's own reset synchroniser counts two
//      clk_ref_i edges and releases the ÷2 flop on a clean edge - hclk and pclk
//      are now both running and edge-aligned, with no runt first pulse.
//   4. The reset controller sees por_n_i released; each domain's two-flop
//      synchroniser counts two edges of its own clock.
//   5. hreset_n de-asserts on an hclk edge; preset_n on a pclk edge, up to one
//      pclk period later. That skew is safe and bounded - during it the
//      bridge's pclk side is still held, so no APB transfer can complete.
//   6. The core's PC loads 0x1000_0000 and the I-Port issues its first fetch to
//      the Boot ROM.
//
// The circularity in step 3/4 - the reset controller needs a clock, the clock
// generator needs a reset - is broken inside clk_div.v, which resets itself
// from por_n_i through its own synchroniser and takes nothing from Block 23.
// =============================================================================

`include "ahb2apb_defs.vh"

module garuda_chip_top #(
    parameter [31:0]  RESET_VECTOR    = 32'h1000_0000,
    parameter         BROM_INIT_FILE  = "",
    parameter integer CLIC_N          = 32,
    parameter [15:0]  APB_WINDOW_MASK = `BRG_WINDOW_MASK_DEFAULT
)(
    // ---- pins -------------------------------------------------------------
    input  wire        clk_ref_i,       // CLK pin, 200 MHz
    input  wire        por_n_i,         // RST pin, active-low
    input  wire        fallback_sel_i,  // static strap / eFuse (CRG Sec. 4.4.2)

    // ---- APB expansion bus (Blocks 10-15, 18-21) --------------------------
    output wire [15:0] apb_psel_o,
    output wire        apb_penable_o,
    output wire        apb_pwrite_o,
    output wire [15:0] apb_paddr_o,
    output wire [31:0] apb_pwdata_o,
    output wire [3:0]  apb_pstrb_o,
    input  wire [31:0] apb_prdata_i,
    input  wire        apb_pready_i,
    input  wire        apb_pslverr_i,

    // ---- DMA peripheral sideband ------------------------------------------
    input  wire [5:0]  dma_req_i,
    output wire [5:0]  dma_ack_o,

    // ---- external interrupt sources ---------------------------------------
    input  wire [CLIC_N-13:0] irq_ext_i,

    // ---- machine timer (Block 20) -----------------------------------------
    input  wire [63:0] mtime_i,
    input  wire [63:0] mtimecmp_i,

    // ---- observability -----------------------------------------------------
    output wire        hclk_o,
    output wire        pclk_o,
    output wire        hreset_n_o,
    output wire        preset_n_o,
    output wire [47:0] dbg_acc_0_o,
    output wire [47:0] dbg_acc_1_o,
    output wire [47:0] dbg_acc_2_o
);

    wire hclk, pclk, hreset_n, preset_n, wdt_reset;

    // =======================================================================
    // Block 22 : clock divider. Resets itself from por_n_i - see its header.
    // =======================================================================
    clk_div u_clk_div (
        .clk_ref_i      (clk_ref_i),
        .por_n_i        (por_n_i),
        .fallback_sel_i (fallback_sel_i),
        .hclk_o         (hclk),
        .pclk_o         (pclk)
    );

    // =======================================================================
    // Block 23 : reset controller. Uses the clocks Block 22 produces, which is
    // an implementation fact rather than a law - the CRG invariant only
    // requires that a domain's reset be synchronised against a clock that is
    // already running when the reset is released.
    // =======================================================================
    reset_ctrl u_reset_ctrl (
        .por_n_i     (por_n_i),
        .wdt_reset_i (wdt_reset),
        .hclk_i      (hclk),
        .pclk_i      (pclk),
        .hreset_n_o  (hreset_n),
        .preset_n_o  (preset_n)
    );

    // =======================================================================
    // The SoC
    // =======================================================================
    garuda_soc_top #(
        .RESET_VECTOR    (RESET_VECTOR),
        .BROM_INIT_FILE  (BROM_INIT_FILE),
        .CLIC_N          (CLIC_N),
        .APB_WINDOW_MASK (APB_WINDOW_MASK)
    ) u_soc (
        .hclk_i        (hclk),
        .pclk_i        (pclk),
        .hreset_n_i    (hreset_n),
        .preset_n_i    (preset_n),

        .apb_psel_o    (apb_psel_o),
        .apb_penable_o (apb_penable_o),
        .apb_pwrite_o  (apb_pwrite_o),
        .apb_paddr_o   (apb_paddr_o),
        .apb_pwdata_o  (apb_pwdata_o),
        .apb_pstrb_o   (apb_pstrb_o),
        .apb_prdata_i  (apb_prdata_i),
        .apb_pready_i  (apb_pready_i),
        .apb_pslverr_i (apb_pslverr_i),

        .dma_req_i     (dma_req_i),
        .dma_ack_o     (dma_ack_o),

        .irq_ext_i     (irq_ext_i),

        .mtime_i       (mtime_i),
        .mtimecmp_i    (mtimecmp_i),

        .wdt_reset_o   (wdt_reset),

        .dbg_acc_0_o   (dbg_acc_0_o),
        .dbg_acc_1_o   (dbg_acc_1_o),
        .dbg_acc_2_o   (dbg_acc_2_o)
    );

    assign hclk_o     = hclk;
    assign pclk_o     = pclk;
    assign hreset_n_o = hreset_n;
    assign preset_n_o = preset_n;

endmodule

`default_nettype wire
