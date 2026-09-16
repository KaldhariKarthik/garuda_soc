`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 23: Reset Controller
// reset_ctrl.v - source qualification + per-domain async-assert/sync-de-assert
//
// Spec reference: GARUDA-CRG-SPEC-001 Rev 2.0, Sec. 3.2, Sec. 6, Sec. 7,
//                 Sec. 8.1-8.3
//
// This block exists because of one asymmetry: a reset must be APPLIED
// immediately and asynchronously, so the chip reaches a known state even if the
// clock is dead, but REMOVED synchronously, so every flop in a domain leaves
// reset on the same clock edge.
//
// Without synchronous de-assertion, flops near the reset driver leave reset an
// edge earlier than flops far from it, so part of the chip begins executing
// while the rest is still held - producing corrupted state on the first cycle
// with nothing to indicate why.
//
// =============================================================================
// ASSERTION IS SIMULTANEOUS; DE-ASSERTION IS PER-DOMAIN AND THEREFORE SKEWED
// =============================================================================
// Both outputs are driven from the same qualified source term, so they assert
// together, asynchronously, the instant any source fires. The Bridge depends on
// this: its reset-during-transfer behaviour (Bridge Sec. 10.3) is only correct
// because both of its domains reset as one event, which is what lets it abandon
// an in-flight transfer without manufacturing a terminal response.
//
// De-assertion is released through a synchroniser clocked by each domain's own
// clock, so preset_n_o can release up to one pclk period (10 ns) after
// hreset_n_o. That skew is unavoidable if de-assertion is to be synchronous in
// each domain, and it is safe: the two domains interact only through the
// bridge, whose pclk side is still held during the window, so no APB transfer
// can be initiated or completed in it. In practice the window is never
// exercised - after reset the core fetches from the Boot ROM, an hclk-domain
// slave, and the first peripheral access does not occur until the bootloader
// initialises SPI many cycles later.
//
// =============================================================================
// THE WATCHDOG RESET MUST NOT CREATE A RESET LOOP (Sec. 8.2)
// =============================================================================
// A watchdog reset has to clear the watchdog's own counter, or the chip
// immediately re-resets and never boots. The counter is reset by hreset_n_o
// like any other hclk-domain flop, which breaks the loop: the reset event
// clears the counter, the counter reloads to its timeout on release, and
// firmware has a full timeout period to feed it.
//
// This makes the watchdog reset self-clearing and NON-LATCHING. There is no
// status bit here recording that the last reset came from the watchdog.
// Firmware cannot distinguish a watchdog reset from a power-on reset. That is a
// real capability gap and it is a DECIDED one, not an oversight: see
// docs/DECISIONS.md D-2. Reset-cause reporting is out of scope for the first
// tapeout because the register would have to survive the reset it records,
// needing either an always-on domain or a flop cleared only by por_n_i, and
// whether GARUDA has an always-on domain at all is undecided. Do not add one
// here without that decision.
//
// =============================================================================
// DEPARTURE FROM THE SPECIFICATION: THE WATCHDOG PULSE IS STRETCHED
// =============================================================================
// Sec. 7.1 combines the sources as a bare term: rst_n_qual low when por_n_i is
// low OR wdt_reset_i is high. Taken literally with a one-cycle watchdog pulse,
// that asserts the whole chip's reset for exactly one hclk period - 5 ns - and
// then releases it.
//
// That is too narrow to rely on. The reset is distributed through a buffered
// reset tree across a 1.45 mm die; a 5 ns pulse can arrive at the far end
// degraded or, after tree insertion delay skew, not overlap at every leaf. The
// spec's own requirement that assertion reach EVERY flop (Sec. 8.4,
// "metastability" row) is what is at risk, and the failure mode is a partial
// reset - some flops cleared, some not - which is indistinguishable from
// corrupted state.
//
// So the watchdog request is stretched to WDT_STRETCH hclk cycles here. POR is
// untouched and remains fully asynchronous with no minimum width, because it is
// driven from outside and is already wide. This is an addition to the spec, it
// is logged in docs/BUGS.md as CRG-1, and Sec. 7.1 should be amended to match.
//
// The stretch counter is reset by por_n_i ONLY, never by its own output. A
// counter cleared by the reset it generates would truncate its own pulse - the
// same shape of bug as the watchdog reset loop above, one level down.
// =============================================================================

module reset_ctrl #(
    parameter integer WDT_STRETCH = 16     // hclk cycles, see header
)(
    // ---- sources (Sec. 6.2) ------------------------------------------------
    input  wire por_n_i,          // external / power-on reset, async, active-low
    input  wire wdt_reset_i,      // watchdog request, active-high, hclk domain

    // ---- domain clocks -----------------------------------------------------
    input  wire hclk_i,           // 200 MHz
    input  wire pclk_i,           // 100 MHz

    // ---- distributed resets ------------------------------------------------
    output wire hreset_n_o,       // hclk domain, async assert / sync de-assert
    output wire preset_n_o        // pclk domain, async assert / sync de-assert
);

    // -----------------------------------------------------------------------
    // Watchdog pulse stretch (see header - departure from Sec. 7.1)
    // -----------------------------------------------------------------------
    localparam integer CW = (WDT_STRETCH <= 2) ? 1 : $clog2(WDT_STRETCH);

    reg [CW-1:0] wdt_cnt;
    reg          wdt_active;

    always @(posedge hclk_i or negedge por_n_i) begin
        if (!por_n_i) begin
            wdt_cnt    <= {CW{1'b0}};
            wdt_active <= 1'b0;
        end else if (wdt_reset_i) begin
            // Re-trigger reloads: a second request during a stretch extends it
            // rather than being ignored.
            wdt_cnt    <= WDT_STRETCH[CW-1:0] - 1'b1;
            wdt_active <= 1'b1;
        end else if (wdt_active) begin
            if (wdt_cnt == {CW{1'b0}}) wdt_active <= 1'b0;
            else                       wdt_cnt    <= wdt_cnt - 1'b1;
        end
    end

    // -----------------------------------------------------------------------
    // Source qualification (Sec. 7.1)
    //
    // One internal active-low term drives the asynchronous reset input of BOTH
    // domain synchronisers, which is what makes assertion simultaneous across
    // the chip. Neither source is maskable and there is no partial or per-block
    // reset in GARUDA - every reset is a full system reset of both domains.
    // -----------------------------------------------------------------------
    wire rst_n_qual = por_n_i && !wdt_active && !wdt_reset_i;

    // -----------------------------------------------------------------------
    // Per-domain reset-release synchronisers (Sec. 7.3, Sec. 7.4)
    //
    // A constant 1 shifted through two flops whose asynchronous clear is
    // rst_n_qual. Assertion is asynchronous and needs no clock; release happens
    // two edges of THAT DOMAIN'S clock later, simultaneously for every flop in
    // the domain.
    //
    // Two stages is the baseline depth. Sec. 7.4 is explicit that depth cannot
    // be justified from clock frequency alone: the final depth is confirmed
    // against the 28 nm library's metastability parameters at sign-off, taking
    // the source event rate and required MTBF into account. If that analysis
    // calls for three stages, adding one here is trivial and should be done
    // rather than argued against.
    // -----------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg hmeta, hq;
    (* ASYNC_REG = "TRUE" *) reg pmeta, pq;

    always @(posedge hclk_i or negedge rst_n_qual) begin
        if (!rst_n_qual) begin
            hmeta <= 1'b0;
            hq    <= 1'b0;
        end else begin
            hmeta <= 1'b1;
            hq    <= hmeta;
        end
    end

    always @(posedge pclk_i or negedge rst_n_qual) begin
        if (!rst_n_qual) begin
            pmeta <= 1'b0;
            pq    <= 1'b0;
        end else begin
            pmeta <= 1'b1;
            pq    <= pmeta;
        end
    end

    assign hreset_n_o = hq;
    assign preset_n_o = pq;

endmodule

`default_nettype wire
