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
// Added 2026-10-04 (sections 8-19), written from the spec text:
//   every channel x every beat size; M2P; R-9 on both regions and both phases
//   AHB ERROR on the write, isolation (R-8), no retry
//   a request that outlives a failed beat (DMA-8)
//   cycle-exact collisions: ICLR against the flag set (old DMA-6), a CR write
//   against the hardware EN clear (R-7 / D-2, [N-11.2])
//   STAT exact on every read, including the read behind the arming write
//   (old DMA-4); back-to-back APB accesses (old DMA-5)
//   all 15 channel pairs requesting in one cycle; per-beat re-arbitration;
//   a request withdrawn before grant; CNT = 0 and 1; EN cleared mid-transfer
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
    // wait states are testbench-controlled so the collision sweeps can place a
    // beat on either hclk phase; the defaults are the original constants
    reg [7:0]  d_waits = 8'd1, p_waits = 8'd3;
    reg        d_rand  = 1'b1;

    ahb_lite_sram #(.BASE_ADDR(32'h2000_0000), .SIZE_BYTES(65536)) u_dsram (
        .hclk_i(hclk), .hreset_n_i(rst_n), .waits_i(d_waits), .rand_waits_i(d_rand), .seed_i(32'h1234),
        .err_en_i(err_en), .err_base_i(err_base), .err_size_i(32'd4),
        .hsel_i(sel_d), .haddr_i(haddr), .htrans_i(htrans), .hwrite_i(hwrite),
        .hsize_i(hsize), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(rd_d), .hreadyout_o(ro_d), .hresp_o(re_d));
    ahb_lite_sram #(.BASE_ADDR(32'h4000_0000), .SIZE_BYTES(65536)) u_periph (
        .hclk_i(hclk), .hreset_n_i(rst_n), .waits_i(p_waits), .rand_waits_i(1'b0), .seed_i(32'h55),
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

    // ---- requesters for channels 1..5: a level request drops when the beat is
    //      acknowledged ([N-7.7]); the test raises req[n] itself -----------------------
    integer acks [0:5];
    integer ack_w [0:5];
    integer first_ack = -1, ack_wbad = 0;
    initial for (int n = 0; n < 6; n++) begin acks[n] = 0; ack_w[n] = 0; end
    always @(posedge pclk) for (int n = 0; n < 6; n++) if (ack[n]) begin
        acks[n] = acks[n] + 1;
        if (first_ack < 0) first_ack = n;
        if (n != 0) req[n] <= 1'b0;
    end
    // dma_ack width in hclk cycles: one pclk period (DECISIONS D-16)
    always @(posedge hclk) for (int n = 0; n < 6; n++) begin
        if (ack[n]) ack_w[n] = ack_w[n] + 1;
        else begin
            if (ack_w[n] != 0 && ack_w[n] != 2) ack_wbad = ack_wbad + 1;
            ack_w[n] = 0;
        end
    end

    // ---- M3 transfer monitor: counts, read/write pairing, SINGLE only ------------------
    integer n_rd = 0, n_wr = 0, split = 0, pair_bad = 0, burst_seen = 0, arm_idx = -1;
    bit        last_was_rd = 0, ord_en = 0;
    reg [31:0] last_rd_addr = 0;
    int        ord [$];                       // owner (by address range) of each accepted read
    always @(posedge hclk) if (rst_n) begin
        if (|dut.beat_err) last_was_rd = 0;   // an aborted beat has no write half
        if (hburst !== 3'b000 || htrans === 2'b11 || htrans === 2'b01) burst_seen = burst_seen + 1;
        if (ord_en && dut.wr_cr[0] && arm_idx < 0) arm_idx = ord.size();
        if (hready && htrans[1]) begin
            if (!hwrite) begin
                n_rd = n_rd + 1;
                if (last_was_rd) split = split + 1;
                last_was_rd = 1; last_rd_addr = haddr;
                if (ord_en) ord.push_back(haddr[15:12] == 4'hA ? 0 : 5);
            end else begin
                n_wr = n_wr + 1;
                if (!last_was_rd) split = split + 1;
                if (ord_en && ((last_rd_addr[15:12] == 4'h8 && haddr[15:12] != 4'h9) ||
                               (last_rd_addr[15:12] == 4'hA && haddr[15:12] != 4'hB))) pair_bad = pair_bad + 1;
                last_was_rd = 0;
            end
        end
    end

    // ---- cycle-exact event monitor for the collision sweeps (channel 1) -----------------
    // Records WHEN the write strobe and the hardware event happened so each sweep
    // point can be classified before / same cycle / after; the expected result
    // for each class comes from the spec ([N-7.17], [N-7.19], §6.2 "sticky").
    longint cyc = 0;
    always @(posedge hclk) cyc <= cyc + 1;
    longint c_iclr = -1, c_done = -1, c_berr = -1, c_cr = -1;
    integer coll_comp = 0, coll_err = 0, coll_en = 0, n_wstb = 0;
    bit     comp1_seen = 0, err1_seen = 0;
    wire    last1 = (dut.stat[32 +: 16] == 16'd1);
    always @(posedge hclk) if (rst_n) begin
        if (dut.u_apb.wstb) n_wstb = n_wstb + 1;
        if (dut.wr_iclr[1]) c_iclr = cyc;
        if (dut.wr_cr[1])   c_cr   = cyc;
        if (dut.beat_done[1] && last1 && c_done < 0) c_done = cyc;
        if (dut.beat_err[1]) c_berr = cyc;
        if (dut.wr_iclr[1] && dut.wdata[0] && dut.beat_done[1] && last1) coll_comp = coll_comp + 1;
        if (dut.wr_iclr[1] && dut.wdata[1] && dut.beat_err[1])           coll_err  = coll_err + 1;
        if (dut.wr_cr[1] && ((dut.beat_done[1] && last1) || dut.beat_err[1])) coll_en = coll_en + 1;
        if (comp[1]) comp1_seen = 1;
        if (err[1])  err1_seen  = 1;
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
    // back-to-back APB: no idle cycle - the next setup phase starts on the pclk
    // edge that ends this access. Call on a pclk edge; finish with apb_idle().
    task automatic wr_bb(input [11:0] a, input [31:0] d);
        #0.1 psel = 1; pwrite = 1; paddr = a; pwdata = d; penable = 0;
        @(posedge pclk); #0.1 penable = 1;
        @(posedge pclk);
    endtask
    integer nwr_cap = 0;
    task automatic rd_bb(input [11:0] a, output [31:0] d);
        #0.1 psel = 1; pwrite = 0; paddr = a; penable = 0;
        @(posedge pclk); nwr_cap = n_wr; #0.1 penable = 1;
        @(posedge pclk); d = prdata;          // sampled at the edge that ends the access, as the bridge does
    endtask
    task automatic apb_idle();
        #0.1 psel = 0; penable = 0; pwrite = 0;
    endtask
    function automatic [11:0] R(input int ch, input int off); return 12'h20 * ch + off; endfunction
    function automatic [7:0] byte_at(input [31:0] a);
        reg [31:0] w;
        w = u_dsram.bd_read({a[31:2], 2'b00});
        return w >> (8 * a[1:0]);
    endfunction
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
    reg [31:0] d1, d2, d3;
    reg [7:0]  exp8;
    int ch, sz, k, wd, wp, bad, ibad, nr0, nw0, a0, nearly, nlate, n0, n5, first0, last0, prev, nreads;
    int prio_spec [6] = '{5, 3, 1, 2, 4, 0};     // GARUDA-DMA-SPEC-001 §6.3, channel 0..5
    task automatic prog(input int c, input [31:0] s_, input [31:0] d_, input [15:0] n_);
        bit e_;
        wr(R(c, SAR), s_, e_); wr(R(c, DAR), d_, e_); wr(R(c, CNT), {16'd0, n_}, e_);
    endtask

    initial begin
        $display("=== tb_dma_top: Block 9 Rev 3.0 ===");
        repeat (4) @(posedge hclk); rst_n = 1; repeat (2) @(posedge hclk);

        rd(12'h100, d); check(d == 0, "reset: all channels idle (GSTAT = 0)");
        rd(R(0, CR), d); check(d[0] == 0 && d[6:5] == 2'd2, "reset: EN = 0, SIZE = word");
        ok = 1;
        for (i = 0; i < 6; i++) begin
            rd(R(i, CR), d);   if (d[0] !== 1'b0 || d[4:1] !== 4'd0 || d[6:5] !== 2'd2 || d[31:7] !== 25'd0) ok = 0;
            rd(R(i, SAR), d);  if (d !== 32'd0) ok = 0;
            rd(R(i, DAR), d);  if (d !== 32'd0) ok = 0;
            rd(R(i, CNT), d);  if (d !== 32'd0) ok = 0;
            rd(R(i, STAT), d); if (d !== 32'd0) ok = 0;
        end
        check(ok && comp == 0 && err == 0 && ack == 0 && htrans == 2'b00,
              "[N-9.2] reset: all six channels disabled, CR fields/SAR/DAR/CNT/STAT at reset values, no IRQ, no ack, M3 idle");

        // ---- 1. M2M word copy, ch2 ------------------------------------------------
        for (i = 0; i < 16; i++) u_dsram.bd_write(32'h2000_1000 + 4*i, 32'hA5A5_0000 + i);
        wr(R(2, SAR), 32'h2000_1000, e); wr(R(2, DAR), 32'h2000_2000, e); wr(R(2, CNT), 16, e);
        wr(R(2, CR), crv(1, 2'd2, 1, 1, 2'd2, 1, 1), e);
        wait_done(2, 400);
        ok = 1; for (i = 0; i < 16; i++) if (u_dsram.bd_read(32'h2000_2000 + 4*i) !== 32'hA5A5_0000 + i) ok = 0;
        check(ok, "[N-7.5] M2M: 16 words copied with no peripheral request");
        rd(R(2, STAT), d);
        check(d[15:0] == 0 && d[17] && !d[16] && !d[18], "[R-6] [N-7.3] STAT: REMAINING 0, COMPLETE, not ACTIVE");
        rd(R(2, CR), d); check(d[0] == 0, "[N-7.3] EN cleared by hardware on completion");
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
        check(ok, "[N-7.1] [N-7.9] P2M: 8 peripheral words landed in order from a pclk-domain requester, SINC=0 DINC=1");
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
        rd(R(3, SAR), d); check(d == 32'h2000_4008, "[N-7.15] SAR frozen at the failing address");
        check(err[3], "[N-7.13] error IRQ (CLIC ID 10) asserted");
        wr(R(3, ICLR), 32'h2, e);
        rd(R(3, STAT), d); check(!d[18] && d[21:19] == 0, "ICLR clears ERROR and ERRPHASE");

        // ---- 5. R-9: destination in ISRAM refused ------------------------------------------------
        isram_touch = 0;
        wr(R(4, SAR), 32'h2000_1000, e); wr(R(4, DAR), 32'h0000_1000, e); wr(R(4, CNT), 2, e);
        wr(R(4, CR), crv(1, 2'd2, 1, 1, 2'd2, 0, 1), e);
        wait_done(4, 200);
        rd(R(4, STAT), d);
        check(d[18] && d[21:19] == 3'd2, "[R-9] [N-6.3] DAR in ISRAM -> ERROR, ERRPHASE = write");
        check(isram_touch == 0, "[R-9] [N-7.20] no AHB transfer ever addressed ISRAM/Boot ROM");
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

        // ====================================================================================
        // Added 2026-10-04. Expected values below come from GARUDA-DMA-SPEC-001, not the RTL.
        // ====================================================================================

        // ---- 8. every channel, every beat size, M2M (R-1, R-2), and its interrupt line (R-5) ----
        bad = 0; ibad = 0;
        for (ch = 0; ch < 6; ch++) for (sz = 0; sz < 3; sz++) begin
            for (i = 0; i < 4; i++) begin
                u_dsram.bd_write(32'h2000_8000 + 4*i, 32'h1020_3040 * (ch + 1) + 32'h0101_0101 * i + sz);
                u_dsram.bd_write(32'h2000_9000 + 4*i, 32'hFFFF_FFFF);
            end
            prog(ch, 32'h2000_8000, 32'h2000_9000, 4);
            wr(R(ch, CR), crv(1, 2'd2, 1, 1, sz[1:0], 1, 1), e);
            wait_done(ch, 400);
            for (i = 0; i < 16; i++) begin
                exp8 = (i < (4 << sz)) ? byte_at(32'h2000_8000 + i) : 8'hFF;
                if (byte_at(32'h2000_9000 + i) !== exp8) bad++;
            end
            rd(R(ch, SAR), d);  if (d !== 32'h2000_8000 + (4 << sz)) bad++;
            rd(R(ch, DAR), d);  if (d !== 32'h2000_9000 + (4 << sz)) bad++;
            rd(R(ch, STAT), d); if (d[18:0] !== {1'b0, 1'b1, 1'b0, 16'd0}) bad++;
            if (comp !== (6'd1 << ch) || err !== 6'd0) ibad++;
            wr(R(ch, ICLR), 32'h1, e);
            repeat (2) @(posedge hclk);
            if (comp !== 6'd0) ibad++;
        end
        check(bad == 0, $sformatf("[R-1] [R-2] each of 6 channels x byte/half/word: 4 beats copied exactly, SAR/DAR advanced by the beat size (%0d errors)", bad));
        check(ibad == 0, $sformatf("[R-5] [N-7.3] completion raises only that channel's dma_complete line, until ICLR (%0d errors)", ibad));
        prog(1, 32'h2000_8000, 32'h2000_9000, 2);
        wr(R(1, CR), crv(1, 2'd2, 1, 1, 2'd2, 0, 0), e);
        wait_done(1, 200);
        rd(R(1, STAT), d);
        check(d[17] && comp == 0, "[N-7.3] COMPLETE sets but dma_complete stays low with IE_COMP = 0");
        wr(R(1, ICLR), 32'h3, e);

        // ---- 9. M2P on ch3: one beat per request, none without one ([N-7.1], [N-7.7]) ----
        for (i = 0; i < 4; i++) u_dsram.bd_write(32'h2000_8000 + 4*i, 32'h0D0D_0000 + i);
        u_periph.bd_write(32'h4000_2000, 32'h0);
        prog(3, 32'h2000_8000, 32'h4000_2000, 4);
        nw0 = n_wr;
        wr(R(3, CR), crv(1, 2'd1, 1, 0, 2'd2, 1, 0), e);
        repeat (30) @(posedge hclk);
        ok = (n_wr == nw0);                                  // armed but no request: nothing moves
        for (i = 0; i < 4; i++) begin
            a0 = acks[3];
            @(posedge pclk); #0.1 req[3] = 1'b1;
            for (k = 0; k < 100 && acks[3] == a0; k++) @(posedge pclk);
            repeat (6) @(posedge pclk);
            if (acks[3] != a0 + 1 || u_periph.bd_read(32'h4000_2000) !== 32'h0D0D_0000 + i || req[3]) ok = 0;
        end
        rd(R(3, STAT), d); rd(R(3, DAR), d1);
        check(ok && d[17] && d[15:0] == 0 && d1 == 32'h4000_2000 && n_wr == nw0 + 4,
              "[R-2] [N-7.1] [N-7.7] M2P: no beat without a request, one beat and one ack per request, DINC=0 holds DAR");
        wr(R(3, ICLR), 32'h3, e);

        // ---- 10. R-9 on every channel, both regions, both phases; error interrupt lines ----
        isram_touch = 0; bad = 0; ibad = 0;
        for (ch = 0; ch < 6; ch++) begin
            // source in ISRAM (0x0...) or Boot ROM (0x1...): refused before any transfer
            nr0 = n_rd; nw0 = n_wr;
            prog(ch, ch[0] ? 32'h1000_0040 : 32'h0000_0040, 32'h2000_9000, 3);
            wr(R(ch, CR), crv(1, 2'd2, 1, 1, 2'd2, 1, 1), e);
            wait_done(ch, 100);
            rd(R(ch, STAT), d);
            if (!(d[18] && d[21:19] == 3'd1 && !d[17] && !d[16] && d[15:0] == 3)) bad++;
            rd(R(ch, CR), d); if (d[0]) bad++;
            if (n_rd != nr0 || n_wr != nw0) bad++;
            if (err !== (6'd1 << ch) || comp !== 6'd0) ibad++;
            wr(R(ch, ICLR), 32'h2, e); repeat (2) @(posedge hclk);
            if (err !== 6'd0) ibad++;
            // destination in Boot ROM or ISRAM: the read happens, the write is refused
            nr0 = n_rd; nw0 = n_wr;
            prog(ch, 32'h2000_8000, ch[0] ? 32'h0FFF_FFFC : 32'h1FFF_FFFC, 3);
            wr(R(ch, CR), crv(1, 2'd2, 1, 1, 2'd2, 1, 0), e);         // IE_ERR = 0
            wait_done(ch, 100);
            rd(R(ch, STAT), d);
            if (!(d[18] && d[21:19] == 3'd2 && !d[17] && !d[16] && d[15:0] == 3)) bad++;
            if (n_wr != nw0 || n_rd != nr0 + 1) bad++;
            if (err !== 6'd0) ibad++;                                 // flag set, line masked
            wr(R(ch, ICLR), 32'h2, e);
        end
        check(bad == 0 && isram_touch == 0,
              $sformatf("[R-9] [N-7.20] [N-7.21] SAR or DAR in 0x0.../0x1... on every channel: clean ERROR with the right ERRPHASE, REMAINING frozen, EN clear, no transfer into either region (%0d errors)", bad));
        check(ibad == 0, $sformatf("[R-5] [N-7.13] an error raises only that channel's dma_error line, only with IE_ERR, until ICLR (%0d errors)", ibad));

        // ---- 11. AHB ERROR on the write; a second channel is unaffected (R-8) -----------------
        for (i = 0; i < 8; i++) begin
            u_dsram.bd_write(32'h2000_8000 + 4*i, 32'hBEEF_0000 + i);
            u_dsram.bd_write(32'h2000_A000 + 4*i, 32'hCAFE_0000 + i);
            u_dsram.bd_write(32'h2000_B000 + 4*i, 32'h0);
        end
        prog(3, 32'h2000_8000, 32'h2000_9100, 6);
        prog(2, 32'h2000_A000, 32'h2000_B000, 8);
        err_en = 1; err_base = 32'h2000_9108;                         // ch3's third destination word
        wr(R(2, CR), crv(1, 2'd2, 1, 1, 2'd2, 1, 1), e);
        wr(R(3, CR), crv(1, 2'd2, 1, 1, 2'd2, 1, 1), e);
        wait_done(3, 400); wait_done(2, 400);
        err_en = 0;
        rd(R(3, STAT), d);
        check(d[18] && d[21:19] == 3'd2 && !d[17] && !d[16],
              "[N-6.3] [N-7.13] AHB ERROR on the destination write: ERROR, ERRPHASE = write, not COMPLETE, not ACTIVE");
        check(d[15:0] == 4, "[N-7.13] [N-7.15] REMAINING frozen at the failed write (4 of 6 left)");
        rd(R(3, SAR), d1); rd(R(3, DAR), d2); rd(R(3, CR), d3);
        check(d1 == 32'h2000_8008 && d2 == 32'h2000_9108, "[N-7.15] SAR and DAR hold the failing beat's addresses");
        check(d3[0] == 0 && err[3] && !comp[3], "[N-7.13] EN cleared and dma_error asserted after the write error");
        rd(R(2, STAT), d);
        ok = 1; for (i = 0; i < 8; i++) if (u_dsram.bd_read(32'h2000_B000 + 4*i) !== 32'hCAFE_0000 + i) ok = 0;
        check(ok && d[17] && !d[18] && comp[2] && !err[2],
              "[R-8] [N-7.14] the other channel ran to completion: data intact, no ERROR, no error IRQ");
        nr0 = n_rd; nw0 = n_wr; repeat (60) @(posedge hclk);
        rd(R(3, CR), d);
        check(n_rd == nr0 && n_wr == nw0 && d[0] == 0, "[N-7.16] no automatic retry: M3 idle and EN still clear 60 cycles after the error");
        wr(R(3, ICLR), 32'h3, e); wr(R(2, ICLR), 32'h3, e);

        // ---- 12. a request that outlives a failed beat is served after the re-arm --------------
        // [N-7.7]: the request stays asserted until the beat has been TAKEN. A beat that
        // errored was not taken (no ack), so a peripheral honouring the contract is still
        // requesting when firmware repairs the address and sets EN again.
        u_dsram.bd_write(32'h2000_8000, 32'h7E57_0001);
        u_periph.bd_write(32'h4000_2000, 32'h0);
        prog(3, 32'h0000_0100, 32'h4000_2000, 1);                     // M2P with a bad source
        a0 = acks[3];
        wr(R(3, CR), crv(1, 2'd1, 0, 0, 2'd2, 1, 1), e);
        @(posedge pclk); #0.1 req[3] = 1'b1;
        repeat (20) @(posedge hclk);
        rd(R(3, STAT), d);
        check(d[18] && d[21:19] == 3'd1 && acks[3] == a0 && req[3],
              "M2P beat refused (bad SAR): ERROR, no ack, the peripheral is still requesting");
        wr(R(3, ICLR), 32'h2, e);
        wr(R(3, SAR), 32'h2000_8000, e);
        wr(R(3, CR), crv(1, 2'd1, 0, 0, 2'd2, 1, 1), e);
        for (i = 0; i < 100 && acks[3] == a0; i++) @(posedge pclk);
        repeat (4) @(posedge pclk);
        rd(R(3, STAT), d);
        check(acks[3] == a0 + 1 && d[17] && !d[16] && u_periph.bd_read(32'h4000_2000) === 32'h7E57_0001,
              "[N-7.7] [N-7.10] DMA-8: the still-pending request is served after the re-arm (channel must not hang ACTIVE)");
        req[3] = 1'b0;
        wr(R(3, CR), 32'h0, e); wr(R(3, ICLR), 32'h3, e);

        // ---- 13. ICLR in the cycle the flag sets (the old DMA-6) --------------------------------
        // Source in the peripheral model, destination in DSRAM, fixed waits: wp + wd
        // moves the beat across both hclk phases, k moves the ICLR write across it.
        d_rand = 0; bad = 0; coll_comp = 0; nearly = 0; nlate = 0;
        for (wp = 0; wp < 2; wp++) for (wd = 0; wd < 2; wd++) for (k = 0; k < 8; k++) begin
            p_waits = wp; d_waits = wd;
            prog(1, 32'h4000_3000, 32'h2000_9200, 1);
            repeat (4) @(posedge hclk);
            comp1_seen = 0; c_iclr = -1; c_done = -1;
            @(posedge pclk);
            wr_bb(R(1, CR), crv(1, 2'd2, 0, 0, 2'd2, 1, 1));
            if (k > 0) begin apb_idle(); repeat (k) @(posedge pclk); end
            wr_bb(R(1, ICLR), 32'h1);
            apb_idle();
            repeat (40) @(posedge hclk);
            rd(R(1, STAT), d);
            if (c_done < 0 || c_iclr < 0 || !comp1_seen) bad++;
            else if (c_iclr <= c_done) begin nearly++; if (!(d[17] && comp[1])) bad++; end   // cleared before/with the set
            else                       begin nlate++;  if (d[17] || comp[1]) bad++; end      // cleared after it
            if (d[16] || d[15:0] != 0) bad++;
            wr(R(1, ICLR), 32'h3, e);
        end
        check(coll_comp > 0 && nearly > coll_comp && nlate > 0,
              $sformatf("ICLR sweep placed the W1C write in the exact cycle COMPLETE sets %0d times (%0d at-or-before, %0d after)", coll_comp, nearly, nlate));
        check(bad == 0, $sformatf("[N-7.19] [R-7] COMPLETE setting in the cycle ICLR clears it is not lost (set wins); a later ICLR clears it (%0d errors)", bad));

        bad = 0; coll_err = 0; nearly = 0; nlate = 0;
        for (wp = 0; wp < 4; wp++) for (k = 0; k < 6; k++) begin
            p_waits = wp;
            prog(1, 32'h4000_3000, 32'h1000_0000, 2);                 // DAR in Boot ROM: refused at the write
            repeat (4) @(posedge hclk);
            err1_seen = 0; c_iclr = -1; c_berr = -1;
            @(posedge pclk);
            wr_bb(R(1, CR), crv(1, 2'd2, 0, 0, 2'd2, 1, 1));
            if (k > 0) begin apb_idle(); repeat (k) @(posedge pclk); end
            wr_bb(R(1, ICLR), 32'h2);
            apb_idle();
            repeat (40) @(posedge hclk);
            rd(R(1, STAT), d);
            if (c_berr < 0 || c_iclr < 0 || !err1_seen) bad++;
            else if (c_iclr <= c_berr) begin nearly++; if (!(d[18] && d[21:19] == 3'd2 && err[1])) bad++; end
            else                       begin nlate++;  if (d[18] || d[21:19] != 3'd0 || err[1]) bad++; end
            if (d[16] || d[15:0] != 2) bad++;
            wr(R(1, ICLR), 32'h3, e);
        end
        check(coll_err > 0 && nearly > coll_err && nlate > 0,
              $sformatf("ICLR sweep placed the W1C write in the exact cycle ERROR sets %0d times (%0d at-or-before, %0d after)", coll_err, nearly, nlate));
        check(bad == 0, $sformatf("[N-7.19] ERROR and ERRPHASE setting in the cycle ICLR clears them are not lost (%0d errors)", bad));

        // ---- 14. a CR write in the completion cycle (R-7, erratum D-2, [N-11.2]) -----------------
        bad = 0; coll_en = 0; nearly = 0; nlate = 0;
        for (wp = 0; wp < 2; wp++) for (wd = 0; wd < 2; wd++) for (k = 0; k < 12; k++) begin
            p_waits = wp; d_waits = wd;
            prog(1, 32'h4000_3000, 32'h2000_9200, 2);
            repeat (4) @(posedge hclk);
            c_done = -1; nw0 = n_wr;
            @(posedge pclk);
            wr_bb(R(1, CR), crv(1, 2'd2, 0, 1, 2'd2, 1, 0));
            if (k > 0) begin apb_idle(); repeat (k) @(posedge pclk); end
            c_cr = -1;
            wr_bb(R(1, CR), crv(1, 2'd2, 0, 1, 2'd2, 1, 1));           // stale EN = 1, IE_ERR changed
            apb_idle();
            repeat (80) @(posedge hclk);
            wait_done(1, 100);
            rd(R(1, STAT), d); rd(R(1, CR), d1);
            // the D-2 signature is a channel left EN/ACTIVE with nothing to do
            if (d[16] || !d[17] || d[15:0] != 0 || d1[0] || !d1[8]) bad++;
            if (c_cr < 0 || c_done < 0) bad++;
            else if (c_cr > c_done) begin nlate++;  if (n_wr - nw0 != 4) bad++; end   // a start after completion: runs again
            else                    begin nearly++; if (n_wr - nw0 != 2) bad++; end   // at or before it: one transfer only
            wr(R(1, ICLR), 32'h3, e);
        end
        check(coll_en > 0, $sformatf("[N-11.2] CR-write sweep hit the hardware EN-clear cycle exactly %0d times (%0d at-or-before, %0d after)", coll_en, nearly, nlate));
        check(bad == 0, $sformatf("[R-7] [N-7.17] [N-7.18] [N-7.19] hardware wins EN on the collision, the rest of the write lands, COMPLETE is kept, the channel is never left ACTIVE with REMAINING = 0 (%0d errors)", bad));

        // ---- 15. STAT is exact on every read (the old DMA-4; R-6, [N-6.2], [N-8.1]) ---------------
        d_rand = 1; d_waits = 8'd1; p_waits = 8'd3;
        bad = 0;
        // (a) the read directly behind the arming write, across multi-bit jumps of REMAINING
        prog(1, 32'h2000_8000, 32'h2000_9000, 16'hFFFF);
        @(posedge pclk); wr_bb(R(1, CR), crv(1, 2'd2, 0, 0, 2'd2, 0, 0)); rd_bb(R(1, STAT), d); apb_idle();
        if (d[21:0] !== {3'd0, 3'b001, 16'hFFFF}) bad++;
        wr(R(1, CR), crv(0, 2'd2, 0, 0, 2'd2, 0, 0), e);
        wr(R(1, CNT), 32'h5555, e);
        @(posedge pclk); wr_bb(R(1, CR), crv(1, 2'd2, 0, 0, 2'd2, 0, 0)); rd_bb(R(1, STAT), d); apb_idle();
        if (d[21:0] !== {3'd0, 3'b001, 16'h5555}) bad++;
        wr(R(1, CR), crv(0, 2'd2, 0, 0, 2'd2, 0, 0), e);
        wr(R(1, CNT), 32'hAAAA, e);
        @(posedge pclk); wr_bb(R(1, CR), crv(1, 2'd2, 0, 0, 2'd2, 0, 0)); rd_bb(R(1, STAT), d); apb_idle();
        if (d[21:0] !== {3'd0, 3'b001, 16'hAAAA}) bad++;
        wr(R(1, CR), crv(0, 2'd2, 0, 0, 2'd2, 0, 0), e);
        repeat (30) @(posedge hclk);
        check(bad == 0, $sformatf("[N-6.2] DMA-4: STAT read directly behind the arming write returns REMAINING = CNT exactly, ACTIVE, not COMPLETE (0xFFFF, 0x5555, 0xAAAA; %0d errors)", bad));
        // (b) back-to-back STAT reads through a whole transfer
        bad = 0; nreads = 0; prev = 24;
        prog(1, 32'h2000_8000, 32'h2000_9000, 24);
        nw0 = n_wr;
        @(posedge pclk); wr_bb(R(1, CR), crv(1, 2'd2, 1, 1, 2'd2, 1, 0));
        do begin
            rd_bb(R(1, STAT), d); nreads++;
            if (d[17] && d[15:0] != 0) bad++;                        // COMPLETE with beats left (erratum D-1)
            if (d[16] && d[15:0] == 0) bad++;                        // ACTIVE with nothing left
            if (d[16] && d[17]) bad++;
            if (d[15:0] > prev) bad++;                               // only ever counts down
            if (d[15:0] + (nwr_cap - nw0) > 25 || d[15:0] + (nwr_cap - nw0) < 23) bad++;   // matches the writes on the bus
            prev = d[15:0];
        end while (!d[17] && nreads < 2000);
        apb_idle();
        check(bad == 0 && d[17] && d[15:0] == 0 && nreads > 20,
              $sformatf("[R-6] [N-6.2] [N-8.1] %0d back-to-back STAT reads through a 24-beat transfer: REMAINING tracks the bus, never rises, COMPLETE only with REMAINING = 0 (%0d errors)", nreads, bad));
        wr(R(1, ICLR), 32'h3, e);

        // ---- 16. back-to-back APB accesses (the old DMA-5; R-3, [N-5.1], [N-9.1]) -----------------
        k = n_wstb;
        @(posedge pclk);
        wr_bb(R(4, CNT), 32'h0000_1111); wr_bb(R(4, CNT), 32'h0000_2222);       // same register twice
        wr_bb(R(4, SAR), 32'h2000_0AA0); wr_bb(R(4, DAR), 32'h2000_0BB0);       // different registers
        rd_bb(R(4, CNT), d1); rd_bb(R(4, SAR), d2);
        wr_bb(R(4, DAR), 32'h2000_0CC0); rd_bb(R(4, DAR), d3);                  // write, then read it at once
        wr_bb(R(5, CNT), 32'h0000_3333); rd_bb(R(4, DAR), d);
        apb_idle();
        check(n_wstb - k == 6, $sformatf("DMA-5: 6 back-to-back APB writes gave exactly 6 one-hclk write strobes (%0d)", n_wstb - k));
        check(d1 == 32'h0000_2222 && d2 == 32'h2000_0AA0 && d3 == 32'h2000_0CC0 && d == 32'h2000_0CC0,
              "[R-3] [N-5.1] [N-9.1] [N-8.2] back-to-back writes all land and a read directly behind a write returns the new value (no synchroniser latency)");
        rd(R(5, CNT), d); rd(R(4, CNT), d1);
        check(d == 32'h0000_3333 && d1 == 32'h0000_2222, "back-to-back writes to different channels do not alias");

        // ---- 17. two requests in the same cycle: all 15 channel pairs (R-4, §6.3) ------------------
        bad = 0;
        for (ch = 0; ch < 6; ch++) for (sz = ch + 1; sz < 6; sz++) begin
            prog(ch, 32'h2000_8000, 32'h2000_9000 + 32'h40 * ch, 1);
            prog(sz, 32'h2000_8000, 32'h2000_9000 + 32'h40 * sz, 1);
            wr(R(ch, CR), crv(1, 2'd0, 0, 0, 2'd2, 0, 0), e);
            wr(R(sz, CR), crv(1, 2'd0, 0, 0, 2'd2, 0, 0), e);
            a0 = acks[ch] + acks[sz];
            @(posedge pclk); first_ack = -1; #0.1 req[ch] = 1'b1; req[sz] = 1'b1;
            for (i = 0; i < 200 && acks[ch] + acks[sz] != a0 + 2; i++) @(posedge pclk);
            repeat (2) @(posedge pclk);
            if (acks[ch] + acks[sz] != a0 + 2) bad++;
            if (first_ack != ((prio_spec[ch] > prio_spec[sz]) ? ch : sz)) begin
                bad++; $display("  pair %0d/%0d: first beat went to ch%0d", ch, sz, first_ack);
            end
            req[ch] = 1'b0; req[sz] = 1'b0;
            wr(R(ch, ICLR), 32'h3, e); wr(R(sz, ICLR), 32'h3, e);
        end
        check(bad == 0, $sformatf("[R-4] [N-7.11] two channels requesting in the same cycle: the higher priority of §6.3 is served first, all 15 pairs (%0d errors)", bad));

        // ---- 18. re-arbitration at every beat boundary, never inside a beat ([N-7.11]) ------------
        for (i = 0; i < 8; i++) begin
            u_dsram.bd_write(32'h2000_8000 + 4*i, 32'h5555_0000 + i);
            u_dsram.bd_write(32'h2000_A000 + 4*i, 32'h0A0A_0000 + i);
        end
        prog(5, 32'h2000_8000, 32'h2000_9000, 8);
        prog(0, 32'h2000_A000, 32'h2000_B000, 4);
        wr(R(0, CR), crv(0, 2'd2, 1, 1, 2'd2, 0, 0), e);
        ord.delete(); arm_idx = -1; pair_bad = 0; k = split; ord_en = 1;
        wr(R(5, CR), crv(1, 2'd2, 1, 1, 2'd2, 0, 0), e);
        repeat (20) @(posedge hclk);                                 // ch5 is a few beats in
        wr(R(0, CR), crv(1, 2'd2, 1, 1, 2'd2, 0, 0), e);
        wait_done(5, 400); wait_done(0, 400);
        ord_en = 0;
        n0 = 0; n5 = 0; first0 = -1; last0 = -1;
        foreach (ord[j]) begin
            if (ord[j] == 0) begin n0++; if (first0 < 0) first0 = j; last0 = j; end
            else n5++;
        end
        check(n0 == 4 && n5 == 8 && arm_idx > 0 && first0 >= arm_idx && first0 - arm_idx <= 1 && last0 - first0 == 3,
              $sformatf("[R-4] [N-7.11] ch0 armed while ch5 runs: at most the beat in flight finishes (%0d), then ch0's 4 beats run unbroken, then ch5 resumes", first0 - arm_idx));
        ok = 1;
        for (i = 0; i < 8; i++) if (u_dsram.bd_read(32'h2000_9000 + 4*i) !== 32'h5555_0000 + i) ok = 0;
        for (i = 0; i < 4; i++) if (u_dsram.bd_read(32'h2000_B000 + 4*i) !== 32'h0A0A_0000 + i) ok = 0;
        check(ok && pair_bad == 0 && split == k,
              "[N-7.11] a beat is never split: every read was followed by the same channel's write, both buffers intact");
        wr(R(5, ICLR), 32'h3, e); wr(R(0, ICLR), 32'h3, e);

        // ---- 19. a request withdrawn before it is granted takes no beat ([N-7.7], [N-7.12]) ------
        prog(2, 32'h2000_8000, 32'h2000_9300, 3);
        wr(R(2, CR), crv(1, 2'd0, 1, 1, 2'd2, 0, 0), e);             // P2M, waiting for a request
        prog(0, 32'h2000_A000, 32'h2000_B000, 16);
        a0 = acks[2];
        wr(R(0, CR), crv(1, 2'd2, 1, 1, 2'd2, 0, 0), e);             // ch0 M2M wins every boundary
        @(posedge pclk); #0.1 req[2] = 1'b1;
        repeat (6) @(posedge pclk); #0.1 req[2] = 1'b0;              // gives up while ch0 is still running
        rd(R(0, STAT), d1);
        wait_done(0, 400);
        repeat (20) @(posedge hclk);
        rd(R(2, STAT), d);
        check(d1[16] && acks[2] == a0 && d[15:0] == 3 && d[16],
              "[N-7.12] [N-7.7] ch2 starved by ch0 and its request withdrawn before grant: no beat, no ack, REMAINING unchanged");
        @(posedge pclk); #0.1 req[2] = 1'b1;
        for (i = 0; i < 100 && acks[2] == a0; i++) @(posedge pclk);
        repeat (6) @(posedge pclk);
        rd(R(2, STAT), d);
        check(acks[2] == a0 + 1 && d[15:0] == 2 && !req[2], "[N-7.10] a later request then takes exactly one beat");
        wr(R(2, CR), 32'h0, e); wr(R(0, ICLR), 32'h3, e);

        // ---- 20. CNT = 0, CNT = 1, EN cleared by software mid-transfer ---------------------------
        prog(4, 32'h2000_8000, 32'h2000_9000, 0);
        nr0 = n_rd; nw0 = n_wr;
        wr(R(4, CR), crv(1, 2'd2, 1, 1, 2'd2, 0, 0), e);
        repeat (40) @(posedge hclk);
        rd(R(4, STAT), d); rd(R(4, CR), d1);
        check(n_rd == nr0 && n_wr == nw0 && !d[16] && d[15:0] == 0 && !d1[0],
              "CNT = 0: no transfer, not ACTIVE, EN drops, REMAINING stays 0 (no wrap to 65,535)");
        wr(R(4, ICLR), 32'h3, e);
        prog(4, 32'h2000_8000, 32'h2000_9000, 1);
        nr0 = n_rd; nw0 = n_wr;
        wr(R(4, CR), crv(1, 2'd2, 1, 1, 2'd2, 0, 0), e);
        repeat (40) @(posedge hclk);
        rd(R(4, STAT), d); rd(R(4, CR), d1);
        check(n_rd == nr0 + 1 && n_wr == nw0 + 1 && d[17] && !d[16] && d[15:0] == 0 && !d1[0],
              "CNT = 1: exactly one beat, then COMPLETE and EN clear");
        wr(R(4, ICLR), 32'h3, e);
        prog(4, 32'h2000_8000, 32'h2000_9000, 200);
        a0 = n_wr;
        wr(R(4, CR), crv(1, 2'd2, 1, 1, 2'd2, 1, 1), e);
        repeat (50) @(posedge hclk);
        wr(R(4, CR), crv(0, 2'd2, 1, 1, 2'd2, 1, 1), e);             // software clears EN
        repeat (30) @(posedge hclk);                                 // the beat in flight finishes
        nr0 = n_rd; nw0 = n_wr;
        rd(R(4, STAT), d);
        repeat (60) @(posedge hclk);
        rd(R(4, STAT), d1); rd(R(4, SAR), d2);
        check(!d[16] && !d[17] && !d[18] && d == d1 && n_rd == nr0 && n_wr == nw0 && comp == 0 && err == 0,
              "EN cleared mid-transfer: the channel stops at a beat boundary, M3 goes idle, no COMPLETE, no ERROR, no IRQ");
        check(d[15:0] > 0 && d[15:0] < 200 && (200 - d[15:0]) == (nw0 - a0) && d2 == 32'h2000_8000 + 4 * (nw0 - a0),
              $sformatf("EN cleared mid-transfer: REMAINING and SAR agree with the %0d beats actually written", nw0 - a0));

        check(ack_wbad == 0, "[N-7.8] every dma_ack pulse is exactly one pclk period wide (2 hclk, DECISIONS D-16)");
        check(burst_seen == 0, "[N-7.2] M3 only ever issues SINGLE transfers: HBURST = 0, HTRANS never SEQ or BUSY");
        check(split == 0, "[N-7.2] every completed beat was a read followed by a write");

        check(v_chk == 0, "AHB-Lite protocol checker clean on M3");

        $display("tb_dma_top: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end
    initial begin #2_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
