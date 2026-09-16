`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - tb_soc_ahb.sv : the wired SoC
//
//   DUT      garuda_soc_top = garuda_core_top (with the real dsu_top inside)
//                           + dma_top
//                           + ahb_interconnect
//                           + isram_top / bootrom_top / dsram_top   (NEW)
//                           + ahb2apb_bridge                        (NEW)
//                           + clic_top                              (NEW)
//
// =============================================================================
// WHAT CHANGED IN THIS REVISION, AND WHAT IT COSTS
// =============================================================================
// The previous revision instantiated three ahb_lite_sram models and an
// ahb2apb_bridge_model alongside the DUT, because Blocks 3/4/5 and 8 had no
// RTL. They do now, so THIS TESTBENCH COMPILES NO VERIFICATION MODEL AT ALL
// except the passive protocol checker. Every slave on the bus is silicon RTL.
//
// Two consequences worth stating plainly rather than discovering later:
//
//  1. THE WAIT-STATE PLUSARGS ARE GONE. +IWAIT/+DWAIT/+RANDW injected wait
//     states into the memory models, and that was the mechanism this testbench
//     used to open and close the core's stall windows. The real memories are
//     zero-wait by specification (MEM Sec. 8.4) and have no such input, so the
//     knob does not exist any more and a run with it is no longer meaningful.
//     THAT COVERAGE HAS NOT DISAPPEARED - it moved: tb_ahb_interconnect.sv
//     still drives ahb_lite_sram and still sweeps wait states, which is now the
//     only place variable slave timing is exercised. If the core's stall paths
//     are to be stressed at SoC level again, the wait states have to come from
//     an APB peripheral holding PREADY low, which is the one place in this
//     design where a slave legitimately stalls.
//
//  2. THE INTERRUPT PATH IS PRESENT FOR THE FIRST TIME. The old testbench tied
//     the core's clic_irq_i low, so the entire interrupt path was unexercised
//     by construction. The CLIC is now in the DUT and the DMA's twelve lines
//     reach it. The boot program still POLLS SR.COMPLETE rather than taking an
//     interrupt, so what is checked here is the reset posture - every CLIC
//     level resets to 0, so no source can interrupt and the CPU must never be
//     diverted - plus that the DMA's completion actually arrived at the CLIC's
//     pending bit. Taking a real interrupt needs an ISR in the boot image and
//     is the obvious next test to write.
//
// Plusargs
//   +HEX=<path>       ROM image (default tb/soc/soc_dma_smoke.hex)
//   +MAXCYC=<n>       cycle timeout (default 400000)
//   +VERBOSE          print bus activity summaries
//   +NO_AHBCHK_FATAL  demote protocol violations to advisory (default: fatal)
// =============================================================================

module tb_soc_ahb;

    // -----------------------------------------------------------------------
    // Clocks. pclk is 100 MHz and deliberately NOT phase-aligned to hclk: a
    // cleanly divided pclk is the easy case for a clock crossing and the skewed
    // one is what finds the bugs. The real silicon relationship is an aligned
    // divide-by-2 produced by Block 22 and verified in tb_crg.sv; the bridge is
    // specified to be correct regardless (BRG Sec. 13.2), and this is where
    // that claim gets exercised.
    // -----------------------------------------------------------------------
    reg hclk = 1'b0;
    reg pclk = 1'b0;
    reg hreset_n = 1'b0;
    reg preset_n = 1'b0;

    always #2.5 hclk = ~hclk;                 // 200 MHz
    initial begin
        #1.3;
        forever #5 pclk = ~pclk;              // 100 MHz, skewed
    end

    // -----------------------------------------------------------------------
    // Scoreboard
    // -----------------------------------------------------------------------
    integer checks = 0;
    integer fails  = 0;
    reg     verbose;
    reg     ahbchk_fatal;

    task chk_eq;
        input [63:0]   got;
        input [63:0]   exp;
        input [1023:0] msg;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                fails = fails + 1;
                $display("[FAIL] %0s : got 0x%0h expected 0x%0h   (t=%0t)",
                         msg, got, exp, $time);
            end else begin
                $display("[ ok ] %0s = 0x%0h", msg, got);
            end
        end
    endtask

    task chk;
        input          cond;
        input [1023:0] msg;
        begin
            checks = checks + 1;
            if (!cond) begin
                fails = fails + 1;
                $display("[FAIL] %0s   (t=%0t)", msg, $time);
            end else begin
                $display("[ ok ] %0s", msg);
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Plusargs
    // -----------------------------------------------------------------------
    reg [1023:0] hexfile;
    integer      maxcyc;

    // -----------------------------------------------------------------------
    // SoC boundary nets. Far fewer than before - the memories, the bridge and
    // the CLIC are inside now.
    // -----------------------------------------------------------------------
    wire [15:0] apb_psel;
    wire        apb_penable, apb_pwrite;
    wire [15:0] apb_paddr;
    wire [31:0] apb_pwdata;
    wire [3:0]  apb_pstrb;

    wire [5:0]  dma_ack;
    reg  [5:0]  dma_req;
    wire        wdt_reset;
    wire [47:0] dbg_acc_0, dbg_acc_1, dbg_acc_2;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    garuda_soc_top #(
        .RESET_VECTOR   (32'h1000_0000),
        .BROM_INIT_FILE (""),              // loaded by backdoor before reset
        .CLIC_N         (32)
    ) u_soc (
        .hclk_i(hclk), .pclk_i(pclk),
        .hreset_n_i(hreset_n), .preset_n_i(preset_n),

        // APB expansion bus - Blocks 10-15/18-21 do not exist. Nothing drives
        // a PSEL for those windows (the bridge masks them and faults instead),
        // so the return path is tied to a benign idle rather than modelled.
        .apb_psel_o(apb_psel), .apb_penable_o(apb_penable),
        .apb_pwrite_o(apb_pwrite), .apb_paddr_o(apb_paddr),
        .apb_pwdata_o(apb_pwdata), .apb_pstrb_o(apb_pstrb),
        .apb_prdata_i(32'h0000_0000), .apb_pready_i(1'b1), .apb_pslverr_i(1'b0),

        .dma_req_i(dma_req), .dma_ack_o(dma_ack),

        // No peripheral or timer interrupt sources exist yet.
        .irq_ext_i(20'b0),

        // Block 20 does not exist: mtime never reaches mtimecmp, so MTIP stays
        // low. mtimecmp is all-ones rather than zero for that reason - zero
        // would make (mtime >= mtimecmp) true immediately and fire a timer
        // interrupt on cycle one.
        .mtime_i(64'd0), .mtimecmp_i({64{1'b1}}),

        .wdt_reset_o(wdt_reset),

        .dbg_acc_0_o(dbg_acc_0), .dbg_acc_1_o(dbg_acc_1), .dbg_acc_2_o(dbg_acc_2)
    );

    // -----------------------------------------------------------------------
    // Protocol checkers. All four tap nets INSIDE the DUT, which is correct -
    // in the finished SoC every one of these is an internal net.
    // -----------------------------------------------------------------------
    wire [31:0] v_i, v_d, v_m, v_s;

    ahb_lite_checker u_chk_i (
        .clk_i(hclk), .rst_n_i(hreset_n),
        .haddr_i(u_soc.i_haddr), .htrans_i(u_soc.i_htrans), .hsize_i(u_soc.i_hsize),
        .hburst_i(u_soc.i_hburst), .hwrite_i(u_soc.i_hwrite), .hwdata_i(u_soc.i_hwdata),
        .hready_i(u_soc.i_hready), .hresp_i(u_soc.i_hresp), .viol_count_o(v_i));

    ahb_lite_checker u_chk_d (
        .clk_i(hclk), .rst_n_i(hreset_n),
        .haddr_i(u_soc.d_haddr), .htrans_i(u_soc.d_htrans), .hsize_i(u_soc.d_hsize),
        .hburst_i(u_soc.d_hburst), .hwrite_i(u_soc.d_hwrite), .hwdata_i(u_soc.d_hwdata),
        .hready_i(u_soc.d_hready), .hresp_i(u_soc.d_hresp), .viol_count_o(v_d));

    ahb_lite_checker u_chk_m (
        .clk_i(hclk), .rst_n_i(hreset_n),
        .haddr_i(u_soc.m_haddr), .htrans_i(u_soc.m_htrans), .hsize_i(u_soc.m_hsize),
        .hburst_i(u_soc.m_hburst), .hwrite_i(u_soc.m_hwrite), .hwdata_i(u_soc.m_hwdata),
        .hready_i(u_soc.m_hready), .hresp_i(u_soc.m_hresp), .viol_count_o(v_m));

    // The slave-side checker is the important one: every master-side violation
    // is a bug in a master, but a SLAVE-side violation is a bug in the fabric,
    // and it is the only place "the interconnect stitched two masters' transfers
    // into one illegal stream" is visible at all.
    ahb_lite_checker u_chk_s (
        .clk_i(hclk), .rst_n_i(hreset_n),
        .haddr_i(u_soc.haddr), .htrans_i(u_soc.htrans), .hsize_i(u_soc.hsize),
        .hburst_i(u_soc.hburst), .hwrite_i(u_soc.hwrite), .hwdata_i(u_soc.hwdata),
        .hready_i(u_soc.hready),
        .hresp_i(u_soc.hresp_isram | u_soc.hresp_rom | u_soc.hresp_dsram |
                 u_soc.hresp_bridge | u_soc.u_ahb.hresp_df),
        .viol_count_o(v_s));

    // -----------------------------------------------------------------------
    // Bus-activity observers. These turn "the test passed" into "the test
    // passed AND all three masters were actually on the bus". A SoC test that
    // quietly never granted the DMA would otherwise look identical to one that
    // did.
    // -----------------------------------------------------------------------
    integer n_grant_i, n_grant_d, n_grant_m;
    integer n_sel_isram, n_sel_rom, n_sel_dsram, n_sel_bridge, n_sel_default;
    integer n_concurrent;
    integer max_dma_wait, dma_wait_run;
    integer n_mem_stall;             // any memory driving HREADYOUT low: must be 0
    integer n_spurious_irq;          // CLIC presenting a request: must be 0 here

    // Sticky observers for the interrupt path.
    //
    // These MUST be sticky. The obvious formulation - sample dma_irq[0] and the
    // CLIC's pending bit at the end of the run - checks a transient long after
    // it has passed: the firmware polls SR.COMPLETE and then W1C-clears it,
    // which drops dma_irq[0], so by the final check both signals are correctly
    // zero and a point sample reports failure against a working design. Latch
    // the event when it happens instead.
    reg saw_dma_irq0;
    reg saw_clic_ip0;

    // Continuous check that the DMA's twelve interrupt lines actually reach the
    // CLIC's source vector. This proves the WIRING without requiring an
    // interrupt to fire, which matters because the boot program disables
    // interrupt generation entirely (see the final checks).
    integer n_irq_wire_bad;

    always @(posedge hclk) begin
        if (!hreset_n) begin
            n_grant_i <= 0; n_grant_d <= 0; n_grant_m <= 0;
            n_sel_isram <= 0; n_sel_rom <= 0; n_sel_dsram <= 0;
            n_sel_bridge <= 0; n_sel_default <= 0;
            n_concurrent <= 0;
            max_dma_wait <= 0; dma_wait_run <= 0;
            n_mem_stall <= 0; n_spurious_irq <= 0;
            saw_dma_irq0 <= 1'b0; saw_clic_ip0 <= 1'b0;
            n_irq_wire_bad <= 0;
        end else begin
            if (u_soc.hready && u_soc.htrans[1]) begin
                case (u_soc.u_ahb.grant)
                    2'd0: n_grant_i <= n_grant_i + 1;
                    2'd1: n_grant_d <= n_grant_d + 1;
                    default: n_grant_m <= n_grant_m + 1;
                endcase
                if (u_soc.hsel_isram)  n_sel_isram  <= n_sel_isram  + 1;
                if (u_soc.hsel_rom)    n_sel_rom    <= n_sel_rom    + 1;
                if (u_soc.hsel_dsram)  n_sel_dsram  <= n_sel_dsram  + 1;
                if (u_soc.hsel_bridge) n_sel_bridge <= n_sel_bridge + 1;
                if (u_soc.u_ahb.hsel[4]) n_sel_default <= n_sel_default + 1;
            end

            if (({1'b0, u_soc.i_htrans[1]} + {1'b0, u_soc.d_htrans[1]} +
                 {1'b0, u_soc.m_htrans[1]}) > 2'd1)
                n_concurrent <= n_concurrent + 1;

            // Longest run of cycles where the DMA was asking and not granted.
            // This is the number ERRATUM AHB-2 is about, measured on a real
            // instruction stream rather than on a BFM.
            if (u_soc.m_htrans[1] && (u_soc.u_ahb.grant != 2'd2)) begin
                dma_wait_run <= dma_wait_run + 1;
                if ((dma_wait_run + 1) > max_dma_wait)
                    max_dma_wait <= dma_wait_run + 1;
            end else begin
                dma_wait_run <= 0;
            end

            // MEM Sec. 8.4: zero wait states, unconditionally, on all three.
            if (!u_soc.hreadyout_isram || !u_soc.hreadyout_rom ||
                !u_soc.hreadyout_dsram)
                n_mem_stall <= n_mem_stall + 1;

            // Every CLIC level resets to 0 and the boot program never programs
            // one, so no source can ever be active.
            if (u_soc.clic_irq) n_spurious_irq <= n_spurious_irq + 1;

            // Latch the interrupt-path events as they occur (see declaration).
            if (u_soc.dma_irq[0])   saw_dma_irq0 <= 1'b1;
            if (u_soc.u_clic.ip[0]) saw_clic_ip0 <= 1'b1;

            // The DMA's 12 lines must land on CLIC sources [11:0] in the
            // documented order: [5:0] complete, [11:6] error (CLIC Sec. 6.2).
            //
            // Tapped at the DRIVER in garuda_soc_top, not inside the CLIC.
            // Two earlier attempts named u_soc.u_clic.irq_src, which does not
            // exist: the port there is irq_src_i, so Icarus refused to bind it
            // whole or part-selected. Tapping the driving net is also the
            // better check - it is the SoC's wiring under test here, and the
            // CLIC's own handling of its input is tb_clic's job.
            //
            // irq_ext_i is tied off at this level, so zero-extending the
            // expected value is exact rather than a weakening of the check.
            if (u_soc.irq_src !==
                {{(32-12){1'b0}}, u_soc.dma_err, u_soc.dma_irq})
                n_irq_wire_bad <= n_irq_wire_bad + 1;
        end
    end

    // -----------------------------------------------------------------------
    // Run
    // -----------------------------------------------------------------------
    localparam [31:0] TOHOST = 32'h2000_F000;

    integer    cyc;
    reg [31:0] th;
    reg        done;
    integer    i;

    initial begin
        verbose      = $test$plusargs("VERBOSE");
        ahbchk_fatal = !$test$plusargs("NO_AHBCHK_FATAL");
        if (!$value$plusargs("MAXCYC=%d", maxcyc)) maxcyc = 400000;
        if (!$value$plusargs("HEX=%s", hexfile))
            hexfile = "tb/soc/soc_dma_smoke.hex";

        dma_req = 6'b0;          // the smoke test is M2M: no peripheral handshake

        $display("=====================================================");
        $display("GARUDA SoC integration TB - the WIRED SoC");
        $display("  core+DSU, DMA, interconnect, memories, bridge, CLIC");
        $display("  hex=%0s", hexfile);
        $display("=====================================================");

        // The Boot ROM is mask-programmed in silicon, so there is no run-time
        // path to write it: the image goes in through the block's backdoor
        // before reset is released.
        u_soc.u_brom.bd_load_hex(hexfile);

        hreset_n = 1'b0;
        preset_n = 1'b0;
        repeat (10) @(posedge hclk);
        // Both resets released together. DMA Sec. 17.5 requires this of Block
        // 23; releasing pclk first could let a toggle raised in pclk look like
        // a spurious arm event when hclk leaves reset. tb_crg.sv is where the
        // reset controller's own sequencing is verified.
        @(negedge hclk);
        hreset_n = 1'b1;
        preset_n = 1'b1;

        // ---- reset-state checks ----
        @(posedge hclk);
        chk_eq(u_soc.htrans, 2'b00, "reset: slave-side HTRANS is IDLE");
        chk_eq(u_soc.dma_irq, 6'b0, "reset: no DMA completion interrupt");
        chk_eq(u_soc.dma_err, 6'b0, "reset: no DMA error interrupt");
        chk(u_soc.clic_irq === 1'b0, "reset: CLIC presents no interrupt");
        chk_eq(apb_psel, 16'h0,     "reset: no APB peripheral selected");

        // ---- run until tohost is written ----
        done = 1'b0;
        for (cyc = 0; (cyc < maxcyc) && !done; cyc = cyc + 1) begin
            @(posedge hclk);
            th = u_soc.u_dsram.bd_read(TOHOST);
            if (th != 32'h0) done = 1'b1;
        end

        $display("");
        if (!done) begin
            fails  = fails + 1;
            checks = checks + 1;
            $display("[FAIL] TIMEOUT after %0d cycles - nothing written to tohost", maxcyc);
            $display("       last slave-side HADDR=0x%08h HTRANS=%b grant=%0d",
                     u_soc.haddr, u_soc.htrans, u_soc.u_ahb.grant);
        end else begin
            $display("tohost = 0x%08h after %0d cycles", th, cyc);
            chk_eq(th, 32'h1, "software verdict (1 = PASS; see soc_dma_smoke.S for codes)");
        end

        // ---- the DMA actually moved the data, checked independently of the
        //      CPU's own comparison, through the memory backdoor ----
        for (i = 0; i < 64; i = i + 1)
            chk_eq(u_soc.u_dsram.bd_read(32'h2000_1000 + i*4), 32'h5A5A_0000 + i,
                   "DMA destination word (backdoor)");

        // ---- all three masters were genuinely on the bus ----
        $display("");
        $display("bus activity: grants I=%0d D=%0d DMA=%0d | selects ISRAM=%0d ROM=%0d DSRAM=%0d BRIDGE=%0d DEFAULT=%0d",
                 n_grant_i, n_grant_d, n_grant_m,
                 n_sel_isram, n_sel_rom, n_sel_dsram, n_sel_bridge, n_sel_default);
        $display("              cycles with >1 master requesting = %0d", n_concurrent);
        $display("              longest DMA request-to-grant wait = %0d hclk", max_dma_wait);

        chk(n_grant_i > 100,   "I-Port fetched from the bus");
        chk(n_grant_d > 100,   "D-Port did loads/stores on the bus");
        chk(n_grant_m > 100,   "DMA moved beats on the bus");
        chk(n_sel_rom   > 100, "Boot ROM was selected (instruction fetch)");
        chk(n_sel_dsram > 100, "Data SRAM was selected (data + DMA)");
        chk(n_sel_bridge >  4, "Bridge was selected (DMA configuration)");
        chk_eq(n_sel_default, 0, "no access ever fell through to the default slave");
        chk(n_concurrent > 50, "masters genuinely contended for the bus");

        // ERRATUM AHB-2 measured on real traffic. The bound is loose on purpose
        // - the point is that it is BOUNDED, not that it is any given number.
        chk(max_dma_wait < 64,
            "DMA was never starved: request-to-grant stayed bounded");

        // ---- the real memories never stalled (MEM Sec. 8.4) ----
        chk_eq(n_mem_stall, 0,
               "ZERO WAIT STATES: no memory drove HREADYOUT low all run");

        // ---- the interrupt path, present for the first time ----
        $display("");
        chk_eq(n_spurious_irq, 0,
               "CLIC never presented a request (every level resets to 0)");
        // THE INTERRUPT PATH IS WIRED BUT NOT EXERCISED BY THIS PROGRAM, and
        // that distinction is worth stating precisely rather than papering over.
        //
        // soc_dma_smoke.S programs CR with IE=0 and EIE=0 (stated in its own
        // header) and POLLS SR.COMPLETE, because it was written before the CLIC
        // existed. dma_irq[n] is only raised when SR.COMPLETE is set AND CR.IE
        // is 1, so the DMA is CORRECT to raise nothing here. An earlier
        // revision of this testbench asserted the opposite and failed against
        // working hardware twice - see TB-21.
        //
        // So what is checked is the honest pair: the DMA raised no interrupt
        // because none was requested, and the wiring from the DMA's lines to
        // the CLIC's source vector is continuously correct regardless.
        chk(!saw_dma_irq0,
            "DMA raised no interrupt - correct, the program sets CR.IE=0");
        chk(!saw_clic_ip0,
            "CLIC source 0 correspondingly never went pending");
        chk_eq(n_irq_wire_bad, 0,
            "DMA irq/err lines are wired to CLIC sources [11:0] every cycle");

        $display("NOTE: the DMA->CLIC->core interrupt path is WIRED and");
        $display("      structurally checked, but never FIRES in this test.");
        $display("      Exercising it end to end needs a boot image with");
        $display("      CR.IE=1, a CLIC level programmed over APB, and an ISR.");
        $display("      That test does not exist yet.");

        // ---- the real DSU executed ----
        chk_eq(dbg_acc_0, 48'd84, "DSU accumulator 0 holds 2 x (7*6) via Custom-0");

        // ---- protocol ----
        $display("");
        u_chk_i.report_result();
        u_chk_d.report_result();
        u_chk_m.report_result();
        u_chk_s.report_result();

        if (ahbchk_fatal) begin
            chk_eq(v_i, 0, "protocol: I-Port port clean");
            chk_eq(v_d, 0, "protocol: D-Port port clean");
            chk_eq(v_m, 0, "protocol: DMA port clean");
            chk_eq(v_s, 0, "protocol: SLAVE-SIDE bus clean");
        end else begin
            $display("NOTE: +NO_AHBCHK_FATAL - protocol violations are advisory this run");
        end

        $display("");
        $display("=====================================================");
        $display("SOC TB: %0d checks, %0d failures", checks, fails);
        $display("RESULT: %0s", (fails == 0) ? "PASSED" : "FAILED");
        $display("=====================================================");
        $finish;
    end

    // Hard watchdog independent of MAXCYC, so a hang in the loop above still
    // produces a verdict rather than an eternal simulation.
    initial begin
        #20_000_000;
        $display("[FAIL] hard watchdog expired");
        $display("SOC TB: %0d checks, %0d failures", checks, fails + 1);
        $display("RESULT: FAILED");
        $finish;
    end

endmodule
