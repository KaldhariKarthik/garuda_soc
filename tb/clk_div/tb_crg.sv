`timescale 1ps/1ps
// =============================================================================
// GARUDA SoC - Blocks 22/23: Clock & Reset Generation - block-level testbench
//
// Covers GARUDA-CRG-SPEC-001 Rev 2.0 Sec. 5.2 (clock divider verification) and
// Sec. 8.4 (reset controller verification), plus the watchdog pulse stretch
// this project added on top of Sec. 7.1 (logged as CRG-1 in docs/BUGS.md).
//
// Both blocks are exercised in ONE testbench even though they are deliberately
// two independent modules, because the properties that matter most are the ones
// at the seam between them: the bootstrap (a clock generator that resets itself
// so the reset controller has a clock to synchronise against) and the bounded
// de-assertion skew between the two domains. Testing them separately would
// verify each block and none of the coupling.
//
// TIMESCALE IS 1ps DELIBERATELY. This testbench measures clock EDGE ALIGNMENT
// and pulse WIDTH; at 1ns resolution a 2.5 ns half-period is not representable
// and every alignment check would pass by rounding.
//
// Plusargs
//   +VERBOSE   print every check
// =============================================================================

module tb_crg;

    // -----------------------------------------------------------------------
    // Scoreboard - same shape as tb_ahb_interconnect.sv
    // -----------------------------------------------------------------------
    integer checks = 0;
    integer fails  = 0;
    reg     verbose;

    task chk;
        input          cond;
        input [1023:0] msg;
        begin
            checks = checks + 1;
            if (!cond) begin
                fails = fails + 1;
                $display("[FAIL] %0s   (t=%0t)", msg, $time);
            end else if (verbose) begin
                $display("[ ok ] %0s", msg);
            end
        end
    endtask

    task chk_eq;
        input [63:0]   got;
        input [63:0]   exp;
        input [1023:0] msg;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                fails = fails + 1;
                $display("[FAIL] %0s : got %0d expected %0d   (t=%0t)",
                         msg, got, exp, $time);
            end else if (verbose) begin
                $display("[ ok ] %0s = %0d", msg, got);
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Reference clock. Gateable, because two of the required checks - async
    // reset assertion with no clock, and reset release phase sweeping - cannot
    // be performed against a free-running clock.
    // -----------------------------------------------------------------------
    localparam integer TREF_HALF = 2500;      // 2.5 ns -> 200 MHz

    reg clk_ref = 1'b0;
    reg run_clk = 1'b1;

    always begin
        #TREF_HALF;
        if (run_clk) clk_ref = ~clk_ref;
    end

    reg por_n        = 1'b0;
    reg fallback_sel = 1'b0;
    reg wdt_reset    = 1'b0;

    wire hclk, pclk;
    wire hreset_n, preset_n;

    // -----------------------------------------------------------------------
    // DUTs
    // -----------------------------------------------------------------------
    clk_div u_clk_div (
        .clk_ref_i      (clk_ref),
        .por_n_i        (por_n),
        .fallback_sel_i (fallback_sel),
        .hclk_o         (hclk),
        .pclk_o         (pclk)
    );

    reset_ctrl #(.WDT_STRETCH(16)) u_reset_ctrl (
        .por_n_i     (por_n),
        .wdt_reset_i (wdt_reset),
        .hclk_i      (hclk),
        .pclk_i      (pclk),
        .hreset_n_o  (hreset_n),
        .preset_n_o  (preset_n)
    );

    // -----------------------------------------------------------------------
    // Measurement helpers
    // -----------------------------------------------------------------------
    time t_last_pclk_rise, t_pclk_period, t_pclk_high;
    time t_last_hclk_rise, t_hclk_period;
    time t_pclk_rise_mark;

    integer n_pclk_rise, n_hclk_rise;
    integer n_align_ok, n_align_bad;

    always @(posedge pclk) begin
        if (t_last_pclk_rise != 0) t_pclk_period = $time - t_last_pclk_rise;
        t_last_pclk_rise = $time;
        n_pclk_rise      = n_pclk_rise + 1;
    end

    // -----------------------------------------------------------------------
    // Edge alignment (Sec. 4.2 - NORMATIVE), sampled just AFTER the pclk edge.
    //
    // The obvious formulation - "was the last hclk rise at the same $time?" -
    // is a RACE, and it reported false misalignment against a divider that was
    // behaving perfectly. Two always blocks triggered by the same edge execute
    // in an arbitrary order, so the hclk block may not have written its
    // timestamp yet when the pclk block reads it. In FALLBACK that is
    // guaranteed to bite, because hclk and pclk are then literally the same
    // net and both blocks wake on the identical event.
    //
    // Sampling the hclk LEVEL a short delay after the pclk edge has no
    // ordering dependency at all: if the two edges coincide, hclk is high
    // here, in normal mode and in fallback alike. 10 ps is far inside the
    // 2500 ps half period, and the timescale is 1ps so it does not round to
    // zero - which #0.1 would have.
    // -----------------------------------------------------------------------
    always @(posedge pclk) begin
        #10;
        if (hclk === 1'b1) n_align_ok  = n_align_ok  + 1;
        else               n_align_bad = n_align_bad + 1;
    end

    always @(negedge pclk) begin
        if (t_last_pclk_rise != 0) t_pclk_high = $time - t_last_pclk_rise;
    end

    always @(posedge hclk) begin
        if (t_last_hclk_rise != 0) t_hclk_period = $time - t_last_hclk_rise;
        t_last_hclk_rise = $time;
        n_hclk_rise      = n_hclk_rise + 1;
    end

    task clear_counts;
        begin
            n_pclk_rise = 0; n_hclk_rise = 0;
            n_align_ok  = 0; n_align_bad = 0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Reset sequencing helper: assert POR, optionally set the strap, release.
    // -----------------------------------------------------------------------
    task por_cycle;
        input strap;
        input integer release_offset_ps;   // phase of release vs clk_ref
        begin
            por_n        = 1'b0;
            fallback_sel = strap;
            @(posedge clk_ref);
            #(release_offset_ps);
            por_n = 1'b1;
        end
    endtask

    time first_period [0:3];

    integer i;
    time    t0, t1;
    time    h_deassert, p_deassert, t_por_rel;

    initial begin
        verbose = $test$plusargs("VERBOSE");
        clear_counts;
        t_last_pclk_rise = 0;
        t_last_hclk_rise = 0;

        $display("======================================================");
        $display("GARUDA CRG (Blocks 22/23) block-level testbench");
        $display("======================================================");

        // ===================================================================
        // T1 - normal mode frequency and duty cycle (Sec. 5.2)
        // ===================================================================
        por_cycle(1'b0, 0);
        repeat (20) @(posedge clk_ref);
        clear_counts;
        repeat (40) @(posedge clk_ref);

        chk_eq(t_hclk_period, 2*TREF_HALF,   "T1 hclk period = 5ns (200 MHz)");
        chk_eq(t_pclk_period, 4*TREF_HALF,   "T1 pclk period = 10ns (100 MHz)");
        // Duty must be exactly 50%: it is a toggle flop. Asserting it catches a
        // counter-based implementation slipping in during a later edit.
        chk_eq(t_pclk_high,   2*TREF_HALF,   "T1 pclk duty is exactly 50%");

        // ===================================================================
        // T2 - edge alignment and ratio, normal mode (Sec. 4.2 - NORMATIVE)
        // ===================================================================
        clear_counts;
        repeat (40) @(posedge clk_ref);
        chk(n_align_bad == 0,
            "T2 every pclk rising edge coincides with an hclk rising edge");
        chk_eq(n_hclk_rise / n_pclk_rise, 2, "T2 hclk:pclk ratio is exactly 2");

        // ===================================================================
        // T3 - deterministic startup phase (Sec. 5.1, Sec. 5.2)
        //
        // Release POR at four different phases relative to clk_ref and confirm
        // the first pclk period is identical every time. This is the check
        // that would have caught a raw-POR release on the divide-by-2 flop.
        // ===================================================================
        for (i = 0; i < 4; i = i + 1) begin
            por_n = 1'b0;
            repeat (3) @(posedge clk_ref);
            t_last_pclk_rise = 0;
            t_pclk_period    = 0;
            por_cycle(1'b0, i * 500);          // 0, 500, 1000, 1500 ps
            repeat (10) @(posedge clk_ref);
            first_period[i] = t_pclk_period;
        end

        chk_eq(first_period[1], first_period[0], "T3 startup phase independent of release phase (1)");
        chk_eq(first_period[2], first_period[0], "T3 startup phase independent of release phase (2)");
        chk_eq(first_period[3], first_period[0], "T3 startup phase independent of release phase (3)");
        chk_eq(first_period[0], 4*TREF_HALF,     "T3 first pclk period is full width (no runt)");

        // ===================================================================
        // T4 - fallback mode: BOTH clocks 100 MHz (Sec. 4.4 - FROZEN)
        //
        // The regression that matters: pclk must be 100 MHz in BOTH modes. If
        // this ever reports 50 MHz, every UART divisor, SPI divider, PWM period
        // and timer prescale in the chip is silently wrong.
        // ===================================================================
        por_cycle(1'b1, 0);
        repeat (20) @(posedge clk_ref);
        clear_counts;
        repeat (40) @(posedge clk_ref);

        chk_eq(t_pclk_period, 4*TREF_HALF, "T4 fallback: pclk STILL 100 MHz");
        chk_eq(t_hclk_period, 4*TREF_HALF, "T4 fallback: hclk is 100 MHz");
        chk_eq(n_hclk_rise, n_pclk_rise,   "T4 fallback: ratio is 1, not 2");
        chk(n_align_bad == 0,              "T4 fallback: edges still coincident");

        // ===================================================================
        // T5 - the strap is captured at reset and frozen (Sec. 4.4.2)
        //
        // Toggling fallback_sel_i AFTER reset release must have no effect on
        // either clock. This is what makes the plain combinational mux safe.
        // ===================================================================
        clear_counts;
        fallback_sel = 1'b0;                  // try to leave fallback at runtime
        repeat (20) @(posedge clk_ref);
        chk_eq(t_hclk_period, 4*TREF_HALF,
               "T5 strap frozen: hclk unchanged by a post-reset strap toggle");
        chk(n_align_bad == 0, "T5 strap frozen: no glitch on the clock outputs");

        fallback_sel = 1'b1;
        repeat (10) @(posedge clk_ref);
        fallback_sel = 1'b0;
        repeat (10) @(posedge clk_ref);
        chk(n_align_bad == 0, "T5 strap frozen: repeated toggling still clean");

        // ===================================================================
        // T6 - reset asserts asynchronously with NO CLOCK RUNNING (Sec. 8.4)
        //
        // This is the property that cannot be verified against a running clock,
        // and it is the condition a watchdog reset may be recovering from.
        // ===================================================================
        por_cycle(1'b0, 0);
        repeat (20) @(posedge clk_ref);
        chk(hreset_n === 1'b1 && preset_n === 1'b1, "T6 both resets released before the test");

        run_clk = 1'b0;                        // stop the reference clock dead
        #10000;
        por_n = 1'b0;
        #1000;
        chk(hreset_n === 1'b0, "T6 hreset_n asserted with the clock stopped");
        chk(preset_n === 1'b0, "T6 preset_n asserted with the clock stopped");
        run_clk = 1'b1;

        // ===================================================================
        // T7 - assertion is SIMULTANEOUS in both domains (Sec. 3.2)
        //
        // The bridge's reset-during-transfer behaviour is only correct because
        // both of its domains reset as one event.
        // ===================================================================
        por_cycle(1'b0, 0);
        repeat (20) @(posedge clk_ref);

        t0 = 0; t1 = 0;
        fork
            begin @(negedge hreset_n); t0 = $time; end
            begin @(negedge preset_n); t1 = $time; end
            begin #100; por_n = 1'b0; end
        join
        chk_eq(t0, t1, "T7 hreset_n and preset_n assert in the same instant");

        // ===================================================================
        // T8 - de-assertion is synchronous per domain, skew bounded by 1 pclk
        // (Sec. 7.3, Sec. 8.1)
        // ===================================================================
        h_deassert = 0; p_deassert = 0; t_por_rel = 0;
        fork
            begin @(posedge hreset_n); h_deassert = $time; end
            begin @(posedge preset_n); p_deassert = $time; end
            begin
                @(posedge clk_ref);
                por_n     = 1'b1;
                t_por_rel = $time;
            end
        join

        chk(p_deassert >= h_deassert,
            "T8 preset_n never releases before hreset_n");
        chk((p_deassert - h_deassert) <= 4*TREF_HALF,
            "T8 inter-domain de-assertion skew <= one pclk period");

        // De-assertion must be SYNCHRONOUS, i.e. released through the two-flop
        // synchroniser rather than following the source immediately.
        //
        // An earlier revision checked this as ($time % hclk_period == 0), which
        // is wrong twice over: it assumes the clock edges sit on exact
        // multiples of absolute zero, and any earlier test that offsets time by
        // a sub-period amount breaks it for the rest of the run. What actually
        // matters is that the release is DELAYED by the synchroniser depth.
        chk((h_deassert - t_por_rel) >= (2*TREF_HALF),
            "T8 hreset_n release is synchronised (>= 2 hclk edges after source)");

        // ===================================================================
        // T9 - watchdog path and the CRG-1 pulse stretch
        //
        // Sec. 7.1 as written would assert the whole chip's reset for a single
        // hclk period. This RTL stretches it; the check is that the reset is
        // both ASSERTED and held for materially longer than one cycle, so the
        // reset tree can actually distribute it.
        // ===================================================================
        repeat (20) @(posedge clk_ref);
        chk(hreset_n === 1'b1, "T9 out of reset before the watchdog fires");

        // The wait MUST be armed before the request is driven. hreset_n drops
        // combinationally the instant wdt_reset_i rises, so a sequential
        // "drive it, then wait for the negedge" misses the event entirely and
        // blocks forever waiting for a second falling edge that never comes.
        // That is what hung the previous revision of this testbench.
        t0 = 0;
        fork
            begin @(negedge hreset_n); t0 = $time; end
            begin
                @(posedge hclk);
                wdt_reset = 1'b1;
                @(posedge hclk);
                wdt_reset = 1'b0;              // a ONE-CYCLE request
            end
        join

        chk(preset_n === 1'b0, "T9 watchdog resets the pclk domain too");
        @(posedge hreset_n);
        t1 = $time;

        chk((t1 - t0) > (4 * 2*TREF_HALF),
            "T9 CRG-1: one-cycle watchdog request is stretched, not a 5ns blip");

        // The chip must come back up rather than latch in reset.
        repeat (40) @(posedge clk_ref);
        chk(hreset_n === 1'b1 && preset_n === 1'b1,
            "T9 chip leaves reset after the watchdog event (no reset loop)");

        // ===================================================================
        // Summary
        // ===================================================================
        $display("======================================================");
        $display("tb_crg: checks=%0d  FAIL=%0d", checks, fails);
        if (fails == 0) $display("tb_crg: PASSED");
        else            $display("tb_crg: FAILED");
        $display("======================================================");
        $finish;
    end

    // Global timeout so a hung clock cannot hang the regression.
    initial begin
        #50_000_000;
        $display("[FAIL] tb_crg: TIMEOUT");
        $display("tb_crg: FAILED");
        $finish;
    end

endmodule
