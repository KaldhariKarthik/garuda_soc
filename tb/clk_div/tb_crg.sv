`timescale 1ns/1ps
// =============================================================================
// tb_crg.sv -- Blocks 21/22 (clk_div + reset_ctrl), Rev 4.0 smoke
//
// Spec: GARUDA-CLKRST-SPEC-001 §11 verification plan. Directed, self-checking.
// Covers: t_clk_div2, t_pclk_div2, t_no_cdc_proof (edge subset + pclk_phase),
// t_div_sel, t_div_switch_glitch (all 12 ordered transitions), t_reset_stretch,
// t_wdt_self_cancel, t_reset_domains (DM outside ndmreset), t_rst_reason,
// t_hartreset scope, t_reset_release_order, MEMCTL.ILOCK, PSLVERR.
// =============================================================================
module tb_crg;

    localparam real TREF = 2.0;              // 500 MHz

    reg        refclk = 0;
    reg        ext_rst_n = 0;
    reg        wdt_req = 0, ndm_req = 0, hart_req = 0;

    reg        psel = 0, penable = 0, pwrite = 0;
    reg [11:0] paddr = 0;
    reg [31:0] pwdata = 0;
    wire [31:0] prdata;
    wire       pready, pslverr;

    wire aon, hclk, pclk, pclk_phase, div_busy;
    wire [1:0] div_act, div_sel;
    wire hreset_n, preset_n, core_rst_n, dm_rst_n, ext_hrst_n, ilock;

    always #(TREF/2) refclk = ~refclk;

    clk_div u_clkdiv (
        .refclk_i(refclk), .raw_rst_n_i(ext_rst_n), .div_sel_i(div_sel),
        .aon_clk_o(aon), .hclk_o(hclk), .pclk_o(pclk), .pclk_phase_o(pclk_phase),
        .div_act_o(div_act), .div_busy_o(div_busy));

    reset_ctrl u_rst (
        .aon_clk_i(aon), .hclk_i(hclk), .pclk_i(pclk),
        .ext_rst_n_i(ext_rst_n), .wdt_rst_req_i(wdt_req),
        .ndm_rst_req_i(ndm_req), .hartreset_req_i(hart_req), .boot_sel_i(1'b1),
        .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite), .paddr_i(paddr),
        .pwdata_i(pwdata), .prdata_o(prdata), .pready_o(pready), .pslverr_o(pslverr),
        .div_sel_o(div_sel), .div_act_i(div_act), .div_busy_i(div_busy),
        .ilock_o(ilock),
        .hreset_n_o(hreset_n), .preset_n_o(preset_n), .core_rst_n_o(core_rst_n),
        .dm_rst_n_o(dm_rst_n), .ext_hrst_n_o(ext_hrst_n));

    // ---------------------------------------------------------------- scoreboard
    integer checks = 0, fails = 0;
    task automatic check(input bit cond, input string what);
        checks++;
        if (!cond) begin fails++; $display("[FAIL] %s  (t=%0t)", what, $time); end
        else             $display("[PASS] %s", what);
    endtask

    // ---------------------------------------------------------------- monitors
    // pclk rising edges must coincide with hclk rising edges (no-CDC argument)
    realtime t_hrise = 0, t_prise = 0;
    integer  subset_viol = 0, phase_viol = 0;
    always @(posedge hclk) t_hrise = $realtime;
    always @(posedge pclk) begin
        t_prise = $realtime;
        #0.001;
        if (t_hrise != t_prise) subset_viol++;
    end
    // pclk_phase sampled at an hclk edge => pclk rises on that edge
    reg ph_prev = 0;
    always @(posedge hclk) begin
        ph_prev <= pclk_phase;
        #0.01;
        if (hreset_n && ph_prev === 1'b1 && pclk !== 1'b1) phase_viol++;
    end
    // shortest hclk high/low phase seen (glitch detector)
    realtime t_hedge = 0, min_phase = 1e9;
    always @(hclk) begin
        if (t_hedge > 0 && ($realtime - t_hedge) < min_phase) min_phase = $realtime - t_hedge;
        t_hedge = $realtime;
    end

    // ---------------------------------------------------------------- APB
    task automatic apb_wr(input [11:0] a, input [31:0] d, output bit err);
        @(posedge pclk); #0.1;
        psel = 1; pwrite = 1; paddr = a; pwdata = d; penable = 0;
        @(posedge pclk); #0.1; penable = 1;
        @(posedge pclk); err = pslverr; #0.1;
        psel = 0; penable = 0; pwrite = 0;
    endtask
    task automatic apb_rd(input [11:0] a, output [31:0] d, output bit err);
        @(posedge pclk); #0.1;
        psel = 1; pwrite = 0; paddr = a; penable = 0;
        @(posedge pclk); #0.1; penable = 1;
        #0.5; d = prdata; err = pslverr;
        @(posedge pclk); #0.1;
        psel = 0; penable = 0;
    endtask

    task automatic measure(output realtime ph, output realtime pp);
        realtime a, b;
        @(posedge hclk); a = $realtime; @(posedge hclk); b = $realtime; ph = b - a;
        @(posedge pclk); a = $realtime; @(posedge pclk); b = $realtime; pp = b - a;
    endtask

    // wait for a reset to assert then measure how long hreset_n stays low
    task automatic reset_width(output realtime w);
        realtime a;
        if (hreset_n) @(negedge hreset_n);
        a = $realtime;
        @(posedge hreset_n);
        w = $realtime - a;
    endtask

    realtime ph, pp, w, t_rel_ext, t_hrel, t_prel;
    reg [31:0] rd; bit err;
    int i, j;

    initial begin
        $display("=== tb_crg: Blocks 21/22 Rev 4.0 ===");
        // ---- power-on --------------------------------------------------------
        #100 ext_rst_n = 1; t_rel_ext = $realtime;
        @(posedge hreset_n); t_hrel = $realtime;
        @(posedge preset_n); t_prel = $realtime;
        check((t_hrel - t_rel_ext) >= 1024*TREF, "t_reset_stretch: power-on hreset_n held >= 1024 refclk");
        check(t_prel >= t_hrel, "t_reset_release_order: preset_n after hreset_n");
        check(core_rst_n && dm_rst_n && ext_hrst_n, "all functional resets released after power-on");

        // ---- clocks at DIV2 ---------------------------------------------------
        measure(ph, pp);
        check(ph == 2*TREF, "t_clk_div2: hclk = refclk/2 (4 ns)");
        check(pp == 4*TREF, "t_pclk_div2: pclk = hclk/2 (8 ns)");

        apb_rd(12'h000, rd, err);
        check(rd == 32'h1 && !err, "t_rst_reason: EXT after power-on");
        apb_rd(12'h008, rd, err);
        check(rd[2:0] == 3'b000, "CLKSTAT: DIVACT=DIV2, not busy");
        check(rd[8] == 1'b1, "CLKSTAT[8] reflects the boot_sel pin (D-19)");

        // ---- every ratio, and all 12 ordered transitions -----------------------
        min_phase = 1e9;
        for (i = 0; i < 4; i++) for (j = 0; j < 4; j++) if (i != j) begin
            apb_wr(12'h004, i << 8, err);
            repeat (40) @(posedge refclk);
            apb_wr(12'h004, j << 8, err);
            repeat (40) @(posedge refclk);
            wait (!div_busy);
            measure(ph, pp);
            check(ph == (2.0*TREF)*(1 << j) && pp == 2*ph,
                  $sformatf("t_div_sel: %0d -> %0d gives DIV%0d (hclk %0.0f ns, pclk %0.0f ns)",
                            i, j, 2 << j, ph, pp));
        end
        check(min_phase >= TREF, $sformatf("t_div_switch_glitch: shortest hclk phase %0.1f ns >= 2 ns", min_phase));
        apb_rd(12'h008, rd, err);
        check(rd[1:0] == div_sel && !rd[2], "CLKSTAT.DIVACT tracks DIVSEL");

        // leave the chip at DIV4 to prove DIVSEL survives SWRST ([N-6.5])
        apb_wr(12'h004, 1 << 8, err);
        wait (!div_busy);

        // ---- MEMCTL.ILOCK RW1S sticky -----------------------------------------
        apb_wr(12'h020, 32'h1, err);
        check(ilock, "MEMCTL.ILOCK set by writing 1");
        apb_wr(12'h020, 32'h0, err);
        check(ilock, "MEMCTL.ILOCK not cleared by writing 0");

        // ---- SWRST -------------------------------------------------------------
        fork apb_wr(12'h004, (1 << 8) | 1, err); reset_width(w); join
        check(w >= 1024*TREF, $sformatf("t_reset_stretch: SWRST reset %0.0f ns >= 1024 refclk", w));
        @(posedge preset_n);
        apb_rd(12'h000, rd, err);
        check(rd == 32'h8, "t_rst_reason: SW after SWRST (EXT replaced)");
        apb_rd(12'h004, rd, err);
        check(rd[9:8] == 2'b01, "DIVSEL survives SWRST");
        check(!ilock, "ILOCK cleared by SWRST");

        // ---- watchdog: one-hclk pulse -> full-length reset ------------------------
        @(posedge hclk); #0.1 wdt_req = 1;
        @(posedge hclk); #0.1 wdt_req = 0;
        #1 check(!dm_rst_n || !hreset_n, "wdt request asserts reset");
        reset_width(w);
        check(w >= 1024*TREF, $sformatf("t_wdt_self_cancel: 1-cycle WDT pulse -> %0.0f ns reset", w));
        check(ext_hrst_n, "t_reset_domains: watchdog request domain (ext-only) not reset by WDT");
        @(posedge preset_n);
        apb_rd(12'h000, rd, err);
        check(rd == 32'h2, "t_rst_reason: WDT");

        // ---- ndmreset: DM stays alive ----------------------------------------------
        @(posedge hclk); #0.1 ndm_req = 1;
        repeat (20) @(posedge hclk);
        check(!hreset_n && !core_rst_n && dm_rst_n, "t_ndmreset_dm_alive: system reset, DM not reset");
        #0.1 ndm_req = 0;
        @(posedge preset_n);
        check(dm_rst_n, "DM never reset across ndmreset");
        apb_rd(12'h000, rd, err);
        check(rd == 32'h4, "t_rst_reason: NDM");

        // ---- W1C and SETBOOTFAIL -----------------------------------------------------
        apb_wr(12'h004, (1 << 8) | (1 << 4), err);
        apb_rd(12'h000, rd, err);
        check(rd == 32'h14, "RSTCTL.SETBOOTFAIL sets RSTREASON.BOOTFAIL");
        apb_wr(12'h000, 32'h1F, err);
        apb_rd(12'h000, rd, err);
        check(rd == 32'h0, "RSTREASON W1C clears all bits");

        // ---- hartreset: core only ---------------------------------------------------------
        @(posedge hclk); #0.1 hart_req = 1;
        repeat (4) @(posedge hclk);
        check(!core_rst_n && hreset_n && preset_n && dm_rst_n, "t_hartreset: core reset, fabric alive");
        #0.1 hart_req = 0;
        repeat (4) @(posedge hclk);
        check(core_rst_n, "hartreset release is immediate (not stretched)");

        // ---- unmapped offset ------------------------------------------------------------
        apb_rd(12'h00C, rd, err);
        check(err, "PSLVERR on unmapped offset 0x00C");
        apb_rd(12'h004, rd, err);
        check(!err, "no PSLVERR on RSTCTL");

        // ---- global monitors ----------------------------------------------------------
        check(subset_viol == 0, $sformatf("t_no_cdc_proof: every pclk rise is an hclk rise (%0d viol)", subset_viol));
        check(phase_viol == 0, $sformatf("a_pclk_phase: pclk rises after every pclk_phase (%0d viol)", phase_viol));

        $display("tb_crg: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end

    initial begin #2_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
