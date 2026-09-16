`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 8: AHB-to-APB Bridge - block-level testbench
//
// Covers GARUDA-BRG-SPEC-001 Rev 2.0 Sec. 12 (Verification Plan), plus one test
// for a failure mode the specification does not anticipate:
//
//   T8  back-to-back accesses            (ERRATUM BRG-1)
//
// pclk IS DELIBERATELY SKEWED AGAINST hclk HERE. This is the opposite choice
// from tb_clic.sv and for the opposite reason: Sec. 13.2 states flatly that the
// bridge's correctness rests on the req/ack handshake and NOT on any clock
// phase relationship, and that the design is expected to stay correct if the
// relationship is later relaxed to fully asynchronous. Verifying under a
// deliberate offset is what proves the HANDSHAKE carries correctness. Running
// it edge-aligned would prove only that it works in the one configuration the
// silicon happens to have today.
//
// Plusargs
//   +VERBOSE   print every check
// =============================================================================

module tb_ahb2apb;

    // -----------------------------------------------------------------------
    // Clocks - pclk skewed 1.3 ns, same as tb_dma_top.sv and the old SoC TB
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

    task chk;
        input          cond;
        input [1023:0] msg;
        begin
            checks = checks + 1;
            if (!cond) begin
                fails = fails + 1;
                $display("[FAIL] %0s   (t=%0t)", msg, $time);
            end else if (verbose) $display("[ ok ] %0s", msg);
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
                $display("[FAIL] %0s : got 0x%0h expected 0x%0h   (t=%0t)",
                         msg, got, exp, $time);
            end else if (verbose) $display("[ ok ] %0s = 0x%0h", msg, got);
        end
    endtask

    // -----------------------------------------------------------------------
    // AHB side
    // -----------------------------------------------------------------------
    reg  [31:0] haddr;
    reg  [1:0]  htrans;
    reg         hwrite, hsel;
    reg  [2:0]  hsize;
    reg  [31:0] hwdata;
    wire [31:0] hrdata;
    wire        hreadyout, hresp;

    // Single slave, so the global HREADY is this slave's HREADYOUT.
    wire hready = hreadyout;

    localparam [1:0] T_IDLE = 2'b00, T_BUSY = 2'b01, T_NONSEQ = 2'b10;
    localparam [2:0] SZ_B = 3'b000, SZ_H = 3'b001, SZ_W = 3'b010;

    // Windows: DMA (5) and CLIC (9) implemented; everything else faults.
    localparam [15:0] WMASK = 16'b0000_0010_0010_0000;

    // -----------------------------------------------------------------------
    // APB side
    // -----------------------------------------------------------------------
    wire [15:0] psel;
    wire        penable, pwrite;
    wire [15:0] paddr;
    wire [31:0] pwdata;
    wire [3:0]  pstrb;

    reg  [3:0]  apb_waits;
    reg         apb_err_en;
    reg  [15:0] apb_err_addr;

    wire [31:0] s5_prdata, s9_prdata;
    wire        s5_pready, s9_pready, s5_pslverr, s9_pslverr;
    wire [31:0] s5_nacc, s9_nacc, s5_nproto, s9_nproto;

    // Return mux on the one-hot select, exactly as the SoC does it.
    wire [31:0] prdata_mux  = psel[5] ? s5_prdata  : psel[9] ? s9_prdata  : 32'h0;
    wire        pready_mux  = psel[5] ? s5_pready  : psel[9] ? s9_pready  : 1'b1;
    wire        pslverr_mux = psel[5] ? s5_pslverr : psel[9] ? s9_pslverr : 1'b0;

    ahb2apb_bridge #(.WINDOW_MASK(WMASK)) dut (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .pclk_i(pclk), .preset_n_i(preset_n),
        .hsel_i(hsel), .haddr_i(haddr), .htrans_i(htrans),
        .hwrite_i(hwrite), .hsize_i(hsize), .hwdata_i(hwdata),
        .hready_i(hready),
        .hrdata_o(hrdata), .hreadyout_o(hreadyout), .hresp_o(hresp),
        .psel_o(psel), .penable_o(penable), .pwrite_o(pwrite),
        .paddr_o(paddr), .pwdata_o(pwdata), .pstrb_o(pstrb),
        .prdata_i(prdata_mux), .pready_i(pready_mux), .pslverr_i(pslverr_mux));

    apb_slave_model u_s5 (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .waits_i(apb_waits), .err_en_i(apb_err_en), .err_addr_i(apb_err_addr),
        .psel_i(psel[5]), .penable_i(penable), .pwrite_i(pwrite),
        .paddr_i(paddr), .pwdata_i(pwdata), .pstrb_i(pstrb),
        .prdata_o(s5_prdata), .pready_o(s5_pready), .pslverr_o(s5_pslverr),
        .n_access_o(s5_nacc), .n_proto_err_o(s5_nproto));

    apb_slave_model u_s9 (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .waits_i(4'd0), .err_en_i(1'b0), .err_addr_i(16'h0),
        .psel_i(psel[9]), .penable_i(penable), .pwrite_i(pwrite),
        .paddr_i(paddr), .pwdata_i(pwdata), .pstrb_i(pstrb),
        .prdata_o(s9_prdata), .pready_o(s9_pready), .pslverr_o(s9_pslverr),
        .n_access_o(s9_nacc), .n_proto_err_o(s9_nproto));

    // -----------------------------------------------------------------------
    // Monitors
    // -----------------------------------------------------------------------
    integer n_err_cycles;        // cycles with HRESP=ERROR
    integer n_multi_psel;        // PSEL not one-hot
    always @(posedge hclk) if (hreset_n && hresp) n_err_cycles = n_err_cycles + 1;
    always @(posedge pclk) begin
        if (preset_n && (psel != 16'h0) && ((psel & (psel - 16'h1)) != 16'h0))
            n_multi_psel = n_multi_psel + 1;
    end

    // -----------------------------------------------------------------------
    // AHB driver. The bridge stalls with HREADYOUT low for the whole crossing,
    // so every phase must wait on it.
    // -----------------------------------------------------------------------
    task ahb_xfer;
        input  [31:0] a;
        input         wr;
        input  [31:0] wd;
        input  [2:0]  sz;
        output [31:0] rdata;
        output        rresp;
        begin
            @(negedge hclk);
            while (hreadyout !== 1'b1) @(negedge hclk);
            hsel = 1'b1; haddr = a; htrans = T_NONSEQ; hwrite = wr; hsize = sz;

            @(negedge hclk);                   // address phase accepted
            hsel = 1'b0; htrans = T_IDLE;
            hwdata = wd;                       // data phase

            while (hreadyout !== 1'b1) @(negedge hclk);
            rdata  = hrdata;
            rresp  = hresp;
            @(negedge hclk);
        end
    endtask

    reg [31:0] rd;
    reg        rsp;
    integer    i;
    integer    acc_before;
    time       t0, t1;

    initial begin
        verbose = $test$plusargs("VERBOSE");
        hsel = 0; haddr = 0; htrans = T_IDLE; hwrite = 0; hsize = SZ_W; hwdata = 0;
        apb_waits = 4'd0; apb_err_en = 1'b0; apb_err_addr = 16'h0;
        n_err_cycles = 0; n_multi_psel = 0;

        $display("======================================================");
        $display("GARUDA AHB-to-APB Bridge (Block 8) testbench");
        $display("======================================================");

        repeat (6) @(posedge hclk);
        hreset_n = 1'b1; preset_n = 1'b1;
        repeat (6) @(posedge hclk);

        chk(hreadyout === 1'b1, "T0 HREADYOUT high out of reset");
        chk_eq(psel, 16'h0,     "T0 no PSEL asserted out of reset");

        // ===================================================================
        // T1 - word write then read back through the crossing
        // ===================================================================
        ahb_xfer(32'h4000_5010, 1'b1, 32'hCAFE_BABE, SZ_W, rd, rsp);
        chk(rsp === 1'b0, "T1 write completed OKAY");
        ahb_xfer(32'h4000_5010, 1'b0, 32'h0, SZ_W, rd, rsp);
        chk_eq(rd, 32'hCAFE_BABE, "T1 read returns what was written");
        chk(rsp === 1'b0, "T1 read completed OKAY");

        // The access reached the right peripheral, and only it.
        chk(s5_nacc > 0, "T1 window 5 peripheral saw the accesses");
        chk_eq(s9_nacc, 0, "T1 window 9 peripheral saw nothing");

        // ===================================================================
        // T2 - address mapping (Sec. 5.3.1)
        //
        // PADDR must be HADDR[15:0]: [15:12] the window, [11:0] the offset.
        // ===================================================================
        ahb_xfer(32'h4000_9024, 1'b1, 32'h1234_5678, SZ_W, rd, rsp);
        ahb_xfer(32'h4000_9024, 1'b0, 32'h0, SZ_W, rd, rsp);
        chk_eq(rd, 32'h1234_5678, "T2 window 9 addressed independently of window 5");
        chk_eq(u_s9.bd_read(16'h0024), 32'h1234_5678,
               "T2 offset within the window is HADDR[11:0]");

        // ===================================================================
        // T3 - byte and half-word writes drive PSTRB (Sec. 8.4, Sec. 13.5)
        //
        // This is what APB4 buys over APB3. The model honours PSTRB, so a
        // bridge generating the wrong strobes corrupts neighbouring lanes here
        // rather than silently working.
        // ===================================================================
        ahb_xfer(32'h4000_5020, 1'b1, 32'hAAAA_AAAA, SZ_W, rd, rsp);

        ahb_xfer(32'h4000_5020, 1'b1, 32'h0000_0011, SZ_B, rd, rsp);
        chk_eq(u_s5.bd_read(16'h0020), 32'hAAAA_AA11, "T3 byte write hit lane 0 only");

        ahb_xfer(32'h4000_5022, 1'b1, 32'h0022_0000, SZ_B, rd, rsp);
        chk_eq(u_s5.bd_read(16'h0020), 32'hAA22_AA11, "T3 byte write hit lane 2 only");

        ahb_xfer(32'h4000_5020, 1'b1, 32'h0000_3344, SZ_H, rd, rsp);
        chk_eq(u_s5.bd_read(16'h0020), 32'hAA22_3344, "T3 half-word write hit lanes 0-1");

        // ===================================================================
        // T4 - peripheral wait states pass through transparently (Sec. 8.3)
        // ===================================================================
        apb_waits = 4'd3;
        ahb_xfer(32'h4000_5030, 1'b1, 32'h0F0F_0F0F, SZ_W, rd, rsp);
        ahb_xfer(32'h4000_5030, 1'b0, 32'h0, SZ_W, rd, rsp);
        chk_eq(rd, 32'h0F0F_0F0F, "T4 access with 3 PREADY wait states still correct");
        chk(rsp === 1'b0, "T4 wait-stated access completed OKAY");
        apb_waits = 4'd0;

        // ===================================================================
        // T5 - PSLVERR becomes a TWO-CYCLE HRESP=ERROR (Sec. 8.5 - NORMATIVE)
        //
        // The first cycle (HREADY=0, HRESP=ERROR) is the only warning the DMA
        // beat engine gets, and it is what lets it retract an already-pipelined
        // write address instead of committing it.
        // ===================================================================
        apb_err_en   = 1'b1;
        apb_err_addr = 16'h0040;
        n_err_cycles = 0;

        ahb_xfer(32'h4000_5040, 1'b0, 32'h0, SZ_W, rd, rsp);
        chk(rsp === 1'b1, "T5 PSLVERR surfaced as HRESP=ERROR");
        chk_eq(n_err_cycles, 2, "T5 ERROR was exactly TWO cycles, not one");
        apb_err_en = 1'b0;

        // ===================================================================
        // T6 - unmapped window faults WITHOUT any APB activity (Sec. 8.5)
        // ===================================================================
        acc_before   = s5_nacc + s9_nacc;
        n_err_cycles = 0;
        ahb_xfer(32'h4000_3000, 1'b1, 32'hDEAD_DEAD, SZ_W, rd, rsp);
        chk(rsp === 1'b1, "T6 unmapped window returned ERROR");
        chk_eq(n_err_cycles, 2, "T6 unmapped window ERROR was two cycles");
        chk_eq(s5_nacc + s9_nacc, acc_before,
               "T6 NO APB transfer was launched for an unmapped window");

        // ===================================================================
        // T7 - IDLE and BUSY start no APB transfer (Sec. 7.5)
        // ===================================================================
        acc_before = s5_nacc + s9_nacc;
        @(negedge hclk);
        hsel = 1'b1; haddr = 32'h4000_5000; htrans = T_IDLE; hwrite = 1'b1;
        repeat (4) @(negedge hclk);
        htrans = T_BUSY;
        repeat (4) @(negedge hclk);
        hsel = 1'b0; htrans = T_IDLE;
        repeat (10) @(posedge hclk);
        chk_eq(s5_nacc + s9_nacc, acc_before,
               "T7 HTRANS=IDLE/BUSY launched no APB transfer");
        chk(hreadyout === 1'b1, "T7 bridge stayed ready through IDLE/BUSY");

        // ===================================================================
        // T8 - BACK-TO-BACK ACCESSES (ERRATUM BRG-1)
        //
        // Sec. 7.5 says the bridge accepts work "only from H_IDLE". H_RESP_OKAY
        // drives HREADYOUT high, which is by definition the condition under
        // which the master's next address phase IS accepted - so a bridge that
        // only latched from H_IDLE would silently DROP every second transfer
        // of a run. Firmware configuring a peripheral with consecutive stores
        // is exactly that run.
        //
        // The check is counted, not sampled: issue N transfers with the address
        // phase presented in every cycle HREADYOUT is high, and require the
        // peripheral to have seen all N.
        // ===================================================================
        acc_before = s5_nacc;

        for (i = 0; i < 8; i = i + 1) begin
            @(negedge hclk);
            while (hreadyout !== 1'b1) @(negedge hclk);
            hsel = 1'b1; haddr = 32'h4000_5100 + (i*4); htrans = T_NONSEQ;
            hwrite = 1'b1; hsize = SZ_W;
            @(negedge hclk);
            hsel = 1'b0; htrans = T_IDLE;
            hwdata = 32'h9000_0000 + i;
            while (hreadyout !== 1'b1) @(negedge hclk);
        end
        @(negedge hclk);
        repeat (10) @(posedge hclk);

        chk_eq(s5_nacc - acc_before, 8,
               "T8 BRG-1: all 8 back-to-back transfers reached APB (none dropped)");

        for (i = 0; i < 8; i = i + 1)
            chk_eq(u_s5.bd_read(16'h0100 + (i*4)), 32'h9000_0000 + i,
                   "T8 BRG-1: back-to-back write landed at the right offset");

        // ===================================================================
        // T9 - single-outstanding: one APB access completes before the next
        // SETUP (Sec. 13.3)
        // ===================================================================
        chk_eq(n_multi_psel, 0, "T9 PSEL was one-hot at all times");
        chk_eq(u_s5.n_proto_err_o, 0, "T9 no APB protocol violation on window 5");
        chk_eq(u_s9.n_proto_err_o, 0, "T9 no APB protocol violation on window 9");

        // ===================================================================
        // T10 - reset during a transfer (Sec. 10.3)
        //
        // The in-flight APB access is abandoned, both FSMs return to idle, the
        // toggles clear so no stale edge is read as traffic, and the first
        // post-reset access is clean. No terminal response is manufactured -
        // the master is being reset in the same event.
        // ===================================================================
        @(negedge hclk);
        hsel = 1'b1; haddr = 32'h4000_5060; htrans = T_NONSEQ; hwrite = 1'b1;
        @(negedge hclk);
        hsel = 1'b0; htrans = T_IDLE; hwdata = 32'h1111_2222;
        @(negedge hclk);                       // mid-crossing
        hreset_n = 1'b0; preset_n = 1'b0;
        repeat (4) @(posedge hclk);
        chk_eq(psel, 16'h0, "T10 PSEL dropped immediately on reset");
        chk(hreadyout === 1'b1, "T10 bridge returned to idle, HREADYOUT high");

        @(negedge hclk);
        hreset_n = 1'b1; preset_n = 1'b1;
        repeat (8) @(posedge hclk);

        ahb_xfer(32'h4000_5070, 1'b1, 32'h7777_8888, SZ_W, rd, rsp);
        ahb_xfer(32'h4000_5070, 1'b0, 32'h0, SZ_W, rd, rsp);
        chk_eq(rd, 32'h7777_8888, "T10 first access after reset is clean");
        chk(rsp === 1'b0, "T10 no stale toggle produced a spurious error");

        $display("======================================================");
        $display("tb_ahb2apb: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %0s", (fails == 0) ? "PASSED" : "FAILED");
        $display("======================================================");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("[FAIL] tb_ahb2apb: TIMEOUT");
        $display("RESULT: FAILED");
        $finish;
    end

endmodule
