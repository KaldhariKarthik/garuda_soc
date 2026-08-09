`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 9: DMA Controller
// dma_cdc_pulse.v - destination half of a toggle (two-phase) event handshake
//
// Spec reference: GARUDA-DMA-SPEC-001 Rev 2.0, Sec. 15.3
//
// WHY A TOGGLE AND NOT A SYNCHRONIZED PULSE
// A one-cycle pulse cannot be pushed through a two-flop synchronizer: if the
// source domain is faster than the destination the pulse can fall between two
// destination edges and vanish entirely. Here that would mean a lost SR W1C
// clear (an interrupt that never deasserts and re-fires forever, Sec. 10.2) or
// a lost EN clear (CR.EN reading 1 on a channel that has finished). Both are
// silent, intermittent, and would look like RTL bugs anywhere but here.
//
// So the event is carried as a LEVEL that inverts once per event. A level
// survives any clock ratio. The destination synchronizes it and edge-detects.
//
// SPLIT OF RESPONSIBILITY
// This module is the DESTINATION half only. The source half is a single flop
// in the producing module, written as:
//
//     always @(posedge src_clk or negedge src_rst_n)
//         if (!src_rst_n)  tog <= 1'b0;
//         else if (event)  tog <= ~tog;
//
// It is kept in the producer (rather than wrapped here) so the toggle flop
// lives in, and is reset by, the producer's own clock domain - a dual-clock
// wrapper would need both resets and would make the reset ordering ambiguous.
//
// THE ONE RULE YOU MUST NOT BREAK
// Two source events closer together than the destination's synchronization
// latency (3 destination clocks, plus source-clock uncertainty - budget 2
// source clocks) are MERGED: the toggle inverts twice and the destination
// sees nothing. Every user in this block is checked against that:
//
//   SR W1C clear   pclk -> hclk : source is an APB write, minimum 2 pclk
//                                 apart = 4 hclk. Safe by protocol.
//   CR arm pulse   pclk -> hclk : same, an APB write to CR. Safe.
//   EN clear       hclk -> pclk : fires once per single-shot completion, and
//                                 the channel cannot complete again without a
//                                 software re-arm. Safe by construction.
//
// If a future change adds a faster event source, it needs a full req/ack
// handshake, not this.
// =============================================================================

module dma_cdc_pulse (
    input  wire clk_i,       // DESTINATION domain clock
    input  wire rst_n_i,     // DESTINATION domain reset
    input  wire tog_i,       // toggle level from the SOURCE domain
    output wire pulse_o      // 1-cycle pulse in the destination domain
);

    (* ASYNC_REG = "TRUE" *) reg sync_meta;
    (* ASYNC_REG = "TRUE" *) reg sync_q;
                             reg sync_dly;   // edge-detect reference

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            sync_meta <= 1'b0;
            sync_q    <= 1'b0;
            sync_dly  <= 1'b0;
        end else begin
            sync_meta <= tog_i;
            sync_q    <= sync_meta;
            sync_dly  <= sync_q;
        end
    end

    // Either edge of the toggle is one event.
    assign pulse_o = sync_q ^ sync_dly;

endmodule

`default_nettype wire
