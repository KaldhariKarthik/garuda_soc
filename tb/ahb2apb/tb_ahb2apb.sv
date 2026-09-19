`timescale 1ns/1ps
// =============================================================================
// tb_ahb2apb.sv -- Block 8 (+7) AHB-to-APB bridge, Rev 4.0 synchronous smoke
//
// Spec: GARUDA-AHB2APB-SPEC-001 §11. Real clk_div provides hclk/pclk/pclk_phase
// so the no-CDC relationship is the production one, not a testbench idealisation.
//
//   windows with a slave model: 1 (spi_master stand-in), 5 (dma_cfg),
//                               9 (reset_ctrl), 11 (timers, APB_DIV = /2)
//   window 2 is present but its slave never raises PREADY (timeout test)
//   window 3 is masked off (absent peripheral)
// =============================================================================
module tb_ahb2apb;

    reg refclk = 0, ext_rst_n = 0;
    always #1 refclk = ~refclk;                          // 500 MHz

    wire aon, hclk, pclk, pclk_phase, div_busy;
    wire [1:0] div_act;
    clk_div u_clk (.refclk_i(refclk), .raw_rst_n_i(ext_rst_n), .div_sel_i(2'b00),
                   .aon_clk_o(aon), .hclk_o(hclk), .pclk_o(pclk), .pclk_phase_o(pclk_phase),
                   .div_act_o(div_act), .div_busy_o(div_busy));

    // simple resets: hreset first, preset a few pclk later (production order)
    reg hreset_n = 0, preset_n = 0;

    // ---- AHB master BFM ------------------------------------------------------
    wire [31:0] haddr, hwdata, hrdata;
    wire [1:0]  htrans;
    wire        hwrite, hreadyout, hresp;
    wire [2:0]  hsize, hburst;
    wire [3:0]  hprot;
    ahb_lite_master_bfm #(.HPROT(4'b0011)) u_m (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .haddr_o(haddr), .htrans_o(htrans), .hwrite_o(hwrite),
        .hsize_o(hsize), .hburst_o(hburst), .hprot_o(hprot), .hwdata_o(hwdata),
        .hrdata_i(hrdata), .hready_i(hreadyout), .hresp_i(hresp));

    // ---- DUT ------------------------------------------------------------------
    localparam [15:0] MASK = 16'b0000_1111_1111_0110;    // windows 1,2,4..11; not 3
    localparam [23:0] DIV  = 24'h0 | (24'b01 << 22);      // window 11: /2

    wire [11:0] psel, paddr;
    wire        penable, pwrite;
    wire [31:0] pwdata;
    wire [12*32-1:0] prdata;
    wire [11:0] pready, pslverr;

    ahb2apb_bridge #(.WINDOW_MASK(MASK), .APB_DIV(DIV)) u_dut (
        .hclk_i(hclk), .hreset_n_i(hreset_n), .pclk_i(pclk), .preset_n_i(preset_n),
        .pclk_phase_i(pclk_phase),
        .hsel_i(haddr[31:28] == 4'h4), .haddr_i(haddr), .htrans_i(htrans),
        .hwrite_i(hwrite), .hsize_i(hsize), .hwdata_i(hwdata), .hready_i(hreadyout),
        .hrdata_o(hrdata), .hreadyout_o(hreadyout), .hresp_o(hresp),
        .psel_o(psel), .penable_o(penable), .pwrite_o(pwrite), .paddr_o(paddr),
        .pwdata_o(pwdata), .prdata_i(prdata), .pready_i(pready), .pslverr_i(pslverr));

    // ---- APB slaves -------------------------------------------------------------
    reg [3:0] waits = 0;
    reg       err_en = 0;
    wire [31:0] nacc [0:11], nproto [0:11];

    genvar g;
    generate for (g = 0; g < 12; g = g + 1) begin : g_win
        if (g == 1 || g == 5 || g == 9 || g == 11) begin : g_model
            apb_slave_model u_s (
                .pclk_i(pclk), .preset_n_i(preset_n), .waits_i(waits),
                .err_en_i(err_en), .err_addr_i(16'h0FFC),
                .psel_i(psel[g]), .penable_i(penable), .pwrite_i(pwrite),
                .paddr_i({4'h0, paddr}), .pwdata_i(pwdata), .pstrb_i(4'hF),
                .prdata_o(prdata[32*g +: 32]), .pready_o(pready[g]), .pslverr_o(pslverr[g]),
                .n_access_o(nacc[g]), .n_proto_err_o(nproto[g]));
        end else begin : g_none
            assign prdata[32*g +: 32] = 32'hDEAD_0000 | g;
            assign pready[g]  = (g == 2) ? 1'b0 : 1'b1;   // window 2 hangs
            assign pslverr[g] = 1'b0;
            assign nacc[g] = 0; assign nproto[g] = 0;
        end
    end endgenerate

    // ---- scoreboard / helpers ---------------------------------------------------
    integer checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    localparam [2:0] SZ_B = 3'b000, SZ_H = 3'b001, SZ_W = 3'b010;
    task automatic go(input [31:0] a, input bit w, input [31:0] d, input [2:0] sz);
        u_m.push_xfer(a, w, d, sz, 3'b000, 2'b10, 8'd0);
    endtask
    task automatic drain;
        int guard = 0;
        while (((u_m.q_head !== u_m.q_tail) || u_m.addr_outstanding || u_m.data_outstanding)
               && guard < 5000) begin @(posedge hclk); guard++; end
        if (guard >= 5000) begin fails++; $display("[FAIL] bus hung"); end
        repeat (4) @(posedge hclk);
    endtask

    // APB monitors: PSEL one-hot, PENABLE only with PSEL, setup exactly 1 cycle
    integer psel_viol = 0, pen_viol = 0, pen_len = 0, max_pen_w11 = 0, apb_starts = 0;
    reg psel_any_d = 0;
    always @(posedge pclk) if (preset_n) begin
        if (!$onehot0(psel)) psel_viol++;
        if (penable && !(|psel)) pen_viol++;
        if ((|psel) && !psel_any_d) begin apb_starts++; if (penable) pen_viol++; end
        psel_any_d <= |psel;
        if (penable && psel[11]) pen_len++;
        else begin if (pen_len > max_pen_w11) max_pen_w11 = pen_len; pen_len = 0; end
    end
    integer rst_hold_viol = 0;
    always @(posedge hclk) if (!(hreset_n && preset_n) && hreadyout) rst_hold_viol++;

    int s;
    initial begin
        $display("=== tb_ahb2apb: Block 8 Rev 4.0 ===");
        #50 ext_rst_n = 1;
        repeat (4) @(posedge hclk);
        hreset_n = 1;
        repeat (6) @(posedge hclk);
        check(!hreadyout, "[N-9.2] hreadyout low while preset_n still asserted");
        @(posedge pclk); preset_n = 1;
        repeat (4) @(posedge hclk);
        check(hreadyout, "[N-9.3] hreadyout released after both resets");

        // ---- word write/read on every present window with a model -----------
        go(32'h4000_1010, 1, 32'h1111_0001, SZ_W);
        go(32'h4000_5020, 1, 32'h5555_0005, SZ_W);
        go(32'h4000_9030, 1, 32'h9999_0009, SZ_W);
        go(32'h4000_B040, 1, 32'hBBBB_000B, SZ_W);
        go(32'h4000_1010, 0, 0, SZ_W);
        go(32'h4000_5020, 0, 0, SZ_W);
        go(32'h4000_9030, 0, 0, SZ_W);
        go(32'h4000_B040, 0, 0, SZ_W);
        drain();
        check(u_m.r_data[4] == 32'h1111_0001 && !u_m.r_resp[4], "window 1 write/read");
        check(u_m.r_data[5] == 32'h5555_0005 && !u_m.r_resp[5], "window 5 (dma_cfg) write/read");
        check(u_m.r_data[6] == 32'h9999_0009 && !u_m.r_resp[6], "window 9 (reset_ctrl) write/read");
        check(u_m.r_data[7] == 32'hBBBB_000B && !u_m.r_resp[7], "window 11 (timers) write/read, APB_DIV /2");
        check(max_pen_w11 >= 2, $sformatf("a_apb_div: window 11 PENABLE held %0d pclk (>= 2)", max_pen_w11));
        u_m.r_head = 0; u_m.r_tail = 0;

        // ---- back-to-back writes (BRG-1 regression) ----------------------------
        for (s = 0; s < 8; s++) go(32'h4000_5100 + 4*s, 1, 32'hA000_0000 + s, SZ_W);
        for (s = 0; s < 8; s++) go(32'h4000_5100 + 4*s, 0, 0, SZ_W);
        drain();
        begin
            bit ok = 1;
            for (s = 0; s < 8; s++) if (u_m.r_data[8+s] !== 32'hA000_0000 + s || u_m.r_resp[s]) ok = 0;
            check(ok, "8 back-to-back writes all land, then read back (BRG-1)");
        end
        u_m.r_head = 0; u_m.r_tail = 0;

        // ---- errors -------------------------------------------------------------
        s = apb_starts;
        go(32'h4000_5000, 1, 32'h1, SZ_B);
        go(32'h4000_5000, 0, 0, SZ_H);
        go(32'h4000_0000, 0, 0, SZ_W);     // window 0: removed SPI slave
        go(32'h4000_C000, 0, 0, SZ_W);     // 0xC: beyond the map
        go(32'h4000_3000, 0, 0, SZ_W);     // window 3: masked (absent IP)
        drain();
        check(u_m.r_resp[0] && u_m.r_resp[1], "[N-7.12] byte and halfword rejected with ERROR");
        check(u_m.r_resp[2] && u_m.r_resp[3], "[N-7.19] window 0 and 0xC unmapped -> ERROR");
        check(u_m.r_resp[4], "masked window 3 -> ERROR");
        check(apb_starts == s, "a_subword_no_apb / a_unmapped: no APB transfer for any of them");
        u_m.r_head = 0; u_m.r_tail = 0;

        err_en = 1;
        go(32'h4000_5FFC, 0, 0, SZ_W);
        go(32'h4000_5004, 0, 0, SZ_W);
        drain();
        err_en = 0;
        check(u_m.r_resp[0], "[N-7.20] PSLVERR -> ERROR");
        check(!u_m.r_resp[1], "next access after PSLVERR is OKAY");
        u_m.r_head = 0; u_m.r_tail = 0;

        go(32'h4000_2000, 0, 0, SZ_W);     // window 2 never ready
        go(32'h4000_5004, 0, 0, SZ_W);
        drain();
        check(u_m.r_resp[0], "[N-7.15] 16-pclk PREADY timeout -> ERROR");
        check(!u_m.r_resp[1], "a_no_hang: bus usable after a timeout");
        u_m.r_head = 0; u_m.r_tail = 0;

        // ---- wait states ------------------------------------------------------------
        waits = 3;
        go(32'h4000_9008, 1, 32'hCAFE_F00D, SZ_W);
        go(32'h4000_9008, 0, 0, SZ_W);
        drain();
        waits = 0;
        check(u_m.r_data[1] == 32'hCAFE_F00D && !u_m.r_resp[1], "3 APB wait states -> OKAY, data intact");

        // ---- global -------------------------------------------------------------------
        check(psel_viol == 0 && pen_viol == 0, "APB: PSEL one-hot, PENABLE only after a 1-cycle SETUP");
        check(rst_hold_viol == 0, "a_dual_reset_hold");
        check(nproto[1] + nproto[5] + nproto[9] + nproto[11] == 0, "APB slave models saw no protocol error");

        $display("tb_ahb2apb: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end
    initial begin #500_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
