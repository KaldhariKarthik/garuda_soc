`timescale 1ns/1ps
// =============================================================================
// tb_pwm.sv -- Block 20 PWM (in-house)
//
// Spec: GARUDA-PWM-SPEC-001 §11. The outputs drive four ESCs, so the tests
// are about what an ESC would see: pulse WIDTH, and never a runt.
//
// PRESCALE is 0 here (tick = pclk) so a frame is microseconds rather than
// milliseconds; the prescaler arithmetic is checked separately.
// =============================================================================
module tb_pwm;

    logic pclk = 0, preset_n = 0;
    always #4 pclk = ~pclk;                        // 125 MHz, 8 ns

    garuda_apb_bfm bfm (.pclk(pclk), .preset_n(preset_n));

    wire       irq;
    wire [3:0] pwm;

    garuda_pwm_top #(.BLOCK_NUM(8'd20), .NCH(4)) dut (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(bfm.psel), .penable_i(bfm.penable), .pwrite_i(bfm.pwrite),
        .paddr_i(bfm.paddr), .pwdata_i(bfm.pwdata), .prdata_o(bfm.prdata),
        .pready_o(bfm.pready), .pslverr_o(bfm.pslverr),
        .irq_o(irq), .pwm_o(pwm));

    localparam [11:0] R_PRESCALE = 12'h000, R_PERIOD = 12'h004, R_CTRL = 12'h008,
                      R_STATUS   = 12'h00C, R_DUTY0  = 12'h010,
                      R_IRQSTAT  = 12'hFE0, R_IRQEN  = 12'hFE4, R_ID = 12'hFEC;

    int pready_viol = 0;
    always @(posedge pclk)
        if (preset_n && bfm.psel && !bfm.pready) pready_viol++;

    // ---- what an ESC sees: the width of each high pulse, per channel -----------
    realtime rise_t [0:3];
    realtime width  [0:3];
    int      npulse [0:3];
    int      runt   [0:3];
    realtime min_w  [0:3];

    // rise-to-rise time (the frame an ESC sees) and, when `strict` is set, a
    // count of pulses whose width is neither of the two the test allows
    realtime per    [0:3];
    int      nrise  [0:3];
    int      odd_w  [0:3];
    bit      strict = 0;
    real     allow_a = 0.0, allow_b = 0.0;
    // [N-6.1] an output may be high only with CTRL.EN AND its own enable set
    int      off_viol [0:3];

    genvar c;
    generate for (c = 0; c < 4; c = c + 1) begin : g_mon
        initial begin rise_t[c] = 0; width[c] = 0; npulse[c] = 0;
                      runt[c] = 0;  min_w[c] = 1e9;
                      per[c] = 0; nrise[c] = 0; odd_w[c] = 0; off_viol[c] = 0; end
        always @(posedge pwm[c]) begin
            if (nrise[c] > 0) per[c] = $realtime - rise_t[c];
            nrise[c] = nrise[c] + 1;
            rise_t[c] = $realtime;
            if (!(preset_n && dut.en_q && dut.ch_en_q[c])) off_viol[c] = off_viol[c] + 1;
        end
        always @(negedge pwm[c]) if (rise_t[c] > 0) begin
            width[c]  = $realtime - rise_t[c];
            npulse[c] = npulse[c] + 1;
            if (width[c] < min_w[c]) min_w[c] = width[c];
            if (strict && width[c] != allow_a && width[c] != allow_b) begin
                odd_w[c] = odd_w[c] + 1;
                $display("    ch%0d: pulse of %0.0f ns, neither %0.0f nor %0.0f (t=%0t)",
                         c, width[c], allow_a, allow_b, $time);
            end
        end
        always @(posedge pclk)
            if (pwm[c] && !(preset_n && dut.en_q && dut.ch_en_q[c])) off_viol[c] = off_viol[c] + 1;
    end endgenerate

    // [N-7.2] with all four channels enabled and non-zero, any rising edge
    // must find all four high in that same cycle
    bit chk_align = 0;
    int skew = 0;
    always @(posedge pwm[0] or posedge pwm[1] or posedge pwm[2] or posedge pwm[3])
        if (chk_align) begin #0.1; if (pwm !== 4'b1111) skew = skew + 1; end

    // Independent APB protocol observer on this block's config port. The
    // shared garuda_apb_bfm carries no PSTRB, so the strobes are tied high.
    wire [31:0] apbviol;
    apb_checker u_apbchk (
        .clk_i(pclk), .rst_n_i(preset_n),
        .psel_i(bfm.psel), .penable_i(bfm.penable), .pwrite_i(bfm.pwrite),
        .paddr_i({20'h0, bfm.paddr}), .pwdata_i(bfm.pwdata), .pstrb_i(4'hF),
        .pready_i(bfm.pready), .pslverr_i(bfm.pslverr), .viol_count_o(apbviol));

    int checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    task automatic reset_mon();
        int j;
        for (j = 0; j < 4; j++) begin
            npulse[j] = 0; min_w[j] = 1e9; runt[j] = 0;
            nrise[j] = 0; per[j] = 0; odd_w[j] = 0;
        end
    endtask

    logic [31:0] d, d2;
    bit e;
    int i, k, nbad;
    logic [3:0] snap;

    initial begin
        $display("=== tb_pwm: Block 20 PWM ===");

        repeat (4) @(posedge pclk);
        check(pwm == 4'b0000, "[R-6] [N-9.2] all four outputs LOW while in reset - motors off");
        preset_n = 1;
        repeat (10) @(posedge pclk);
        check(pwm == 4'b0000, "[R-6] [N-9.2] all four outputs LOW out of reset, before configuration");

        bfm.read(R_ID, d, e);
        check(d == {16'h6A5D, 8'd20, 8'd1} && !e, "ID register reads block 20");
        bfm.read(12'h800, d, e);
        check(e, "[R-4] PSLVERR on an unmapped offset");

        // ---- registers ------------------------------------------------------------
        bfm.wr(R_PERIOD, 32'd1000);
        bfm.read(R_PERIOD, d, e);
        check(d == 32'd1000, "[R-4] PERIOD reads back");
        for (i = 0; i < 4; i++) bfm.wr(R_DUTY0 + 4*i, 32'd100 + 10*i);
        nbad = 0;
        for (i = 0; i < 4; i++) begin
            bfm.read(R_DUTY0 + 4*i, d, e);
            if (d != 32'd100 + 10*i) nbad++;
        end
        check(nbad == 0, $sformatf("[R-4] four independent duty registers read back (%0d wrong)", nbad));

        // ---- still low until enabled ------------------------------------------------
        repeat (50) @(posedge pclk);
        check(pwm == 4'b0000, "[R-6] [N-9.2] configured but not enabled: still low");

        // ---- four different widths from one time base --------------------------------
        // period 1000 ticks x 8 ns = 8 us; duties 100/200/300/400 ticks
        bfm.wr(R_PRESCALE, 32'd0);
        bfm.wr(R_PERIOD, 32'd1000);
        bfm.wr(R_DUTY0 + 0, 32'd100);
        bfm.wr(R_DUTY0 + 4, 32'd200);
        bfm.wr(R_DUTY0 + 8, 32'd300);
        bfm.wr(R_DUTY0 + 12, 32'd400);
        reset_mon();
        bfm.wr(R_CTRL, 32'h0F1);                     // EN + all four channels
        repeat (4000) @(posedge pclk);               // ~4 frames

        check(npulse[0] >= 2, $sformatf("[R-1] channel 0 is pulsing (%0d pulses)", npulse[0]));
        check(width[0] > 780.0 && width[0] < 820.0,
              $sformatf("[R-1] ch0 width %0.0f ns (100 ticks x 8 ns = 800)", width[0]));
        check(width[1] > 1580.0 && width[1] < 1620.0,
              $sformatf("[R-1] ch1 width %0.0f ns (1600)", width[1]));
        check(width[2] > 2380.0 && width[2] < 2420.0,
              $sformatf("[R-1] ch2 width %0.0f ns (2400)", width[2]));
        check(width[3] > 3180.0 && width[3] < 3220.0,
              $sformatf("[R-2] ch3 width %0.0f ns (3200) - four independent duties", width[3]));

        // ---- edges are aligned: one counter, so all four rise together ----------------
        @(posedge pwm[0]);
        check(pwm == 4'b1111,
              "[R-3] [N-7.2] all four outputs rise in the same cycle - one shared time base");

        // ---- double buffering: a mid-pulse write must not produce a runt ---------------
        // Wait until ch3 is high, then rewrite its duty to something much
        // shorter. The pulse in progress must finish at its ORIGINAL width.
        reset_mon();
        @(posedge pwm[3]);
        repeat (100) @(posedge pclk);                // we are mid-pulse now
        bfm.wr(R_DUTY0 + 12, 32'd50);                // 400 -> 50 ticks
        @(negedge pwm[3]); #1;                       // let the monitor record it
        check(width[3] > 3180.0 && width[3] < 3220.0,
              $sformatf("[R-5] [N-7.3] the pulse in progress kept its original width (%0.0f ns)",
                        width[3]));
        @(posedge pwm[3]); @(negedge pwm[3]); #1;
        check(width[3] > 380.0 && width[3] < 420.0,
              $sformatf("[R-5] and the NEXT pulse is the new width (%0.0f ns = 50 ticks)",
                        width[3]));
        check(min_w[3] > 380.0,
              $sformatf("[R-5] no runt pulse anywhere (shortest %0.0f ns)", min_w[3]));
        bfm.wr(R_DUTY0 + 12, 32'd400);

        // ---- disabling a channel drops only that channel ---------------------------------
        bfm.wr(R_CTRL, 32'h071);                     // channels 0,1,2 only
        repeat (2000) @(posedge pclk);
        reset_mon();
        repeat (3000) @(posedge pclk);
        check(npulse[3] == 0 && npulse[0] > 0,
              $sformatf("[R-2] channel 3 is off, the others still run (%0d vs %0d)",
                        npulse[3], npulse[0]));

        // ---- the global stop is immediate, not end-of-frame --------------------------------
        bfm.wr(R_CTRL, 32'h0F1);
        @(posedge pwm[3]);
        repeat (20) @(posedge pclk);                 // mid-pulse
        bfm.wr(R_CTRL, 32'h000);                     // EN off
        repeat (2) @(posedge pclk);
        check(pwm == 4'b0000,
              "[R-6] [N-7.5] clearing EN mid-pulse: all four low two cycles later");
        repeat (2000) @(posedge pclk);
        check(pwm == 4'b0000, "[R-6] and they stay low");

        // ---- a duty wider than the period is clamped and reported ---------------------------
        bfm.wr(R_IRQSTAT, 32'h3);
        bfm.wr(R_IRQEN, 32'h2);                      // clamp interrupt
        bfm.wr(R_DUTY0 + 0, 32'd5000);               // > period 1000
        bfm.wr(R_CTRL, 32'h0F1);
        repeat (3000) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        check(d[16], "[R-7] [N-7.4] STATUS reports channel 0's duty was clamped");
        check(irq, "[R-7] [R-9] and it raised the clamp interrupt");
        check(pwm[0] === 1'b1, "[R-7] the clamped channel sits at 100%, not glitching");
        bfm.wr(R_DUTY0 + 0, 32'd100);
        repeat (3000) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        check(!d[16], "[R-7] and the clamp clears once the duty is legal again");
        bfm.wr(R_IRQSTAT, 32'h3);
        repeat (4) @(posedge pclk);

        // ---- the prescaler ---------------------------------------------------------------------
        bfm.wr(R_CTRL, 32'h000);
        bfm.wr(R_PRESCALE, 32'd9);                   // tick = 10 pclk = 80 ns
        bfm.wr(R_PERIOD, 32'd100);                   // frame = 8 us
        bfm.wr(R_DUTY0 + 0, 32'd25);                 // 25 ticks = 2 us
        reset_mon();
        bfm.wr(R_CTRL, 32'h011);                     // EN + channel 0
        repeat (4000) @(posedge pclk);
        check(width[0] > 1960.0 && width[0] < 2040.0,
              $sformatf("[R-8] with PRESCALE 9, 25 ticks = %0.0f ns (2000 expected)",
                        width[0]));

        // ---- a real ESC frame ---------------------------------------------------------------------
        // 1 MHz tick, 20 ms frame, 1.5 ms pulse: the classic servo centre value.
        bfm.wr(R_CTRL, 32'h000);
        bfm.wr(R_PRESCALE, 32'd124);                 // 125 MHz / 125 = 1 MHz
        bfm.wr(R_PERIOD, 32'd20000);                 // 20 ms
        bfm.wr(R_DUTY0 + 0, 32'd1500);               // 1.5 ms
        reset_mon();
        bfm.wr(R_CTRL, 32'h011);
        @(posedge pwm[0]); @(negedge pwm[0]); #1;
        check(width[0] > 1_495_000.0 && width[0] < 1_505_000.0,
              $sformatf("[R-1] a 1.5 ms servo pulse measures %0.1f us", width[0] / 1000.0));
        @(posedge pwm[0]); #1;
        check(per[0] == 20_000_000.0 && width[0] == 1_500_000.0,
              $sformatf("[N-7.1] PRESCALE 124, PERIOD 20000, DUTY 1500: frame %0.3f ms rise to rise, pulse %0.3f ms - exact",
                        per[0] / 1.0e6, width[0] / 1.0e6));
        bfm.wr(R_CTRL, 32'h000);

        // =====================================================================
        // 2026-10-04: checks written from the spec notes that had none
        // =====================================================================

        // ---- [N-7.1] tick, period and pulse, exact to the pclk ----------------------------
        bfm.wr(R_PRESCALE, 32'd9);                   // tick = 10 pclk = 80 ns
        bfm.wr(R_PERIOD, 32'd100);                   // 8 us
        bfm.wr(R_DUTY0 + 0, 32'd25);                 // 2 us
        bfm.wr(R_DUTY0 + 4, 32'd1);                  // one tick
        bfm.wr(R_DUTY0 + 8, 32'd99);                 // one tick short of the frame
        bfm.wr(R_DUTY0 + 12, 32'd0);                 // never
        reset_mon();
        bfm.wr(R_CTRL, 32'h0F1);
        repeat (3500) @(posedge pclk);               // three and a half frames
        check(per[0] == 8000.0 && width[0] == 2000.0,
              $sformatf("[N-7.1] PRESCALE 9, PERIOD 100, DUTY 25: frame %0.0f ns (8000), pulse %0.0f ns (2000)",
                        per[0], width[0]));
        check(per[1] == 8000.0 && width[1] == 80.0,
              $sformatf("[R-1] DUTY 1 is exactly one tick (%0.0f ns, want 80)", width[1]));
        check(per[2] == 8000.0 && width[2] == 7920.0,
              $sformatf("[R-1] DUTY = PERIOD - 1 is low for exactly one tick (high %0.0f ns, want 7920)", width[2]));
        check(nrise[3] == 0 && pwm[3] === 1'b0, "[R-1] DUTY 0 never rises");

        // ---- [N-7.1a] PRESCALE and PERIOD changed with EN clear, then re-enabled -------------
        bfm.wr(R_CTRL, 32'h000);                     // stopped mid-frame, prescaler mid-count
        bfm.wr(R_PRESCALE, 32'd1);                   // tick = 16 ns
        bfm.wr(R_PERIOD, 32'd50);                    // 800 ns
        for (i = 0; i < 4; i++) bfm.wr(R_DUTY0 + 4*i, 32'd20);   // 320 ns
        reset_mon();
        bfm.wr(R_CTRL, 32'h011);
        @(negedge pwm[0]); #1;
        d[0] = (width[0] == 320.0);
        @(posedge pwm[0]); #1;
        check(d[0] && per[0] == 800.0,
              $sformatf("[N-7.1a] PRESCALE and PERIOD changed with EN clear: the FIRST frame after re-enable is exact (pulse %0.0f ns want 320, frame %0.0f ns want 800)",
                        width[0], per[0]));

        // ---- [N-6.1] high needs CTRL.EN AND the channel's own enable ---------------------------
        bfm.wr(R_CTRL, 32'h001);                     // EN, no channel
        repeat (200) @(posedge pclk);
        snap = pwm;
        bfm.wr(R_CTRL, 32'h0F0);                     // every channel, no EN
        repeat (200) @(posedge pclk);
        check(snap == 4'b0000 && pwm == 4'b0000,
              "[N-6.1] EN alone, or the channel enables alone: all four low");
        reset_mon();
        bfm.wr(R_CTRL, 32'h051);                     // EN + channels 0 and 2
        repeat (400) @(posedge pclk);
        check(npulse[0] > 0 && npulse[2] > 0 && nrise[1] == 0 && nrise[3] == 0,
              $sformatf("[N-6.1] CTRL[7:4] are per channel: with 0101 only channels 0 and 2 pulse (%0d %0d %0d %0d)",
                        npulse[0], nrise[1], npulse[2], nrise[3]));

        // ---- [N-7.2] no register value can skew the rising edges --------------------------------
        bfm.wr(R_CTRL, 32'h000);
        bfm.wr(R_PRESCALE, 32'd3);
        bfm.wr(R_PERIOD, 32'd200);
        bfm.wr(R_DUTY0 + 0, 32'd1);
        bfm.wr(R_DUTY0 + 4, 32'd77);
        bfm.wr(R_DUTY0 + 8, 32'd199);
        bfm.wr(R_DUTY0 + 12, 32'd150);
        reset_mon();
        skew = 0; chk_align = 1;
        bfm.wr(R_CTRL, 32'h0F1);
        repeat (3 * 200 * 4 + 40) @(posedge pclk);   // into the fourth frame
        chk_align = 0;
        check(skew == 0 && nrise[0] == 4 && nrise[1] == 4 && nrise[2] == 4 && nrise[3] == 4,
              $sformatf("[N-7.2] duties 1/77/199/150 behind a prescaler: all four rise in the same pclk cycle in every frame (%0d skewed, %0d frames)",
                        skew, nrise[0]));

        // ---- [N-7.3] double buffering: both directions, and all four together -------------------
        bfm.wr(R_CTRL, 32'h000);
        bfm.wr(R_PRESCALE, 32'd0);
        bfm.wr(R_PERIOD, 32'd1000);
        for (i = 0; i < 4; i++) bfm.wr(R_DUTY0 + 4*i, 32'd100);
        reset_mon();
        bfm.wr(R_CTRL, 32'h0F1);
        @(posedge pwm[0]);                           // second frame
        repeat (20) @(posedge pclk);                 // 20 ticks into a 100-tick pulse
        for (i = 0; i < 4; i++) bfm.wr(R_DUTY0 + 4*i, 32'd300);    // LENGTHEN all four
        @(negedge pwm[0]); #1;
        check(width[0] == 800.0 && width[1] == 800.0 && width[2] == 800.0 && width[3] == 800.0,
              $sformatf("[N-7.3] a longer duty written mid-pulse does not stretch the pulse in progress (%0.0f ns, want 800)",
                        width[0]));
        @(posedge pwm[0]); @(negedge pwm[0]); #1;
        check(width[0] == 2400.0 && width[1] == 2400.0 && width[2] == 2400.0 && width[3] == 2400.0,
              $sformatf("[N-7.3] the four shadows load together at the boundary: the next pulse is 300 ticks on every channel (%0.0f %0.0f %0.0f %0.0f ns)",
                        width[0], width[1], width[2], width[3]));

        // a write walked across the boundary one pclk at a time: every pulse
        // must be exactly the old width or the new one
        reset_mon();
        allow_a = 800.0; allow_b = 2400.0; strict = 1;
        for (k = 0; k < 12; k++) begin
            @(posedge pwm[0]);
            repeat (1000 - 8 + k) @(posedge pclk);   // the write lands from 5 pclk before the wrap to 6 after
            bfm.wr(R_DUTY0 + 0, (k % 2) ? 32'd300 : 32'd100);
        end
        repeat (2500) @(posedge pclk);
        strict = 0;
        check(odd_w[0] == 0 && npulse[0] >= 12,
              $sformatf("[N-7.3] a DUTY write walked across the period boundary never makes a third width (%0d odd pulses in %0d)",
                        odd_w[0], npulse[0]));

        // ---- [N-7.4] the clamp, per channel, and exactly at the edge of legal --------------------
        bfm.wr(R_CTRL, 32'h000);
        bfm.wr(R_IRQEN, 32'h0);
        bfm.wr(R_PERIOD, 32'd500);
        bfm.wr(R_DUTY0 + 0, 32'd500);                // == PERIOD: legal, 100%
        bfm.wr(R_DUTY0 + 4, 32'd100);
        bfm.wr(R_DUTY0 + 8, 32'd501);                // one over
        bfm.wr(R_DUTY0 + 12, 32'hFFFF);              // as far over as it goes
        bfm.wr(R_CTRL, 32'h0F1);
        bfm.wr(R_IRQSTAT, 32'h3);
        reset_mon();
        repeat (1600) @(posedge pclk);               // three boundaries
        bfm.read(R_STATUS, d, e);
        bfm.read(R_IRQSTAT, d2, e);
        check(d[19:16] == 4'b1100 && d2[1],
              $sformatf("[N-7.4] STATUS[16+n] is per channel and IRQSTAT[1] is raised: DUTY = PERIOD is legal, PERIOD + 1 and 0xFFFF are clamped (STATUS[19:16]=%04b IRQSTAT[1]=%0b)",
                        d[19:16], d2[1]));
        check(pwm[0] && pwm[2] && pwm[3] && npulse[0] == 0 && npulse[2] == 0 && npulse[3] == 0 && npulse[1] >= 2,
              $sformatf("[N-7.4] DUTY = PERIOD and both clamped channels are a steady 100%% with no edge across three boundaries; channel 1 still pulses (%0d %0d %0d %0d falls)",
                        npulse[0], npulse[1], npulse[2], npulse[3]));
        bfm.wr(R_DUTY0 + 8, 32'd250);
        bfm.wr(R_DUTY0 + 12, 32'd250);
        repeat (1600) @(posedge pclk);               // three boundaries: one whole pulse at the new duty
        bfm.read(R_STATUS, d, e);
        check(d[19:16] == 4'b0000 && width[2] == 2000.0 && width[3] == 2000.0,
              $sformatf("[N-7.4] the flags clear by themselves at the boundary once the duty is legal, and the channels pulse again (STATUS[19:16]=%04b, %0.0f ns)",
                        d[19:16], width[2]));
        bfm.wr(R_IRQSTAT, 32'h3);

        // ---- [N-7.5] low beats everything, and in the cycle it is asked for ----------------------
        bfm.wr(R_CTRL, 32'h000);
        bfm.wr(R_PERIOD, 32'd1000);
        for (i = 0; i < 4; i++) bfm.wr(R_DUTY0 + 4*i, 32'd400);
        bfm.wr(R_CTRL, 32'h0F1);
        @(posedge pwm[0]);
        repeat (50) @(posedge pclk);                 // 50 ticks into a 400-tick pulse
        bfm.wr(R_CTRL, 32'h0E1);                     // channel 0 off; bfm.wr returns on the edge that lands it
        #1 snap = pwm;
        check(snap == 4'b1110,
              $sformatf("[N-7.5] clearing one channel enable mid-pulse drops that channel in the same cycle and no other (pwm=%04b)", snap));
        bfm.wr(R_CTRL, 32'h0E0);                     // EN off
        #1 snap = pwm;
        check(snap == 4'b0000,
              $sformatf("[N-7.5] clearing CTRL.EN mid-pulse: all four low in the cycle the write lands, not at the end of the frame (pwm=%04b)", snap));

        // ---- [R-9] the period-boundary interrupt: held, masked, cleared ---------------------------
        bfm.wr(R_IRQSTAT, 32'h3);
        bfm.wr(R_PERIOD, 32'd200);
        bfm.wr(R_DUTY0 + 0, 32'd50);
        bfm.wr(R_IRQEN, 32'h1);
        bfm.wr(R_CTRL, 32'h011);
        repeat (100) @(posedge pclk);
        snap[0] = irq;                               // half a frame in: no boundary yet
        repeat (150) @(posedge pclk);
        check(!snap[0] && irq, "[R-9] the period-boundary interrupt rises at the first boundary and not before");
        bfm.wr(R_CTRL, 32'h000);                     // no more boundaries
        bfm.wr(R_IRQSTAT, 32'h1);
        repeat (2) @(posedge pclk);
        snap[0] = irq;
        bfm.wr(R_IRQEN, 32'h0);
        bfm.wr(R_CTRL, 32'h011);
        repeat (250) @(posedge pclk);
        bfm.read(R_IRQSTAT, d, e);
        snap[1] = irq;
        bfm.wr(R_CTRL, 32'h000);
        bfm.wr(R_IRQEN, 32'h1);
        repeat (60) @(posedge pclk);
        check(!snap[0] && d[0] && !snap[1] && irq,
              "[R-9] W1C drops it; with IRQEN clear the event is recorded but the line stays low; enabled, it is a level still held 60 pclk after the block stopped");
        bfm.wr(R_IRQSTAT, 32'h3);
        bfm.wr(R_IRQEN, 32'h0);

        // ---- zero and maximum of every field -------------------------------------------------------
        bfm.wr(R_PERIOD, 32'd0);
        bfm.wr(R_DUTY0 + 0, 32'd0);
        bfm.wr(R_DUTY0 + 4, 32'd1);
        bfm.wr(R_DUTY0 + 8, 32'hFFFF);
        reset_mon();
        bfm.wr(R_CTRL, 32'h0F1);
        repeat (300) @(posedge pclk);
        check(pwm == 4'b0000 && nrise[0] + nrise[1] + nrise[2] + nrise[3] == 0,
              "[R-6] PERIOD 0 with EN set: all four stay low whatever the duties");
        bfm.wr(R_CTRL, 32'h000);

        bfm.wr(R_PRESCALE, 32'd0);
        bfm.wr(R_PERIOD, 32'hFFFF);
        bfm.wr(R_DUTY0 + 0, 32'hFFFE);
        bfm.wr(R_DUTY0 + 4, 32'hFFFF);
        bfm.wr(R_DUTY0 + 8, 32'd1);
        reset_mon();
        bfm.wr(R_CTRL, 32'h071);
        @(negedge pwm[0]); @(posedge pwm[0]); @(negedge pwm[0]); #1;
        bfm.read(R_STATUS, d, e);
        check(width[0] == 65534.0 * 8.0 && per[0] == 65535.0 * 8.0 && width[2] == 8.0,
              $sformatf("[R-8] PERIOD 0xFFFF: frame %0.0f ns (524280), DUTY 0xFFFE high %0.0f ns (524272), DUTY 1 high %0.0f ns (8)",
                        per[0], width[0], width[2]));
        check(pwm[1] === 1'b1 && npulse[1] == 0 && d[19:16] == 4'b0000,
              "[R-8] DUTY = PERIOD = 0xFFFF is a steady 100%, not clamped and not wrapped");
        bfm.wr(R_CTRL, 32'h000);

        bfm.wr(R_PRESCALE, 32'hFFFF);                // one tick = 65536 pclk
        bfm.wr(R_PERIOD, 32'd2);
        bfm.wr(R_DUTY0 + 0, 32'd1);
        reset_mon();
        bfm.wr(R_CTRL, 32'h011);
        @(negedge pwm[0]); @(posedge pwm[0]); #1;
        check(width[0] == 65536.0 * 8.0 && per[0] == 2.0 * 65536.0 * 8.0,
              $sformatf("[R-8] PRESCALE 0xFFFF: one tick is 65536 pclk (pulse %0.0f ns want 524288, frame %0.0f ns want 1048576)",
                        width[0], per[0]));
        bfm.wr(R_CTRL, 32'h000);

        // ---- reserved bits, the read-only register, the uniform tail ---------------------------------
        nbad = 0;
        bfm.wr(R_PRESCALE, 32'hFFFF_FFFF); bfm.read(R_PRESCALE, d, e); if (d != 32'h0000_FFFF) nbad++;
        bfm.wr(R_PERIOD,   32'hFFFF_FFFF); bfm.read(R_PERIOD, d, e);   if (d != 32'h0000_FFFF) nbad++;
        for (i = 0; i < 4; i++) begin
            bfm.wr(R_DUTY0 + 4*i, 32'hFFFF_0000 | (32'h1111 << i));
            bfm.read(R_DUTY0 + 4*i, d, e);
            if (d != (32'h1111 << i)) nbad++;
        end
        bfm.wr(R_CTRL, 32'hFFFF_FFFE);               // everything but EN
        bfm.read(R_CTRL, d, e);                      if (d != 32'h0000_00F0) nbad++;
        check(nbad == 0 && pwm == 4'b0000,
              $sformatf("[R-4] every register keeps only its defined bits; the rest read 0 (%0d wrong)", nbad));
        bfm.read(R_STATUS, d, e);
        bfm.wr(R_STATUS, 32'hFFFF_FFFF);
        bfm.read(R_STATUS, d2, e);
        check(d == d2 && d[31:20] == 12'd0, "[R-4] STATUS is read-only and [31:20] read 0");
        bfm.wr(12'hFE8, 32'hFFFF_FFFF);
        bfm.read(12'hFE8, d, e);
        check(d == 32'h3 && !e, "[R-4] DMACTL is present in the tail and holds its two bits, though the block has no DMA channel");
        bfm.wr(12'hFE8, 32'h0);
        bfm.wr(R_CTRL, 32'h000);

        // ---- every offset without a register answers PSLVERR ------------------------------------------
        nbad = 0;
        for (i = 'h020; i < 'h1000; i = i + 4)
            if (!(i >= 'hFE0 && i <= 'hFEC)) begin
                bfm.read(i[11:0], d, e);
                if (!e) nbad++;
            end
        for (i = 0; i < 8; i++) begin
            bfm.read(4*i, d, e);                     if (e) nbad++;      // the eight registers
            if (i < 4) begin bfm.read(R_IRQSTAT + 4*i, d, e); if (e) nbad++; end
        end
        check(nbad == 0,
              $sformatf("[R-4] every offset with no register answers PSLVERR and the twelve that have one do not (%0d wrong)", nbad));

        // ---- [N-9.2] reset in the middle of a pulse ------------------------------------------------------
        bfm.wr(R_PRESCALE, 32'd0);
        bfm.wr(R_PERIOD, 32'd1000);
        for (i = 0; i < 4; i++) bfm.wr(R_DUTY0 + 4*i, 32'd400);
        bfm.wr(R_IRQEN, 32'h3);
        bfm.wr(R_CTRL, 32'h0F1);
        repeat (50) @(posedge pclk);
        snap = pwm;
        #2 preset_n = 0;                             // asynchronous: between two clock edges
        #1 check(snap == 4'b1111 && pwm == 4'b0000,
              "[N-9.2] reset mid-pulse: all four low at once, without waiting for a clock");
        repeat (3) @(posedge pclk);
        #1 preset_n = 1;
        repeat (4) @(posedge pclk);
        nbad = 0;
        for (i = 0; i < 8; i++) begin
            bfm.read(4*i, d, e);
            if (d != 32'd0) nbad++;
        end
        bfm.read(R_IRQSTAT, d, e); if (d != 32'd0) nbad++;
        bfm.read(R_IRQEN, d, e);   if (d != 32'd0) nbad++;
        repeat (1200) @(posedge pclk);               // longer than the frame that was running
        check(nbad == 0 && pwm == 4'b0000 && !irq,
              $sformatf("[N-9.2] after it every register reads 0 and the outputs stay low until firmware re-enables (%0d wrong)", nbad));

        check(off_viol[0] + off_viol[1] + off_viol[2] + off_viol[3] == 0,
              $sformatf("[N-6.1] over the whole run no output was ever high without CTRL.EN and its own enable (%0d violations)",
                        off_viol[0] + off_viol[1] + off_viol[2] + off_viol[3]));

        // ---- recorded, not judged: a channel enabled part-way through a frame ---------------------------
        // [N-6.1] as written makes the output follow the enable at once, so
        // the first pulse is whatever is left of it.
        bfm.wr(R_PERIOD, 32'd1000);
        bfm.wr(R_DUTY0 + 0, 32'd400);
        bfm.wr(R_DUTY0 + 12, 32'd400);
        bfm.wr(R_CTRL, 32'h011);
        @(posedge pwm[0]);
        repeat (300) @(posedge pclk);
        reset_mon();
        bfm.wr(R_CTRL, 32'h091);                     // channel 3 joins 303 ticks into a 400-tick pulse
        @(negedge pwm[3]); #1;
        $display("[OBSERVED] a channel enabled 303 ticks into a frame emits a first pulse of %0.0f ns where its duty asks for 3200 - see the report.",
                 width[3]);
        bfm.wr(R_CTRL, 32'h000);

        check(pready_viol == 0, "[R-4] PREADY high in every cycle of every access");

        u_apbchk.report_result;
        check(apbviol == 0, "APB protocol checker clean on the config port");
        check(u_apbchk.n_access > 0, "APB protocol checker observed traffic");

        $display("tb_pwm: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end

    initial begin #100_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
