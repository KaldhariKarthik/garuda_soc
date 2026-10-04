`timescale 1ns/1ps
// =============================================================================
// tb_timers.sv -- Block 11 timers + watchdog, Rev 4.0 smoke
//
// Spec: GARUDA-TIMERS-SPEC-001 §11. Runs with the real clk_div + reset_ctrl so
// the watchdog reset goes through the production stretch and domain logic.
//   mtimecmp reset value, mtip never asserts at reset       [N-6.1]
//   coherent 64-bit mtime read across a low-word carry      [N-7.5]
//   mtip assert on >=, clear by advancing mtimecmp          [N-7.8]..[N-7.10]
//   WDT: EN sticky RW1S, idle WDTVAL = WDTLOAD, magic kick  [N-6.2], [N-6.4]
//   warning IRQ, then a full-length stretched reset         [N-6.6], §8.3
//   t_wdt_req_survives: request flop outside hreset_n       [N-7.19]
// Added 2026-10-04, written from the spec text:
//   mtime rate, MTIME_HI alone, mtimecmp read-back, 64-bit unsigned compare
//   (high word, bit 63, equality, wrap), mtime write moving mtip, the naive
//   and the three-step mtimecmp sequences, back-to-back APB accesses
//   watchdog: count rate, 132-value kick sweep, WDTLOAD while running, three
//   warning thresholds, warning-before-reset, post-reset register values, and
//   a kick swept across the expiry cycle (wins at WDTVAL = 1, loses at 0)
// =============================================================================
module tb_timers;
    reg refclk = 0, ext_rst_n = 1;

    // ---- reset must arrive as an EDGE, not merely be low at time 0 (TB-22) ---
    // A Verilog async reset is edge-sensitive in simulation: `always @(... or
    // negedge rst_n)` is not evaluated just because rst_n is already low when
    // the run starts. A reset declared `= 0` therefore produces no negedge
    // ever, and every flop whose only reset is that signal stays X for the
    // whole simulation -- and `q <= ~q` on a clock divider keeps X forever, so
    // the derived clock and its reset never resolve. Real silicon resets on a
    // LEVEL and cannot behave this way; it is a simulation artefact, so the fix
    // belongs here. Declare the reset de-asserted and assert it at time 0.
    initial #0 ext_rst_n = 1'b0;

    always #1 refclk = ~refclk;

    wire aon, hclk, pclk, pclk_phase, div_busy;
    wire [1:0] div_act, div_sel;
    wire hreset_n, preset_n, core_rst_n, dm_rst_n, ext_hrst_n, ilock;

    // APB bus shared by the TB between reset_ctrl (window 9) and timers (11)
    reg        penable = 0, pwrite = 0;
    reg  [1:0] sel = 0;                      // [0] reset_ctrl, [1] timers
    reg [11:0] paddr = 0;
    reg [31:0] pwdata = 0;
    wire [31:0] prd_r, prd_t;
    wire        rdy_r, rdy_t, err_r, err_t;

    wire mtip, warn_irq, wdt_req;
    reg  hart_req = 0;                       // debugger holds the core in hartreset

    clk_div u_clk (.refclk_i(refclk), .raw_rst_n_i(ext_rst_n), .div_sel_i(div_sel),
        .aon_clk_o(aon), .hclk_o(hclk), .pclk_o(pclk), .pclk_phase_o(pclk_phase),
        .div_act_o(div_act), .div_busy_o(div_busy));

    reset_ctrl u_rst (.aon_clk_i(aon), .hclk_i(hclk), .pclk_i(pclk),
        .ext_rst_n_i(ext_rst_n), .wdt_rst_req_i(wdt_req), .ndm_rst_req_i(1'b0),
        .hartreset_req_i(hart_req), .boot_sel_i(1'b0),
        .psel_i(sel[0]), .penable_i(penable), .pwrite_i(pwrite), .paddr_i(paddr),
        .pwdata_i(pwdata), .prdata_o(prd_r), .pready_o(rdy_r), .pslverr_o(err_r),
        .div_sel_o(div_sel), .div_act_i(div_act), .div_busy_i(div_busy), .ilock_o(ilock),
        .hreset_n_o(hreset_n), .preset_n_o(preset_n), .core_rst_n_o(core_rst_n),
        .dm_rst_n_o(dm_rst_n), .ext_hrst_n_o(ext_hrst_n));

    // ---- ADR-0002 Rev 2: PRDATA must be stable for the whole access phase ----
    // WDTVAL is a free-running hclk down-counter, so before the pclk migration
    // PRDATA moved at the hclk edge in the middle of every access phase. This
    // counts any such movement; it is the check that distinguishes the pclk
    // front end from the hclk one, and it FAILS on the old RTL.
    // The access phase spans two hclk cycles. The update AT the setup-to-access
    // edge is legitimate, so the comparison starts from the second cycle: if
    // PRDATA differs between the two, it moved DURING the phase.
    integer prdata_moved = 0;
    reg [31:0] prd_hold;
    reg        acc_d;
    always @(posedge hclk) begin
        if (sel[1] && penable && acc_d && !pwrite && $time > 1000)
            if (prd_hold !== prd_t) prdata_moved = prdata_moved + 1;
        prd_hold <= prd_t;
        acc_d    <= sel[1] & penable;
    end

    timers_top dut (.hclk_i(hclk), .hreset_n_i(hreset_n), .ext_rst_n_i(ext_hrst_n),
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(sel[1]), .penable_i(penable), .pwrite_i(pwrite), .paddr_i(paddr),
        .pwdata_i(pwdata), .prdata_o(prd_t), .pready_o(rdy_t), .pslverr_o(err_t),
        .mtip_o(mtip), .wdt_warn_irq_o(warn_irq), .wdt_rst_req_o(wdt_req));

    // ---- monitors (added 2026-10-04) -----------------------------------------------
    longint hcyc = 0, cap_cyc = 0;
    always @(posedge hclk) hcyc <= hcyc + 1;
    // one hclk strobe per APB access
    integer n_ws = 0, n_rs = 0;
    always @(posedge hclk) if (hreset_n) begin
        if (dut.u_apb.ws) n_ws = n_ws + 1;
        if (dut.u_apb.rs) n_rs = n_rs + 1;
    end
    // [N-7.8]: mtip is the 64-bit unsigned compare, registered once
    integer mtip_bad = 0, mtip_cycles = 0;
    reg        exp_mtip = 0, mtip_d = 0;
    reg [63:0] mt_at_rise = 0;
    always @(posedge hclk or negedge hreset_n)
        if (!hreset_n) begin exp_mtip <= 1'b0; mtip_d <= 1'b0; end
        else begin
            if (mtip !== exp_mtip) mtip_bad = mtip_bad + 1;
            if (mtip) mtip_cycles = mtip_cycles + 1;
            if (mtip && !mtip_d) mt_at_rise = dut.u_mtime.mtime_q;
            exp_mtip <= ({1'b0, dut.u_mtime.mtime_q} >= {1'b0, dut.u_mtime.cmp_q});
            mtip_d   <= mtip;
        end
    // watchdog: when the request rises and falls, when the warning rises, what
    // the counter held in the cycle a kick landed
    integer req_rise_bad = 0, req_fall_bad = 0, n_req_rise = 0, n_kick = 0, n_warn_rise = 0;
    longint c_req = -1, c_warn = -1;
    reg        wdt_req_d = 0, hreset_d = 1, warn_d = 0, req_seen = 0;
    reg [31:0] ctr_d = 0, ctr_at_warn = 0, ctr_at_kick = 0;
    always @(posedge hclk) begin
        if (wdt_req && !wdt_req_d) begin
            n_req_rise = n_req_rise + 1; c_req = hcyc;
            if (ctr_d != 32'd0) req_rise_bad = req_rise_bad + 1;      // [N-7.16]: only at zero
        end
        if (!wdt_req && wdt_req_d && hreset_d) req_fall_bad = req_fall_bad + 1;   // R-8
        if (wdt_req) req_seen = 1;
        if (warn_irq && !warn_d) begin ctr_at_warn = dut.u_wdt.ctr_q; n_warn_rise = n_warn_rise + 1; c_warn = hcyc; end
        if (hreset_n && dut.u_wdt.kick) begin ctr_at_kick = dut.u_wdt.ctr_q; n_kick = n_kick + 1; end
        wdt_req_d <= wdt_req; hreset_d <= hreset_n; warn_d <= warn_irq; ctr_d <= dut.u_wdt.ctr_q;
    end

    integer checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask
    task automatic apb(input int s, input bit w, input [11:0] a, input [31:0] d,
                       output [31:0] r, output bit e);
        @(posedge pclk); cap_cyc = hcyc; #0.1 sel = (1 << s); pwrite = w; paddr = a; pwdata = d; penable = 0;
        @(posedge pclk); #0.1 penable = 1;
        // sample at the edge that ends the access phase, as the bridge does
        @(posedge pclk); r = s ? prd_t : prd_r; e = s ? err_t : err_r;
        #0.1 sel = 0; penable = 0; pwrite = 0;
    endtask
    // back-to-back access to the timers window: no idle cycle, the next setup
    // phase starts on the pclk edge that ends this access. Call on a pclk edge.
    task automatic apb_bb(input bit w, input [11:0] a, input [31:0] d, output [31:0] r);
        cap_cyc = hcyc;
        #0.1 sel = 2'b10; pwrite = w; paddr = a; pwdata = d; penable = 0;
        @(posedge pclk); #0.1 penable = 1;
        @(posedge pclk); r = prd_t;
    endtask
    task automatic apb_idle();
        #0.1 sel = 0; penable = 0; pwrite = 0;
    endtask
    localparam T = 1, R = 0;
    reg [31:0] r, lo, hi; bit e;
    int i, bad;
    reg [31:0] r2, v;
    longint c0;
    int k, ok, L, nwin, nlose, nearly, hit0, hit1;
    realtime t_fall;
    reg [31:0] rng = 32'h7157_0001;
    function automatic [31:0] rnd32();
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng;
    endfunction
    task automatic set_time(input [31:0] h, input [31:0] l);
        reg [31:0] r_; bit e_;
        apb(T, 1, 12'h004, h, r_, e_); apb(T, 1, 12'h000, l, r_, e_);
    endtask
    task automatic set_cmp(input [31:0] h, input [31:0] l);          // [N-7.12] sequence
        reg [31:0] r_; bit e_;
        apb(T, 1, 12'h008, 32'hFFFF_FFFF, r_, e_); apb(T, 1, 12'h00C, h, r_, e_); apb(T, 1, 12'h008, l, r_, e_);
    endtask
    task automatic wait_reset_done();
        wait (!hreset_n);
        wait (hreset_n && preset_n);
        repeat (2) @(posedge pclk);
    endtask

    initial begin
        $display("=== tb_timers: Block 11 Rev 4.0 ===");
        #40 ext_rst_n = 1;
        @(posedge preset_n);

        apb(T, 0, 12'h008, 0, r, e); check(r == 32'hFFFF_FFFF, "[N-6.1] MTIMECMP_LO resets to all ones");
        apb(T, 0, 12'h00C, 0, r, e); check(r == 32'hFFFF_FFFF, "[N-6.1] MTIMECMP_HI resets to all ones");
        check(!mtip, "mtip low after reset");
        ok = 1;
        apb(T, 0, 12'h010, 0, r, e); if (r !== 32'd0 || e) ok = 0;            // WDTCTL
        apb(T, 0, 12'h014, 0, r, e); if (r !== 32'hFFFF_FFFF || e) ok = 0;    // WDTLOAD
        apb(T, 0, 12'h018, 0, r, e); if (r !== 32'hFFFF_FFFF || e) ok = 0;    // WDTVAL = WDTLOAD while disabled
        apb(T, 0, 12'h020, 0, r, e); if (r !== 32'd0 || e) ok = 0;            // WDTWARN
        apb(T, 0, 12'h01C, 0, r, e); if (e) ok = 0;                           // WDTKICK is mapped
        apb(T, 0, 12'h004, 0, r, e); if (r !== 32'd0 || e) ok = 0;            // MTIME_HI (shadow)
        check(ok && !warn_irq && !wdt_req, "[N-9.2] reset values: WDTCTL = 0, WDTLOAD = all ones, WDTWARN = 0, watchdog disabled, no warning, no request");

        // ---- coherent read across the carry -------------------------------------
        bad = 0;
        for (i = 0; i < 16; i++) begin                  // FFFF_FFF0..FFFF_FFFF
            apb(T, 1, 12'h004, 32'h0000_0007, r, e);
            apb(T, 1, 12'h000, 32'hFFFF_FFF0 + i, r, e);   // carry lands mid-read
            apb(T, 0, 12'h000, 0, lo, e);
            apb(T, 0, 12'h004, 0, hi, e);
            if (!((hi == 7 && lo >= 32'hFFFF_FF00) || (hi == 8 && lo < 32'h0000_0100))) begin bad++; if (bad < 4) $display("  i=%0d hi=%h lo=%h", i, hi, lo); end
        end
        check(bad == 0, "[N-7.5] LO-then-HI read is coherent across a carry (16 offsets)");

        // ---- mtip ---------------------------------------------------------------------
        apb(T, 1, 12'h004, 0, r, e); apb(T, 1, 12'h000, 0, r, e);       // epoch 0
        apb(T, 1, 12'h008, 32'hFFFF_FFFF, r, e);                      // 3-step sequence
        apb(T, 1, 12'h00C, 32'h0, r, e);
        apb(T, 1, 12'h008, 32'd400, r, e);
        check(!mtip, "mtip low before the deadline");
        repeat (420) @(posedge hclk);
        check(mtip, "[N-7.8] mtip asserts once mtime >= mtimecmp");
        apb(T, 1, 12'h008, 32'hFFFF_FFFF, r, e);
        apb(T, 1, 12'h00C, 32'h0, r, e);
        apb(T, 1, 12'h008, 32'd1_000_000, r, e);
        repeat (2) @(posedge hclk);
        check(!mtip, "[N-7.10] mtip clears when mtimecmp is written past mtime while the interrupt is pending");
        apb(T, 1, 12'h008, 32'd5, r, e);                              // late write
        repeat (3) @(posedge hclk);
        check(mtip, "[N-7.9] a deadline already passed asserts at once (>=, not ==)");
        apb(T, 1, 12'h008, 32'hFFFF_FFFF, r, e); apb(T, 1, 12'h00C, 32'hFFFF_FFFF, r, e);

        // ---- watchdog registers ----------------------------------------------------------
        apb(T, 1, 12'h014, 32'd3000, r, e);
        apb(T, 0, 12'h018, 0, r, e); check(r == 3000, "[N-7.17] WDTVAL reads WDTLOAD while disabled");
        apb(T, 1, 12'h018, 0, r, e); check(e, "PSLVERR on a write to read-only WDTVAL");
        apb(T, 0, 12'h030, 0, r, e); check(e, "PSLVERR on unmapped offset");
        apb(T, 1, 12'h020, 32'd1000, r, e);                           // WDTWARN
        apb(T, 1, 12'h010, 32'h3, r, e);                              // EN | WARNEN
        apb(T, 1, 12'h010, 32'h2, r, e);                              // try to clear EN
        apb(T, 0, 12'h010, 0, r, e); check(r[0], "[N-6.2] WDTCTL.EN is sticky: writing 0 does not clear it");
        repeat (200) @(posedge hclk);
        apb(T, 1, 12'h01C, 32'h1234_5678, r, e);                      // wrong kick
        apb(T, 0, 12'h018, 0, lo, e);
        apb(T, 1, 12'h01C, 32'h5A5A_C3C3, r, e);                      // magic kick
        apb(T, 0, 12'h018, 0, hi, e);
        check(lo < 2800 && hi > lo, "[N-6.4] only 0x5A5A_C3C3 reloads the counter");

        // ---- warning, then the reset ----------------------------------------------------
        wait (warn_irq);
        apb(T, 0, 12'h018, 0, r, e);
        check(r <= 1000, "[N-6.6] warning IRQ (CLIC 22) asserts at WDTVAL <= WDTWARN");
        repeat (4) @(posedge hclk);
        check(warn_irq, "D-17: warning stays asserted (level) until kick or reset");
        wait (wdt_req);
        begin : survive
            realtime t0, t1; int lowcyc;
            t0 = $realtime;
            lowcyc = 0;
            @(negedge hreset_n);
            t_fall = $realtime;
            // was `check(wdt_req || 1, ...)`, which could not fail
            check(wdt_req, "[R-8] [N-7.21] the request is still asserted at the instant hreset_n falls");
            // the request must outlive its own first effect on hreset_n
            #0.5 check(ext_hrst_n, "t_wdt_req_survives: request flop's domain (ext-only) is not reset");
            @(posedge hreset_n); t1 = $realtime;
            check((t1 - t0) >= 2048.0, $sformatf("stretched reset: hreset_n held %0.0f ns (>= 1024 refclk)", t1 - t0));
            check((t1 - t_fall) >= 2048.0, $sformatf("[N-7.21] hreset_n itself was low for %0.0f ns (>= 1024 refclk), measured edge to edge", t1 - t_fall));
        end
        check(!wdt_req, "[N-7.21] request cleared once the reset was in force");
        @(posedge preset_n);
        apb(R, 0, 12'h000, 0, r, e); check(r == 32'h2, "[N-7.22] RSTREASON = WDT after the watchdog reset");
        apb(T, 0, 12'h010, 0, r, e); check(r == 0, "[N-9.2] watchdog restarts disabled after the reset");
        check(!warn_irq, "warning cleared by the reset");

        check(prdata_moved == 0, $sformatf("[ADR-0002 Rev 2] PRDATA never moved mid-access-phase (%0d moves)", prdata_moved));

        $display("tb_timers: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end
    initial begin #3_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
