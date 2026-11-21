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

    logic pclk = 0, preset_n = 1;

    // ---- reset must arrive as an EDGE, not merely be low at time 0 (TB-22) ---
    // A Verilog async reset is edge-sensitive in simulation: `always @(... or
    // negedge rst_n)` is not evaluated just because rst_n is already low when
    // the run starts. A reset declared `= 0` therefore produces no negedge
    // ever, and every flop whose only reset is that signal stays X for the
    // whole simulation -- and `q <= ~q` on a clock divider keeps X forever, so
    // the derived clock and its reset never resolve. Real silicon resets on a
    // LEVEL and cannot behave this way; it is a simulation artefact, so the fix
    // belongs here. Declare the reset de-asserted and assert it at time 0.
    initial #0 preset_n = 1'b0;

    always #4 pclk = ~pclk;                        // 125 MHz

    garuda_apb_bfm bfm (.pclk(pclk), .preset_n(preset_n));

    logic dma_ack = 0;
    wire  irq, dma_req;
    wire  sclk, mosi, cs_flash_n, cs_imu_n;
    wire  miso;

    garuda_spim_top dut (
        .pclk(pclk), .preset_n(preset_n),
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
    int pready_viol = 0, cs_both = 0, quad_cycles = 0, cs_low = 0;
    always @(posedge pclk) if (preset_n && (!cs_flash_n || !cs_imu_n)) cs_low++;
    // SPIM-4: the engine never leaves single-bit mode ([N-7.5]). en_quad is the vendored controller's own
    // quad flag; its spi_mode output reads SPI_QUAD_RX whenever it is idle, so it cannot be used
    always @(posedge pclk) if (preset_n && dut.u_spi.u_spictrl.en_quad !== 1'b0) quad_cycles++;
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

    // wait for a started transfer to end: the engine leaves IDLE within a few cycles of the
    // STATUS write (see flash_read_word), so poll the idle bit only after that
    task automatic xfer_idle(output int g);
        logic [31:0] d;
        bit e;
        repeat (8) @(posedge pclk);
        g = 0;
        do begin bfm.read(R_STATUS, d, e); g++; end
        while (!d[0] && g < 4000);
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

        // ---- AUD-13: PSLVERR exactly where the window has no register, all 4096 offsets ----
        begin : map_sweep
            integer nb;
            bfm.sweep_map(64'h77F, nb);
            check(nb == 0, $sformatf("[AUD-13] PSLVERR at every offset that is not a register, and at no register (0x00 to 0x18, 0x20, 0x24, 0x28 and the tail): %0d wrong", nb));
        end

        // ---- SPIM-3: a STATUS write that sets both chip-select bits must not select both devices ----
        begin : both_cs
            logic [31:0] d; bit e; int g; int n0;
            n0 = cs_both;
            bfm.wr(R_CMD, 32'h0300_0000);
            bfm.wr(R_ADDR, 32'h0);
            bfm.wr(R_LEN, (32 << 16) | (24 << 8) | 8);
            bfm.wr(R_STATUS, CS_FLASH | CS_IMU | ST_RD);       // a firmware mistake: both bits
            g = 0;
            do begin bfm.read(R_STATUS, d, e); g++; end
            while (d[20:16] == 0 && g < 4000);
            drain_rx();
            check(cs_both == n0, $sformatf("[R-3] SPIM-3: both chip-select bits written, the two pins still never low together (%0d cycles both low)", cs_both - n0));
        end

        // ---- SPIM-4: STATUS[2] and [3] would start a quad transfer upstream; GARUDA has no quad pins ----
        begin : no_quad
            int n0;
            n0 = quad_cycles;
            bfm.wr(R_STATUS, CS_FLASH | (1 << 2));               // quad read requested
            repeat (200) @(posedge pclk);
            bfm.wr(R_STATUS, CS_FLASH | (1 << 3));               // quad write requested
            repeat (200) @(posedge pclk);
            bfm.wr(R_STATUS, CS_FLASH | (3 << 2));               // both quad bits
            repeat (200) @(posedge pclk);
            drain_rx();
            check(quad_cycles == n0, $sformatf("[N-7.5] SPIM-4: a quad start bit written to STATUS leaves the engine in single-bit mode (%0d cycles in quad mode)", quad_cycles - n0));
        end

        // ---- coverage closure (2026-11-20, D-40): the register model of SPEC §6 -----------
        // Every command / address / data length class, read and write, each device select,
        // dummy cycles, slower dividers, the threshold interrupts, TX DMA and the soft reset.
        // Command 0xA5 is not one the flash model answers, so no flash protocol rule applies.
        begin : matrix
            int cl[3] = '{0, 8, 16};
            int al[4] = '{0, 24, 32, 16};
            int dl[4] = '{0, 32, 64, 16};
            int nbad, n, n_eot;
            nbad = 0; n = 0; n_eot = 0;
            bfm.wr(R_CLKDIV, 32'd3);
            bfm.wr(R_CMD, 32'hA500_0000); bfm.wr(R_ADDR, 32'h1234_5678);
            foreach (cl[a]) foreach (al[b]) foreach (dl[c]) for (int dir = 1; dir <= 2; dir++) begin
                bfm.wr(R_LEN, (dl[c] << 16) | (al[b] << 8) | cl[a]);
                bfm.wr(R_DUM, ((a + b + c) % 3 == 0) ? 32'h0004_0004 : 32'h0);
                if (dir == 2) for (int k = 0; k < (dl[c] + 31) / 32; k++) bfm.wr(R_TXFIFO, 32'hC0DE_0000 + k);
                bfm.wr(R_IRQSTAT, 32'h7);
                bfm.wr(R_STATUS, (((a + b + c + dir) % 2) ? CS_IMU : CS_FLASH) | dir);
                xfer_idle(t);
                n++;
                if (t >= 4000) begin nbad++; $display("[FAIL] len cmd %0d addr %0d data %0d dir %0d did not finish", cl[a], al[b], dl[c], dir); end
                // SPIM-6: every transfer ends with IRQSTAT[0], with or without a data phase ([N-6.1a]);
                // all three lengths 0 is no transfer at all and is not counted
                bfm.read(R_IRQSTAT, d, e);
                if ((cl[a] + al[b] + dl[c]) != 0) begin
                    n_eot++;
                    if (!d[0]) begin nbad++; $display("[FAIL] SPIM-6: len cmd %0d addr %0d data %0d dir %0d ended without IRQSTAT[0]", cl[a], al[b], dl[c], dir); end
                end
                drain_rx();
                bfm.read(R_STATUS, d, e);
                if (d[28:24] != 0) begin nbad++; $display("[FAIL] len cmd %0d addr %0d data %0d dir %0d left %0d TX words", cl[a], al[b], dl[c], dir, d[28:24]); end
            end
            check(nbad == 0, $sformatf("[N-6.1] %0d transfers over every command/address/data length class, read and write, with and without dummy cycles: each returns to idle with its FIFO words used", n));
            check(nbad == 0 && n_eot > 0, $sformatf("[N-6.1a] SPIM-6: IRQSTAT[0] set at the end of all %0d transfers, those with no data phase included", n_eot));
            bfm.wr(R_DUM, 32'h0);
        end

        begin : devices_dirs
            int nbad; nbad = 0;
            bfm.wr(R_LEN, (32 << 16) | (0 << 8) | 8);
            for (int dv = 0; dv < 4; dv++) for (int dir = 1; dir <= 3; dir++) begin
                if (dir == 2) bfm.wr(R_TXFIFO, 32'h5A5A_A5A5);
                bfm.wr(R_STATUS, (dv << 8) | dir);
                xfer_idle(t);
                if (t >= 4000) nbad++;
                drain_rx();
            end
            bfm.read(R_STATUS, d, e);
            check(nbad == 0 && d[28:24] == 0, "[N-6.1] each device select with read, write and both bits set completes (read wins when both are set)");
            check(cs_both == 0, "[R-3] the two chip selects are never asserted together (whole run)");
        end

        begin : dividers
            realtime m;
            bfm.wr(R_LEN, (32 << 16) | (24 << 8) | 8);
            bfm.wr(R_CMD, 32'h0300_0000); bfm.wr(R_ADDR, 32'h0000_0000);
            for (int k = 0; k < 2; k++) begin
                bfm.wr(R_CLKDIV, k ? 32'd16 : 32'd5);
                sclk_min = 1e9;
                bfm.wr(R_STATUS, CS_FLASH | ST_RD);
                xfer_idle(t);
                bfm.read(R_RXFIFO, w, e);
                check(w == 32'hA0A1A2A3 && t < 4000 && sclk_min >= (k ? 135.0 : 47.0),
                      $sformatf("[N-6.2] CLKDIV %0d: flash read %08h, shortest SCLK half-period %0.1f ns", k ? 16 : 5, w, sclk_min));
            end
            bfm.wr(R_CLKDIV, 32'd3);
            check(u_flash.viol() == 0, "[R-2/R-4] flash model saw no protocol violation (whole run)");
        end

        begin : thresholds
            // INTCFG [3:0] TX threshold, [11:8] RX threshold, [19:16]/[27:24] counts, [30] count
            // enable, [31] enable; INTSTA read re-arms. Events reach IRQSTAT [1] RX / [2] TX.
            bfm.wr(R_IRQSTAT, 32'h7); bfm.wr(R_IRQEN, 32'h0);
            bfm.wr(R_INTCFG, (1 << 31) | (2 << 8) | 0);        // TX <= 0 words, RX >= 2 words
            repeat (8) @(posedge pclk);
            bfm.read(R_IRQSTAT, d, e);
            check(d[2] && !d[1], "[N-7.7] TX threshold event with an empty TX FIFO; no RX event yet");
            bfm.read(12'h028, d, e);                            // INTSTA: re-arm
            bfm.wr(R_IRQSTAT, 32'h7);
            bfm.wr(R_LEN, (64 << 16) | (24 << 8) | 8);
            bfm.wr(R_STATUS, CS_FLASH | ST_RD);
            xfer_idle(t);
            repeat (8) @(posedge pclk);
            bfm.read(R_IRQSTAT, d, e);
            check(d[1], "[N-7.7] RX threshold event once two words are in the RX FIFO");
            drain_rx();
            // counted mode: the event re-arms after cnt words moved, not on an INTSTA read
            bfm.wr(R_INTCFG, (1 << 31) | (1 << 30) | (2 << 24) | (2 << 16) | (1 << 8) | 0);
            bfm.wr(R_IRQSTAT, 32'h7);
            for (int k = 0; k < 2; k++) begin
                bfm.wr(R_LEN, (64 << 16) | (24 << 8) | 8);
                bfm.wr(R_STATUS, CS_FLASH | ST_RD);
                xfer_idle(t); drain_rx();
                bfm.wr(R_LEN, (64 << 16) | (0 << 8) | 8);
                bfm.wr(R_TXFIFO, 32'h1111_2222); bfm.wr(R_TXFIFO, 32'h3333_4444);
                bfm.wr(R_STATUS, CS_IMU | 2);
                xfer_idle(t);
            end
            bfm.read(R_IRQSTAT, d, e);
            check(d[1] && d[2], "[N-7.7] counted mode: RX and TX events again after each two-word transfer");
            bfm.wr(R_INTCFG, 32'h0); bfm.wr(R_IRQSTAT, 32'h7);
        end

        begin : tx_dma
            // DMACTL[1]: dma_req while the TX FIFO has space; the DMA writes one word per beat
            int nb;
            for (int mode = 2; mode <= 3; mode++) begin
                bfm.wr(R_DMACTL, mode);
                nb = 0;
                for (int k = 0; k < 3; k++) begin
                    t = 0; while (!dma_req && t < 400) begin @(posedge pclk); t++; end
                    if (dma_req) begin
                        bfm.wr(R_TXFIFO, 32'hD0A0_0000 + k);
                        @(posedge pclk); #0.1 dma_ack = 1;
                        @(posedge pclk); #0.1 dma_ack = 0;
                        nb++;
                    end
                end
                bfm.read(R_STATUS, d, e);
                check(nb == 3 && d[28:24] == 3, $sformatf("[N-7.8] DMACTL %0d: three TX beats, three words in the TX FIFO (%0d)", mode, d[28:24]));
                bfm.wr(R_LEN, (96 << 16) | (0 << 8) | 8);
                bfm.wr(R_STATUS, CS_IMU | 2);                      // started with the DMA still enabled
                bfm.wr(R_DMACTL, 32'h0);
                xfer_idle(t);
            end
            check(u_dchk.violations() == 0, "[R-7] dma_req_checker clean (TX)");
        end

        begin : rx_backpressure
            // reads longer than the 10-word RX FIFO with nobody draining it: the engine stops
            // SCLK and waits (WAIT_FIFO), or holds the last word (WAIT_FIFO_DONE), and loses nothing
            logic [31:0] ex;
            int bad, nw;
            bfm.wr(R_CLKDIV, 32'd3); bfm.wr(R_DUM, 32'h0);
            bfm.wr(R_CMD, 32'h0300_0000); bfm.wr(R_ADDR, 32'h0000_0000);
            for (int len = 11; len <= 12; len++) begin
                bad = 0;
                bfm.wr(R_LEN, ((32 * len) << 16) | (24 << 8) | 8);
                bfm.wr(R_STATUS, CS_FLASH | ST_RD);
                repeat (6000) @(posedge pclk);
                bfm.read(R_STATUS, d, e);
                // 12 words: the engine stops mid-transfer (WAIT_FIFO); 11 words: the last word waits in the
                // receiver (WAIT_FIFO_DONE) after the controller has finished
                check(d[20:16] == 10 && (len == 11 || !d[0]), $sformatf("%0d-word read: the RX FIFO full (%0d words), the %s", len, d[20:16], len == 11 ? "last word held by the receiver" : "engine stopped mid-transfer"));
                nw = 0;
                for (int k = 0; k < len; k++) begin
                    t = 0;
                    do begin bfm.read(R_STATUS, d, e); t++; end while (d[20:16] == 0 && t < 4000);
                    bfm.read(R_RXFIFO, w, e);
                    for (int j = 0; j < 4; j++) begin
                        int bi;                                    // assigned, not initialised: a declaration
                        bi = 4 * k + j;                            // initialiser runs once (static)
                        ex[31 - 8*j -: 8] = (bi == 32'h20) ? 8'h44 : (bi == 32'h21) ? 8'h52 : (bi == 32'h22) ? 8'h41 : (bi == 32'h23) ? 8'h47 : 8'hA0 + bi[7:0];
                    end
                    if (w !== ex) begin bad++; if (bad < 4) $display("[FAIL] %0d-word read, word %0d: %08h, expected %08h", len, k, w, ex); end
                    nw++;
                end
                xfer_idle(t);
                bfm.read(R_STATUS, d, e);
                check(bad == 0 && nw == len && d[20:16] == 0 && t < 4000, $sformatf("%0d-word read through a full RX FIFO: every word in order (%0d wrong)", len, bad));
            end
            check(u_flash.viol() == 0, "[R-2] flash model clean through the stalls (SCLK stops only between bits)");
        end

        begin : dummy_rewrite
            // SPILEN rewritten to no data while the engine counts dummy cycles: the transfer
            // ends at the end of the dummy phase instead of hanging
            bfm.wr(R_CLKDIV, 32'd16);
            bfm.wr(R_DUM, 32'd40);
            bfm.wr(R_CMD, 32'hA500_0000);
            bfm.wr(R_LEN, (32 << 16) | (0 << 8) | 8);
            bfm.wr(R_IRQSTAT, 32'h7);
            bfm.wr(R_STATUS, CS_IMU | ST_RD);
            t = 0;
            do begin bfm.read(R_STATUS, d, e); t++; end while (!d[4] && t < 4000);
            bfm.wr(R_LEN, (0 << 16) | (0 << 8) | 8);
            xfer_idle(t);
            bfm.read(R_STATUS, d, e);
            bfm.read(R_IRQSTAT, w, e);
            check(t < 4000 && d[0] && d[20:16] == 0 && w[0], "SPILEN data cleared during the dummy phase: the transfer ends (end-of-transfer event), no word received");
            bfm.wr(R_IRQSTAT, 32'h7); bfm.wr(R_DUM, 32'h0); bfm.wr(R_CLKDIV, 32'd3);
        end

        begin : registers
            // every RW field of SPEC §6 written 0, 1, 0 and read back
            logic [11:0] o [6];
            logic [31:0] m [6];
            int bad;
            o = '{R_CLKDIV, R_CMD, R_ADDR, R_LEN, R_DUM, R_INTCFG};
            m = '{32'h0000_00FF, 32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'hFFFF_3F3F, 32'hFFFF_FFFF, 32'hDF1F_1F1F};
            bad = 0;
            for (int v = 0; v < 3; v++) foreach (o[k]) begin
                bfm.wr(o[k], (v == 1) ? 32'hFFFF_FFFF : 32'h0);
                bfm.read(o[k], d, e);
                if (d !== ((v == 1) ? m[k] : 32'h0)) begin bad++; $display("[FAIL] register %03h read %08h", o[k], d); end
            end
            check(bad == 0, "[SPEC §6] CLKDIV, SPICMD, SPIADR, SPILEN, SPIDUM, INTCFG: every field reads back 1 and 0");
            bfm.wr(R_IRQSTAT, 32'h7); bfm.wr(R_CLKDIV, 32'd3);
        end

        begin : tx_full
            // ten words fill the TX FIFO (BUFFER_DEPTH 10); an eleventh write is not taken and
            // the bus is not stalled (R-5); the soft reset below empties it
            for (int k = 0; k < 11; k++) bfm.wr(R_TXFIFO, 32'h7E57_0000 + k);
            bfm.read(R_STATUS, d, e);
            check(d[28:24] == 10, $sformatf("TX FIFO holds 10 words after 11 writes, the eleventh not taken (%0d)", d[28:24]));
            bfm.wr(R_STATUS, (1 << 4));
            repeat (4) @(posedge pclk);
        end

        begin : long_transfers
            // the 16-bit length and dummy counters through every bit: 65535 bits each way after
            // 65535 dummy cycles, at CLKDIV 3 (the fastest the spec allows: below 3 the first MOSI
            // bit changes on an SCLK rise, [N-6.3a] rule 3, which a_mosi_stable_on_rise catches),
            // on the IMU select (no flash rules);
            // counted interrupt mode on, the RX FIFO left to fill once before it is drained
            int nw, pushed, g;
            bfm.wr(R_CLKDIV, 32'd3);
            bfm.wr(R_INTCFG, (1 << 31) | (1 << 30) | (31 << 24) | (31 << 16) | (10 << 8) | 9);
            bfm.wr(R_DUM, 32'hFFFF_FFFF);
            bfm.wr(R_CMD, 32'hFFFF_FFFF); bfm.wr(R_ADDR, 32'hFFFF_FFFF);
            bfm.wr(R_LEN, (16'hFFFF << 16) | (32 << 8) | 32);
            bfm.wr(R_STATUS, CS_IMU | ST_RD);
            g = 0;
            do begin bfm.read(R_STATUS, d, e); g++; end while (d[20:16] != 10 && g < 400000);
            nw = 0; g = 0;
            do begin
                bfm.read(R_STATUS, d, e); g++;
                if (d[20:16] != 0) begin bfm.read(R_RXFIFO, w, e); nw++; end
            end while (!(d[0] && d[20:16] == 0) && g < 1000000);
            check(nw == 2048 && d[0], $sformatf("65535-bit read after 65535 dummy cycles: 2048 words (the last partial), engine idle (%0d)", nw));
            bfm.wr(R_STATUS, CS_IMU | 2);
            pushed = 0; g = 0;
            while (pushed < 2048 && g < 1000000) begin
                bfm.read(R_STATUS, d, e); g++;
                if (d[28:24] < 10) begin bfm.wr(R_TXFIFO, {$urandom, pushed[0]}); pushed++; end
            end
            xfer_idle(t);
            bfm.read(R_STATUS, d, e);
            check(pushed == 2048 && d[0] && d[28:24] == 0, $sformatf("65535-bit write after 65535 dummy cycles: 2048 words sent, TX FIFO empty, engine idle (%0d)", pushed));
            bfm.wr(R_INTCFG, 32'h0); bfm.wr(R_DUM, 32'h0); bfm.wr(R_IRQSTAT, 32'h7);
            // the slowest divider: an 8-bit command at CLKDIV 255
            bfm.wr(R_CLKDIV, 32'd255);
            bfm.wr(R_LEN, (0 << 16) | (0 << 8) | 8);
            sclk_min = 1e9;
            bfm.wr(R_STATUS, CS_IMU | 2);
            xfer_idle(t);
            check(t < 4000 && sclk_min >= 2047.0, $sformatf("CLKDIV 255: shortest SCLK half-period %0.1f ns (256 pclk)", sclk_min));
            bfm.wr(R_CLKDIV, 32'd3);
        end

        begin : push_on_pop
            // a TX FIFO write in the same cycle as the engine takes a word, with the FIFO neither
            // empty nor full: the count must stay right. The engine takes a word every 256 pclk at
            // CLKDIV 3; each write is timed from the last take, sweeping the offset by one cycle
            int hit, pushed;
            bfm.wr(R_CLKDIV, 32'd3); bfm.wr(R_CMD, 32'hA500_0000);
            bfm.wr(R_LEN, ((32 * 24) << 16) | (0 << 8) | 8);
            for (int k = 0; k < 4; k++) bfm.wr(R_TXFIFO, 32'h5050_0000 + k);
            pushed = 4; hit = 0;
            bfm.wr(R_STATUS, CS_IMU | 2);
            // each round: wait for a take, push one word timed onto the next take, push one more
            // (two taken, two pushed: the FIFO stays between empty and full)
            for (int k = 0; k < 10 && pushed < 24; k++) begin
                int g; g = 0;
                while (!(dut.u_spi.u_txfifo.ready_i && dut.u_spi.u_txfifo.valid_o) && g < 2000) begin @(posedge pclk); g++; end
                repeat (256 - 4 + (k % 6)) @(posedge pclk);
                fork
                    bfm.wr(R_TXFIFO, 32'h5050_0100 + k);
                    begin
                        repeat (6) begin
                            @(posedge pclk);
                            if (dut.u_spi.u_txfifo.ready_i && dut.u_spi.u_txfifo.valid_o && dut.u_spi.u_txfifo.valid_i) hit++;
                        end
                    end
                join
                bfm.wr(R_TXFIFO, 32'h5050_0180 + k);
                pushed += 2;
            end
            while (pushed < 24) begin bfm.wr(R_TXFIFO, 32'h5050_0200 + pushed); pushed++; end
            xfer_idle(t);
            bfm.read(R_STATUS, d, e);
            check(hit > 0 && d[0] && d[28:24] == 0, $sformatf("TX FIFO write in the cycle the engine takes a word (%0d times): 24 words in, 24 out, FIFO empty, engine idle", hit));
        end

        begin : cs_without_pin
            // STATUS[11:10] select the upstream chip selects 2 and 3, which have no pin: a read
            // runs, its word arrives, and neither device is selected (R-3)
            int n0, nw;
            bfm.wr(R_CLKDIV, 32'd3); bfm.wr(R_CMD, 32'hA500_0000);
            bfm.wr(R_LEN, (32 << 16) | (0 << 8) | 8);
            n0 = cs_low; nw = 0;
            for (int c = 2; c < 4; c++) begin
                bfm.wr(R_STATUS, (1 << (8 + c)) | ST_RD);
                xfer_idle(t);
                bfm.read(R_STATUS, d, e);
                if (d[20:16] == 1) begin bfm.read(R_RXFIFO, w, e); nw++; end
            end
            check(nw == 2 && cs_low == n0, $sformatf("[R-3] chip selects 2 and 3 (no pins): each read completes with one word and neither device selected (%0d words, %0d cycles a pin low)", nw, cs_low - n0));
        end

        begin : soft_reset
            bfm.wr(R_TXFIFO, 32'h1); bfm.wr(R_TXFIFO, 32'h2);
            bfm.read(R_STATUS, d, e);
            check(d[28:24] == 2, "two words waiting in the TX FIFO");
            bfm.wr(R_STATUS, (1 << 4));                           // soft reset
            repeat (4) @(posedge pclk);
            bfm.read(R_STATUS, d, e);
            check(d[28:24] == 0 && d[20:16] == 0 && d[0], "STATUS[4] soft reset empties both FIFOs and leaves the engine idle");
        end

        check(pready_viol == 0, "[R-5] PREADY high in every cycle of every access");

        $display("tb_spim: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end

    initial begin #40_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
