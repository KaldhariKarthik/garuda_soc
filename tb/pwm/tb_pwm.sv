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

    genvar c;
    generate for (c = 0; c < 4; c = c + 1) begin : g_mon
        initial begin rise_t[c] = 0; width[c] = 0; npulse[c] = 0;
                      runt[c] = 0;  min_w[c] = 1e9; end
        always @(posedge pwm[c]) rise_t[c] = $realtime;
        always @(negedge pwm[c]) if (rise_t[c] > 0) begin
            width[c]  = $realtime - rise_t[c];
            npulse[c] = npulse[c] + 1;
            if (width[c] < min_w[c]) min_w[c] = width[c];
        end
    end endgenerate

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
        end
    endtask

    logic [31:0] d;
    bit e;
    int i;

    initial begin
        $display("=== tb_pwm: Block 20 PWM ===");

        repeat (4) @(posedge pclk);
        check(pwm == 4'b0000, "[R-6] all four outputs LOW while in reset - motors off");
        preset_n = 1;
        repeat (10) @(posedge pclk);
        check(pwm == 4'b0000, "[R-6] all four outputs LOW out of reset, before configuration");

        bfm.read(R_ID, d, e);
        check(d == {16'h6A5D, 8'd20, 8'd1} && !e, "ID register reads block 20");
        bfm.read(12'h800, d, e);
        check(e, "[R-4] PSLVERR on an unmapped offset");

        // ---- registers ------------------------------------------------------------
        bfm.wr(R_PERIOD, 32'd1000);
        bfm.read(R_PERIOD, d, e);
        check(d == 32'd1000, "[R-4] PERIOD reads back");
        for (i = 0; i < 4; i++) bfm.wr(R_DUTY0 + 4*i, 32'd100 + 10*i);
        for (i = 0; i < 4; i++) begin
            bfm.read(R_DUTY0 + 4*i, d, e);
            if (d != 32'd100 + 10*i) fails++;
        end
        check(1'b1, "[R-4] four independent duty registers read back");

        // ---- still low until enabled ------------------------------------------------
        repeat (50) @(posedge pclk);
        check(pwm == 4'b0000, "[R-6] configured but not enabled: still low");

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
              "[R-3] all four outputs rise in the same cycle - one shared time base");

        // ---- double buffering: a mid-pulse write must not produce a runt ---------------
        // Wait until ch3 is high, then rewrite its duty to something much
        // shorter. The pulse in progress must finish at its ORIGINAL width.
        reset_mon();
        @(posedge pwm[3]);
        repeat (100) @(posedge pclk);                // we are mid-pulse now
        bfm.wr(R_DUTY0 + 12, 32'd50);                // 400 -> 50 ticks
        @(negedge pwm[3]); #1;                       // let the monitor record it
        check(width[3] > 3180.0 && width[3] < 3220.0,
              $sformatf("[R-5] the pulse in progress kept its original width (%0.0f ns)",
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
              "[R-6] clearing EN drops all four in the same cycle, mid-pulse");
        repeat (2000) @(posedge pclk);
        check(pwm == 4'b0000, "[R-6] and they stay low");

        // ---- a duty wider than the period is clamped and reported ---------------------------
        bfm.wr(R_IRQSTAT, 32'h3);
        bfm.wr(R_IRQEN, 32'h2);                      // clamp interrupt
        bfm.wr(R_DUTY0 + 0, 32'd5000);               // > period 1000
        bfm.wr(R_CTRL, 32'h0F1);
        repeat (3000) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        check(d[16], "[R-7] STATUS reports channel 0's duty was clamped");
        check(irq, "[R-7] and it raised the clamp interrupt");
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
        bfm.wr(R_CTRL, 32'h000);

        check(pready_viol == 0, "[R-4] PREADY high in every cycle of every access");

        $display("tb_pwm: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end

    initial begin #60_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
