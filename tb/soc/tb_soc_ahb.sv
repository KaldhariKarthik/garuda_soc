`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - tb_soc_ahb.sv : first testbench with CORE + DSU + DMA on one bus
//
// Until this file, every block in the project had only ever talked to a model
// built for it alone: the core to a dual-ported memory with no decoder and no
// arbiter (rtl/ahb/ahb_mem_slave.v says so in its own header), the DMA to a
// single TB slave. Multi-master arbitration, address decoding, slave hand-off
// and the 200/100 MHz configuration path were unverified by construction.
//
//   DUT      garuda_soc_top  = garuda_core_top (with the real dsu_top inside)
//                            + dma_top
//                            + ahb_interconnect
//
//   models   ahb_lite_sram        x3   ISRAM / Boot ROM / Data SRAM
//            ahb2apb_bridge_model x1   Block 8 stand-in, real 200->100 crossing
//            ahb_lite_checker     x4   I-Port, D-Port, DMA, and the slave bus
//
// The CPU runs sw/tests/soc_dma_smoke.S out of Boot ROM: it exercises the DSU,
// fills a buffer in Data SRAM, programs the DMA over the bridge, and polls
// SR.COMPLETE in a tight loop while the DMA moves 64 words. During that poll
// all three masters are live on three different slaves at once - the traffic
// pattern that nothing in this project had produced before.
//
// Plusargs
//   +HEX=<path>     ROM image (default tb/soc/soc_dma_smoke.hex)
//   +MAXCYC=<n>     cycle timeout (default 400000)
//   +IWAIT=<n>      max wait states on ISRAM / ROM
//   +DWAIT=<n>      max wait states on Data SRAM
//   +RANDW=1        randomise the wait count per access
//   +SEED=<n>       PRNG seed for the slave models
//   +VERBOSE        print bus activity summaries
//   +NO_AHBCHK_FATAL  demote protocol violations to advisory (default: fatal)
// =============================================================================

module tb_soc_ahb;

    // -----------------------------------------------------------------------
    // Clocks. pclk is 100 MHz and deliberately NOT phase-aligned to hclk: a
    // cleanly divided pclk is the easy case for a clock crossing, and the
    // skewed one is what finds the bugs. Same reasoning, and the same 1.3 ns
    // offset, as tb/dma/tb_dma_top.sv.
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
        input [63:0] got;
        input [63:0] exp;
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
        input        cond;
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
    integer maxcyc, iwait, dwait, randw, seed;

    // -----------------------------------------------------------------------
    // SoC boundary nets
    // -----------------------------------------------------------------------
    wire        hsel_isram, hsel_rom, hsel_dsram, hsel_bridge;
    wire [31:0] haddr, hwdata;
    wire [1:0]  htrans;
    wire        hwrite, hready;
    wire [2:0]  hsize, hburst;
    wire [3:0]  hprot;

    wire [31:0] hrdata_isram, hrdata_rom, hrdata_dsram, hrdata_bridge;
    wire        hreadyout_isram, hreadyout_rom, hreadyout_dsram, hreadyout_bridge;
    wire        hresp_isram, hresp_rom, hresp_dsram, hresp_bridge;

    wire        dma_psel, dma_penable, dma_pwrite;
    wire [7:0]  dma_paddr;
    wire [31:0] dma_pwdata, dma_prdata;
    wire        dma_pready, dma_pslverr;

    wire [5:0]  dma_ack, dma_irq, dma_err;
    reg  [5:0]  dma_req;

    wire        clic_irq_ack;
    wire [11:0] clic_irq_id_ack;
    wire [7:0]  clic_mintthresh;
    wire [47:0] dbg_acc_0, dbg_acc_1, dbg_acc_2;

    reg  [7:0]  iw, dw;
    reg         rw;

    // Handed to every slave model so the BUS TIMING varies with the seed, not
    // just the stimulus - see the seed_i note in tb/ahb/ahb_lite_sram.v.
    reg  [31:0] seed_run;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    garuda_soc_top #(.RESET_VECTOR(32'h1000_0000)) u_soc (
        .hclk_i(hclk), .pclk_i(pclk),
        .hreset_n_i(hreset_n), .preset_n_i(preset_n),

        .hsel_isram_o(hsel_isram), .hsel_rom_o(hsel_rom),
        .hsel_dsram_o(hsel_dsram), .hsel_bridge_o(hsel_bridge),

        .haddr_o(haddr), .htrans_o(htrans), .hwrite_o(hwrite),
        .hsize_o(hsize), .hburst_o(hburst), .hprot_o(hprot),
        .hwdata_o(hwdata), .hready_o(hready),

        .hrdata_isram_i(hrdata_isram),   .hreadyout_isram_i(hreadyout_isram),   .hresp_isram_i(hresp_isram),
        .hrdata_rom_i(hrdata_rom),       .hreadyout_rom_i(hreadyout_rom),       .hresp_rom_i(hresp_rom),
        .hrdata_dsram_i(hrdata_dsram),   .hreadyout_dsram_i(hreadyout_dsram),   .hresp_dsram_i(hresp_dsram),
        .hrdata_bridge_i(hrdata_bridge), .hreadyout_bridge_i(hreadyout_bridge), .hresp_bridge_i(hresp_bridge),

        .dma_psel_i(dma_psel), .dma_penable_i(dma_penable),
        .dma_pwrite_i(dma_pwrite), .dma_paddr_i(dma_paddr),
        .dma_pwdata_i(dma_pwdata), .dma_prdata_o(dma_prdata),
        .dma_pready_o(dma_pready), .dma_pslverr_o(dma_pslverr),

        .dma_req_i(dma_req), .dma_ack_o(dma_ack),
        .dma_irq_o(dma_irq), .dma_err_o(dma_err),

        // Block 7 does not exist: no interrupts are delivered in this test.
        .clic_irq_i(1'b0), .clic_irq_id_i(12'd0), .clic_irq_lvl_i(8'd0),
        .clic_irq_shv_i(1'b0),
        .clic_irq_ack_o(clic_irq_ack), .clic_irq_id_ack_o(clic_irq_id_ack),
        .clic_mintthresh_o(clic_mintthresh),

        // Block 20 does not exist: mtime never reaches mtimecmp, so MTIP stays
        // low. mtimecmp is all-ones rather than zero for that reason - zero
        // would make (mtime >= mtimecmp) true immediately and fire a timer
        // interrupt on cycle one.
        .mtime_i(64'd0), .mtimecmp_i({64{1'b1}}),

        .dbg_acc_0_o(dbg_acc_0), .dbg_acc_1_o(dbg_acc_1), .dbg_acc_2_o(dbg_acc_2)
    );

    // -----------------------------------------------------------------------
    // Slaves (verification models - Blocks 3 / 5 / 4 do not exist yet)
    // -----------------------------------------------------------------------
    ahb_lite_sram #(.BASE_ADDR(32'h0000_0000), .SIZE_BYTES(65536),
                    .READ_ONLY(0), .SEED(32'h1357_9BDF)) u_isram (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .waits_i(iw), .rand_waits_i(rw), .seed_i(seed_run),
        .err_en_i(1'b0), .err_base_i(32'h0), .err_size_i(32'h0),
        .hsel_i(hsel_isram), .haddr_i(haddr), .htrans_i(htrans),
        .hwrite_i(hwrite), .hsize_i(hsize), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(hrdata_isram), .hreadyout_o(hreadyout_isram), .hresp_o(hresp_isram));

    ahb_lite_sram #(.BASE_ADDR(32'h1000_0000), .SIZE_BYTES(4096),
                    .READ_ONLY(1), .SEED(32'h2468_ACE0)) u_rom (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .waits_i(iw), .rand_waits_i(rw), .seed_i(seed_run),
        .err_en_i(1'b0), .err_base_i(32'h0), .err_size_i(32'h0),
        .hsel_i(hsel_rom), .haddr_i(haddr), .htrans_i(htrans),
        .hwrite_i(hwrite), .hsize_i(hsize), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(hrdata_rom), .hreadyout_o(hreadyout_rom), .hresp_o(hresp_rom));

    ahb_lite_sram #(.BASE_ADDR(32'h2000_0000), .SIZE_BYTES(65536),
                    .READ_ONLY(0), .SEED(32'h0F1E_2D3C)) u_dsram (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .waits_i(dw), .rand_waits_i(rw), .seed_i(seed_run),
        .err_en_i(1'b0), .err_base_i(32'h0), .err_size_i(32'h0),
        .hsel_i(hsel_dsram), .haddr_i(haddr), .htrans_i(htrans),
        .hwrite_i(hwrite), .hsize_i(hsize), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(hrdata_dsram), .hreadyout_o(hreadyout_dsram), .hresp_o(hresp_dsram));

    // -----------------------------------------------------------------------
    // Block 8 stand-in: AHB (200 MHz) -> APB (100 MHz)
    // -----------------------------------------------------------------------
    wire        apb_psel, apb_penable, apb_pwrite;
    wire [31:0] apb_paddr, apb_pwdata;
    wire [31:0] apb_prdata_mux;
    wire        apb_pready_mux;
    wire        apb_pslverr_mux;

    ahb2apb_bridge_model u_bridge (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .pclk_i(pclk), .preset_n_i(preset_n),
        .hsel_i(hsel_bridge), .haddr_i(haddr), .htrans_i(htrans),
        .hwrite_i(hwrite), .hsize_i(hsize), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(hrdata_bridge), .hreadyout_o(hreadyout_bridge), .hresp_o(hresp_bridge),
        .psel_o(apb_psel), .penable_o(apb_penable), .pwrite_o(apb_pwrite),
        .paddr_o(apb_paddr), .pwdata_o(apb_pwdata),
        .prdata_i(apb_prdata_mux), .pready_i(apb_pready_mux), .pslverr_i(apb_pslverr_mux));

    // APB sub-decode. In the real SoC this is the bridge's own peripheral
    // select fan-out; here only one APB slave exists, the DMA at 0x4000_5000.
    // Everything else in the peripheral window answers OKAY with zero rather
    // than hanging, so a stray access shows up as wrong data instead of a
    // dead simulation.
    assign dma_psel    = apb_psel && (apb_paddr[15:12] == 4'h5);
    assign dma_penable = apb_penable;
    assign dma_pwrite  = apb_pwrite;
    assign dma_paddr   = apb_paddr[7:0];
    assign dma_pwdata  = apb_pwdata;

    assign apb_prdata_mux  = dma_psel ? dma_prdata  : 32'h0000_0000;
    assign apb_pready_mux  = dma_psel ? dma_pready  : 1'b1;
    assign apb_pslverr_mux = dma_psel ? dma_pslverr : 1'b0;


    // -----------------------------------------------------------------------
    // Protocol checkers. Master ports are tapped inside the DUT because
    // garuda_soc_top does not expose them - which is correct, they are
    // internal nets in the finished SoC.
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

    ahb_lite_checker u_chk_s (
        .clk_i(hclk), .rst_n_i(hreset_n),
        .haddr_i(haddr), .htrans_i(htrans), .hsize_i(hsize),
        .hburst_i(hburst), .hwrite_i(hwrite), .hwdata_i(hwdata),
        .hready_i(hready),
        .hresp_i(hresp_isram | hresp_rom | hresp_dsram | hresp_bridge |
                 u_soc.u_ahb.hresp_df),
        .viol_count_o(v_s));

    // -----------------------------------------------------------------------
    // Bus-activity observers. These are what turn "the test passed" into
    // "the test passed AND all three masters were actually on the bus".
    // A SoC test that quietly never granted the DMA would otherwise look
    // identical to one that did.
    // -----------------------------------------------------------------------
    integer n_grant_i, n_grant_d, n_grant_m;
    integer n_sel_isram, n_sel_rom, n_sel_dsram, n_sel_bridge, n_sel_default;
    integer n_concurrent;          // cycles with >=2 masters requesting
    integer max_dma_wait, dma_wait_run;

    always @(posedge hclk) begin
        if (!hreset_n) begin
            n_grant_i <= 0; n_grant_d <= 0; n_grant_m <= 0;
            n_sel_isram <= 0; n_sel_rom <= 0; n_sel_dsram <= 0;
            n_sel_bridge <= 0; n_sel_default <= 0;
            n_concurrent <= 0;
            max_dma_wait <= 0; dma_wait_run <= 0;
        end else begin
            if (hready && htrans[1]) begin
                case (u_soc.u_ahb.grant)
                    2'd0: n_grant_i <= n_grant_i + 1;
                    2'd1: n_grant_d <= n_grant_d + 1;
                    default: n_grant_m <= n_grant_m + 1;
                endcase
                if (hsel_isram)  n_sel_isram  <= n_sel_isram  + 1;
                if (hsel_rom)    n_sel_rom    <= n_sel_rom    + 1;
                if (hsel_dsram)  n_sel_dsram  <= n_sel_dsram  + 1;
                if (hsel_bridge) n_sel_bridge <= n_sel_bridge + 1;
                if (u_soc.u_ahb.hsel[4]) n_sel_default <= n_sel_default + 1;
            end

            if (({1'b0, u_soc.i_htrans[1]} + {1'b0, u_soc.d_htrans[1]} +
                 {1'b0, u_soc.m_htrans[1]}) > 2'd1)
                n_concurrent <= n_concurrent + 1;

            // Longest run of cycles where the DMA was asking and not granted.
            // This is the number that ERRATUM AHB-2 is about, measured on a
            // real instruction stream rather than on a BFM.
            if (u_soc.m_htrans[1] && (u_soc.u_ahb.grant != 2'd2)) begin
                dma_wait_run <= dma_wait_run + 1;
                if ((dma_wait_run + 1) > max_dma_wait)
                    max_dma_wait <= dma_wait_run + 1;
            end else begin
                dma_wait_run <= 0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Run
    // -----------------------------------------------------------------------
    localparam [31:0] TOHOST = 32'h2000_F000;

    integer cyc;
    reg [31:0] th;
    reg        done;
    integer    i;

    initial begin
        seed_run = 32'h1;
        verbose = $test$plusargs("VERBOSE");
        ahbchk_fatal = !$test$plusargs("NO_AHBCHK_FATAL");
        if (!$value$plusargs("MAXCYC=%d", maxcyc)) maxcyc = 400000;
        if (!$value$plusargs("IWAIT=%d",  iwait))  iwait  = 0;
        if (!$value$plusargs("DWAIT=%d",  dwait))  dwait  = 0;
        if (!$value$plusargs("RANDW=%d",  randw))  randw  = 0;
        if (!$value$plusargs("SEED=%d",   seed))   seed   = 1;
        if (!$value$plusargs("HEX=%s", hexfile))
            hexfile = "tb/soc/soc_dma_smoke.hex";

        iw = iwait[7:0];
        dw = dwait[7:0];
        rw = (randw != 0);
        seed_run = (seed == 0) ? 32'h1 : seed[31:0];

        dma_req = 6'b0;          // the smoke test is M2M: no peripheral handshake

        $display("=====================================================");
        $display("GARUDA SoC integration TB  (core + DSU + DMA + AHB)");
        $display("  hex=%0s  IWAIT=%0d DWAIT=%0d RANDW=%0d", hexfile, iwait, dwait, randw);
        $display("=====================================================");

        // Load the boot image into ROM before releasing reset.
        u_rom.bd_load_hex(hexfile);

        hreset_n = 1'b0;
        preset_n = 1'b0;
        repeat (10) @(posedge hclk);
        // Both resets released together. GARUDA-DMA-SPEC-001 Sec. 17.5 requires
        // this of Block 23; releasing pclk first could let a toggle raised in
        // pclk look like a spurious arm event when hclk leaves reset.
        @(negedge hclk);
        hreset_n = 1'b1;
        preset_n = 1'b1;

        // ---- reset-state checks (AHB spec Sec. 10) ----
        @(posedge hclk);
        chk_eq(htrans, 2'b00, "reset: slave-side HTRANS is IDLE");
        chk_eq(dma_irq, 6'b0,  "reset: no DMA completion interrupt");
        chk_eq(dma_err, 6'b0,  "reset: no DMA error interrupt");

        // ---- run until tohost is written ----
        done = 1'b0;
        for (cyc = 0; (cyc < maxcyc) && !done; cyc = cyc + 1) begin
            @(posedge hclk);
            th = u_dsram.bd_read(TOHOST);
            if (th != 32'h0) done = 1'b1;
        end

        $display("");
        if (!done) begin
            fails = fails + 1;
            checks = checks + 1;
            $display("[FAIL] TIMEOUT after %0d cycles - nothing written to tohost", maxcyc);
            $display("       last slave-side HADDR=0x%08h HTRANS=%b grant=%0d",
                     haddr, htrans, u_soc.u_ahb.grant);
        end else begin
            $display("tohost = 0x%08h after %0d cycles", th, cyc);
            chk_eq(th, 32'h1, "software verdict (1 = PASS; see soc_dma_smoke.S for codes)");
        end

        // ---- the DMA actually moved the data, checked independently of the
        //      CPU's own comparison, through the memory backdoor ----
        for (i = 0; i < 64; i = i + 1)
            chk_eq(u_dsram.bd_read(32'h2000_1000 + i*4), 32'h5A5A_0000 + i,
                   "DMA destination word (backdoor)");

        // ---- all three masters were genuinely on the bus ----
        $display("");
        $display("bus activity: grants I=%0d D=%0d DMA=%0d | selects ISRAM=%0d ROM=%0d DSRAM=%0d BRIDGE=%0d DEFAULT=%0d",
                 n_grant_i, n_grant_d, n_grant_m,
                 n_sel_isram, n_sel_rom, n_sel_dsram, n_sel_bridge, n_sel_default);
        $display("              cycles with >1 master requesting = %0d", n_concurrent);
        $display("              longest DMA request-to-grant wait = %0d hclk", max_dma_wait);

        chk(n_grant_i > 100, "I-Port fetched from the bus");
        chk(n_grant_d > 100, "D-Port did loads/stores on the bus");
        chk(n_grant_m > 100, "DMA moved beats on the bus");
        chk(n_sel_rom   > 100, "Boot ROM was selected (instruction fetch)");
        chk(n_sel_dsram > 100, "Data SRAM was selected (data + DMA)");
        chk(n_sel_bridge >  4, "Bridge was selected (DMA configuration)");
        chk_eq(n_sel_default, 0, "no access ever fell through to the default slave");
        chk(n_concurrent > 50, "masters genuinely contended for the bus");

        // ERRATUM AHB-2 measured on real traffic. The bound is loose on purpose
        // - the point is that it is BOUNDED, not that it is any given number.
        chk(max_dma_wait < 64,
            "DMA was never starved: request-to-grant stayed bounded");

        // ---- the real DSU executed (software already checked the value; this
        //      is the independent confirmation from the debug taps) ----
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
