`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 22: Clock Divider
// clk_div.v - 200 MHz reference -> hclk (200/100) + pclk (100), no PLL
//
// Spec reference: GARUDA-CRG-SPEC-001 Rev 2.0, Sec. 3.3, Sec. 4.1-4.6, Sec. 5.1
//
// No PLL, no DLL, no analogue content. The 200 MHz reference arrives from
// outside the chip and the only division performed is a single flip-flop
// toggling on every rising edge of it, which gives an exact 50% duty cycle with
// zero added jitter and a fixed phase relationship to the source.
//
// =============================================================================
// THE CLOCK RELATIONSHIP IS A FROZEN CONTRACT, NOT AN IMPLEMENTATION CHOICE
// =============================================================================
// Two released specifications have built their clock-domain-crossing arguments
// on the precise nature of the relationship between hclk_o and pclk_o:
//
//   Bridge Sec. 13.4/13.4.1 requires STA to model pclk as a generated ÷2 clock
//   of hclk with the correct source relationship, and explicitly forbids
//   declaring them an asynchronous clock group.
//
//   CLIC Sec. 5.1.1 goes further and instantiates NO CDC synchronisers at all
//   on its configuration path, on the strength of pclk being a ÷2 of clk from
//   the same source. That is the most safety-critical consumer of this
//   contract, and the failure mode if it is broken is the nastiest kind:
//   nothing fails in simulation, only in silicon.
//
// So, normative in BOTH modes: hclk_o and pclk_o are synchronous, edge-aligned,
// and derived from one common source with an integer frequency ratio. What
// differs between modes is only the VALUE of that ratio.
//
//   Normal    hclk = 200 MHz (÷1 reference)   pclk = 100 MHz (÷2 net)   ratio 2
//   Fallback  hclk = 100 MHz (the ÷2 net)     pclk = 100 MHz (÷2 net)   ratio 1
//
// In fallback the two outputs ORIGINATE FROM ONE NET. Do not describe or
// constrain a ÷2 relationship between them in that mode - there is no divider
// between them, and constraining one would have STA analysing a division that
// does not exist (Sec. 4.2, Sec. 5.2 STA note).
//
// =============================================================================
// FALLBACK HALVES THE CORE CLOCK AND NOTHING ELSE (Sec. 4.4 - FROZEN)
// =============================================================================
// pclk stays at 100 MHz in BOTH modes. The TRM describes fallback as inserting
// "another div-2 in the core clock path", which read literally - with pclk
// continuing to be derived as ÷2 of the core tap - would make pclk 50 MHz. That
// reading is rejected, and the second reason is decisive: it would silently
// break every peripheral. UART baud divisors, SPI clock dividers, PWM period
// counts and the system timer's 1 us prescaler are all computed against a
// 100 MHz pclk. Halving it would halve every one of those rates with nothing to
// indicate it had happened. A fallback that exists to rescue a CORE timing
// closure problem must not also invalidate the configuration of every
// peripheral. See docs/DECISIONS.md and the TRM erratum recorded there.
//
// =============================================================================
// THE BOOTSTRAP: WHY THIS BLOCK RESETS ITSELF (Sec. 3.3, Sec. 4.5)
// =============================================================================
// There is an obvious circularity in the CRG invariant: the reset controller
// needs a running clock to release reset synchronously, while this block
// contains a flop that needs a reset to start in a known state. If the ÷2 flop
// waited for a synchronously de-asserted reset from Block 23, neither block
// could ever start.
//
// Resolution: this block carries its OWN two-flop reset-release synchroniser,
// clocked by clk_ref_i, and takes no reset from Block 23 at all. por_n_i
// asynchronously asserts that synchroniser; its output releases the ÷2 flop
// synchronously to clk_ref_i, which is already running because it comes from
// outside. The circularity is broken without Block 23 being involved.
//
// WHY THE ÷2 FLOP MUST NOT TAKE RAW por_n_i ON ITS ASYNC CLEAR:
// that flop IS the clock generator. If its reset release violates recovery or
// removal against clk_ref_i it can go metastable and emit a runt or
// indeterminate transition on the very first pclk edge. A metastable CLOCK is
// far worse than a metastable data signal - a runt pulse can violate the
// minimum pulse width of every flop in the pclk domain, and different flops may
// see different numbers of edges. The usual reassurance, that metastability
// resolves before anything consumes it, does NOT apply here: the first consumer
// of pclk_o is Block 23's pclk reset synchroniser, whose whole job is to time
// the release of preset_n against that same clock. There is no downstream
// margin to absorb it. Hence the local synchroniser - two flops and a few
// reference cycles of startup delay, which is irrelevant during power-on.
// =============================================================================

module clk_div (
    input  wire clk_ref_i,        // 200 MHz reference from the pad
    input  wire por_n_i,          // raw asynchronous power-on reset, active-low
    input  wire fallback_sel_i,   // static strap: 0 = 200/100, 1 = 100/100

    output wire hclk_o,           // core domain
    output wire pclk_o            // peripheral domain, 100 MHz in BOTH modes
);

    // -----------------------------------------------------------------------
    // Local reset-release synchroniser (Sec. 4.5)
    //
    // Conventional structure: a constant 1 shifted through two flops whose
    // asynchronous clear is por_n_i. por_n_i low holds the chain - and through
    // it the ÷2 flop - cleared with no clock required. On release the output
    // rises two clk_ref_i edges later, on a clean edge, so the ÷2 flop's reset
    // release meets recovery and removal by construction.
    //
    // Metastability is never literally impossible in silicon; the point is that
    // the unresolved event is confined to sync_meta, where a full clk_ref_i
    // period is available to settle it, rather than occurring on the clock
    // generator itself.
    // -----------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg sync_meta;
    (* ASYNC_REG = "TRUE" *) reg sync_q;

    always @(posedge clk_ref_i or negedge por_n_i) begin
        if (!por_n_i) begin
            sync_meta <= 1'b0;
            sync_q    <= 1'b0;
        end else begin
            sync_meta <= 1'b1;
            sync_q    <= sync_meta;
        end
    end

    wire int_rst_n = sync_q;      // released synchronously to clk_ref_i

    // -----------------------------------------------------------------------
    // Mode strap capture and freeze (Sec. 4.4.2)
    //
    // fallback_sel_i is sampled ONLY while the divider is still held in its
    // local reset, and is frozen for the operating life of the chip the moment
    // int_rst_n releases. Because clk_ref_i is running before the ÷2 flop is
    // released, the capture completes before either output clock is live.
    //
    // This matters more than it looks. It converts "the select is static, so a
    // simple mux is safe" from a promise about how the input will be DRIVEN
    // into a property guaranteed by the BLOCK. A noisy strap, a slowly-settling
    // eFuse read, or a future integrator who wires this to something less than
    // static cannot produce a mid-operation clock switch, because the block
    // stops listening once reset releases.
    //
    // Note the reset here is por_n_i, not int_rst_n: this flop must LOAD during
    // the window in which int_rst_n is still low, so int_rst_n cannot be its
    // reset.
    // -----------------------------------------------------------------------
    reg fb_q;

    always @(posedge clk_ref_i or negedge por_n_i) begin
        if (!por_n_i)          fb_q <= 1'b0;          // default: normal mode
        else if (!int_rst_n)   fb_q <= fallback_sel_i;
        // else: frozen forever
    end

    // -----------------------------------------------------------------------
    // The ÷2 flop. This is the clock generator (Sec. 4.1).
    //
    // A single toggle gives an exact 50% duty cycle. Asserting that in the
    // testbench is not redundant: it is what catches a counter-based
    // implementation slipping in during a later edit, which would not be 50%
    // and would not be jitter-free.
    // -----------------------------------------------------------------------
    reg div2;

    always @(posedge clk_ref_i or negedge int_rst_n) begin
        if (!int_rst_n) div2 <= 1'b0;
        else            div2 <= ~div2;
    end

    // -----------------------------------------------------------------------
    // Output taps (Sec. 4.4.1)
    //
    // pclk_o is ALWAYS the ÷2 net. hclk_o selects the undivided reference
    // (normal) or that same ÷2 net (fallback), so in fallback both outputs
    // originate from one net and the ÷2 contract degenerates to ÷1 - an integer
    // ratio from the same source, which is why the Bridge and the CLIC need no
    // special-casing for fallback.
    //
    // A PLAIN COMBINATIONAL MUX IS CORRECT HERE, and Sec. 4.6 is explicit that
    // no glitch-free clock-switching structure should be implemented: the
    // select is captured at reset and cannot change while the clocks are live,
    // so it would be dead logic guarding a transition that cannot occur.
    //
    // CONDITIONAL GUARD, RETAINED DELIBERATELY: if any future revision makes
    // the mode select changeable while the clocks are running - from software,
    // from a debug interface, from anything - a glitch-free clock mux becomes
    // MANDATORY at that moment. Switching between two live clocks with this mux
    // can emit a runt pulse that violates the minimum pulse width of every flop
    // downstream and corrupts state across the whole SoC. The required
    // structure is the standard one: each clock input gated by a flop
    // synchronised into its own domain, with one path's enable removed and
    // allowed to settle before the other is enabled. A stretched cycle at the
    // switch point is acceptable; a short pulse is not. This paragraph is here
    // so the requirement is not rediscovered the hard way.
    // -----------------------------------------------------------------------
    assign pclk_o = div2;
    assign hclk_o = fb_q ? div2 : clk_ref_i;

endmodule

`default_nettype wire
