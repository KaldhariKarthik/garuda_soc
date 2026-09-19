`timescale 1ns/1ps
// =============================================================================
// tb_dma_top.sv -- Block 9 DMA controller, Rev 3.0 smoke
//
// Spec: GARUDA-DMA-SPEC-001 Rev 3.0 §11. hclk 250 MHz, pclk = hclk/2 on shared
// edges (the production relationship). Two AHB SRAM models stand in for DSRAM
// (0x2000_0000) and a peripheral data window (0x4000_0000); an AHB-Lite
// protocol checker watches the M3 port.
//   M2M word copy, completion status/IRQ/GSTAT, ICLR
//   P2M with a pclk-domain request/ack peripheral: one beat per request
//   byte beats with arbitrary source/destination alignment
//   AHB ERROR on read: ERRPHASE, freeze of SAR/REMAINING, error IRQ
//   R-9: DAR in ISRAM refused with ERRPHASE=write and no bus write
//   priority: ch0 (IMU, 5) beats ch5 (console, 0)
//   MODE=3 write rejected, PSLVERR on unmapped/RO offsets
// =============================================================================
module tb_dma_top;
    reg hclk = 0, pclk = 0, rst_n = 0;
    always #2 hclk = ~hclk;
    always @(posedge hclk) pclk <= ~pclk;

    // ---- APB -------------------------------------------------------------------
    reg        psel = 0, penable = 0, pwrite = 0;
    reg [11:0] paddr = 0;
    reg [31:0] pwdata = 0;
    wire [31:0] prdata;
    wire        pready, pslverr;

    // ---- AHB --------------------------------------------------------------------
    wire [31:0] haddr, hwdata, hrdata;
    wire [1:0]  htrans;
    wire        hwrite, hready, hresp;
    wire [2:0]  hsize, hburst;

    reg  [5:0]  req = 0;
    wire [5:0]  ack, comp, err;

    dma_top dut (
        .hclk_i(hclk), .hreset_n_i(rst_n), .pclk_i(pclk), .preset_n_i(rst_n),
        .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite), .paddr_i(paddr),
        .pwdata_i(pwdata), .prdata_o(prdata), .pready_o(pready), .pslverr_o(pslverr),
        .haddr_o(haddr), .htrans_o(htrans), .hwrite_o(hwrite), .hsize_o(hsize),
        .hburst_o(hburst), .hwdata_o(hwdata), .hrdata_i(hrdata), .hready_i(hready),
        .hresp_i(hresp), .dma_req_i(req), .dma_ack_o(ack),
        .dma_complete_o(comp), .dma_error_o(err));

    // ---- slaves -----------------------------------------------------------------
    wire sel_d = haddr[31:28] == 4'h2, sel_p = haddr[31:28] == 4'h4;
    reg  dsel;                                    // 1 = peripheral window in data phase
    always @(posedge hclk) if (hready && htrans[1]) dsel <= sel_p;
    wire [31:0] rd_d, rd_p; wire ro_d, ro_p, re_d, re_p;
    assign hrdata = dsel ? rd_p : rd_d;
    assign hready = dsel ? ro_p : ro_d;
    assign hresp  = dsel ? re_p : re_d;
    reg        err_en = 0;
    reg [31:0] err_base = 0;

    ahb_lite_sram #(.BASE_ADDR(32'h2000_0000), .SIZE_BYTES(65536)) u_dsram (
        .hclk_i(hclk), .hreset_n_i(rst_n), .waits_i(8'd1), .rand_waits_i(1'b1), .seed_i(32'h1234),
        .err_en_i(err_en), .err_base_i(err_base), .err_size_i(32'd4),
        .hsel_i(sel_d), .haddr_i(haddr), .htrans_i(htrans), .hwrite_i(hwrite),
        .hsize_i(hsize), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(rd_d), .hreadyout_o(ro_d), .hresp_o(re_d));
    ahb_lite_sram #(.BASE_ADDR(32'h4000_0000), .SIZE_BYTES(65536)) u_periph (
        .hclk_i(hclk), .hreset_n_i(rst_n), .waits_i(8'd3), .rand_waits_i(1'b0), .seed_i(32'h55),
        .err_en_i(1'b0), .err_base_i(32'h0), .err_size_i(32'h0),
        .hsel_i(sel_p), .haddr_i(haddr), .htrans_i(htrans), .hwrite_i(hwrite),
        .hsize_i(hsize), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(rd_p), .hreadyout_o(ro_p), .hresp_o(re_p));

    wire [31:0] v_chk;
    ahb_lite_checker u_chk (.clk_i(hclk), .rst_n_i(rst_n),
        .haddr_i(haddr), .htrans_i(htrans), .hsize_i(hsize), .hburst_i(hburst),
        .hwrite_i(hwrite), .hwdata_i(hwdata), .hready_i(hready), .hresp_i(hresp),
        .viol_count_o(v_chk));

    // monitors
    integer isram_touch = 0;
    always @(posedge hclk) if (rst_n && htrans[1] && haddr[31:29] == 3'b000) isram_touch++;
    integer both_seen = 0, wrong_order = 0;
    always @(posedge hclk)
        if (rst_n && dut.eligible[0] && dut.eligible[5] && dut.u_eng.st == 3'd0) begin
            both_seen++;
            if (dut.grant_ch != 3'd0) wrong_order++;
        end

    // ---- peripheral model for channel 0 (pclk domain, level req, ack clears) ----
    integer p_items = 0, p_acks = 0;
    always @(posedge pclk) begin
        if (ack[0]) begin req[0] <= 1'b0; p_acks++; end
        else if (p_items > 0 && !req[0]) begin req[0] <= 1'b1; p_items--; end
    end

    // ---- helpers -----------------------------------------------------------------
    integer checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask
    task automatic wr(input [11:0] a, input [31:0] d, output bit e);
        @(posedge pclk); #0.1 psel = 1; pwrite = 1; paddr = a; pwdata = d; penable = 0;
        @(posedge pclk); #0.1 penable = 1; #0.5 e = pslverr;
        @(posedge pclk); #0.1 psel = 0; penable = 0; pwrite = 0;
    endtask
    task automatic rd(input [11:0] a, output [31:0] d);
        @(posedge pclk); #0.1 psel = 1; pwrite = 0; paddr = a; penable = 0;
        @(posedge pclk); #0.1 penable = 1; #0.5 d = prdata;
        @(posedge pclk); #0.1 psel = 0; penable = 0;
    endtask
    function automatic [11:0] R(input int ch, input int off); return 12'h20 * ch + off; endfunction
    localparam CR = 'h00, SAR = 'h04, DAR = 'h08, CNT = 'h0C, STAT = 'h10, ICLR = 'h14;
    // CR fields
    function automatic [31:0] crv(input bit en, input [1:0] mode, input bit sinc, input bit dinc,
                                  input [1:0] size, input bit iec, input bit iee);
        return {23'd0, iee, iec, size, dinc, sinc, mode, en};
    endfunction
    task automatic wait_done(input int ch, input int maxc);
        int g = 0;
        reg [31:0] s;
        do begin rd(R(ch, STAT), s); g++; end while (s[16] && g < maxc);
    endtask

    reg [31:0] d; bit e; int i, ok;

    initial begin
        $display("=== tb_dma_top: Block 9 Rev 3.0 ===");
        repeat (4) @(posedge hclk); rst_n = 1; repeat (2) @(posedge hclk);

        rd(12'h100, d); check(d == 0, "reset: all channels idle (GSTAT = 0)");
        rd(R(0, CR), d); check(d[0] == 0 && d[6:5] == 2'd2, "reset: EN = 0, SIZE = word");

        // ---- 1. M2M word copy, ch2 ------------------------------------------------
        for (i = 0; i < 16; i++) u_dsram.bd_write(32'h2000_1000 + 4*i, 32'hA5A5_0000 + i);
        wr(R(2, SAR), 32'h2000_1000, e); wr(R(2, DAR), 32'h2000_2000, e); wr(R(2, CNT), 16, e);
        wr(R(2, CR), crv(1, 2'd2, 1, 1, 2'd2, 1, 1), e);
        wait_done(2, 400);
        ok = 1; for (i = 0; i < 16; i++) if (u_dsram.bd_read(32'h2000_2000 + 4*i) !== 32'hA5A5_0000 + i) ok = 0;
        check(ok, "M2M: 16 words copied");
        rd(R(2, STAT), d);
        check(d[15:0] == 0 && d[17] && !d[16] && !d[18], "STAT: REMAINING 0, COMPLETE, not ACTIVE (R-6)");
        rd(R(2, CR), d); check(d[0] == 0, "EN cleared by hardware on completion");
        rd(R(2, SAR), d); check(d == 32'h2000_1040, "SAR advanced 16 x 4");
        check(comp[2] && !err[2], "[N-7.4] complete IRQ (CLIC ID 3) asserted, level");
        rd(12'h100, d); check(d[10] && !d[2], "GSTAT: COMPLETE[2]");
        wr(R(2, ICLR), 32'h1, e);
        repeat (2) @(posedge hclk);
        check(!comp[2], "ICLR clears COMPLETE and the IRQ");

        // ---- 2. P2M on ch0 with the request/ack handshake ------------------------------
        for (i = 0; i < 8; i++) u_periph.bd_write(32'h4000_1000, 0);
        wr(R(0, SAR), 32'h4000_1000, e); wr(R(0, DAR), 32'h2000_3000, e); wr(R(0, CNT), 8, e);
        wr(R(0, CR), crv(1, 2'd0, 0, 1, 2'd2, 1, 0), e);
        for (i = 0; i < 8; i++) begin
            u_periph.bd_write(32'h4000_1000, 32'hD00D_0000 + i);
            p_items = 1;
            wait (p_acks == i + 1);
            repeat (4) @(posedge pclk);
        end
        wait_done(0, 200);
        ok = 1; for (i = 0; i < 8; i++) if (u_dsram.bd_read(32'h2000_3000 + 4*i) !== 32'hD00D_0000 + i) ok = 0;
        check(ok, "P2M: 8 peripheral words landed in order, SINC=0 DINC=1");
        check(p_acks == 8, "[N-7.10] exactly one beat (one ack) per request assertion");
        wr(R(0, ICLR), 32'h3, e);

        // ---- 3. byte beats, odd alignment -----------------------------------------------
        u_dsram.bd_write(32'h2000_0100, 32'h4433_2211);
        u_dsram.bd_write(32'h2000_0104, 32'h8877_6655);
        u_dsram.bd_write(32'h2000_0300, 32'hFFFF_FFFF);
        u_dsram.bd_write(32'h2000_0304, 32'hFFFF_FFFF);
        wr(R(1, SAR), 32'h2000_0101, e); wr(R(1, DAR), 32'h2000_0302, e); wr(R(1, CNT), 5, e);
        wr(R(1, CR), crv(1, 2'd2, 1, 1, 2'd0, 0, 0), e);
        wait_done(1, 400);
        check(u_dsram.bd_read(32'h2000_0300) == 32'h3322_FFFF &&
              u_dsram.bd_read(32'h2000_0304) == 32'hFF66_5544, "byte beats: 5 bytes 0x..101 -> 0x..302");
        wr(R(1, ICLR), 32'h3, e);

        // ---- 4. AHB ERROR on the read --------------------------------------------------------
        err_en = 1; err_base = 32'h2000_4008;
        wr(R(3, SAR), 32'h2000_4000, e); wr(R(3, DAR), 32'h2000_5000, e); wr(R(3, CNT), 6, e);
        wr(R(3, CR), crv(1, 2'd2, 1, 1, 2'd2, 0, 1), e);
        wait_done(3, 400);
        err_en = 0;
        rd(R(3, STAT), d);
        check(d[18] && d[21:19] == 3'd1 && !d[17], "[N-7.13] ERROR, ERRPHASE = read, not COMPLETE");
        check(d[15:0] == 4, "[N-7.15] REMAINING frozen at the failure point (4 of 6 left)");
        rd(R(3, SAR), d); check(d == 32'h2000_4008, "SAR frozen at the failing address");
        check(err[3], "error IRQ (CLIC ID 10) asserted");
        wr(R(3, ICLR), 32'h2, e);
        rd(R(3, STAT), d); check(!d[18] && d[21:19] == 0, "ICLR clears ERROR and ERRPHASE");

        // ---- 5. R-9: destination in ISRAM refused ------------------------------------------------
        isram_touch = 0;
        wr(R(4, SAR), 32'h2000_1000, e); wr(R(4, DAR), 32'h0000_1000, e); wr(R(4, CNT), 2, e);
        wr(R(4, CR), crv(1, 2'd2, 1, 1, 2'd2, 0, 1), e);
        wait_done(4, 200);
        rd(R(4, STAT), d);
        check(d[18] && d[21:19] == 3'd2, "R-9: DAR in ISRAM -> ERROR, ERRPHASE = write");
        check(isram_touch == 0, "R-9: no AHB transfer ever addressed ISRAM/Boot ROM");
        wr(R(4, ICLR), 32'h3, e);

        // ---- 6. priority: ch0 (5) beats ch5 (0) ----------------------------------------------------
        wr(R(5, SAR), 32'h2000_1000, e); wr(R(5, DAR), 32'h2000_6000, e); wr(R(5, CNT), 4, e);
        wr(R(0, SAR), 32'h2000_1000, e); wr(R(0, DAR), 32'h2000_7000, e); wr(R(0, CNT), 4, e);
        wr(R(0, CR), crv(0, 2'd2, 1, 1, 2'd2, 0, 0), e);         // MODE = M2M, not yet enabled
        // enable both in the same hclk cycle by forcing the strobes' effect via two quick writes
        fork
            wr(R(5, CR), crv(1, 2'd2, 1, 1, 2'd2, 0, 0), e);
            begin @(posedge pclk); @(posedge pclk); @(posedge pclk); end
        join
        wr(R(0, CR), crv(1, 2'd2, 1, 1, 2'd2, 0, 0), e);
        wait_done(5, 200); wait_done(0, 200);
        check(u_dsram.bd_read(32'h2000_7000) == 32'hA5A5_0000 && u_dsram.bd_read(32'h2000_600C) == 32'hA5A5_0003,
              "both M2M channels completed");
        check(both_seen > 0 && wrong_order == 0,
              $sformatf("[N-7.11] ch0 (prio 5) always granted over ch5 (prio 0) - %0d contested cycles", both_seen));

        // ---- 7. register rules ---------------------------------------------------------------------
        wr(R(2, CR), crv(0, 2'd1, 0, 0, 2'd2, 0, 0), e);          // MODE = M2P
        wr(R(2, CR), crv(0, 2'd3, 0, 0, 2'd2, 0, 0), e);          // MODE = 3 (reserved)
        rd(R(2, CR), d); check(d[2:1] == 2'd1, "[N-6.1] MODE = 3 write leaves MODE unchanged");
        wr(12'h0C0, 32'h0, e); check(e, "PSLVERR on unmapped offset (channel 6)");
        wr(R(1, STAT), 32'h0, e); check(e, "PSLVERR on a write to read-only STAT");

        check(v_chk == 0, "AHB-Lite protocol checker clean on M3");

        $display("tb_dma_top: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end
    initial begin #2_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
