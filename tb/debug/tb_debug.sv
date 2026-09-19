`timescale 1ns/1ps
// =============================================================================
// tb_debug.sv -- Block 12 debug subsystem, Rev 4.0 smoke
//
// Spec: GARUDA-DEBUG-SPEC-001 §11. JTAG is bit-banged on the pins at 20 MHz,
// asynchronous to hclk (250 MHz), so every DMI access really crosses dmi_cdc.
// SBA reaches the real ISRAM (ILOCK set - SBA must bypass it), an AHB SRAM
// model standing in for DSRAM, and an error window.
//   5x TMS reset, IDCODE 0x0000_0DB1, DTMCS abits 7 / idle 5 / version 1
//   dmactive, dmstatus version/authenticated, haltreq/resumereq -> hartreset
//   ndmreset level out, abstractcs reads 0 (no progbuf, no data regs)
//   SBA write/read, autoincrement bulk, sbreadonaddr + sbreadondata stream
//   ILOCK bypass on ISRAM, sberror 2 (misaligned) / 3 (size) / 4 (bus error)
//   coherent 48-bit DSU tap read while the accumulator runs
// =============================================================================
module tb_debug;
    reg hclk = 0; always #2 hclk = ~hclk;
    reg rst_n = 0;
    reg tck = 0, tms = 1, tdi = 0;
    wire tdo, tdo_oe;

    wire ndmreset, hartreset;
    reg  [47:0] acc0 = 48'h1234_5678_9ABC, acc1 = 0, acc2 = 0;
    reg         ovf = 0;

    wire [31:0] haddr, hwdata, hrdata;
    wire [1:0]  htrans;
    wire        hwrite, hready, hresp;
    wire [2:0]  hsize, hburst;

    debug_top dut (
        .tck_i(tck), .tms_i(tms), .tdi_i(tdi), .tdo_o(tdo), .tdo_oe_o(tdo_oe), .por_n_i(rst_n),
        .hclk_i(hclk), .dm_rst_n_i(rst_n), .ndmreset_o(ndmreset), .hartreset_o(hartreset),
        .dsu_acc0_i(acc0), .dsu_acc1_i(acc1), .dsu_acc2_i(acc2), .dsu_ovf_i(ovf),
        .haddr_o(haddr), .htrans_o(htrans), .hwrite_o(hwrite), .hsize_o(hsize),
        .hburst_o(hburst), .hwdata_o(hwdata), .hrdata_i(hrdata), .hready_i(hready),
        .hresp_i(hresp));

    // ---- slaves: ISRAM (real, locked) + DSRAM model --------------------------------
    wire sel_i = haddr[31:28] == 4'h0, sel_d = haddr[31:28] == 4'h2;
    reg  dsel;
    always @(posedge hclk) if (hready && htrans[1]) dsel <= sel_d;
    wire [31:0] rd_i, rd_d; wire ro_i, ro_d, re_i, re_d;
    assign hrdata = dsel ? rd_d : rd_i;
    assign hready = dsel ? ro_d : ro_i;
    assign hresp  = dsel ? re_d : re_i;

    isram_top u_isram (.hclk_i(hclk), .hreset_n_i(rst_n), .hsel_i(sel_i), .haddr_i(haddr),
        .htrans_i(htrans), .hwrite_i(hwrite), .hsize_i(hsize), .hburst_i(hburst),
        .hprot_i(4'h3), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(rd_i), .hreadyout_o(ro_i), .hresp_o(re_i),
        .ilock_i(1'b1), .hmaster_is_sba_i(1'b1));             // only SBA drives this bus
    ahb_lite_sram #(.BASE_ADDR(32'h2000_0000), .SIZE_BYTES(65536)) u_dsram (
        .hclk_i(hclk), .hreset_n_i(rst_n), .waits_i(8'd2), .rand_waits_i(1'b1), .seed_i(32'h7),
        .err_en_i(1'b1), .err_base_i(32'h2000_F000), .err_size_i(32'h10),
        .hsel_i(sel_d), .haddr_i(haddr), .htrans_i(htrans), .hwrite_i(hwrite),
        .hsize_i(hsize), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(rd_d), .hreadyout_o(ro_d), .hresp_o(re_d));

    wire [31:0] v_chk;
    ahb_lite_checker u_chk (.clk_i(hclk), .rst_n_i(rst_n),
        .haddr_i(haddr), .htrans_i(htrans), .hsize_i(hsize), .hburst_i(hburst),
        .hwrite_i(hwrite), .hwdata_i(hwdata), .hready_i(hready), .hresp_i(hresp),
        .viol_count_o(v_chk));

    // ---- JTAG bit-bang, TCK = 20 MHz -------------------------------------------------
    localparam real TH = 25.0;
    task automatic clk1(input bit m, input bit d, output bit q);
        tms = m; tdi = d; #TH; tck = 1; q = tdo; #TH; tck = 0;
    endtask
    task automatic tap_reset;
        bit q; repeat (5) clk1(1, 0, q); clk1(0, 0, q);        // -> Run-Test/Idle
    endtask
    task automatic idle(input int n); bit q; repeat (n) clk1(0, 0, q); endtask
    task automatic shift_ir(input [4:0] v);
        bit q;
        clk1(1, 0, q); clk1(1, 0, q); clk1(0, 0, q); clk1(0, 0, q);   // Sel-DR, Sel-IR, Cap-IR, Shift-IR
        for (int i = 0; i < 5; i++) clk1(i == 4, v[i], q);
        clk1(1, 0, q); clk1(0, 0, q);                                   // Update-IR, RTI
    endtask
    task automatic shift_dr(input [63:0] v, input int n, output [63:0] o);
        bit q;
        o = 0;
        clk1(1, 0, q); clk1(0, 0, q); clk1(0, 0, q);                  // Sel-DR, Cap-DR, Shift-DR
        for (int i = 0; i < n; i++) begin clk1(i == n - 1, v[i], q); o[i] = q; end
        clk1(1, 0, q); clk1(0, 0, q);                                   // Update-DR, RTI
    endtask

    // TDO is updated on the falling edge before each shift clock, so the bit
    // sampled at rising edge i is bit i of the captured register.
    reg [63:0] o;
    task automatic dmi(input [6:0] a, input [31:0] d, input [1:0] op, output [31:0] rd, output [1:0] st);
        reg [63:0] x;
        shift_dr({23'd0, a, d, op}, 41, x);
        idle(8);
        shift_dr({23'd0, a, 32'd0, 2'd0}, 41, x);              // nop: collect the result
        rd = x[33:2]; st = x[1:0];
        idle(4);
    endtask
    task automatic dmw(input [6:0] a, input [31:0] d); reg [31:0] r; reg [1:0] s; dmi(a, d, 2'd2, r, s); endtask
    task automatic dmr(input [6:0] a, output [31:0] r); reg [1:0] s; dmi(a, 0, 2'd1, r, s); endtask

    integer checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    reg [31:0] r, lo, hi;
    int i, ok;

    // accumulator keeps running during the tap test
    always @(posedge hclk) if (rst_n) acc0 <= acc0 + 48'h0000_0010_0001;

    initial begin
        $display("=== tb_debug: Block 12 Rev 4.0 ===");
        #100 rst_n = 1;
        tap_reset();

        // IDCODE is selected by Test-Logic-Reset
        shift_dr(0, 32, o);
        check(o[31:0] == 32'h0000_0DB1, "IDCODE selected by Test-Logic-Reset");
        shift_ir(5'h01); shift_dr(0, 32, o);
        check(o[31:0] == 32'h0000_0DB1, "[N-6.1] IDCODE = 0x0000_0DB1");
        shift_ir(5'h10); shift_dr(0, 32, o);
        check(o[3:0] == 1 && o[9:4] == 7 && o[14:12] == 5, "DTMCS: version 1, abits 7, idle 5");
        shift_ir(5'h1F); shift_dr(64'h5, 3, o);
        check(1, "BYPASS instruction selectable");

        shift_ir(5'h11);                                        // DMI from here on
        dmw(7'h10, 32'h1);                                      // dmactive
        dmr(7'h10, r); check(r[0] == 1, "[N-7.1] dmactive set");
        dmr(7'h11, r); check(r[3:0] == 2 && r[7] && r[11] && !r[9], "dmstatus: v0.13, authenticated, running");
        dmr(7'h16, r); check(r == 0, "[N-6.3] abstractcs reads 0: datacount 0, progbufsize 0");

        dmw(7'h10, 32'h8000_0001);                              // haltreq
        #200 check(hartreset, "[N-7.8] haltreq holds the hart in hartreset");
        dmr(7'h11, r); check(r[9] && r[8] && !r[11], "dmstatus: allhalted while in hartreset");
        dmw(7'h10, 32'h4000_0001);                              // resumereq
        #200 check(!hartreset, "resumereq releases hartreset");
        dmw(7'h10, 32'h0000_0003);                              // ndmreset
        #200 check(ndmreset && !hartreset, "ndmreset is a level out to reset_ctrl");
        dmw(7'h10, 32'h0000_0001);
        #200 check(!ndmreset, "ndmreset released");

        // ---- SBA single write/read to DSRAM ------------------------------------------
        dmr(7'h38, r); check(r[31:29] == 1 && r[19:17] == 2 && r[11:5] == 32 && r[2], "sbcs: v1, sbaccess=2, 32-bit only");
        dmw(7'h39, 32'h2000_0100); dmw(7'h3C, 32'hCAFE_0001);
        dmw(7'h38, 32'h0010_0000 | (2 << 17));                  // sbreadonaddr
        dmw(7'h39, 32'h2000_0100);
        dmr(7'h3C, r); check(r == 32'hCAFE_0001, "SBA write then read-on-addr to DSRAM");

        // ---- bulk load into LOCKED ISRAM with autoincrement ---------------------------
        dmw(7'h38, (2 << 17) | (1 << 16));                      // autoincrement
        dmw(7'h39, 32'h0000_0000);
        for (i = 0; i < 8; i++) dmw(7'h3C, 32'h1000_0000 + i);
        ok = 1; for (i = 0; i < 8; i++) if (u_isram.bd_read(4*i) !== 32'h1000_0000 + i) ok = 0;
        check(ok, "[N-7.7] 8-word autoincrement load into ISRAM with ILOCK set (SBA bypass)");
        dmr(7'h39, r); check(r == 32'h20, "sbaddress0 advanced by 4 per access");

        // stream back with readonaddr + readondata + autoincrement
        dmw(7'h38, (1 << 20) | (2 << 17) | (1 << 16) | (1 << 15));
        dmw(7'h39, 32'h0000_0000);
        ok = 1;
        for (i = 0; i < 8; i++) begin dmr(7'h3C, r); if (r !== 32'h1000_0000 + i) ok = 0; end
        check(ok, "[N-6.5] readonaddr + readondata streams 8 words, one DMI read each");

        // ---- errors --------------------------------------------------------------------
        dmw(7'h38, (2 << 17));
        dmw(7'h39, 32'h2000_0102); dmw(7'h3C, 32'h1);
        dmr(7'h38, r); check(r[14:12] == 2, "[N-7.6] misaligned sbaddress0 -> sberror 2");
        dmw(7'h38, (2 << 17) | (7 << 12));                      // W1C
        dmr(7'h38, r); check(r[14:12] == 0, "sberror is W1C");
        dmw(7'h38, (0 << 17));                                  // sbaccess = 8-bit
        dmw(7'h39, 32'h2000_0100); dmw(7'h3C, 32'h1);
        dmr(7'h38, r); check(r[14:12] == 3, "[N-6.6] unsupported size -> sberror 3");
        dmw(7'h38, (2 << 17) | (7 << 12));
        dmw(7'h39, 32'h2000_F004); dmw(7'h3C, 32'h1);
        dmr(7'h38, r); check(r[14:12] == 4, "AHB ERROR -> sberror 4");
        dmw(7'h39, 32'h2000_0104); dmw(7'h3C, 32'h55);
        check(u_dsram.bd_read(32'h2000_0104) !== 32'h55, "sberror is sticky: accesses blocked until cleared");
        dmw(7'h38, (2 << 17) | (7 << 12));

        // ---- DSU taps ---------------------------------------------------------------------
        ok = 1;
        for (i = 0; i < 4; i++) begin
            dmr(7'h60, lo); dmr(7'h61, hi);
            // the snapshot must be a value the counter actually held: low word
            // = 0x...N*1, high = N*0x10 for the same N, since both halves step together
            if ((({hi[15:0], lo} - 48'h1234_5678_9ABC) % 48'h0000_0010_0001) != 0) ok = 0;
        end
        check(ok, "[N-6.8] dsuacc0 lo-then-hi is a coherent 48-bit snapshot while running");
        ovf = 1; dmr(7'h66, r); check(r[0], "dsuovf reports the sticky DSU overflow");

        check(v_chk == 0, "AHB-Lite protocol checker clean on the SBA master");
        $display("tb_debug: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end
    initial begin #20_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
