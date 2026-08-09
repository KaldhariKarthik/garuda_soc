`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 9: DMA Controller
// dma_irq_agg.v - interrupt aggregation, 12 lines to the CLIC
//
// Spec reference: GARUDA-DMA-SPEC-001 Rev 2.0, Sec. 3.1 (#7), Sec. 5.5,
//                 Sec. 10, Sec. 17.3
//
//   dma_irq[n] = SR.COMPLETE[n] AND CR.IE[n]
//   dma_err[n] = SR.ERROR[n]    AND CR.EIE[n]
//
// LEVEL-SENSITIVE, NOT PULSED (Sec. 10.2). The line stays asserted until
// firmware clears the SR flag with a W1C write. There is no edge detection and
// no auto-clear anywhere in this path - if the ISR returns without clearing,
// the interrupt re-fires immediately, exactly as Sec. 10.2 warns. That is the
// specified contract with the CLIC and must not be "fixed" here.
//
// WHY IE/EIE ARE SYNCHRONIZED
// The status flags arrive from the channel FSMs already in hclk. CR.IE and
// CR.EIE, however, live in the pclk register bank, and Sec. 3.1 places this
// aggregator in hclk. ANDing an hclk flag with a raw pclk flop would put a
// metastable node directly onto an interrupt line into the CLIC - a glitch
// there can latch a spurious vectored interrupt, which in this SoC means a
// wrong-handler dispatch that reproduces roughly never. The 12 enable bits are
// independent single-bit levels, so a plain two-flop sync is the right tool.
//
// OUTPUTS ARE REGISTERED (Sec. 15.1: "12 AND gates + output registers"). This
// costs one hclk of latency against the ~10-20 cycle ISR entry of Sec. 11.1 -
// nothing - and guarantees the CLIC never sees a combinational hazard from the
// flag and the enable changing in the same cycle.
// =============================================================================

`include "dma_defs.vh"

module dma_irq_agg (
    input  wire                          hclk_i,
    input  wire                          hreset_n_i,

    // Status flags from the channel FSMs (hclk domain, Sec. 7.5)
    input  wire [`DMA_NCH-1:0]           done_flag_i,
    input  wire [`DMA_NCH-1:0]           err_flag_i,

    // CR.IE / CR.EIE only, one bit per channel, extracted in dma_top. Taking
    // just these two bits rather than the whole flattened CR bus keeps the
    // interface honest about what this block reads - and means lint flags a
    // genuinely unused input instead of shrugging at 66 dead bits.
    input  wire [`DMA_NCH-1:0]           ie_i,      // pclk domain
    input  wire [`DMA_NCH-1:0]           eie_i,     // pclk domain

    // To the CLIC (Sec. 5.5)
    output reg  [`DMA_NCH-1:0]           dma_irq_o,
    output reg  [`DMA_NCH-1:0]           dma_err_o
);

    // ---- pclk -> hclk : 12 independent enable bits -------------------------
    wire [`DMA_NCH-1:0] ie_h;
    wire [`DMA_NCH-1:0] eie_h;

    dma_cdc_sync #(.WIDTH(2*`DMA_NCH), .RESET_VAL(1'b0)) u_en_sync (
        .clk_i   (hclk_i),
        .rst_n_i (hreset_n_i),
        .d_i     ({eie_i, ie_i}),
        .q_o     ({eie_h, ie_h})
    );

    // ---- the 12 AND gates, registered --------------------------------------
    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            // Sec. 12: all interrupt lines deasserted out of reset.
            dma_irq_o <= {`DMA_NCH{1'b0}};
            dma_err_o <= {`DMA_NCH{1'b0}};
        end else begin
            dma_irq_o <= done_flag_i & ie_h;
            dma_err_o <= err_flag_i  & eie_h;
        end
    end

endmodule

`default_nettype wire
