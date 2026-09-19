`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 6: AHB-Lite Interconnect - block-level testbench
//
// Covers every row of GARUDA-AHB-SPEC-001 Rev 2.0 Sec. 12 (Verification Plan),
// plus four tests for failure modes the spec does not anticipate:
//
//   T12  DMA starvation under a continuously-requesting I-Port  (ERRATUM AHB-2)
//   T13  read data delivered to a master that was preempted mid-data-phase
//   T14  HWDATA follows the DATA-phase master, not the grant     (ERRATUM AHB-1)
//   T15  SEQ re-opened as NONSEQ after an interrupting transfer  (ERRATUM AHB-3)
//
// Structure
//   4 x ahb_lite_master_bfm   M0 = I-Port stand-in (INCR), M1 = D-Port,
//                             M2 = Debug SBA (u_ms, Rev 4.0), M3 = DMA (u_m2)
//   4 x ahb_lite_sram         S0 ISRAM, S1 ROM (read-only), S2 DSRAM, S3 Bridge
//   5 x ahb_lite_checker      one per master port + one on the shared slave bus
//
// The slave-side checker is the important one. Every master-side violation is
// a bug in a BFM or a master; a SLAVE-side violation is a bug in the fabric,
// and it is the only place where "the interconnect stitched two masters'
// transfers into one illegal stream" can be seen at all.
//
// Plusargs
//   +GWAIT=n   maximum slave wait states (0 = zero-wait)
//   +GRAND=1   randomise the wait count per access within 0..GWAIT
//   +SEED=n    PRNG seed for the soak test
//   +VERBOSE   print every check
// =============================================================================

module tb_ahb_interconnect;

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    reg hclk = 1'b0;
    reg hreset_n = 1'b0;
    always #2.5 hclk = ~hclk;            // 200 MHz

    // -----------------------------------------------------------------------
    // Scoreboard
    // -----------------------------------------------------------------------
    integer checks = 0;
    integer fails  = 0;
    integer verbose;

    task chk;
        input        cond;
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
        input [63:0] got;
        input [63:0] exp;
        input [1023:0] msg;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                fails = fails + 1;
                $display("[FAIL] %0s : got 0x%0h expected 0x%0h   (t=%0t)",
                         msg, got, exp, $time);
            end else if (verbose) begin
                $display("[ ok ] %0s = 0x%0h", msg, got);
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Bus timing configuration
    // -----------------------------------------------------------------------
    reg [7:0]  gwait;
    reg        grand;
    reg [31:0] seed;

    // Handed to every slave model so the BUS TIMING varies with the seed, not
    // just the stimulus. Without it a seed sweep re-runs one wait-state
    // pattern N times and reports N passes - see the seed_i note in
    // tb/ahb/ahb_lite_sram.v.
    reg [31:0] seed_run;

    // -----------------------------------------------------------------------
    // Master ports
    // -----------------------------------------------------------------------
    wire [31:0] m0_haddr, m1_haddr, m2_haddr;
    wire [1:0]  m0_htrans, m1_htrans, m2_htrans;
    wire        m0_hwrite, m1_hwrite, m2_hwrite;
    wire [2:0]  m0_hsize, m1_hsize, m2_hsize;
    wire [2:0]  m0_hburst, m1_hburst, m2_hburst;
    wire [3:0]  m0_hprot, m1_hprot, m2_hprot;
    wire [31:0] m0_hwdata, m1_hwdata, m2_hwdata;
    wire [31:0] m0_hrdata, m1_hrdata, m2_hrdata;
    wire        m0_hready, m1_hready, m2_hready;
    wire        m0_hresp,  m1_hresp,  m2_hresp;

    // M0 stands in for the CPU I-Port: HPROT = 4'b0010 (opcode, privileged),
    // matching garuda_iport_ahb_master.v exactly.
    ahb_lite_master_bfm #(.HPROT(4'b0010)) u_m0 (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .haddr_o(m0_haddr), .htrans_o(m0_htrans), .hwrite_o(m0_hwrite),
        .hsize_o(m0_hsize), .hburst_o(m0_hburst), .hprot_o(m0_hprot),
        .hwdata_o(m0_hwdata),
        .hrdata_i(m0_hrdata), .hready_i(m0_hready), .hresp_i(m0_hresp)
    );

    // M1 stands in for the CPU D-Port: HPROT = 4'b0011 (data, privileged).
    ahb_lite_master_bfm #(.HPROT(4'b0011)) u_m1 (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .haddr_o(m1_haddr), .htrans_o(m1_htrans), .hwrite_o(m1_hwrite),
        .hsize_o(m1_hsize), .hburst_o(m1_hburst), .hprot_o(m1_hprot),
        .hwdata_o(m1_hwdata),
        .hrdata_i(m1_hrdata), .hready_i(m1_hready), .hresp_i(m1_hresp)
    );

    // M2 stands in for the DMA. Its HPROT output is NOT connected to the
    // interconnect (the DMA boundary has no HPROT port); the interconnect must
    // substitute 4'b0011 itself - checked in T10.
    ahb_lite_master_bfm #(.HPROT(4'b1111)) u_m2 (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .haddr_o(m2_haddr), .htrans_o(m2_htrans), .hwrite_o(m2_hwrite),
        .hsize_o(m2_hsize), .hburst_o(m2_hburst), .hprot_o(m2_hprot),
        .hwdata_o(m2_hwdata),
        .hrdata_i(m2_hrdata), .hready_i(m2_hready), .hresp_i(m2_hresp)
    );

    // Debug SBA (Rev 4.0 master M2). Like the DMA it has no HPROT at the
    // interconnect boundary. Named u_ms so the DMA keeps its historical u_m2.
    wire [31:0] ms_haddr, ms_hwdata, ms_hrdata;
    wire [1:0]  ms_htrans;
    wire        ms_hwrite, ms_hready, ms_hresp;
    wire [2:0]  ms_hsize, ms_hburst;
    wire [3:0]  ms_hprot;
    wire        is_sba;
    ahb_lite_master_bfm #(.HPROT(4'b1111)) u_ms (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .haddr_o(ms_haddr), .htrans_o(ms_htrans), .hwrite_o(ms_hwrite),
        .hsize_o(ms_hsize), .hburst_o(ms_hburst), .hprot_o(ms_hprot),
        .hwdata_o(ms_hwdata),
        .hrdata_i(ms_hrdata), .hready_i(ms_hready), .hresp_i(ms_hresp)
    );

    // -----------------------------------------------------------------------
    // Slave side
    // -----------------------------------------------------------------------
    wire        hsel_s0, hsel_s1, hsel_s2, hsel_s3;
    wire [31:0] haddr_s;
    wire [1:0]  htrans_s;
    wire        hwrite_s;
    wire [2:0]  hsize_s, hburst_s;
    wire [3:0]  hprot_s;
    wire [31:0] hwdata_s;
    wire        hready_s;

    wire [31:0] hrdata_s0, hrdata_s1, hrdata_s2, hrdata_s3;
    wire        hreadyout_s0, hreadyout_s1, hreadyout_s2, hreadyout_s3;
    wire        hresp_s0, hresp_s1, hresp_s2, hresp_s3;

    reg        err_en;
    reg [31:0] err_base, err_size;

    ahb_lite_sram #(.BASE_ADDR(32'h0000_0000), .SIZE_BYTES(65536),
                    .READ_ONLY(0), .SEED(32'h1357_9BDF)) u_s0 (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .waits_i(gwait), .rand_waits_i(grand), .seed_i(seed_run),
        .err_en_i(err_en), .err_base_i(err_base), .err_size_i(err_size),
        .hsel_i(hsel_s0), .haddr_i(haddr_s), .htrans_i(htrans_s),
        .hwrite_i(hwrite_s), .hsize_i(hsize_s), .hwdata_i(hwdata_s),
        .hready_i(hready_s),
        .hrdata_o(hrdata_s0), .hreadyout_o(hreadyout_s0), .hresp_o(hresp_s0)
    );

    ahb_lite_sram #(.BASE_ADDR(32'h1000_0000), .SIZE_BYTES(4096),
                    .READ_ONLY(1), .SEED(32'h2468_ACE0)) u_s1 (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .waits_i(gwait), .rand_waits_i(grand), .seed_i(seed_run),
        .err_en_i(err_en), .err_base_i(err_base), .err_size_i(err_size),
        .hsel_i(hsel_s1), .haddr_i(haddr_s), .htrans_i(htrans_s),
        .hwrite_i(hwrite_s), .hsize_i(hsize_s), .hwdata_i(hwdata_s),
        .hready_i(hready_s),
        .hrdata_o(hrdata_s1), .hreadyout_o(hreadyout_s1), .hresp_o(hresp_s1)
    );

    ahb_lite_sram #(.BASE_ADDR(32'h2000_0000), .SIZE_BYTES(65536),
                    .READ_ONLY(0), .SEED(32'h0F1E_2D3C)) u_s2 (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .waits_i(gwait), .rand_waits_i(grand), .seed_i(seed_run),
        .err_en_i(err_en), .err_base_i(err_base), .err_size_i(err_size),
        .hsel_i(hsel_s2), .haddr_i(haddr_s), .htrans_i(htrans_s),
        .hwrite_i(hwrite_s), .hsize_i(hsize_s), .hwdata_i(hwdata_s),
        .hready_i(hready_s),
        .hrdata_o(hrdata_s2), .hreadyout_o(hreadyout_s2), .hresp_o(hresp_s2)
    );

    // S3 stands in for the AHB-to-APB bridge (Block 8). A plain memory is the
    // right stand-in HERE because this testbench verifies the interconnect,
    // not the bridge: all the fabric cares about is that region 0x4 decodes to
    // a fourth slave that obeys HREADY and the two-cycle ERROR.
    ahb_lite_sram #(.BASE_ADDR(32'h4000_0000), .SIZE_BYTES(65536),
                    .READ_ONLY(0), .SEED(32'h5A5A_3C3C)) u_s3 (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .waits_i(gwait), .rand_waits_i(grand), .seed_i(seed_run),
        .err_en_i(err_en), .err_base_i(err_base), .err_size_i(err_size),
        .hsel_i(hsel_s3), .haddr_i(haddr_s), .htrans_i(htrans_s),
        .hwrite_i(hwrite_s), .hsize_i(hsize_s), .hwdata_i(hwdata_s),
        .hready_i(hready_s),
        .hrdata_o(hrdata_s3), .hreadyout_o(hreadyout_s3), .hresp_o(hresp_s3)
    );

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    ahb_interconnect u_ic (
        .hclk_i(hclk), .hreset_n_i(hreset_n),

        .i_haddr_i(m0_haddr), .i_htrans_i(m0_htrans), .i_hwrite_i(m0_hwrite),
        .i_hsize_i(m0_hsize), .i_hburst_i(m0_hburst), .i_hprot_i(m0_hprot),
        .i_hwdata_i(m0_hwdata),
        .i_hrdata_o(m0_hrdata), .i_hready_o(m0_hready), .i_hresp_o(m0_hresp),

        .d_haddr_i(m1_haddr), .d_htrans_i(m1_htrans), .d_hwrite_i(m1_hwrite),
        .d_hsize_i(m1_hsize), .d_hburst_i(m1_hburst), .d_hprot_i(m1_hprot),
        .d_hwdata_i(m1_hwdata),
        .d_hrdata_o(m1_hrdata), .d_hready_o(m1_hready), .d_hresp_o(m1_hresp),

        .s_haddr_i(ms_haddr), .s_htrans_i(ms_htrans), .s_hwrite_i(ms_hwrite),
        .s_hsize_i(ms_hsize), .s_hburst_i(ms_hburst),
        .s_hwdata_i(ms_hwdata),
        .s_hrdata_o(ms_hrdata), .s_hready_o(ms_hready), .s_hresp_o(ms_hresp),

        .m_haddr_i(m2_haddr), .m_htrans_i(m2_htrans), .m_hwrite_i(m2_hwrite),
        .m_hsize_i(m2_hsize), .m_hburst_i(m2_hburst),
        .m_hwdata_i(m2_hwdata),
        .m_hrdata_o(m2_hrdata), .m_hready_o(m2_hready), .m_hresp_o(m2_hresp),

        .hsel_isram_o(hsel_s0), .hsel_rom_o(hsel_s1),
        .hsel_dsram_o(hsel_s2), .hsel_bridge_o(hsel_s3),

        .haddr_o(haddr_s), .htrans_o(htrans_s), .hwrite_o(hwrite_s),
        .hsize_o(hsize_s), .hburst_o(hburst_s), .hprot_o(hprot_s),
        .hwdata_o(hwdata_s), .hready_o(hready_s), .hmaster_is_sba_o(is_sba),

        .hrdata_isram_i(hrdata_s0),  .hreadyout_isram_i(hreadyout_s0),  .hresp_isram_i(hresp_s0),
        .hrdata_rom_i(hrdata_s1),    .hreadyout_rom_i(hreadyout_s1),    .hresp_rom_i(hresp_s1),
        .hrdata_dsram_i(hrdata_s2),  .hreadyout_dsram_i(hreadyout_s2),  .hresp_dsram_i(hresp_s2),
        .hrdata_bridge_i(hrdata_s3), .hreadyout_bridge_i(hreadyout_s3), .hresp_bridge_i(hresp_s3)
    );

    // -----------------------------------------------------------------------
    // Protocol checkers
    // -----------------------------------------------------------------------
    wire [31:0] v_m0, v_m1, v_m2, v_ms, v_sl;

    ahb_lite_checker u_chk_ms (
        .clk_i(hclk), .rst_n_i(hreset_n),
        .haddr_i(ms_haddr), .htrans_i(ms_htrans), .hsize_i(ms_hsize),
        .hburst_i(ms_hburst), .hwrite_i(ms_hwrite), .hwdata_i(ms_hwdata),
        .hready_i(ms_hready), .hresp_i(ms_hresp), .viol_count_o(v_ms));

    ahb_lite_checker u_chk_m0 (
        .clk_i(hclk), .rst_n_i(hreset_n),
        .haddr_i(m0_haddr), .htrans_i(m0_htrans), .hsize_i(m0_hsize),
        .hburst_i(m0_hburst), .hwrite_i(m0_hwrite), .hwdata_i(m0_hwdata),
        .hready_i(m0_hready), .hresp_i(m0_hresp), .viol_count_o(v_m0));

    ahb_lite_checker u_chk_m1 (
        .clk_i(hclk), .rst_n_i(hreset_n),
        .haddr_i(m1_haddr), .htrans_i(m1_htrans), .hsize_i(m1_hsize),
        .hburst_i(m1_hburst), .hwrite_i(m1_hwrite), .hwdata_i(m1_hwdata),
        .hready_i(m1_hready), .hresp_i(m1_hresp), .viol_count_o(v_m1));

    ahb_lite_checker u_chk_m2 (
        .clk_i(hclk), .rst_n_i(hreset_n),
        .haddr_i(m2_haddr), .htrans_i(m2_htrans), .hsize_i(m2_hsize),
        .hburst_i(m2_hburst), .hwrite_i(m2_hwrite), .hwdata_i(m2_hwdata),
        .hready_i(m2_hready), .hresp_i(m2_hresp), .viol_count_o(v_m2));

    // The one that matters: the stream the SLAVES actually see.
    ahb_lite_checker u_chk_sl (
        .clk_i(hclk), .rst_n_i(hreset_n),
        .haddr_i(haddr_s), .htrans_i(htrans_s), .hsize_i(hsize_s),
        .hburst_i(hburst_s), .hwrite_i(hwrite_s), .hwdata_i(hwdata_s),
        .hready_i(hready_s), .hresp_i(hresp_s0 | hresp_s1 | hresp_s2 | hresp_s3 |
                                     u_ic.hresp_df),
        .viol_count_o(v_sl));

    // -----------------------------------------------------------------------
    // Convenience
    // -----------------------------------------------------------------------
    localparam [2:0] SZ_B = 3'b000, SZ_H = 3'b001, SZ_W = 3'b010;
    localparam [2:0] BURST_SINGLE = 3'b000, BURST_INCR = 3'b001;
    localparam [1:0] T_IDLE = 2'b00, T_NONSEQ = 2'b10, T_SEQ = 2'b11;

    task hwait; input integer n; integer q; begin
        for (q = 0; q < n; q = q + 1) @(posedge hclk);
    end endtask

    // Wait until every master's queue has drained and no transfer is in flight.
    task drain;
        integer guard;
        begin
            guard = 0;
            while (((u_m0.q_head !== u_m0.q_tail) || u_m0.addr_outstanding || u_m0.data_outstanding ||
                    (u_m1.q_head !== u_m1.q_tail) || u_m1.addr_outstanding || u_m1.data_outstanding ||
                    (u_m2.q_head !== u_m2.q_tail) || u_m2.addr_outstanding || u_m2.data_outstanding ||
                    (u_ms.q_head !== u_ms.q_tail) || u_ms.addr_outstanding || u_ms.data_outstanding)
                   && (guard < 20000)) begin
                @(posedge hclk);
                guard = guard + 1;
            end
            if (guard >= 20000) begin
                fails = fails + 1;
                $display("[FAIL] drain() timed out - the bus is hung (t=%0t)", $time);
            end
            hwait(3);
        end
    endtask

    task clear_rsp; begin
        u_m0.r_head = 0; u_m0.r_tail = 0;
        u_m1.r_head = 0; u_m1.r_tail = 0;
        u_m2.r_head = 0; u_m2.r_tail = 0;
        u_ms.r_head = 0; u_ms.r_tail = 0;
    end endtask

    function integer n_rsp0; begin n_rsp0 = (u_m0.r_tail - u_m0.r_head + 256) % 256; end endfunction
    function integer n_rsp1; begin n_rsp1 = (u_m1.r_tail - u_m1.r_head + 256) % 256; end endfunction
    function integer n_rsp2; begin n_rsp2 = (u_m2.r_tail - u_m2.r_head + 256) % 256; end endfunction

    // -----------------------------------------------------------------------
    // xorshift PRNG (never $random - see TOOL-4 in docs/DMA_RTL_LOG.md)
    // -----------------------------------------------------------------------
    reg [31:0] rng;
    function [31:0] rnd;
        input dummy;
        begin
            rng  = rng ^ (rng << 13);
            rng  = rng ^ (rng >> 17);
            rng  = rng ^ (rng << 5);
            rnd  = rng;
        end
    endfunction

    // -----------------------------------------------------------------------
    // Observers used by the directed tests
    // -----------------------------------------------------------------------
    integer sel_onehot_viol;          // T2 : HSEL must be one-hot every cycle
    integer grant_swing_viol;         // T5 : grant must not move while HREADY low
    integer hprot_dma_viol;           // T10: HPROT must be 0x3 whenever DMA granted
    integer sba_ind_viol = 0;         // T17: hmaster_is_sba tracks the grant
    always @(posedge hclk) if (hreset_n && (is_sba !== (u_ic.grant == 2'd2))) sba_ind_viol = sba_ind_viol + 1;
    reg [1:0] prev_grant;
    reg       prev_hready;

    wire [4:0] sel_bus = {u_ic.hsel[4], hsel_s3, hsel_s2, hsel_s1, hsel_s0};

    always @(posedge hclk) begin
        if (!hreset_n) begin
            sel_onehot_viol  <= 0;
            grant_swing_viol <= 0;
            hprot_dma_viol   <= 0;
            prev_grant       <= 2'd0;
            prev_hready      <= 1'b1;
        end else begin
            // Sec. 6: decode is one-hot and mutually exclusive, ALWAYS.
            if (sel_bus != 5'b00001 && sel_bus != 5'b00010 && sel_bus != 5'b00100 &&
                sel_bus != 5'b01000 && sel_bus != 5'b10000)
                sel_onehot_viol <= sel_onehot_viol + 1;

            // Sec. 7.2: grant_r stable through a beat, no mid-beat swing.
            if (!prev_hready && (u_ic.grant !== prev_grant))
                grant_swing_viol <= grant_swing_viol + 1;

            // Sec. 7.6: DMA has no HPROT; the fabric substitutes 0x3.
            if ((u_ic.grant == 2'd3) && (hprot_s !== 4'b0011))
                hprot_dma_viol <= hprot_dma_viol + 1;

            prev_grant  <= u_ic.grant;
            prev_hready <= hready_s;
        end
    end

    // -----------------------------------------------------------------------
    // Test body
    // -----------------------------------------------------------------------
    integer i, j;
    integer b0, b1, b2;
    integer first_m2_cycle;
    integer saw_all3;
    integer boundaries, m2_boundary;
    reg [31:0] tmp;

    initial begin
        seed_run = 32'h1;
        verbose  = $test$plusargs("VERBOSE");
        if (!$value$plusargs("GWAIT=%d", gwait)) gwait = 8'd0;
        if (!$value$plusargs("GRAND=%d", grand)) grand = 1'b0;
        if (!$value$plusargs("SEED=%d",  seed))  seed  = 32'd1;
        rng      = (seed == 0) ? 32'h1 : seed;
        seed_run = (seed == 0) ? 32'h1 : seed;

        err_en   = 1'b0;
        err_base = 32'h0;
        err_size = 32'h0;

        $display("=====================================================");
        $display("AHB-Lite interconnect TB   GWAIT=%0d GRAND=%0d SEED=%0d",
                 gwait, grand, seed);
        $display("=====================================================");

        // ===================================================================
        // T0 - reset behaviour (Sec. 10)
        // ===================================================================
        $display("--- T0: reset state ---");
        hreset_n = 1'b0;
        hwait(5);
        chk_eq(htrans_s, T_IDLE,  "reset: slave-side HTRANS is IDLE");
        chk_eq(hready_s, 1'b1,    "reset: shared HREADY is high (bus usable)");
        chk_eq(u_ic.dph_valid, 1'b0, "reset: no data phase in flight");
        @(negedge hclk);
        hreset_n = 1'b1;
        hwait(3);
        chk_eq(hready_s, 1'b1, "post-reset: shared HREADY high before any transfer");

        // Preload known patterns through the backdoor. The tag encodes which
        // slave the word came from and the low half encodes its word index, so
        // any check can say both "right slave" and "right address" at once -
        // which is what catches a read-data mux that returns the correct slave
        // but the previous cycle's word.
        //
        // 3072 words covers every address these tests touch; the ROM is only
        // 4 KB (1024 words) so it gets its own bound.
        for (i = 0; i < 3072; i = i + 1) begin
            u_s0.bd_write(32'h0000_0000 + i*4, 32'hA000_0000 + i);
            u_s2.bd_write(32'h2000_0000 + i*4, 32'hC000_0000 + i);
            u_s3.bd_write(32'h4000_0000 + i*4, 32'hD000_0000 + i);
            if (i < 1024)
                u_s1.bd_write(32'h1000_0000 + i*4, 32'hB000_0000 + i);
        end

        // ===================================================================
        // T1 - decode: one transfer to every region, from every master
        // ===================================================================
        $display("--- T1: address decode, all four regions ---");
        clear_rsp();
        u_m1.push_xfer(32'h0000_0010, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd2);
        u_m1.push_xfer(32'h1000_0010, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd2);
        u_m1.push_xfer(32'h2000_0010, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd2);
        u_m1.push_xfer(32'h4000_0010, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd2);
        drain();
        chk_eq(n_rsp1(), 4, "T1: four responses returned");
        chk_eq(u_m1.r_data[0], 32'hA000_0004, "T1: ISRAM  read data");
        chk_eq(u_m1.r_data[1], 32'hB000_0004, "T1: ROM    read data");
        chk_eq(u_m1.r_data[2], 32'hC000_0004, "T1: DSRAM  read data");
        chk_eq(u_m1.r_data[3], 32'hD000_0004, "T1: BRIDGE read data");
        chk_eq(u_m1.r_resp[0] | u_m1.r_resp[1] | u_m1.r_resp[2] | u_m1.r_resp[3], 1'b0,
               "T1: all four responses OKAY");

        // Region boundary addresses: base and base+size-4 of each slave.
        $display("--- T1b: region boundary addresses ---");
        clear_rsp();
        u_s0.bd_write(32'h0000_0000, 32'h1111_0000);
        u_s0.bd_write(32'h0000_FFFC, 32'h1111_FFFC);
        u_s2.bd_write(32'h2000_0000, 32'h3333_0000);
        u_s2.bd_write(32'h2000_FFFC, 32'h3333_FFFC);
        u_m1.push_xfer(32'h0000_0000, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd1);
        u_m1.push_xfer(32'h0000_FFFC, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd1);
        u_m1.push_xfer(32'h2000_0000, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd1);
        u_m1.push_xfer(32'h2000_FFFC, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd1);
        drain();
        chk_eq(u_m1.r_data[0], 32'h1111_0000, "T1b: ISRAM base");
        chk_eq(u_m1.r_data[1], 32'h1111_FFFC, "T1b: ISRAM base+size-4");
        chk_eq(u_m1.r_data[2], 32'h3333_0000, "T1b: DSRAM base");
        chk_eq(u_m1.r_data[3], 32'h3333_FFFC, "T1b: DSRAM base+size-4");

        // ===================================================================
        // T2 - HSEL one-hot, no aliasing (checked continuously, reported here)
        // ===================================================================
        $display("--- T2: HSEL one-hot for every address ---");
        chk_eq(sel_onehot_viol, 0, "T2: HSEL was one-hot on every cycle so far");

        // ===================================================================
        // T3 - default slave: unmapped address gives a two-cycle ERROR
        // ===================================================================
        $display("--- T3: default slave, unmapped address ---");
        clear_rsp();
        u_m1.push_xfer(32'h8000_0000, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd3);
        u_m1.push_xfer(32'h3000_0000, 1'b1, 32'hDEAD_BEEF, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd3);
        u_m1.push_xfer(32'h2000_0020, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd3);
        drain();
        chk_eq(n_rsp1(), 3, "T3: three responses");
        chk_eq(u_m1.r_resp[0], 1'b1, "T3: unmapped read  -> ERROR");
        chk_eq(u_m1.r_resp[1], 1'b1, "T3: unmapped write -> ERROR");
        chk_eq(u_m1.r_resp[2], 1'b0, "T3: the mapped access after it is OKAY");
        chk_eq(u_m1.r_data[2], 32'hC000_0008, "T3: bus recovered, correct data");
        chk_eq(u_chk_m1.v_err_single, 0, "T3: no one-cycle ERROR seen by the master");

        // Back-to-back faults (a runaway PC walking unmapped space).
        $display("--- T3b: back-to-back unmapped accesses ---");
        clear_rsp();
        for (i = 0; i < 4; i = i + 1)
            u_m1.push_xfer(32'h9000_0000 + i*4, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        drain();
        chk_eq(n_rsp1(), 4, "T3b: all four faulting accesses retired (no hang)");
        chk_eq(u_m1.r_resp[0] & u_m1.r_resp[1] & u_m1.r_resp[2] & u_m1.r_resp[3], 1'b1,
               "T3b: every one returned ERROR");

        // ===================================================================
        // T4 - arbitration priority, all master combinations
        // ===================================================================
        $display("--- T4: priority DMA > D-Port > I-Port ---");
        clear_rsp();
        // Line all three up so their address phases collide.
        u_m0.push_xfer(32'h0000_0100, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd200);
        u_m1.push_xfer(32'h2000_0100, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd200);
        u_m2.push_xfer(32'h4000_0100, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd200);
        // The three queues were filled in the same delta, so all three BFMs
        // present their address phase on the same cycle. Sampling starts NOW,
        // before that cycle - waiting for "all three requesting" first and only
        // then starting to look would miss the DMA's acceptance, which happens
        // in that very cycle.
        //
        // gap=200 on each command means each master does exactly one transfer
        // inside this window, so "first accepted cycle" is unambiguous.
        b0 = -1; b1 = -1; b2 = -1;
        saw_all3 = 0;
        for (i = 0; i < 80; i = i + 1) begin
            @(posedge hclk);
            if (m0_htrans[1] && m1_htrans[1] && m2_htrans[1]) saw_all3 = 1;
            if (hready_s && htrans_s[1]) begin
                if (u_ic.grant == 2'd3 && b2 < 0) b2 = i;
                if (u_ic.grant == 2'd1 && b1 < 0) b1 = i;
                if (u_ic.grant == 2'd0 && b0 < 0) b0 = i;
            end
        end
        chk(saw_all3, "T4: precondition - all three masters requested together");
        chk((b2 >= 0) && (b1 > b2) && (b0 > b1),
            "T4: accepted in priority order DMA, then D-Port, then I-Port");
        if (verbose || !((b2 >= 0) && (b1 > b2) && (b0 > b1)))
            $display("       first accepted cycle: DMA=%0d D-Port=%0d I-Port=%0d",
                     b2, b1, b0);
        drain();
        chk_eq(u_m2.r_data[0], 32'hD000_0040, "T4: DMA   got its own read data");
        chk_eq(u_m1.r_data[0], 32'hC000_0040, "T4: D-Port got its own read data");
        chk_eq(u_m0.r_data[0], 32'hA000_0040, "T4: I-Port got its own read data");

        // ===================================================================
        // T5 - per-master hold: ungranted masters frozen, grant stable
        // ===================================================================
        $display("--- T5: per-master hold rule ---");
        chk_eq(grant_swing_viol, 0, "T5: grant never moved while HREADY was low");
        // During T4 the I-Port was held for many cycles with a live NONSEQ.
        // The master-side checker proves its HADDR/control never moved.
        chk_eq(u_chk_m0.v_addr_change,  0, "T5: I-Port HADDR stable while held");
        chk_eq(u_chk_m0.v_ctrl_change,  0, "T5: I-Port control stable while held");
        chk_eq(u_chk_m0.v_trans_change, 0, "T5: I-Port HTRANS stable while held");
        chk_eq(u_chk_m0.v_retract,      0, "T5: I-Port never retracted a transfer");

        // ===================================================================
        // T6 - data-phase select: back-to-back transfers to DIFFERENT slaves
        // ===================================================================
        $display("--- T6: data-phase slave select ---");
        clear_rsp();
        for (i = 0; i < 8; i = i + 1) begin
            u_m1.push_xfer(32'h0000_0200 + i*4, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
            u_m1.push_xfer(32'h2000_0200 + i*4, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
            u_m1.push_xfer(32'h4000_0200 + i*4, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
            u_m1.push_xfer(32'h1000_0200 + i*4, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        end
        drain();
        chk_eq(n_rsp1(), 32, "T6: 32 interleaved-slave responses");
        for (i = 0; i < 8; i = i + 1) begin
            chk_eq(u_m1.r_data[i*4+0], 32'hA000_0080 + i, "T6: ISRAM  in an alternating stream");
            chk_eq(u_m1.r_data[i*4+1], 32'hC000_0080 + i, "T6: DSRAM  in an alternating stream");
            chk_eq(u_m1.r_data[i*4+2], 32'hD000_0080 + i, "T6: BRIDGE in an alternating stream");
            chk_eq(u_m1.r_data[i*4+3], 32'hB000_0080 + i, "T6: ROM    in an alternating stream");
        end

        // ===================================================================
        // T7 - writes, byte enables, and read-back
        // ===================================================================
        $display("--- T7: writes and byte lanes ---");
        clear_rsp();
        u_m1.push_xfer(32'h2000_1000, 1'b1, 32'h0000_0000, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        u_m1.push_xfer(32'h2000_1000, 1'b1, 32'h0000_00AA, SZ_B, BURST_SINGLE, T_NONSEQ, 8'd0);
        u_m1.push_xfer(32'h2000_1001, 1'b1, 32'h0000_BB00, SZ_B, BURST_SINGLE, T_NONSEQ, 8'd0);
        u_m1.push_xfer(32'h2000_1002, 1'b1, 32'hDDCC_0000, SZ_H, BURST_SINGLE, T_NONSEQ, 8'd0);
        u_m1.push_xfer(32'h2000_1000, 1'b0, 32'h0,         SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        drain();
        chk_eq(u_m1.r_data[n_rsp1()-1], 32'hDDCC_BBAA, "T7: byte/half writes merged correctly");
        // ROM must ignore writes but still answer OKAY.
        clear_rsp();
        u_m1.push_xfer(32'h1000_0040, 1'b1, 32'hFFFF_FFFF, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        u_m1.push_xfer(32'h1000_0040, 1'b0, 32'h0,         SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        drain();
        chk_eq(u_m1.r_resp[0], 1'b0,          "T7: write to ROM answers OKAY");
        chk_eq(u_m1.r_data[1], 32'hB000_0010, "T7: write to ROM did not change it");

        // ===================================================================
        // T8 - wait states, transparent to the master
        // ===================================================================
        $display("--- T8: slave wait states ---");
        clear_rsp();
        for (i = 0; i < 16; i = i + 1)
            u_m1.push_xfer(32'h2000_0300 + i*4, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        drain();
        chk_eq(n_rsp1(), 16, "T8: every transfer completed under wait states");
        for (i = 0; i < 16; i = i + 1)
            chk_eq(u_m1.r_data[i], 32'hC000_00C0 + i, "T8: data correct under wait states");

        // ===================================================================
        // T9 - two-cycle ERROR from a mapped slave, mid-stream
        // ===================================================================
        $display("--- T9: injected two-cycle ERROR ---");
        err_en   = 1'b1;
        err_base = 32'h2000_0400;
        err_size = 32'h0000_0004;
        clear_rsp();
        u_m1.push_xfer(32'h2000_03FC, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        u_m1.push_xfer(32'h2000_0400, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        u_m1.push_xfer(32'h2000_0404, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        drain();
        err_en = 1'b0;
        chk_eq(u_m1.r_resp[0], 1'b0, "T9: transfer before the error is OKAY");
        chk_eq(u_m1.r_resp[1], 1'b1, "T9: the faulting transfer returns ERROR");
        chk_eq(u_m1.r_resp[2], 1'b0, "T9: the transfer after it is OKAY");
        chk_eq(u_chk_m1.v_err_single, 0, "T9: the master saw a compliant two-cycle ERROR");
        chk_eq(u_chk_sl.v_err_single, 0, "T9: the slave bus carried a two-cycle ERROR");

        // An ERROR to one master must not reach another master that happens to
        // have an address phase accepted in the same cycle.
        $display("--- T9b: ERROR is not broadcast ---");
        err_en   = 1'b1;
        err_base = 32'h0000_0500;
        err_size = 32'h0000_0004;
        clear_rsp();
        u_m0.push_xfer(32'h0000_0500, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        u_m1.push_xfer(32'h2000_0500, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        u_m2.push_xfer(32'h4000_0500, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        drain();
        err_en = 1'b0;
        chk_eq(u_m0.r_resp[0], 1'b1, "T9b: only the I-Port's faulting access errors");
        chk_eq(u_m1.r_resp[0], 1'b0, "T9b: D-Port response stays OKAY");
        chk_eq(u_m2.r_resp[0], 1'b0, "T9b: DMA response stays OKAY");

        // ===================================================================
        // T10 - HPROT pass-through and the DMA substitution (Sec. 7.6)
        // ===================================================================
        $display("--- T10: HPROT ---");
        chk_eq(hprot_dma_viol, 0, "T10: HPROT was 0x3 on every DMA-granted cycle");
        clear_rsp();
        u_m0.push_xfer(32'h0000_0600, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        @(posedge hclk);
        while (!(hready_s && htrans_s[1] && u_ic.grant == 2'd0)) @(posedge hclk);
        chk_eq(hprot_s, 4'b0010, "T10: I-Port HPROT reaches the slave unchanged");
        drain();

        // ===================================================================
        // T11 - I-Port INCR burst, uninterrupted
        // ===================================================================
        $display("--- T11: uninterrupted INCR burst ---");
        clear_rsp();
        u_m0.push_xfer(32'h0000_0700, 1'b0, 32'h0, SZ_W, BURST_INCR, T_NONSEQ, 8'd0);
        for (i = 1; i < 8; i = i + 1)
            u_m0.push_xfer(32'h0000_0700 + i*4, 1'b0, 32'h0, SZ_W, BURST_INCR, T_SEQ, 8'd0);
        drain();
        chk_eq(n_rsp0(), 8, "T11: eight-beat INCR completed");
        for (i = 0; i < 8; i = i + 1)
            chk_eq(u_m0.r_data[i], 32'hA000_01C0 + i, "T11: INCR beat data in order");
        chk_eq(u_chk_sl.v_seq_no_burst,   0, "T11: no orphan SEQ on the slave bus");
        chk_eq(u_chk_sl.v_seq_after_idle, 0, "T11: no SEQ after IDLE on the slave bus");

        // ===================================================================
        // T12 - *** ERRATUM AHB-2 *** DMA must not be starved by the I-Port
        // ===================================================================
        $display("--- T12: DMA preemption vs a continuously-requesting I-Port ---");
        clear_rsp();
        // 64 back-to-back I-Port beats: gap 0 everywhere means the BFM presents
        // a new address phase on EVERY cycle, which is exactly what
        // garuda_iport_ahb_master does on straight-line code at 1 IPC.
        u_m0.push_xfer(32'h0000_0800, 1'b0, 32'h0, SZ_W, BURST_INCR, T_NONSEQ, 8'd0);
        for (i = 1; i < 64; i = i + 1)
            u_m0.push_xfer(32'h0000_0800 + i*4, 1'b0, 32'h0, SZ_W, BURST_INCR, T_SEQ, 8'd0);
        // Let the I-Port get properly into its stride, then ask for the bus.
        hwait(12);
        chk(m0_htrans[1], "T12: precondition - I-Port is requesting continuously");
        //
        // The property asserted is deliberately counted in ARBITRATION
        // BOUNDARIES, not in cycles. A cycle bound would really be a statement
        // about the slave's wait states: while HREADY is low the bus is
        // genuinely busy and the grant is frozen, so at GWAIT=10 a perfectly
        // healthy arbiter can take 14 cycles. Counting accepted address phases
        // instead makes the check wait-state independent and says the thing
        // that actually matters:
        //
        //     at most TWO transfers may be accepted between the DMA raising
        //     HTRANS and the DMA being granted
        //
        // Two, not one, because the boundary where the DMA's request first
        // appears may already be frozen by hold_r onto the incumbent - so the
        // incumbent gets that one, and the DMA takes the next. Under the
        // deleted force_owner rule this number is unbounded.
        first_m2_cycle  = -1;
        boundaries      = 0;
        m2_boundary     = -1;
        u_m2.push_xfer(32'h2000_0800, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        for (i = 0; i < 400; i = i + 1) begin
            @(posedge hclk);
            if (hready_s && htrans_s[1]) begin
                if (u_ic.grant == 2'd3) begin
                    if (m2_boundary < 0) begin
                        m2_boundary    = boundaries;
                        first_m2_cycle = i;
                    end
                end else if (m2_boundary < 0) begin
                    boundaries = boundaries + 1;
                end
            end
        end
        chk(m2_boundary >= 0 && m2_boundary <= 2,
            "T12: DMA granted within 2 arbitration boundaries of asking");
        if (m2_boundary < 0)
            $display("       DMA NEVER granted in 400 cycles - the I-Port starved it");
        else if (verbose)
            $display("       DMA granted after %0d other transfers, %0d cycles",
                     m2_boundary, first_m2_cycle);
        drain();

        // ===================================================================
        // T13 - *** ERRATUM AHB-2 *** the preempted master keeps its data
        // ===================================================================
        $display("--- T13: response hold across a preemption ---");
        chk_eq(n_rsp0(), 64, "T13: every I-Port beat retired despite preemption");
        for (i = 0; i < 64; i = i + 1)
            chk_eq(u_m0.r_data[i], 32'hA000_0200 + i,
                   "T13: preempted I-Port beat returned its OWN data, in order");
        chk_eq(u_m2.r_data[0], 32'hC000_0200, "T13: DMA read its own data");
        chk_eq(u_chk_m0.v_addr_change, 0, "T13: I-Port address stable across the steal");

        // ===================================================================
        // T14 - *** ERRATUM AHB-1 *** HWDATA follows the DATA-phase master
        // ===================================================================
        $display("--- T14: HWDATA is a data-phase signal ---");
        clear_rsp();
        // The DMA writes a sentinel; the I-Port hammers the bus with reads so
        // that the grant is handed away in the DMA's write DATA phase. If
        // HWDATA followed the grant, the I-Port's HWDATA (zero) would land in
        // DSRAM instead of the sentinel.
        u_s2.bd_write(32'h2000_2000, 32'h0000_0000);
        u_m0.push_xfer(32'h0000_0900, 1'b0, 32'h0, SZ_W, BURST_INCR, T_NONSEQ, 8'd0);
        for (i = 1; i < 24; i = i + 1)
            u_m0.push_xfer(32'h0000_0900 + i*4, 1'b0, 32'h0, SZ_W, BURST_INCR, T_SEQ, 8'd0);
        hwait(4);
        for (i = 0; i < 8; i = i + 1)
            u_m2.push_xfer(32'h2000_2000 + i*4, 1'b1, 32'h5EED_0000 + i,
                           SZ_W, BURST_SINGLE, T_NONSEQ, 8'd1);
        drain();
        for (i = 0; i < 8; i = i + 1)
            chk_eq(u_s2.bd_read(32'h2000_2000 + i*4), 32'h5EED_0000 + i,
                   "T14: DMA write data survived the hand-off");
        chk_eq(u_chk_sl.v_wdata_change, 0, "T14: HWDATA stable across wait states");

        // ===================================================================
        // T15 - *** ERRATUM AHB-3 *** SEQ re-opened as NONSEQ after a steal
        // ===================================================================
        $display("--- T15: burst split on the slave side ---");
        chk_eq(u_chk_sl.v_seq_no_burst,   0, "T15: no SEQ with no open burst reached a slave");
        chk_eq(u_chk_sl.v_seq_after_idle, 0, "T15: no SEQ after IDLE reached a slave");
        chk_eq(u_chk_sl.v_addr_seq,       0, "T15: no SEQ address discontinuity on the slave bus");
        chk_eq(u_chk_sl.v_burst_change,   0, "T15: HBURST constant within each slave-side burst");

        // ===================================================================
        // T16 - randomised soak, all three masters, random slaves and timing
        // ===================================================================
        $display("--- T16: randomised three-master soak ---");
        for (j = 0; j < 8; j = j + 1) begin
            clear_rsp();
            for (i = 0; i < 24; i = i + 1) begin
                tmp = rnd(0);
                // Writes go only to DSRAM/bridge so the read expectation stays
                // simple; reads go anywhere mapped.
                u_m0.push_xfer(32'h0000_1000 + ((rnd(0) % 64) * 4), 1'b0, 32'h0,
                               SZ_W, BURST_SINGLE, T_NONSEQ, (rnd(0) % 3));
                u_m1.push_xfer(32'h2000_1100 + ((rnd(0) % 64) * 4), 1'b0, 32'h0,
                               SZ_W, BURST_SINGLE, T_NONSEQ, (rnd(0) % 4));
                u_m2.push_xfer(32'h4000_1200 + ((rnd(0) % 64) * 4), 1'b0, 32'h0,
                               SZ_W, BURST_SINGLE, T_NONSEQ, (rnd(0) % 2));
            end
            drain();
            chk_eq(n_rsp0(), 24, "T16: I-Port retired all 24");
            chk_eq(n_rsp1(), 24, "T16: D-Port retired all 24");
            chk_eq(n_rsp2(), 24, "T16: DMA    retired all 24");
            // Every response must match the slave the address decodes to, which
            // is what catches a read-data mux steering to the wrong master.
            for (i = 0; i < 24; i = i + 1) begin
                chk_eq(u_m0.r_data[i], u_s0.bd_read(u_m0.r_addr[i]), "T16: I-Port data matches ISRAM");
                chk_eq(u_m1.r_data[i], u_s2.bd_read(u_m1.r_addr[i]), "T16: D-Port data matches DSRAM");
                chk_eq(u_m2.r_data[i], u_s3.bd_read(u_m2.r_addr[i]), "T16: DMA    data matches BRIDGE");
            end
        end

        // ===================================================================
        // T17 - Rev 4.0 fourth master: Debug SBA (M2)
        // ===================================================================
        $display("--- T17: Debug SBA master ---");
        clear_rsp();
        sba_ind_viol = 0;
        u_ms.push_xfer(32'h0000_2000, 1'b1, 32'h5BA0_0001, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        u_ms.push_xfer(32'h0000_2000, 1'b0, 32'h0,         SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        u_ms.push_xfer(32'h2000_2004, 1'b1, 32'h5BA0_0002, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        u_ms.push_xfer(32'h2000_2004, 1'b0, 32'h0,         SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        u_ms.push_xfer(32'h8000_0000, 1'b0, 32'h0,         SZ_W, BURST_SINGLE, T_NONSEQ, 8'd0);
        drain();
        chk_eq(u_ms.r_data[1], 32'h5BA0_0001, "T17: SBA write/read ISRAM");
        chk_eq(u_ms.r_data[3], 32'h5BA0_0002, "T17: SBA write/read DSRAM");
        chk_eq(u_ms.r_resp[4], 1'b1,          "T17: SBA unmapped access gets ERROR");
        chk_eq(sba_ind_viol, 0,               "T17: hmaster_is_sba == (grant == M2) every cycle");
        // priority: DMA > SBA > D-Port
        clear_rsp();
        u_m1.push_xfer(32'h2000_0100, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd200);
        u_ms.push_xfer(32'h2000_0100, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd200);
        u_m2.push_xfer(32'h2000_0100, 1'b0, 32'h0, SZ_W, BURST_SINGLE, T_NONSEQ, 8'd200);
        b0 = -1; b1 = -1; b2 = -1;
        for (i = 0; i < 80; i = i + 1) begin
            @(posedge hclk);
            if (hready_s && htrans_s[1]) begin
                if (u_ic.grant == 2'd3 && b2 < 0) b2 = i;
                if (u_ic.grant == 2'd2 && b0 < 0) b0 = i;
                if (u_ic.grant == 2'd1 && b1 < 0) b1 = i;
            end
        end
        chk((b2 >= 0) && (b0 > b2) && (b1 > b0), "T17: accepted in priority order DMA, SBA, D-Port");
        drain();

        // ===================================================================
        // Final protocol verdict
        // ===================================================================
        hwait(10);
        $display("");
        u_chk_m0.report_result();
        u_chk_m1.report_result();
        u_chk_m2.report_result();
        u_chk_ms.report_result();
        u_chk_sl.report_result();

        chk_eq(v_m0, 0, "protocol: I-Port port clean");
        chk_eq(v_m1, 0, "protocol: D-Port port clean");
        chk_eq(v_m2, 0, "protocol: DMA port clean");
        chk_eq(v_ms, 0, "protocol: SBA port clean");
        chk_eq(v_sl, 0, "protocol: SLAVE-SIDE bus clean");
        chk_eq(sel_onehot_viol,  0, "final: HSEL one-hot throughout");
        chk_eq(grant_swing_viol, 0, "final: grant never swung mid-beat");
        chk_eq(hprot_dma_viol,   0, "final: HPROT=0x3 whenever the DMA was granted");

        $display("");
        $display("=====================================================");
        $display("AHB IC TB: %0d checks, %0d failures", checks, fails);
        $display("RESULT: %0s", (fails == 0) ? "PASSED" : "FAILED");
        $display("=====================================================");
        $finish;
    end

    // Global watchdog - a hung bus must fail, not run forever.
    initial begin
        #4_000_000;
        $display("[FAIL] watchdog expired - simulation hung");
        $display("AHB IC TB: %0d checks, %0d failures", checks, fails + 1);
        $display("RESULT: FAILED");
        $finish;
    end

endmodule
