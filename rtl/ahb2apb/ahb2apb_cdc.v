`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 8: AHB-to-APB Bridge
// ahb2apb_cdc.v - destination half of a toggle handshake: 2FF sync + edge detect
//
// Spec reference: GARUDA-BRG-SPEC-001 Rev 2.0, Sec. 7.3, Sec. 13.2
//
// WHY A TOGGLE AND NOT A SYNCHRONISED PULSE
// A one-cycle pulse cannot be pushed through a two-flop synchroniser: if the
// source domain is faster than the destination, the pulse can fall between two
// destination edges and vanish. Here that would mean a request that never
// reaches the APB side, or an acknowledge that never returns - either one hangs
// the bridge with HREADYOUT low, which hangs the master, which hangs the SoC.
// So the event is carried as a LEVEL that inverts once per event. A level
// survives any clock ratio. The destination synchronises it and edge-detects.
//
// Structurally identical to rtl/dma/dma_cdc_pulse.v, and deliberately a
// separate file rather than an instantiation of it: Block 8 must not depend on
// Block 9's source tree to build. The two are checked against each other by
// eye, which is cheap, and neither can break the other, which is not.
//
// THE CORRECTNESS ARGUMENT LIVES HERE, NOT IN THE CLOCK RELATIONSHIP.
// Sec. 13.2 is blunt about this and it is worth repeating at the top of the
// file that implements it: these synchronisers are NOT defensive hardening
// layered on top of a synchronous design. They are the mechanism that makes the
// crossing metastability-safe, and the bridge is expected to remain correct if
// the hclk/pclk relationship is later relaxed to fully asynchronous. Do not
// remove them on the grounds that pclk is a ÷2 of hclk.
//
// The source half is a single flop in the producing domain, deliberately left
// there rather than wrapped here: a dual-clock wrapper would need both resets
// and would make the reset ordering ambiguous.
// =============================================================================

module ahb2apb_cdc (
    input  wire clk_i,        // DESTINATION domain clock
    input  wire rst_n_i,      // DESTINATION domain reset
    input  wire tog_i,        // toggle level from the SOURCE domain
    output wire pulse_o       // 1-cycle pulse in the destination domain
);

    (* ASYNC_REG = "TRUE" *) reg sync_meta;
    (* ASYNC_REG = "TRUE" *) reg sync_q;
                             reg sync_dly;

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
