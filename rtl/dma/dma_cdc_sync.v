`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 9: DMA Controller
// dma_cdc_sync.v - N-bit two-flop level synchronizer
//
// Spec reference: GARUDA-DMA-SPEC-001 Rev 2.0, Sec. 15.3
//
// WHAT THIS IS FOR - and what it is NOT for.
//
// This is a metastability filter for INDEPENDENT single-bit level signals. It
// is correct for a 1-bit control level (CR.EN, an SR flag, CR.IE) and it is
// correct for a multi-bit bus ONLY when that bus is quasi-static: written by
// the source domain long before the destination samples it, and stable for
// the whole window in which it is used.
//
// It is NOT correct for a freely-changing multi-bit value. Two bits of the
// same word can resolve on opposite sides of a clock edge, so the destination
// sees a mixture of the old and new words that was never a real value. For a
// counter crossing domains use dma_cdc_gray.v; for an event use the toggle
// handshake in dma_cdc_pulse.v.
//
// WIDTH>1 is therefore deliberately allowed but carries that obligation. Every
// instantiation in this block states which category it is in:
//   dma_channel_fsm : WIDTH=1, CR.EN         -> single-bit level        (OK)
//   dma_reg_bank    : WIDTH=12, SR flags     -> 12 independent bits     (OK)
//   dma_irq_agg     : WIDTH=12, CR.IE/EIE    -> 12 independent bits     (OK)
// "Independent bits" is the key: each bit is consumed on its own, never as a
// multi-bit number, so a skewed capture cannot manufacture a wrong value.
//
// RESET_VAL is applied to BOTH stages so the destination domain sees the
// deasserted state out of reset rather than shifting an X through.
// =============================================================================

module dma_cdc_sync #(
    parameter integer WIDTH     = 1,
    parameter         RESET_VAL = 1'b0
)(
    input  wire             clk_i,      // DESTINATION domain clock
    input  wire             rst_n_i,    // DESTINATION domain reset
    input  wire [WIDTH-1:0] d_i,        // source-domain signal (async to clk_i)
    output wire [WIDTH-1:0] q_o         // synchronized to clk_i
);

    // synthesis attribute: these two must not be merged or retimed. The
    // ASYNC_REG form is understood by the FPGA flow used for xsim smoke runs;
    // Genus takes the equivalent constraint from the SDC false path.
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync_meta;
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync_q;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            sync_meta <= {WIDTH{RESET_VAL}};
            sync_q    <= {WIDTH{RESET_VAL}};
        end else begin
            sync_meta <= d_i;
            sync_q    <= sync_meta;
        end
    end

    assign q_o = sync_q;

endmodule

`default_nettype wire
