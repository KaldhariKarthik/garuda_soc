`timescale 1ns/1ps
// =============================================================================
// tb_spim.sv -- Block 13 SPI master (vendored PULP engine + GARUDA wrapper)
//
// Spec: GARUDA-SPIM-SPEC-001 §11. Drives the real flash model on the pins.
//   R-1/R-2  a flash 0x03 read returns the programmed bytes, CS held throughout
//   R-3      only the selected chip select falls; never both
//   R-4      SCLK <= 20 MHz at CLKDIV=3 (the flash model checks it too)
//   R-5      PREADY high in every cycle of every access
//   R-6      IRQ sticky and held; cleared only by W1C
//   R-7      dma_req drops after ack (dma_req_checker)
//   R-8      pins at safe idle out of reset
//   plus     PSLVERR on an unmapped offset, ID register, RDID via the model
// =============================================================================
module tb_spim;

    logic pclk = 0, preset_n = 0;
    always #4 pclk = ~pclk;                        // 125 MHz

    garuda_apb_bfm bfm (.pclk(pclk), .preset_n(preset_n));

    logic dma_ack = 0;
    wire  irq, dma_req;
    wire  sclk, mosi, cs_flash_n, cs_imu_n;
    wire  miso;

    garuda_spim_top dut (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(bfm.psel), .penable_i(bfm.penable), .pwrite_i(bfm.pwrite),
        .paddr_i(bfm.paddr), .pwdata_i(bfm.pwdata), .prdata_o(bfm.prdata),
        .pready_o(bfm.pready), .pslverr_o(bfm.pslverr),
        .irq_o(irq), .dma_req_o(dma_req), .dma_ack_i(dma_ack),
        .spim_sclk_o(sclk), .spim_mosi_o(mosi), .spim_miso_i(miso),
        .spim_cs_flash_n_o(cs_flash_n), .spim_cs_imu_n_o(cs_imu_n));

    spi_flash_model #(.MAX_MHZ(20.0)) u_flash (
        .cs_n(cs_flash_n), .sclk(sclk), .mosi(mosi), .miso(miso));

    dma_req_checker #(.NAME("spim")) u_dchk (
        .clk_i(pclk), .rst_n_i(preset_n), .req_i(dma_req), .ack_i(dma_ack));

    // contract monitors
    int pready_viol = 0, cs_both = 0;
    always @(posedge pclk) begin
        if (preset_n && bfm.psel && !bfm.pready) pready_viol++;
        if (preset_n && !cs_flash_n && !cs_imu_n) cs_both++;
    end
    realtime sclk_edge = 0, sclk_min = 1e9;
    always @(sclk) begin
        if (sclk_edge > 0 && ($realtime - sclk_edge) < sclk_min) sclk_min = $realtime - sclk_edge;
        sclk_edge = $realtime;
    end

    // register offsets (SPIM-SPEC §6)
    localparam [11:0] R_STATUS = 12'h000, R_CLKDIV = 12'h004, R_CMD = 12'h008,
                      R_ADDR   = 12'h00C, R_LEN    = 12'h010, R_DUM = 12'h014,
                      R_TXFIFO = 12'h018, R_RXFIFO = 12'h020, R_INTCFG = 12'h024,
                      R_IRQSTAT = 12'hFE0, R_IRQEN = 12'hFE4, R_DMACTL = 12'hFE8,
                      R_ID = 12'hFEC;
    localparam CS_FLASH = (1 << 8), CS_IMU = (1 << 9);
    localparam ST_RD = (1 << 0);

    int checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    // one 32-bit flash word, exactly as sw/bootrom/spim.c will do it (§7.1)
    //
    // Poll the RX word count, NOT STATUS[0]. STATUS[0] is the engine's idle
    // bit, and it is still set in the cycles between the STATUS write and the
    // FSM leaving IDLE - a poll loop that starts fast enough sees "idle" and
    // reads an empty FIFO. "A word has arrived" has no such race.
    task automatic flash_read_word(input [23:0] byte_addr, output [31:0] w);
        logic [31:0] d;
        bit e;
        int guard;
        bfm.wr(R_CMD, 32'h0300_0000);                       // cmd 0x03, MSB-aligned
        bfm.wr(R_ADDR, byte_addr << 8);                     // 24-bit address, MSB-aligned
        bfm.wr(R_LEN, (32 << 16) | (24 << 8) | 8);          // data / addr / cmd bits
        bfm.wr(R_STATUS, CS_FLASH | ST_RD);                 // select flash, start read
        guard = 0;
        do begin bfm.read(R_STATUS, d, e); guard++; end
        while (d[20:16] == 0 && guard < 4000);
        bfm.read(R_RXFIFO, w, e);
    endtask

    // drop whatever a transfer left in the RX FIFO
    task automatic drain_rx();
        logic [31:0] d;
        bit e;
        bfm.read(R_STATUS, d, e);
        while (d[20:16] != 0) begin
            bfm.read(R_RXFIFO, d, e);
            bfm.read(R_STATUS, d, e);
        end
    endtask

    logic [31:0] d, w;
    bit e;
    int i, t;

    initial begin
        $display("=== tb_spim: Block 13 SPI master ===");

        // fill the flash: byte i = 0xA0 + i, then a recognisable pattern
        for (i = 0; i < 256; i++) u_flash.bd_write(i, 8'hA0 + i[7:0]);
        u_flash.bd_write(32'h20, 8'h44); u_flash.bd_write(32'h21, 8'h52);
        u_flash.bd_write(32'h22, 8'h41); u_flash.bd_write(32'h23, 8'h47);

        repeat (4) @(posedge pclk);
        check(cs_flash_n && cs_imu_n && !sclk, "[R-8] pins at safe idle while in reset");
        preset_n = 1;
        repeat (4) @(posedge pclk);
        check(cs_flash_n && cs_imu_n && !sclk, "[R-8] pins at safe idle out of reset");

        bfm.read(R_ID, d, e);
        check(d == {16'h6A5D, 8'd13, 8'd1} && !e, "ID register reads block 13");
        bfm.read(12'h800, d, e);
        check(e, "PSLVERR on an unmapped offset");

        // ---- flash read ---------------------------------------------------------
        bfm.wr(R_CLKDIV, 32'd3);                            // 15.6 MHz (§6.2)
        bfm.wr(R_DUM, 32'd0);
        flash_read_word(24'h000020, w);
        check(w == 32'h44524147, $sformatf("[R-1] flash read at 0x20 returned %08h (bytes 44 52 41 47)", w));
        flash_read_word(24'h000000, w);
        check(w == 32'hA0A1A2A3, $sformatf("[R-1] flash read at 0x00 returned %08h", w));
        flash_read_word(24'h000004, w);
        check(w == 32'hA4A5A6A7, "[R-1] a second read advances to the next word");

        check(u_flash.viol() == 0, "[R-2/R-4] flash model saw no protocol violation (CS held, SCLK in range, MOSI stable)");
        check(sclk_min >= 31.9, $sformatf("[R-4] shortest SCLK half-period %0.1f ns (>= 32 ns = 15.6 MHz)", sclk_min));
        check(cs_both == 0, "[R-3] the two chip selects are never asserted together");
        check(cs_flash_n && cs_imu_n, "chip selects released after the transfer");

        // ---- IMU chip select ------------------------------------------------------
        bfm.wr(R_CMD, 32'h9F00_0000);
        bfm.wr(R_LEN, (24 << 16) | (0 << 8) | 8);
        fork
            bfm.wr(R_STATUS, CS_IMU | ST_RD);
            begin
                wait (!cs_imu_n);
                check(cs_flash_n, "[R-3] selecting the IMU leaves the flash deselected");
            end
        join
        t = 0;
        do begin bfm.read(R_STATUS, d, e); t++; end while (d[20:16] == 0 && t < 4000);
        check(t < 4000, "IMU-selected transfer completed");
        drain_rx();

        // ---- interrupt ------------------------------------------------------------
        bfm.wr(R_IRQSTAT, 32'h7);
        bfm.wr(R_IRQEN, 32'h1);                              // transfer complete
        flash_read_word(24'h000008, w);
        repeat (40) @(posedge pclk);
        check(irq, "[R-6] transfer-complete IRQ is asserted and still held 40 cycles later");
        bfm.read(R_IRQSTAT, d, e);
        check(d[0], "IRQSTAT[0] captured the completion");
        bfm.wr(R_IRQSTAT, 32'h1);
        repeat (2) @(posedge pclk);
        check(!irq, "[R-6] W1C clears it");

        // ---- DMA request ------------------------------------------------------------
        // One 32-bit word takes 32 SCLK = ~2 us = ~256 pclk to arrive, so the
        // gap between the two beats is long; the point of the test is that the
        // request DROPS after each ack and comes BACK for the next word.
        drain_rx();
        bfm.wr(R_DMACTL, 32'h1);                             // request on RX data
        bfm.wr(R_CMD, 32'h0300_0000);
        bfm.wr(R_ADDR, 32'h0000_0000);
        bfm.wr(R_LEN, (64 << 16) | (24 << 8) | 8);           // two words
        bfm.wr(R_STATUS, CS_FLASH | ST_RD);
        t = 0;
        while (!dma_req && t < 4000) begin @(posedge pclk); t++; end
        check(dma_req, "[R-7] dma_req asserts once the RX FIFO has a word");

        // beat 1: the DMA reads the FIFO then acks, exactly as rtl/dma does
        bfm.read(R_RXFIFO, w, e);
        check(w == 32'hA0A1A2A3, $sformatf("DMA beat 1 read %08h", w));
        @(posedge pclk); #0.1 dma_ack = 1;
        @(posedge pclk); #0.1 dma_ack = 0;
        #0.5 check(!dma_req, "[R-7] dma_req drops on ack");

        t = 0;
        while (!dma_req && t < 4000) begin @(posedge pclk); t++; end
        check(dma_req && t >= 1, "[R-7] and re-asserts for the second word after a gap");
        bfm.read(R_RXFIFO, w, e);
        check(w == 32'hA4A5A6A7, $sformatf("DMA beat 2 read %08h", w));
        @(posedge pclk); #0.1 dma_ack = 1;
        @(posedge pclk); #0.1 dma_ack = 0;
        repeat (8) @(posedge pclk);
        check(!dma_req, "dma_req drops when the FIFO empties");
        check(u_dchk.violations() == 0, "[R-7] dma_req_checker clean");
        bfm.wr(R_DMACTL, 32'h0);

        check(pready_viol == 0, "[R-5] PREADY high in every cycle of every access");

        $display("tb_spim: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end

    initial begin #3_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
