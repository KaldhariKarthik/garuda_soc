`timescale 1ns/1ps
// =============================================================================
// tb_map_pkg.sv -- qualification of garuda_map_pkg (Track A bus plan B0)
//
// garuda_map_pkg (tools/gen/gen_map_pkg.py) and rtl/include/garuda_map.vh
// (tools/garuda_gen.py) are both generated from garuda_system.yaml by different
// scripts. This bench checks that they agree value by value, and that the
// package's decode functions give the specified answers on hand-picked
// addresses (edges of every region and of the APB aperture). Every bus/DMA
// model trusts the package, so the package is checked before it is used.
//
// +NEGCTL  compares one value against a deliberately wrong constant: the run
//          must FAIL with "[FAIL] [negctl]", proving a mismatch is reported.
// =============================================================================
`include "garuda_map.vh"

module tb_map_pkg;
    import garuda_map_pkg::*;

    int checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s", what); end
    endtask
    task automatic eq(input longint got, input longint exp, input string what);
        check(got == exp, $sformatf("%s: package %0d (0x%0h), expected %0d (0x%0h)", what, got, got, exp, exp));
    endtask

    initial begin
        // ---- package vs RTL header ------------------------------------------
        eq(ISRAM_BASE,   `GARUDA_ISRAM_BASE,   "ISRAM_BASE");   eq(ISRAM_BYTES,   `GARUDA_ISRAM_SIZE,   "ISRAM size");
        eq(BOOTROM_BASE, `GARUDA_BOOTROM_BASE, "BOOTROM_BASE"); eq(BOOTROM_BYTES, `GARUDA_BOOTROM_SIZE, "BOOTROM size");
        eq(DSRAM_BASE,   `GARUDA_DSRAM_BASE,   "DSRAM_BASE");   eq(DSRAM_BYTES,   `GARUDA_DSRAM_SIZE,   "DSRAM size");
        eq(APB_BASE,     `GARUDA_APB_BASE,     "APB_BASE");     eq(APB_BYTES,     `GARUDA_APB_SIZE,     "APB aperture");
        eq(APB_WINDOW_BYTES, `GARUDA_APB_WINDOW_BYTES, "APB window size");
        eq(APB_TIMEOUT_PCLK, `GARUDA_APB_TIMEOUT_PCLK, "APB timeout");
        eq(APB_WINDOW_MASK_ALL, `GARUDA_APB_WINDOW_MASK_ALL, "APB window mask");
        eq(WIN_SPI_SLAVE, `GARUDA_APB_WIN_SPI_SLAVE, "WIN spi_slave");   eq(WIN_SPI_MASTER, `GARUDA_APB_WIN_SPI_MASTER, "WIN spi_master");
        eq(WIN_I2C, `GARUDA_APB_WIN_I2C, "WIN i2c");                     eq(WIN_UART0, `GARUDA_APB_WIN_UART0, "WIN uart0");
        eq(WIN_UART1, `GARUDA_APB_WIN_UART1, "WIN uart1");               eq(WIN_DMA_CFG, `GARUDA_APB_WIN_DMA_CFG, "WIN dma_cfg");
        eq(WIN_UART2, `GARUDA_APB_WIN_UART2, "WIN uart2");               eq(WIN_GPIO, `GARUDA_APB_WIN_GPIO, "WIN gpio");
        eq(WIN_PWM, `GARUDA_APB_WIN_PWM, "WIN pwm");                     eq(WIN_RESET_CTRL, `GARUDA_APB_WIN_RESET_CTRL, "WIN reset_ctrl");
        eq(WIN_CLIC_CFG, `GARUDA_APB_WIN_CLIC_CFG, "WIN clic_cfg");      eq(WIN_TIMERS_CFG, `GARUDA_APB_WIN_TIMERS_CFG, "WIN timers_cfg");
        eq(DMA_CHANNELS, `GARUDA_DMA_CHANNELS, "DMA channels");
        eq(DMA_PRIO[0], `GARUDA_DMA_PRIO_CH0, "DMA prio ch0"); eq(DMA_PRIO[1], `GARUDA_DMA_PRIO_CH1, "DMA prio ch1");
        eq(DMA_PRIO[2], `GARUDA_DMA_PRIO_CH2, "DMA prio ch2"); eq(DMA_PRIO[3], `GARUDA_DMA_PRIO_CH3, "DMA prio ch3");
        eq(DMA_PRIO[4], `GARUDA_DMA_PRIO_CH4, "DMA prio ch4"); eq(DMA_PRIO[5], `GARUDA_DMA_PRIO_CH5, "DMA prio ch5");
        // channel -> peripheral window, against the RTL header's channel numbers
        eq(DMA_PERIPH_WIN[`GARUDA_DMA_CH_SPI_MASTER], `GARUDA_APB_WIN_SPI_MASTER, "DMA ch spi_master window");
        eq(DMA_PERIPH_WIN[`GARUDA_DMA_CH_I2C],        `GARUDA_APB_WIN_I2C,        "DMA ch i2c window");
        eq(DMA_PERIPH_WIN[`GARUDA_DMA_CH_UART0],      `GARUDA_APB_WIN_UART0,      "DMA ch uart0 window");
        eq(DMA_PERIPH_WIN[`GARUDA_DMA_CH_UART1],      `GARUDA_APB_WIN_UART1,      "DMA ch uart1 window");
        eq(DMA_PERIPH_WIN[`GARUDA_DMA_CH_SPI_SLAVE],  `GARUDA_APB_WIN_SPI_SLAVE,  "DMA ch spi_slave window");
        eq(DMA_PERIPH_WIN[`GARUDA_DMA_CH_UART2],      `GARUDA_APB_WIN_UART2,      "DMA ch uart2 window");
        for (int c = 0; c < 6; c++) begin
            eq(CLIC_ID_DMA_COMPLETE[c], `GARUDA_CLIC_ID_DMA_COMPLETE_CH0_5_FIRST + c, $sformatf("CLIC complete ch%0d", c));
            eq(CLIC_ID_DMA_ERROR[c],    `GARUDA_CLIC_ID_DMA_ERROR_CH0_5_FIRST + c,    $sformatf("CLIC error ch%0d", c));
        end
        eq(CLIC_ID_SPI_SLAVE, `GARUDA_CLIC_ID_SPI_SLAVE, "CLIC spi_slave"); eq(CLIC_ID_UART2, `GARUDA_CLIC_ID_UART2, "CLIC uart2");
        eq(CLIC_ID_WDT_EARLY_WARNING, `GARUDA_CLIC_ID_WDT_EARLY_WARNING, "CLIC wdt");
        begin   // every ID with a source is in the RTL's ID mask; no reserved ID is
            logic [31:0] m = `GARUDA_CLIC_ID_MASK;
            foreach (CLIC_ID_RESERVED[i]) check(!m[CLIC_ID_RESERVED[i]], $sformatf("reserved CLIC ID %0d not in GARUDA_CLIC_ID_MASK", CLIC_ID_RESERVED[i]));
            for (int c = 0; c < 6; c++) check(m[CLIC_ID_DMA_COMPLETE[c]] && m[CLIC_ID_DMA_ERROR[c]], $sformatf("DMA ch%0d IDs in mask", c));
        end

        // ---- decode functions on hand-worked addresses ----------------------
        check(region_of(32'h0000_0000) == R_ISRAM,   "0x0000_0000 ISRAM");
        check(region_of(32'h0000_FFFF) == R_ISRAM,   "0x0000_FFFF ISRAM (last byte)");
        check(region_of(32'h0001_0000) == R_NONE,    "0x0001_0000 past ISRAM");
        check(region_of(32'h1000_0FFF) == R_BOOTROM, "0x1000_0FFF BOOTROM (last byte)");
        check(region_of(32'h1000_1000) == R_NONE,    "0x1000_1000 past BOOTROM");
        check(region_of(32'h2000_FFFC) == R_DSRAM,   "0x2000_FFFC DSRAM");
        check(region_of(32'h3000_0000) == R_NONE,    "0x3000_0000 undecoded");
        check(region_of(32'h4000_BFFF) == R_APB,     "0x4000_BFFF APB (last byte)");
        check(region_of(32'h4000_C000) == R_NONE,    "0x4000_C000 past the APB aperture");
        check(region_of(32'h4001_5000) == R_NONE,    "0x4001_5000 past the APB aperture (APB-2 address)");
        check(region_of(32'hF000_0000) == R_NONE,    "0xF000_0000 undecoded");
        check(apb_window_of(32'h4000_5000) == 5,     "0x4000_5000 -> window 5");
        check(apb_window_of(32'h4000_0FFC) == 0,     "0x4000_0FFC -> window 0");
        check(apb_window_of(32'h4000_C000) == -1,    "0x4000_C000 -> no window");
        check(apb_window_of(32'h4001_5000) == -1,    "0x4001_5000 -> no window");
        check(apb_window_of(32'h4000_3000, 16'h0FF7) == -1, "window 3 masked off -> no window");
        check(region_nibble_decoded(4'h4) && !region_nibble_decoded(4'h3), "nibble decode 4 yes, 3 no");
        check(!region_writable(R_BOOTROM) && region_writable(R_DSRAM), "BOOTROM read-only, DSRAM writable");
        check(ahb_winner(4'b1111) == M_DMA && ahb_winner(4'b0111) == M_SBA && ahb_winner(4'b0011) == M_DPORT
              && ahb_winner(4'b0001) == M_IPORT && ahb_winner(4'b0000) == -1, "AHB fixed priority DMA > SBA > D > I");
        check(dma_winner(6'b111111) == 0 && dma_winner(6'b111110) == 4 && dma_winner(6'b101110) == 1
              && dma_winner(6'b101100) == 3 && dma_winner(6'b100100) == 2 && dma_winner(6'b100000) == 5,
              "DMA order CH0 > CH4 > CH1 > CH3 > CH2 > CH5");
        foreach (DMA_PRIO_ORDER[i]) if (i > 0) check(DMA_PRIO[DMA_PRIO_ORDER[i-1]] > DMA_PRIO[DMA_PRIO_ORDER[i]], "DMA_PRIO_ORDER descending");
        check(master_reaches(M_DMA, R_DSRAM) && master_reaches(M_DMA, R_APB) && !master_reaches(M_DMA, R_BOOTROM),
              "DMA reaches DSRAM and APB, not Boot ROM (YAML)");
        check(master_reaches(M_IPORT, R_BOOTROM) && master_reaches(M_SBA, R_ISRAM), "I-port reaches Boot ROM, SBA reaches ISRAM");

        if ($test$plusargs("NEGCTL")) begin
            checks++;
            if (DMA_PRIO[0] != 4) begin fails++; $display("[FAIL] [negctl] DMA prio ch0 compared against a wrong constant (4)"); end
        end

        $display("CHECKS: %0d  FAILS: %0d", checks, fails);
        if (fails == 0 && checks > 0) $display("RESULT: PASSED"); else $display("RESULT: FAILED");
        $finish;
    end
endmodule
