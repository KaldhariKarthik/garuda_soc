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
    always #4 pclk = ~pclk;                        // 125 MHz, 8 ns

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

    localparam [11:0] R_RXDATA = 12'h000, R_TXDATA = 12'h004, R_CTRL = 12'h008,
                      R_STATUS = 12'h00C, R_IRQSTAT= 12'hFE0, R_IRQEN = 12'hFE4,
                      R_DMACTL = 12'hFE8, R_ID     = 12'hFEC;
    localparam ST_RXVALID=0, ST_CSACT=1, ST_OVR=2, ST_DONE=3;

    int checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    logic [31:0] d;
    bit e;
    int i, nbad, got_n;
    byte unsigned b;

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
        check(d[ST_DONE], "[R-3] packet-done latched on the cs_n rising edge");
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
              $sformatf("[R-3] after a truncated frame the next packet is aligned (0x%02h)", d[7:0]));
        bfm.read(R_RXDATA, d, e);
        check(d[7:0] == 8'h7F, "[R-3] and its second byte follows");

        // ---- overrun --------------------------------------------------------------
        bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);
        bfm.wr(R_IRQSTAT, 32'h7);
        u_esp.packet(20, 8'h40);                         // 20 into a 16-deep FIFO
        repeat (20) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        check(d[8:4] == 5'd16, $sformatf("[R-8] FIFO holds 16 (got %0d)", d[8:4]));
        check(d[ST_OVR], "[R-8] OVERRUN is set");
        bfm.read(R_IRQSTAT, d, e);
        check(d[2], "[R-8] IRQSTAT[2] captured it");
        nbad = 0;
        for (i = 0; i < 16; i++) begin
            bfm.read(R_RXDATA, d, e);
            if (d[7:0] != 8'h40 + i[7:0]) nbad++;
        end
        check(nbad == 0,
              $sformatf("[R-8] the 16 kept bytes are the FIRST 16, contiguous (%0d wrong)", nbad));
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
        check(irq, "[R-6] packet-complete interrupt asserted");
        repeat (60) @(posedge pclk);
        check(irq, "[R-6] still asserted 60 pclk later");
        bfm.wr(R_IRQSTAT, 32'h2);
        repeat (4) @(posedge pclk);
        check(!irq, "[R-6] W1C clears it");
        bfm.wr(R_IRQEN, 32'h0);

        // ---- DMA ----------------------------------------------------------------------
        bfm.wr(R_DMACTL, 32'h1);
        repeat (4) @(posedge pclk);
        check(dma_req, "[R-7] dma_req asserts - bytes are waiting from the last packet");
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
        check(u_dchk.violations() == 0, "[R-7] dma_req_checker clean");
        bfm.wr(R_DMACTL, 32'h0);

        // ---- SCLK rate: correct at the limit, and where it breaks -----------------------
        // [N-7.1a] says SCLK <= pclk/6. pclk is 8 ns, so the limit is a 24 ns
        // half period. This walks past it and reports the measured edge.
        begin
            real hn;
            int  first_bad = 0;
            // Deliberately NOT multiples of the 8 ns pclk: with aligned edges
            // the oversampler looks better than it is, because every sample
            // lands in the same place in the bit.
            for (hn = 49.0; hn >= 9.0; hn = hn - 5.0) begin
                bfm.wr(R_CTRL, 32'h3); bfm.wr(R_CTRL, 32'h1);
                u_esp.half_ns = hn;
                u_esp.packet(4, 8'h10);
                repeat (30) @(posedge pclk);
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
        end
        u_esp.half_ns = 100.0;

        check(pready_viol == 0, "[R-5] PREADY high in every cycle of every access");

        $display("tb_spis: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end

    initial begin #20_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
