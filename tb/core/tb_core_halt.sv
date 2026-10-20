// =============================================================================
// tb_core_halt.sv -- t_core_hartreset (CORE spec 11): a debugger halt at many
// moments of a running program must never break the bus (bug RDC-1).
//
// Core + real DSU + AHB memory model + the two passive AHB-Lite checkers (as in
// tb_boot) + the REAL Debug Module, driven through its DMI port the way the
// JTAG DTM would: dmactive, then NHALT times { run a seeded random time; write
// dmcontrol.haltreq; wait for dmstatus.allhalted; stay halted a random time;
// write dmcontrol.resumereq } -- each resume restarts the program at the reset
// vector (ADR-0012: halt = hold in hartreset). The checkers and the memory are
// on the BUS reset only, so a hart reset that withdraws or corrupts a transfer
// in flight is reported. After the last resume the program must still finish
// with TOHOST = 1.
//
// The test is only meaningful if halts actually land on a waited store (the
// RDC-1 window): their number is counted and must be > 0 (+MIN_STORE_HALTS).
//
// The bounded fallback: if the core cannot reach a safe point (a slave holds
// HREADY low), the Debug Module grants after HALT_TIMEOUT cycles and sets the
// sticky haltinfo.haltforced (DMI 0x70). Normal runs require haltforced == 0;
// the timeout variant (+define+HALT_TIMEOUT_TEST: HALT_TIMEOUT = 8, long waits,
// +EXPECT_FORCED=1) requires it to be 1, and then bus violations are the
// documented price of the forced reset, not a failure.
//
// Plusargs: +HEX=<image> (t_mem)  +NHALT=<n> (60)  +DWAIT=<n> (5)  +SEED=<n>
//           +EXPECT_FORCED=1
// =============================================================================
`timescale 1ns/1ps

module tb_core_halt;
    localparam logic [31:0] BASE   = 32'h1000_0000;
    localparam logic [31:0] TOHOST = 32'h1000_F000;

    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---- core ----------------------------------------------------------------
    wire [31:0] i_haddr, i_hwdata, i_hrdata, d_haddr, d_hwdata, d_hrdata;
    wire [1:0]  i_htrans, d_htrans;
    wire [2:0]  i_hsize, i_hburst, d_hsize, d_hburst;
    wire [3:0]  i_hprot, d_hprot;
    wire        i_hwrite, i_hready, i_hresp, d_hwrite, d_hready, d_hresp;
    wire [47:0] acc0, acc1, acc2;
    wire        dsu_ovf, core_sleep;
    wire        dm_hartreset;
    wire        halt_req, halt_safe;          // RDC-1 drain handshake (core <-> Debug Module)

    garuda_core_top #(.RESET_VECTOR(BASE)) dut (
        .clk_i(clk), .core_rst_n_i(rst_n), .hartreset_n_i(~dm_hartreset),
        .halt_req_i(halt_req), .halt_safe_o(halt_safe),
        .i_haddr_o(i_haddr), .i_htrans_o(i_htrans), .i_hsize_o(i_hsize),
        .i_hburst_o(i_hburst), .i_hprot_o(i_hprot), .i_hwrite_o(i_hwrite),
        .i_hwdata_o(i_hwdata), .i_hrdata_i(i_hrdata), .i_hready_i(i_hready), .i_hresp_i(i_hresp),
        .d_haddr_o(d_haddr), .d_htrans_o(d_htrans), .d_hsize_o(d_hsize),
        .d_hburst_o(d_hburst), .d_hprot_o(d_hprot), .d_hwrite_o(d_hwrite),
        .d_hwdata_o(d_hwdata), .d_hrdata_i(d_hrdata), .d_hready_i(d_hready), .d_hresp_i(d_hresp),
        .clic_irq_valid_i(1'b0), .clic_irq_id_i(5'd0), .clic_irq_level_i(8'd0), .mtip_i(1'b0),
        .dbg_acc_0_o(acc0), .dbg_acc_1_o(acc1), .dbg_acc_2_o(acc2),
        .dsu_ovf_o(dsu_ovf), .core_sleep_o(core_sleep)
    );

    // ---- memory (bus reset only) ---------------------------------------------------
    int unsigned dwait = 5;
    ahb_mem_slave #(.BASE_ADDR(BASE), .SIZE_BYTES(32'h0004_0000)) u_mem (
        .clk_i(clk), .rst_n_i(rst_n),
        .i_waits_i(8'd0), .d_waits_i(dwait[7:0]), .i_rand_i(1'b0), .d_rand_i(1'b0),
        .err_en_i(1'b0), .err_base_i(32'd0), .err_size_i(32'd0),
        .i_haddr_i(i_haddr), .i_htrans_i(i_htrans), .i_hsize_i(i_hsize),
        .i_hwrite_i(i_hwrite), .i_hwdata_i(i_hwdata),
        .i_hrdata_o(i_hrdata), .i_hready_o(i_hready), .i_hresp_o(i_hresp),
        .d_haddr_i(d_haddr), .d_htrans_i(d_htrans), .d_hsize_i(d_hsize),
        .d_hwrite_i(d_hwrite), .d_hwdata_i(d_hwdata),
        .d_hrdata_o(d_hrdata), .d_hready_o(d_hready), .d_hresp_o(d_hresp));

    // ---- passive AHB-Lite checkers (bus reset only) --------------------------------
    wire [31:0] i_viol, d_viol;
    ahb_lite_checker u_ichk (.clk_i(clk), .rst_n_i(rst_n),
        .haddr_i(i_haddr), .htrans_i(i_htrans), .hsize_i(i_hsize), .hburst_i(i_hburst),
        .hwrite_i(i_hwrite), .hwdata_i(i_hwdata), .hready_i(i_hready), .hresp_i(i_hresp),
        .viol_count_o(i_viol));
    ahb_lite_checker u_dchk (.clk_i(clk), .rst_n_i(rst_n),
        .haddr_i(d_haddr), .htrans_i(d_htrans), .hsize_i(d_hsize), .hburst_i(d_hburst),
        .hwrite_i(d_hwrite), .hwdata_i(d_hwdata), .hready_i(d_hready), .hresp_i(d_hresp),
        .viol_count_o(d_viol));

    // ---- Debug Module (DMI driven directly; SBA idle) ----------------------------
    logic        dmi_req = 1'b0;
    logic [6:0]  dmi_addr = '0;
    logic [31:0] dmi_wdata = '0;
    logic [1:0]  dmi_op = '0;
    wire  [31:0] dmi_rdata;
    wire         dmi_done, ndmreset, sba_start, sba_write;
    wire  [31:0] sba_addr, sba_wdata;
`ifdef HALT_TIMEOUT_TEST
    localparam int HT = 8;
`else
    localparam int HT = 1024;
`endif
    debug_module #(.HALT_TIMEOUT(HT)) u_dm (
        .hclk_i(clk), .dm_rst_n_i(rst_n),
        .req_i(dmi_req), .addr_i(dmi_addr), .wdata_i(dmi_wdata), .op_i(dmi_op),
        .rdata_o(dmi_rdata), .done_o(dmi_done),
        .ndmreset_o(ndmreset), .hartreset_o(dm_hartreset),
        .halt_req_o(halt_req), .halt_safe_i(halt_safe),
        .dsu_acc0_i(acc0), .dsu_acc1_i(acc1), .dsu_acc2_i(acc2), .dsu_ovf_i(dsu_ovf),
        .sba_start_o(sba_start), .sba_write_o(sba_write), .sba_addr_o(sba_addr),
        .sba_wdata_o(sba_wdata), .sba_done_i(1'b0), .sba_err_i(1'b0),
        .sba_rdata_i(32'd0), .sba_busy_i(1'b0));

    task automatic dmi(input logic [1:0] op, input logic [6:0] a, input logic [31:0] d,
                       output logic [31:0] r);
        @(negedge clk); dmi_req = 1'b1; dmi_op = op; dmi_addr = a; dmi_wdata = d;
        @(negedge clk); dmi_req = 1'b0;
        while (!dmi_done) @(negedge clk);
        r = dmi_rdata;
    endtask

    // ---- bus observation: waited store in flight, TOHOST --------------------------------
    logic d_wphase = 1'b0;        // a write data phase is in progress
    logic th_phase = 1'b0;        // ... and it is the TOHOST store
    logic [31:0] tohost = 32'd0;
    logic        clr_th = 1'b0;   // pulsed at each resume: only the LAST run's result counts
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin d_wphase <= 1'b0; th_phase <= 1'b0; end
        else if (clr_th) tohost <= 32'd0;
        else if (d_hready) begin
            if (th_phase) tohost <= d_hwdata;
            d_wphase <= d_htrans[1] & d_hwrite;
            th_phase <= d_htrans[1] & d_hwrite & (d_haddr == TOHOST);
        end
    wire store_waiting = d_wphase & ~d_hready;

    // ---- the scenario ---------------------------------------------------------------
    int unsigned nhalt = 60, seed = 1, min_store_halts = 1, expect_forced = 0;
    int unsigned store_halts = 0, halts_done = 0, errors = 0;
    string hex;
    logic [31:0] r;

    initial begin
        if (!$value$plusargs("HEX=%s", hex)) $fatal(1, "need +HEX=<image>");
        void'($value$plusargs("NHALT=%d", nhalt));
        void'($value$plusargs("DWAIT=%d", dwait));
        void'($value$plusargs("SEED=%d", seed));
        void'($value$plusargs("MIN_STORE_HALTS=%d", min_store_halts));
        void'($value$plusargs("EXPECT_FORCED=%d", expect_forced));
        process::self().srandom(seed);
        $readmemh(hex, u_mem.mem);
        $display("tb_core_halt: %0s  NHALT=%0d DWAIT=%0d SEED=%0d", hex, nhalt, dwait, seed);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        dmi(2'd2, 7'h10, 32'h0000_0001, r);                      // dmactive

        for (int unsigned h = 0; h < nhalt; h++) begin
            repeat ($urandom_range(5, 900)) @(negedge clk);       // run a random time
            if (store_waiting) store_halts++;
            dmi(2'd2, 7'h10, 32'h8000_0001, r);                  // haltreq
            begin : wait_halted
                int unsigned n = 0;
                do begin
                    dmi(2'd1, 7'h11, 32'd0, r);                   // dmstatus
                    n++;
                end while (!r[9] && n < 400);                     // allhalted
                if (!r[9]) begin
                    errors++;
                    $display("[FAIL] halt %0d: dmstatus.allhalted not set after %0d polls", h, n);
                end
            end
            repeat ($urandom_range(2, 20)) @(negedge clk);        // stay halted
            dmi(2'd2, 7'h10, 32'h4000_0001, r);                  // resumereq
            @(negedge clk) clr_th = 1'b1;
            @(negedge clk) clr_th = 1'b0;
            halts_done++;
        end

        // after the last resume the program must still run to completion
        begin : finish
            int unsigned n = 0;
            while (tohost == 32'd0 && n < 200000) begin @(negedge clk); n++; end
        end
        dmi(2'd1, 7'h70, 32'd0, r);                              // haltinfo
        $display("tb_core_halt: halts %0d, halts landing on a waited store %0d, AHB violations i=%0d d=%0d, TOHOST=%08h, haltforced=%0d",
                 halts_done, store_halts, i_viol, d_viol, tohost, r[0]);
        if (expect_forced) begin
            // the timeout variant: the forced grant must have happened and been
            // flagged; violations are then the documented price, so not judged
            $display("AHB-PROTOCOL: iport=0 dport=0 (not judged: forced-grant variant, i=%0d d=%0d)", i_viol, d_viol);
            if (!r[0]) begin errors++; $display("[FAIL] haltforced not set although every halt had to time out"); end
        end else begin
            $display("AHB-PROTOCOL: iport=%0d dport=%0d", i_viol, d_viol);
            if (r[0]) begin errors++; $display("[FAIL] haltforced set: a halt was granted by the timeout, not at a safe point"); end
        end
        if (!expect_forced && (i_viol != 0 || d_viol != 0)) begin
            errors++; $display("[FAIL] the bus saw %0d protocol violation(s) across the halts", i_viol + d_viol);
        end
        if (tohost != 32'd1) begin
            errors++; $display("[FAIL] the program did not finish after the last resume (TOHOST=%08h)", tohost);
        end
        if (store_halts < min_store_halts) begin
            errors++; $display("[FAIL] only %0d halt(s) landed on a waited store (want >= %0d): the test proved nothing",
                               store_halts, min_store_halts);
        end
        if (errors == 0) $display(" RESULT: ALL CHECKS PASSED (%0d halts, %0d on a waited store)", halts_done, store_halts);
        else             $display(" RESULT: %0d CHECK(S) FAILED", errors);
        $finish;
    end
endmodule
