`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 16: CLIC
// clic_source_cond.v - per-source conditioning: level pass or edge latch
//
// Spec reference: GARUDA-CLIC-SPEC-001 Rev 2.0, Sec. 6.3, Sec. 8.1, Sec. 8.4
//
// One instance per interrupt source. Produces that source's pending bit.
//
// =============================================================================
// LEVEL IS THE DEFAULT, AND THAT IS A SAFETY CHOICE (Sec. 10.2, Sec. 13.4)
// =============================================================================
// Reset puts every source in level mode because a level source CANNOT BE MISSED
// if the CPU is briefly masked - the line is still high when the mask lifts.
// An un-latched edge in the same window is gone forever. It also matches how
// GARUDA peripherals actually signal: the DMA and most peripherals hold a line
// until firmware clears the source at its origin.
//
// Edge mode exists for genuine pulse sources and latches the event so it
// survives until acknowledged.
//
// =============================================================================
// RE-FIRE IS INTENDED BEHAVIOUR, NOT A BUG (Sec. 8.4 - NORMATIVE)
// =============================================================================
// On the acknowledge pulse this block clears pending. For an EDGE source that
// ends the event. For a LEVEL source, if the underlying line is still high,
// pending RE-ASSERTS ON THE NEXT CYCLE and the source is presented again as
// soon as the handler's level drops.
//
// That is why every level source must be cleared AT THE PERIPHERAL: the DMA ISR
// writes 1 to its SR flag (W1C), which drops dma_irq[n], and only then does
// this source stop re-firing. A handler that returns without clearing its
// source immediately re-enters - the classic level-interrupt infinite loop, and
// per Sec. 10.4 the single most common interrupt bug there is.
//
// Clearing the CLIC pending bit alone is NOT sufficient, and the structure of
// this module is what makes that true: in level mode `ip` is reloaded from the
// line every cycle, so a clear that does not reach the peripheral lasts exactly
// one cycle.
//
// =============================================================================
// CLEAR PRIORITY
// =============================================================================
// The two clear sources - acknowledge and the APB W1C - take priority over the
// set path in the same cycle. The W1C strobe arrives from the pclk domain and
// is therefore two clk cycles wide (the clocks are ÷2-related, Sec. 5.1.1).
// Clearing is idempotent so a wide clear is harmless for a level source. For an
// EDGE source a new edge arriving inside that two-cycle window is swallowed -
// an accepted and documented consequence of clearing an edge source by software
// rather than by acknowledge, and a reason to prefer acknowledge-clearing for
// genuine pulse sources.
// =============================================================================

`include "clic_defs.vh"

module clic_source_cond (
    input  wire clk_i,          // core-domain clock - the fabric runs here
    input  wire rst_n_i,

    input  wire src_i,          // raw source line (see clic_top.v on async pads)
    input  wire trig_i,         // clicintattr.TRIG: 0 = level, 1 = rising edge

    input  wire ack_clr_i,      // core acknowledged THIS id (Sec. 8.4)
    input  wire w1c_clr_i,      // firmware wrote 1 to clicintip[i] over APB

    output reg  ip_o            // pending
);

    reg src_d;                  // edge-detect reference

    wire clr      = ack_clr_i || w1c_clr_i;
    wire rise     = src_i && !src_d;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            ip_o  <= 1'b0;
            src_d <= 1'b0;
        end else begin
            src_d <= src_i;

            if (clr)
                ip_o <= 1'b0;
            else if (trig_i == `CLIC_TRIG_EDGE) begin
                // Latch and hold until acknowledged or cleared.
                if (rise) ip_o <= 1'b1;
            end else begin
                // Level: transparent. This single assignment is the whole
                // re-fire mechanism described in the header.
                ip_o <= src_i;
            end
        end
    end

endmodule

`default_nettype wire
