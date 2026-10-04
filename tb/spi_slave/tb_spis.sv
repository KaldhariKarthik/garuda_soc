`timescale 1ns/1ps
// =============================================================================
// tb_spis.sv -- Block 14 SPI slave (in-house)
//
// Spec: GARUDA-SPIS-SPEC-001 §11. An spi_master_model drives the pins, so the
// only way a byte lands in RXDATA is if the framing and the oversampling are
// both right on the wire.
// =============================================================================
module tb_spis;

    logic pclk = 0, preset_n = 0;
    real  pclk_half = 4.0;                         // 125 MHz, 8 ns; [N-7.1b] slows it
    always #(pclk_half) pclk = ~pclk;

    garuda_apb_bfm bfm (.pclk(pclk), .preset_n(preset_n));

    logic dma_ack = 0;
    wire  irq, dma_req;
    wire  sclk, mosi, cs_n, miso_o, miso_oe;
    wire  miso = miso_oe ? miso_o : 1'bz;

    garuda_spis_top #(.BLOCK_NUM(8'd14), .FIFO_DEPTH(16)) dut (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(bfm.psel), .penable_i(bfm.penable), .pwrite_i(bfm.pwrite),
        .paddr_i(bfm.paddr), .pwdata_i(bfm.pwdata), .prdata_o(bfm.prdata),
        .pready_o(bfm.pready), .pslverr_o(bfm.pslverr),
        .irq_o(irq), .dma_req_o(dma_req), .dma_ack_i(dma_ack),
        .spis_sclk_i(sclk), .spis_mosi_i(mosi), .spis_cs_n_i(cs_n),
        .spis_miso_o(miso_o), .spis_miso_oe_o(miso_oe));

    spi_master_model u_esp (.sclk(sclk), .mosi(mosi), .cs_n(cs_n), .miso(miso));

    dma_req_checker #(.NAME("spis")) u_dchk (
        .clk_i(pclk), .rst_n_i(preset_n), .req_i(dma_req), .ack_i(dma_ack));

    // ---- permanent monitors --------------------------------------------------
    // [N-9.2] MISO may only be driven while selected. cs_n is synchronised, so
    // release lags the pin by the synchroniser depth; the property is that the
    // tail is BOUNDED, not that it is zero - see the spec note.
    int pready_viol = 0, drive_unselected = 0, tail = 0;
    always @(posedge pclk) begin
        if (preset_n && bfm.psel && !bfm.pready) pready_viol++;
        if (preset_n && cs_n && miso_oe) begin
            tail++;
            if (tail > 3) drive_unselected++;      // > 3 pclk is a real fault
        end else tail = 0;
    end

    // [N-7.2] mode 0: miso is launched from the falling edge, so inside the
    // specified rate it may only change while sclk is low. Also measures how
    // long after the falling edge it moves, in pclk.
    int      miso_chg_high = 0;
    realtime t_sclk_fall = 0;
    bit      fall_armed = 0;
    real     max_miso_dly = 0.0;
    always @(negedge sclk) begin t_sclk_fall = $realtime; fall_armed = 1; end
    always @(negedge cs_n) fall_armed = 0;
    always @(miso_o) if (preset_n && !cs_n && miso_oe && u_esp.half_ns >= 25.0) begin
        if (sclk) miso_chg_high++;
        else if (fall_armed) begin
            if (($realtime - t_sclk_fall) / (2.0 * pclk_half) > max_miso_dly)
                max_miso_dly = ($realtime - t_sclk_fall) / (2.0 * pclk_half);
            fall_armed = 0;
        end
    end

    // [N-9.2a] how long after the cs_n PIN rises the output enable drops, in pclk
    realtime t_cs_up = 0;
    real     max_tail_pclk = 0.0;
    int      n_release = 0;
    always @(posedge cs_n) t_cs_up = $realtime;
    always @(negedge miso_oe) if (preset_n && cs_n) begin
        n_release++;
        if (($realtime - t_cs_up) / (2.0 * pclk_half) > max_tail_pclk)
            max_tail_pclk = ($realtime - t_cs_up) / (2.0 * pclk_half);
    end

    localparam [11:0] R_RXDATA = 12'h000, R_TXDATA = 12'h004, R_CTRL = 12'h008,
                      R_STATUS = 12'h00C, R_IRQSTAT= 12'hFE0, R_IRQEN = 12'hFE4,
                      R_DMACTL = 12'hFE8, R_ID     = 12'hFEC;
    localparam ST_RXVALID=0, ST_CSACT=1, ST_OVR=2, ST_DONE=3;

    // Independent APB protocol observer on this block's config port. The
    // shared garuda_apb_bfm carries no PSTRB, so the strobes are tied high.
    wire [31:0] apbviol;
    apb_checker u_apbchk (
        .clk_i(pclk), .rst_n_i(preset_n),
        .psel_i(bfm.psel), .penable_i(bfm.penable), .pwrite_i(bfm.pwrite),
        .paddr_i({20'h0, bfm.paddr}), .pwdata_i(bfm.pwdata), .pstrb_i(4'hF),
        .pready_i(bfm.pready), .pslverr_i(bfm.pslverr), .viol_count_o(apbviol));

    int checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    logic [31:0] d;
    bit e;
    int i, k, nbad, got_n;
    byte unsigned b;
    byte unsigned rb [0:3];
    logic [31:0] d2;
    bit oe_seen;

    initial begin
        $display("=== tb_spis: Block 14 SPI slave ===");

        repeat (4) @(posedge pclk);
        check(!miso_oe, "[R-9] MISO released while in reset");
        preset_n = 1;
        repeat (6) @(posedge pclk);
        check(!miso_oe, "[R-9] MISO still released out of reset, before enable");

        bfm.read(R_ID, d, e);
        check(d == {16'h6A5D, 8'd14, 8'd1} && !e, "ID register reads block 14");
        bfm.read(12'h800, d, e);
        check(e, "[R-5] PSLVERR on an unmapped offset");

        bfm.wr(R_CTRL, 32'h1);                       // EN
        u_esp.half_ns = 100.0;                       // 5 MHz, well inside the limit

        // ---- receive a packet ------------------------------------------------
        u_esp.packet(4, 8'hA0);                      // A0 A1 A2 A3
        repeat (20) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        check(d[ST_RXVALID], "[R-1] RXVALID set after a packet");
        check(d[8:4] == 5'd4, $sformatf("[R-1] FIFO level is 4 (got %0d)", d[8:4]));
        check(d[ST_DONE], "[R-3] [N-7.3] packet-done (STATUS[3]) latched on the cs_n rising edge");
        nbad = 0;
        for (i = 0; i < 4; i++) begin
            bfm.read(R_RXDATA, d, e);
            if (d[7:0] != 8'hA0 + i[7:0]) nbad++;
            if (d[31:8] != 24'd0) nbad++;
        end
        check(nbad == 0, $sformatf("[R-1] all four bytes correct and in order (%0d wrong)", nbad));
        bfm.read(R_STATUS, d, e);
        check(!d[ST_RXVALID], "[R-1] FIFO empty after draining");

        // ---- transmit a response ---------------------------------------------
        bfm.wr(R_IRQSTAT, 32'h7);
        bfm.wr(R_TXDATA, 32'h5A);
        u_esp.clear();
        u_esp.packet(1, 8'h11);
        repeat (20) @(posedge pclk);
        check(u_esp.n_rx() == 1, "[R-2] the master clocked one byte back");
        if (u_esp.n_rx()) begin
            b = u_esp.get();
            check(b == 8'h5A, $sformatf("[R-2] and it was TXDATA 0x5A (got 0x%02h)", b));
        end
        bfm.read(R_RXDATA, d, e);

        // ---- MISO is not driven while deselected --------------------------------
        check(drive_unselected == 0,
              "[R-9] MISO release after deselect is within the 2-pclk synchroniser tail ([N-9.2])");

        // ---- a packet that ends mid-byte is NOT delivered -------------------------
        bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);   // RXFLUSH then EN
        bfm.wr(R_IRQSTAT, 32'h7);
        u_esp.partial_frame(12, 8'hC3);                  // 12 bits = 1.5 bytes
        repeat (20) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        check(d[8:4] == 5'd1,
              $sformatf("[N-7.3a] a 12-bit frame delivers ONE byte, not two (level=%0d)", d[8:4]));
        check(d[ST_DONE], "[N-7.3a] and the packet-done flag still fires");
        bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);

        // ---- framing realigns: a new packet always starts byte-aligned -------------
        bfm.wr(R_IRQSTAT, 32'h7);
        u_esp.packet(2, 8'h7E);
        repeat (20) @(posedge pclk);
        bfm.read(R_RXDATA, d, e);
        check(d[7:0] == 8'h7E,
              $sformatf("[R-3] [N-7.3] after a truncated frame the next packet is byte-aligned (0x%02h)", d[7:0]));
        bfm.read(R_RXDATA, d, e);
        check(d[7:0] == 8'h7F, "[R-3] and its second byte follows");

        // ---- overrun --------------------------------------------------------------
        bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);
        bfm.wr(R_IRQSTAT, 32'h7);
        u_esp.packet(20, 8'h40);                         // 20 into a 16-deep FIFO
        repeat (20) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        check(d[8:4] == 5'd16, $sformatf("[R-8] [N-8.1] FIFO holds 16 (got %0d)", d[8:4]));
        check(d[ST_OVR], "[R-8] [N-7.5] OVERRUN (STATUS[2]) is set");
        bfm.read(R_IRQSTAT, d, e);
        check(d[2], "[R-8] [N-7.5] IRQSTAT[2] captured it");
        nbad = 0;
        for (i = 0; i < 16; i++) begin
            bfm.read(R_RXDATA, d, e);
            if (d[7:0] != 8'h40 + i[7:0]) nbad++;
        end
        check(nbad == 0,
              $sformatf("[R-8] [N-7.5] the 16 kept bytes are the FIRST 16, contiguous (%0d wrong)", nbad));
        bfm.wr(R_IRQSTAT, 32'h4);
        bfm.read(R_STATUS, d, e);
        check(!d[ST_OVR], "[R-8] clearing IRQSTAT[2] clears STATUS.OVERRUN");

        // ---- interrupt -------------------------------------------------------------
        bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);
        bfm.wr(R_IRQSTAT, 32'h7);
        bfm.wr(R_IRQEN, 32'h2);                          // packet complete only
        check(!irq, "[R-6] no interrupt before a packet");
        u_esp.packet(3, 8'h90);
        repeat (20) @(posedge pclk);
        check(irq, "[R-6] [N-7.4] packet-complete interrupt asserted");
        repeat (60) @(posedge pclk);
        check(irq, "[R-6] still asserted 60 pclk later");
        bfm.wr(R_IRQSTAT, 32'h2);
        repeat (4) @(posedge pclk);
        check(!irq, "[R-6] W1C clears it");
        bfm.wr(R_IRQEN, 32'h0);

        // ---- DMA ----------------------------------------------------------------------
        bfm.wr(R_DMACTL, 32'h1);
        repeat (4) @(posedge pclk);
        check(dma_req, "[R-7] [N-7.6] dma_req asserts - bytes are waiting from the last packet");
        bfm.read(R_RXDATA, d, e);
        check(d[7:0] == 8'h90, "[R-7] the DMA's read returns the first byte");
        @(posedge pclk); #0.1 dma_ack = 1;
        @(posedge pclk); #0.1 dma_ack = 0;
        repeat (4) @(posedge pclk);
        check(dma_req, "[R-7] and re-asserts for the next byte");
        bfm.read(R_RXDATA, d, e);
        @(posedge pclk); #0.1 dma_ack = 1;
        @(posedge pclk); #0.1 dma_ack = 0;
        bfm.read(R_RXDATA, d, e);
        repeat (6) @(posedge pclk);
        check(!dma_req, "[R-7] and drops when the FIFO empties");
        check(u_dchk.violations() == 0, "[R-7] [N-7.6] dma_req_checker clean");
        bfm.wr(R_DMACTL, 32'h0);


        // =====================================================================
        // 2026-10-04: checks written from the spec notes that had none
        // =====================================================================

        // ---- [N-6.2] TXDATA is loaded at the start of EVERY byte ------------------------
        // 0xA5 is not shift-symmetric, so a byte loaded one bit out reads 0x4A.
        bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);
        bfm.wr(R_IRQSTAT, 32'h7);
        bfm.wr(R_TXDATA, 32'hA5);
        u_esp.clear();
        u_esp.packet(3, 8'h00);
        repeat (20) @(posedge pclk);
        for (i = 0; i < 3; i++) rb[i] = u_esp.get();
        check(rb[0] == 8'hA5 && rb[1] == 8'hA5 && rb[2] == 8'hA5,
              $sformatf("[N-6.2] nothing written between bytes: the previous TXDATA is re-sent on every byte (got %02h %02h %02h, want a5 a5 a5)",
                        rb[0], rb[1], rb[2]));

        // a write between bytes goes out on the NEXT byte and leaves the one
        // on the wire alone
        bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);
        bfm.wr(R_TXDATA, 32'hA5);
        u_esp.clear();
        fork
            u_esp.packet(3, 8'h00);
            begin #700; bfm.wr(R_TXDATA, 32'h3C); end       // in the middle of byte 0
        join
        repeat (20) @(posedge pclk);
        for (i = 0; i < 3; i++) rb[i] = u_esp.get();
        check(rb[0] == 8'hA5,
              $sformatf("[N-6.2] a TXDATA write mid-byte does not disturb the byte being shifted (got %02h, want a5)", rb[0]));
        check(rb[1] == 8'h3C && rb[2] == 8'h3C,
              $sformatf("[N-6.2] and the new value is loaded at the start of the following bytes (got %02h %02h, want 3c 3c)",
                        rb[1], rb[2]));

        // [N-13.2] one holding register: a second write replaces the first
        bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);
        bfm.wr(R_TXDATA, 32'h11);
        bfm.wr(R_TXDATA, 32'h22);
        u_esp.clear();
        u_esp.packet(2, 8'h00);
        repeat (20) @(posedge pclk);
        for (i = 0; i < 2; i++) rb[i] = u_esp.get();
        check(rb[0] == 8'h22 && rb[1] == 8'h22,
              $sformatf("[N-13.2] no TX FIFO: of two writes before a packet only the last is sent (got %02h %02h, want 22 22)",
                        rb[0], rb[1]));

        // ---- [N-7.2] mode 0, MSB first ------------------------------------------------------
        bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);
        bfm.wr(R_TXDATA, 32'h80);                        // MSB only: must be on the FIRST clock
        u_esp.clear();
        u_esp.packet(1, 8'h01);                          // LSB only: arrives on the LAST clock
        repeat (20) @(posedge pclk);
        bfm.read(R_RXDATA, d, e);
        b = u_esp.get();
        check(d[7:0] == 8'h01 && b == 8'h80,
              $sformatf("[N-7.2] MSB first in both directions (rx %02h want 01, tx %02h want 80)", d[7:0], b));
        check(miso_chg_high == 0,
              $sformatf("[N-7.2] mode 0: miso only ever changed while sclk was low (%0d changes while high)",
                        miso_chg_high));

        // ---- [N-7.3] [N-7.4] the three interrupt sources, one at a time ---------------------
        bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);
        bfm.wr(R_IRQSTAT, 32'h7);
        u_esp.open_frame();
        repeat (6) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        check(d[ST_CSACT] && !d[ST_DONE],
              "[N-7.3] cs_n low: STATUS[1] shows the packet open, packet-done not yet set");
        u_esp.xfer(8'h66, b);
        repeat (6) @(posedge pclk);
        bfm.read(R_IRQSTAT, d, e);
        check(d[2:0] == 3'b001,
              $sformatf("[N-7.4] a byte arriving sets IRQSTAT[0] alone while the packet is still open (IRQSTAT=%03b)", d[2:0]));
        u_esp.close_frame();
        repeat (6) @(posedge pclk);
        bfm.read(R_IRQSTAT, d, e);
        bfm.read(R_STATUS, d2, e);
        check(d[2:0] == 3'b011 && d2[ST_DONE] && !d2[ST_CSACT],
              $sformatf("[N-7.3] cs_n rising sets IRQSTAT[1] and STATUS[3] (IRQSTAT=%03b STATUS=%04b)", d[2:0], d2[3:0]));
        bfm.wr(R_IRQEN, 32'h4);
        repeat (2) @(posedge pclk);
        check(!irq, "[N-7.4] IRQEN masks per source: overrun enabled, none pending, line low");
        bfm.wr(R_IRQEN, 32'h1);
        repeat (2) @(posedge pclk);
        check(irq, "[N-7.4] byte-received enabled and pending: line high");
        bfm.wr(R_IRQSTAT, 32'h1);
        repeat (2) @(posedge pclk);
        bfm.read(R_IRQSTAT, d, e);
        check(!irq && d[2:0] == 3'b010,
              "[N-7.4] W1C of bit 0 drops the line and leaves the packet-complete bit alone");
        bfm.wr(R_IRQEN, 32'h0);
        bfm.wr(R_IRQSTAT, 32'h7);

        // ---- [N-7.5] exactly full is not an overrun; the 17th byte is ---------------------------
        bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);
        bfm.wr(R_IRQSTAT, 32'h7);
        u_esp.packet(16, 8'h20);
        repeat (20) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        bfm.read(R_IRQSTAT, d2, e);
        check(d[8:4] == 5'd16 && !d[ST_OVR] && !d2[2],
              $sformatf("[N-7.5] 16 bytes fill the FIFO exactly and that is not an overrun (level=%0d OVR=%0b IRQSTAT[2]=%0b)",
                        d[8:4], d[ST_OVR], d2[2]));
        bfm.read(R_RXDATA, d, e);                        // 0x20 out: one free slot
        u_esp.packet(2, 8'hE0);                          // E0 fits, E1 does not
        repeat (20) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        bfm.read(R_IRQSTAT, d2, e);
        check(d[8:4] == 5'd16 && d[ST_OVR] && d2[2],
              "[N-7.5] one byte past full latches STATUS[2] and IRQSTAT[2]");
        nbad = 0;
        for (i = 1; i < 17; i++) begin
            bfm.read(R_RXDATA, d, e);
            if (d[7:0] != ((i < 16) ? (8'h20 + i[7:0]) : 8'hE0)) nbad++;
        end
        check(nbad == 0,
              $sformatf("[N-7.5] the NEWEST byte was the one dropped: 21..2f then e0, in order (%0d wrong)", nbad));
        bfm.wr(R_IRQSTAT, 32'h7);

        // ---- [N-6.1] RXDATA pop, and the DMA request that goes with it ----------------------------
        bfm.read(R_RXDATA, d, e);
        bfm.read(R_STATUS, d2, e);
        check(d == 32'd0 && d2[8:4] == 5'd0 && !d2[ST_RXVALID],
              "[N-6.1] reading RXDATA with the FIFO empty returns 0 and does not underflow it");
        u_esp.packet(3, 8'h31);
        repeat (20) @(posedge pclk);
        bfm.read(R_RXDATA, d, e);
        bfm.read(R_STATUS, d2, e);
        check(d == 32'h31 && d2[8:4] == 5'd2,
              $sformatf("[N-6.1] one read pops exactly one byte, [31:8] read 0 (data=%08h level=%0d)", d, d2[8:4]));
        check(!dma_req, "[N-7.6] no request while DMACTL[0] is clear, even with RXVALID set");
        bfm.wr(R_DMACTL, 32'h1);
        repeat (2) @(posedge pclk);
        check(dma_req, "[N-7.6] DMACTL[0] set and RXVALID set: request");
        @(posedge pclk); #0.1 dma_ack = 1;               // ack with two bytes still waiting
        @(posedge pclk); #0.1 dma_ack = 0;
        #1 check(!dma_req, "[N-7.6] the request drops for a pclk after dma_ack although bytes are still waiting");
        repeat (2) @(posedge pclk);
        #1 check(dma_req, "[N-7.6] and comes back for the next beat");
        bfm.read(R_RXDATA, d, e);                        // 0x32, one left
        bfm.read(R_RXDATA, d, e);                        // 0x33, empty
        #1 check(d[7:0] == 8'h33 && !dma_req,
              "[N-6.1] reading the last byte drops the DMA request with it");
        bfm.wr(R_DMACTL, 32'h0);

        // ---- read-only and reserved bits; RXFLUSH self-clears ---------------------------------------
        u_esp.packet(1, 8'h44);
        repeat (20) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        bfm.wr(R_STATUS, 32'hFFFF_FFFF);
        bfm.wr(R_RXDATA, 32'hFFFF_FFFF);
        bfm.read(R_STATUS, d2, e);
        check(d == d2 && d[8:4] == 5'd1, "[R-5] STATUS and RXDATA are read-only: a write changes nothing");
        bfm.wr(R_TXDATA, 32'hFFFF_FF5A);
        bfm.read(R_TXDATA, d, e);
        check(d == 32'h5A, "[R-5] TXDATA[31:8] read 0");
        bfm.wr(R_CTRL, 32'hFFFF_FFFF);
        bfm.read(R_CTRL, d, e);
        bfm.read(R_STATUS, d2, e);
        check(d == 32'h1 && d2[8:4] == 5'd0,
              $sformatf("[R-5] CTRL: RXFLUSH empties the FIFO and reads back 0, reserved bits read 0 (CTRL=%08h level=%0d)",
                        d, d2[8:4]));

        // ---- every offset without a register answers PSLVERR ----------------------------------------
        // AHB2APB [N-7.20]: peripherals assert PSLVERR for unmapped offsets
        // within their own window. This block has four registers and the tail.
        nbad = 0;
        for (i = 'h010; i < 'h1000; i = i + 4)
            if (!(i >= 'hFE0 && i <= 'hFEC)) begin
                bfm.read(i[11:0], d, e);
                if (!e) begin
                    if (nbad < 4) $display("    offset 0x%03h: no PSLVERR", i[11:0]);
                    nbad++;
                end
            end
        check(nbad == 0,
              $sformatf("[R-5] every offset that has no register answers PSLVERR (%0d did not)", nbad));
        nbad = 0;
        for (i = 0; i < 4; i++) begin
            bfm.read(4*i, d, e);             if (e) nbad++;      // RXDATA (empty) TXDATA CTRL STATUS
            bfm.read(R_IRQSTAT + 4*i, d, e); if (e) nbad++;      // the tail
        end
        check(nbad == 0, "[R-5] and the eight offsets that do have a register do not");

        // ---- [N-9.2] CTRL.EN clear: deaf and not driving ------------------------------------------------
        bfm.wr(R_CTRL, 32'h2);                           // flush, EN = 0
        bfm.wr(R_IRQSTAT, 32'h7);
        oe_seen = 0;
        fork
            u_esp.packet(2, 8'h55);
            begin #1000; oe_seen = miso_oe; end
        join
        repeat (20) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        bfm.read(R_IRQSTAT, d2, e);
        check(!oe_seen && d == 32'd0 && d2 == 32'd0,
              $sformatf("[N-9.2] with CTRL.EN clear a packet is ignored: MISO not driven, nothing received, no event (STATUS=%08h IRQSTAT=%0h)",
                        d, d2));
        bfm.wr(R_CTRL, 32'h1);

        // ---- SCLK rate: correct at the limit, and where it breaks -----------------------
        // [N-7.1a] says SCLK <= pclk/6. pclk is 8 ns, so the limit is a 24 ns
        // half period. This walks past it and reports the measured edge.
        begin
            // no initialisers on these: in a static initial they would run
            // once at time 0, not when the block is entered
            real hn;
            int  first_bad;
            int  first_bad_tx;
            int  nbad_tx;
            first_bad = 0;
            first_bad_tx = 0;
            bfm.wr(R_TXDATA, 32'hA5);
            // Deliberately NOT multiples of the 8 ns pclk: with aligned edges
            // the oversampler looks better than it is, because every sample
            // lands in the same place in the bit.
            for (hn = 49.0; hn >= 9.0; hn = hn - 5.0) begin
                bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);
                u_esp.half_ns = hn;
                u_esp.clear();
                u_esp.packet(4, 8'h10);
                repeat (30) @(posedge pclk);
                nbad_tx = 0;
                for (i = 0; i < 4; i++) begin
                    b = u_esp.get();
                    if (b != 8'hA5) nbad_tx++;
                end
                if (nbad_tx != 0 && first_bad_tx == 0) first_bad_tx = $rtoi(hn);
                nbad = 0;
                bfm.read(R_STATUS, d, e);
                got_n = d[8:4];
                for (i = 0; i < got_n; i++) begin
                    bfm.read(R_RXDATA, d, e);
                    if (d[7:0] != 8'h10 + i[7:0]) nbad++;
                end
                if ((got_n != 4 || nbad != 0) && first_bad == 0)
                    first_bad = $rtoi(hn);
            end
            // Informational, with a caveat that matters: ideal simulation
            // edges cannot find the real limit, which exists because of
            // metastability and finite edge rates in silicon. What this proves
            // is correctness AT and above the specified 24 ns; anything below
            // that is simulation being kinder than a chip will be.
            $display("[MEASURED] correct at every half period tested down to %0d ns; spec limit is 24 ns = pclk/6.",
                     first_bad == 0 ? 9 : first_bad + 5);
            $display("[MEASURED] ideal edges - this does NOT license running faster than the spec limit.");
            check(first_bad == 0 || first_bad < 24,
                  $sformatf("[R-4] correct at and above the specified 24 ns half period (first failure at %0d ns)",
                            first_bad));
            // The response direction has its own limit and [N-7.1a] does not
            // derive it: miso moves 2 to 3 pclk after the falling edge, and
            // the master samples one half period after that edge.
            $display("[MEASURED] miso moved at most %0.2f pclk after the sclk falling edge (in-spec rates only).",
                     max_miso_dly);
            check(first_bad_tx == 0 || first_bad_tx < 25,
                  $sformatf("[R-2] the response is also correct down to the specified 20 MHz = 25 ns half period (first failure at %0d ns)",
                            first_bad_tx));
        end
        u_esp.half_ns = 100.0;

        // ---- [N-7.1b] the limit scales with pclk -------------------------------------------
        // DIV=4 fallback: pclk = 62.5 MHz, so the limit is 10 MHz (50 ns half period).
        pclk_half = 8.0;
        repeat (4) @(posedge pclk);
        bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);
        bfm.wr(R_TXDATA, 32'hC3);
        u_esp.half_ns = 50.0;
        u_esp.clear();
        u_esp.packet(4, 8'h70);
        repeat (20) @(posedge pclk);
        nbad = 0;
        for (i = 0; i < 4; i++) begin
            bfm.read(R_RXDATA, d, e);
            if (d[7:0] != 8'h70 + i[7:0]) nbad++;
            b = u_esp.get();
            if (b != 8'hC3) nbad++;
        end
        check(nbad == 0,
              $sformatf("[N-7.1b] at pclk = 62.5 MHz a 10 MHz packet is received and answered correctly (%0d wrong)", nbad));
        pclk_half = 4.0;
        u_esp.half_ns = 100.0;
        repeat (4) @(posedge pclk);

        // ---- [N-9.2a] the release tail, measured from the pin ---------------------------------
        check(n_release > 0 && max_tail_pclk <= 3.0,
              $sformatf("[N-9.2a] miso_oe dropped at most %0.2f pclk after the cs_n pin rose, over %0d packets (bound 3, expected 2)",
                        max_tail_pclk, n_release));

        // ---- a W1C that lands on a new event must not lose it ------------------------------------
        // [N-7.3] says cs_n rising SETS IRQSTAT[1] and STATUS[3]; [N-7.5] says
        // an overrun latches STATUS[2] and sets IRQSTAT[2]. The W1C is walked
        // across the event one pclk at a time: wherever it lands, the two
        // registers must agree on whether the event is still pending.
        bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);
        nbad = 0;
        for (k = 0; k < 9; k++) begin
            u_esp.select();
            repeat (6) @(posedge pclk);
            u_esp.deselect();                            // packet 1 ends: both bits set
            repeat (8) @(posedge pclk);
            u_esp.select();
            repeat (6) @(posedge pclk);
            fork
                begin #2 u_esp.deselect(); end           // packet 2 ends...
                begin repeat (k) @(posedge pclk); bfm.wr(R_IRQSTAT, 32'h2); end   // ...as the first is acknowledged
            join
            repeat (8) @(posedge pclk);
            bfm.read(R_IRQSTAT, d, e);
            bfm.read(R_STATUS, d2, e);
            if (d[1] != d2[ST_DONE]) begin
                nbad++;
                $display("    W1C %0d pclk after the pin: IRQSTAT[1]=%0b STATUS[3]=%0b", k, d[1], d2[ST_DONE]);
            end
            bfm.wr(R_IRQSTAT, 32'h7);
        end
        check(nbad == 0,
              $sformatf("[N-7.3] a W1C landing on a packet-complete event leaves IRQSTAT[1] and STATUS[3] in agreement (%0d of 9 alignments disagree)",
                        nbad));

        bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);
        u_esp.packet(16, 8'h00);                         // fill it: every byte from here overruns
        repeat (20) @(posedge pclk);
        bfm.wr(R_IRQSTAT, 32'h7);
        nbad = 0;
        for (k = 0; k < 10; k++) begin
            @(posedge pclk);
            fork
                u_esp.packet(1, 8'hFF);                  // the 8th rising edge is 1600 ns in
                begin #(1576.0 + 8.0 * k); bfm.wr(R_IRQSTAT, 32'h4); end
            join
            repeat (8) @(posedge pclk);
            bfm.read(R_IRQSTAT, d, e);
            bfm.read(R_STATUS, d2, e);
            if (d[2] != d2[ST_OVR]) begin
                nbad++;
                $display("    W1C started %0d ns into the packet: IRQSTAT[2]=%0b STATUS[2]=%0b",
                         1576 + 8 * k, d[2], d2[ST_OVR]);
            end
            bfm.wr(R_IRQSTAT, 32'h7);
        end
        check(nbad == 0,
              $sformatf("[N-7.5] a W1C landing on an overrun leaves IRQSTAT[2] and STATUS[2] in agreement (%0d of 10 alignments disagree)",
                        nbad));

        // ---- CTRL.EN dropped and restored while the master is mid-packet ---------------------------
        // [N-7.3]: a packet starts on a cs_n FALLING edge and always begins
        // byte-aligned. Bits clocked after a re-enable belong to no packet.
        bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);
        bfm.wr(R_IRQSTAT, 32'h7);
        oe_seen = 1;
        fork
            u_esp.packet(4, 8'hB0);                      // 6.6 us on the wire
            begin
                #2300;                                   // inside byte 1; byte 0 is complete
                bfm.wr(R_CTRL, 32'h0);
                #1 oe_seen = miso_oe;
                bfm.wr(R_CTRL, 32'h1);
            end
        join
        repeat (20) @(posedge pclk);
        check(!oe_seen, "[N-9.2] clearing CTRL.EN mid-packet releases MISO in the same cycle");
        bfm.read(R_STATUS, d, e);
        bfm.read(R_RXDATA, d2, e);
        check(d[8:4] == 5'd1 && d2[7:0] == 8'hB0,
              $sformatf("[N-7.3] re-enabled mid-packet: only the byte completed before the disable is delivered, nothing misaligned after it (level=%0d first=%02h)",
                        d[8:4], d2[7:0]));

        // ---- [N-9.3] a reset that lands during a transfer --------------------------------------------
        bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);
        bfm.wr(R_TXDATA, 32'hFF);
        bfm.wr(R_IRQEN, 32'h7);
        bfm.wr(R_DMACTL, 32'h1);
        oe_seen = 1;
        fork
            u_esp.packet(4, 8'hD0);
            begin
                #2300;                                   // inside byte 1
                preset_n = 0;
                #1 oe_seen = miso_oe;                    // no clock edge needed
                repeat (3) @(posedge pclk);
                #1 preset_n = 1;
                repeat (2) @(posedge pclk);
                bfm.read(R_TXDATA, d, e);  nbad = (d != 0);
                bfm.read(R_CTRL, d, e);    nbad += (d != 0);
                bfm.read(R_STATUS, d, e);  nbad += (d != 0);
                bfm.read(R_IRQSTAT, d, e); nbad += (d != 0);
                bfm.read(R_IRQEN, d, e);   nbad += (d != 0);
                bfm.read(R_DMACTL, d, e);  nbad += (d != 0);
                bfm.wr(R_CTRL, 32'h1);                   // firmware comes back up; the master is still clocking
            end
        join
        repeat (20) @(posedge pclk);
        check(!oe_seen, "[R-9] reset releases MISO at once, with cs_n still low");
        check(nbad == 0 && !irq && !dma_req,
              $sformatf("[R-9] every register reads its reset value and irq/dma_req are low (%0d wrong)", nbad));
        bfm.read(R_STATUS, d, e);
        check(d[8:4] == 5'd0,
              $sformatf("[N-9.3] the block does not come up mid-byte: nothing from the interrupted transfer is delivered (level=%0d)",
                        d[8:4]));
        bfm.wr(R_TXDATA, 32'h69);
        u_esp.clear();
        u_esp.packet(2, 8'h9A);
        repeat (20) @(posedge pclk);
        bfm.read(R_RXDATA, d, e);
        bfm.read(R_RXDATA, d2, e);
        b = u_esp.get();
        check(d[7:0] == 8'h9A && d2[7:0] == 8'h9B && b == 8'h69,
              $sformatf("[N-9.3] and the next packet, opened by a cs_n falling edge, is byte-aligned both ways (rx %02h %02h, tx %02h)",
                        d[7:0], d2[7:0], b));

        check(pready_viol == 0, "[R-5] PREADY high in every cycle of every access");

        u_apbchk.report_result;
        check(apbviol == 0, "APB protocol checker clean on the config port");
        check(u_apbchk.n_access > 0, "APB protocol checker observed traffic");

        $display("tb_spis: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end

    initial begin #20_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
