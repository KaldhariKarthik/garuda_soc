`timescale 1ns/1ps
// =============================================================================
// tb_chip.sv -- whole-chip smoke on garuda_chip_top (Rev 4.0)
//
// Pins only: 500 MHz refclk, ext_rst_n, boot_sel, JTAG. The real Boot ROM image
// (sw/build/bootrom.hex) runs from the reset vector. With boot_sel = 1 it
// enters the recovery loop and waits on the JTAG mailbox (D-20); the program
// under test is placed in ISRAM and the mailbox is posted, either by backdoor
// or - +MODE=jtag - over the real JTAG pins through the Debug Module's System
// Bus Access, which is the development loop of DEBUG-SPEC §7.6.
//
//   +TEST=<hex>   ISRAM image (sw/build/t_chip_*.hex)
//   +MODE=basic | irq | wdt | jtag | flash
//   +MAXUS=<n>    timeout in microseconds (default 400)
//
// Pass = the program writes 1 to tohost (0x2000_F000); (n<<1)|1 = step n
// failed. AHB-Lite protocol checkers watch all four masters and the shared
// slave bus throughout and fail the run on any violation.
// =============================================================================
module tb_chip;
    reg refclk = 0, ext_rst_n = 0, boot_sel = 1;
    reg tck = 0, tms = 1, tdi = 0;
    always #1 refclk = ~refclk;

    wire tdo, spim_sclk, spim_mosi, spim_cs_flash_n, spim_cs_imu_n, spim_miso;
    wire i2c_scl, i2c_sda, gpio0, gpio1;
    wire uart0_tx, uart1_tx, uart2_tx, pwm0, pwm1, pwm2, pwm3;
    pullup (i2c_scl); pullup (i2c_sda);

    garuda_chip_top #(.BROM_INIT_FILE("sw/build/bootrom.hex")) dut (
        .refclk(refclk), .ext_rst_n(ext_rst_n),
        .tck(tck), .tms(tms), .tdi(tdi), .tdo(tdo),
        .spim_sclk(spim_sclk), .spim_mosi(spim_mosi), .spim_miso(spim_miso),
        .spim_cs_flash_n(spim_cs_flash_n), .spim_cs_imu_n(spim_cs_imu_n),
        .i2c_scl(i2c_scl), .i2c_sda(i2c_sda),
        // Each UART's tx is looped back to its own rx. Nothing else in the chip
        // depends on these pins, and it lets t_chip_uart prove both directions
        // AND that the three instances do not talk to each other, with no
        // model on the board.
        .uart0_rx(uart0_tx), .uart0_tx(uart0_tx),
        .uart1_rx(uart1_tx), .uart1_tx(uart1_tx),
        .uart2_rx(uart2_tx), .uart2_tx(uart2_tx),
        .pwm0(pwm0), .pwm1(pwm1), .pwm2(pwm2), .pwm3(pwm3),
        .gpio0(gpio0), .gpio1(gpio1), .boot_sel(boot_sel));

    // ---- AHB-Lite protocol checkers --------------------------------------------
    wire hclk = dut.hclk;
    wire hrst = dut.hreset_n;
    wire [31:0] vi, vd, vs, vm, vsl;
    ahb_lite_checker u_ci (.clk_i(hclk), .rst_n_i(hrst),
        .haddr_i(dut.u_soc.i_haddr), .htrans_i(dut.u_soc.i_htrans), .hsize_i(dut.u_soc.i_hsize),
        .hburst_i(dut.u_soc.i_hburst), .hwrite_i(dut.u_soc.i_hwrite), .hwdata_i(dut.u_soc.i_hwdata),
        .hready_i(dut.u_soc.i_hready), .hresp_i(dut.u_soc.i_hresp), .viol_count_o(vi));
    ahb_lite_checker u_cd (.clk_i(hclk), .rst_n_i(hrst),
        .haddr_i(dut.u_soc.d_haddr), .htrans_i(dut.u_soc.d_htrans), .hsize_i(dut.u_soc.d_hsize),
        .hburst_i(dut.u_soc.d_hburst), .hwrite_i(dut.u_soc.d_hwrite), .hwdata_i(dut.u_soc.d_hwdata),
        .hready_i(dut.u_soc.d_hready), .hresp_i(dut.u_soc.d_hresp), .viol_count_o(vd));
    ahb_lite_checker u_cs (.clk_i(hclk), .rst_n_i(hrst),
        .haddr_i(dut.u_soc.s_haddr), .htrans_i(dut.u_soc.s_htrans), .hsize_i(dut.u_soc.s_hsize),
        .hburst_i(dut.u_soc.s_hburst), .hwrite_i(dut.u_soc.s_hwrite), .hwdata_i(dut.u_soc.s_hwdata),
        .hready_i(dut.u_soc.s_hready), .hresp_i(dut.u_soc.s_hresp), .viol_count_o(vs));
    ahb_lite_checker u_cm (.clk_i(hclk), .rst_n_i(hrst),
        .haddr_i(dut.u_soc.m_haddr), .htrans_i(dut.u_soc.m_htrans), .hsize_i(dut.u_soc.m_hsize),
        .hburst_i(dut.u_soc.m_hburst), .hwrite_i(dut.u_soc.m_hwrite), .hwdata_i(dut.u_soc.m_hwdata),
        .hready_i(dut.u_soc.m_hready), .hresp_i(dut.u_soc.m_hresp), .viol_count_o(vm));
    // the slave-side stream: misaligned/unmapped accesses are deliberately issued
    // by t_chip_basic, so this one reports but only the master checkers gate
    ahb_lite_checker u_csl (.clk_i(hclk), .rst_n_i(hrst),
        .haddr_i(dut.u_soc.haddr), .htrans_i(dut.u_soc.htrans), .hsize_i(dut.u_soc.hsize),
        .hburst_i(dut.u_soc.hburst), .hwrite_i(dut.u_soc.hwrite), .hwdata_i(dut.u_soc.hwdata),
        .hready_i(dut.u_soc.hready),
        .hresp_i(dut.u_soc.hresp_isram | dut.u_soc.hresp_rom | dut.u_soc.hresp_dsram |
                 dut.u_soc.hresp_bridge | dut.u_soc.u_ahb.hresp_df),
        .viol_count_o(vsl));

    // ---- statistics ----------------------------------------------------------------------
    integer n_retire = 0, n_sleep = 0, n_hreset_fall = 0;
    always @(posedge hclk) if (hrst) begin
        if (dut.u_soc.u_core.mw_retire) n_retire++;
        if (dut.u_soc.core_sleep_o)     n_sleep++;
    end

    // ---- JTAG bit-bang (20 MHz) ------------------------------------------------------------
    localparam real TH = 25.0;
    task automatic clk1(input bit m, input bit d, output bit q);
        tms = m; tdi = d; #TH; tck = 1; q = tdo; #TH; tck = 0;
    endtask
    task automatic idle(input int n); bit q; repeat (n) clk1(0, 0, q); endtask
    task automatic tap_reset; bit q; repeat (5) clk1(1, 0, q); clk1(0, 0, q); endtask
    task automatic shift_ir(input [4:0] v);
        bit q;
        clk1(1, 0, q); clk1(1, 0, q); clk1(0, 0, q); clk1(0, 0, q);
        for (int i = 0; i < 5; i++) clk1(i == 4, v[i], q);
        clk1(1, 0, q); clk1(0, 0, q);
    endtask
    task automatic shift_dr(input [63:0] v, input int n, output [63:0] o);
        bit q; o = 0;
        clk1(1, 0, q); clk1(0, 0, q); clk1(0, 0, q);
        for (int i = 0; i < n; i++) begin clk1(i == n - 1, v[i], q); o[i] = q; end
        clk1(1, 0, q); clk1(0, 0, q);
    endtask
    task automatic dmw(input [6:0] a, input [31:0] d);
        reg [63:0] x; shift_dr({23'd0, a, d, 2'd2}, 41, x); idle(6);
    endtask
    task automatic dmr(input [6:0] a, output [31:0] r);
        reg [63:0] x;
        shift_dr({23'd0, a, 32'd0, 2'd1}, 41, x); idle(6);
        shift_dr({23'd0, a, 32'd0, 2'd0}, 41, x); r = x[33:2]; idle(2);
    endtask

    // ---- program image -------------------------------------------------------------------
    reg [1023:0] test_hex;
    reg [8*8-1:0] mode;
    reg [31:0] img [0:16383];
    integer maxus, nwords, i;
    reg [31:0] th, r;
    integer rc;

    localparam [31:0] TOHOST = 32'h2000_F000, MBOX = 32'h2000_FFF0, MBOX_MAGIC = 32'h4A54_4147;

    // The boot flash. Present in every mode - in the others nothing ever
    // selects it - so the pin path is always the real one.
    spi_flash_model #(.MAX_MHZ(20.0)) u_flash (
        .cs_n(spim_cs_flash_n), .sclk(spim_sclk), .mosi(spim_mosi), .miso(spim_miso));

    task automatic post_mailbox;
        dut.u_soc.u_dsram.bd_write(MBOX + 4, 32'h0000_0000);     // entry = ISRAM base
        dut.u_soc.u_dsram.bd_write(MBOX,     MBOX_MAGIC);
    endtask

    always @(negedge dut.hreset_n) if (ext_rst_n) begin
        n_hreset_fall++;
        $display("[tb_chip] system reset observed at %0t (RSTREASON source will say why)", $time);
        if (mode == "wdt") post_mailbox();                      // run 2
    end

    initial begin
        if (!$value$plusargs("TEST=%s", test_hex)) test_hex = "sw/build/t_chip_basic.hex";
        if (!$value$plusargs("MODE=%s", mode))     mode     = "basic";
        if (!$value$plusargs("MAXUS=%d", maxus))   maxus    = 400;
        $display("=== tb_chip: garuda_chip_top, MODE=%0s TEST=%0s ===", mode, test_hex);

        // SRAM is not reset: start from a known tohost and an empty mailbox
        dut.u_soc.u_dsram.bd_write(TOHOST, 32'h0);
        dut.u_soc.u_dsram.bd_write(MBOX, 32'h0);

        if (mode == "flash") begin
            // Nothing is placed anywhere and no mailbox is posted: the ROM
            // reads the image off the SPI bus itself. boot_sel low selects the
            // flash path instead of recovery.
            boot_sel = 1'b0;
            u_flash.bd_load_hex(test_hex);
            $display("[tb_chip] flash image %0s loaded, booting from SPI", test_hex);
        end else begin
            for (i = 0; i < 16384; i++) img[i] = 32'hx;
            $readmemh(test_hex, img);
            for (nwords = 0; nwords < 16384 && img[nwords] !== 32'hx; nwords++) ;
            if (mode != "jtag") begin
                for (i = 0; i < nwords; i++) dut.u_soc.u_isram.bd_write(4 * i, img[i]);
                post_mailbox();
            end
        end

        #50 ext_rst_n = 1;

        if (mode == "jtag") begin
            @(posedge dut.hreset_n);
            #200;
            tap_reset();
            shift_ir(5'h11);
            dmw(7'h10, 32'h0000_0001);                           // dmactive
            dmw(7'h10, 32'h8000_0001);                           // haltreq: hold the hart
            dmw(7'h38, (2 << 17) | (1 << 16));                   // 32-bit, autoincrement
            dmw(7'h39, 32'h0000_0000);
            for (i = 0; i < nwords; i++) dmw(7'h3C, img[i]);     // stream the image
            dmw(7'h39, MBOX + 4); dmw(7'h3C, 32'h0);             // entry
            dmw(7'h39, MBOX);     dmw(7'h3C, MBOX_MAGIC);        // post
            dmr(7'h11, r);
            if (!r[9]) begin $display("[FAIL] hart not halted during the JTAG load"); $display("RESULT: FAILED"); $finish; end
            dmw(7'h10, 32'h4000_0001);                           // resumereq: run
            $display("[tb_chip] %0d words loaded over JTAG SBA, hart resumed at %0t", nwords, $time);
        end
    end

    // ---- verdict ---------------------------------------------------------------------------
    initial begin
        #100;
        forever begin
            #1000;
            th = dut.u_soc.u_dsram.bd_read(TOHOST);
            if (th != 0) begin
                rc = (th == 1) ? 0 : (th >> 1);
                $display("[tb_chip] tohost = 0x%08h at %0t: %0d retired, %0d hclk cycles clock-gated, %0d system resets",
                         th, $time, n_retire, n_sleep, n_hreset_fall);
                $display("[tb_chip] AHB checker violations: I=%0d D=%0d SBA=%0d DMA=%0d (slave bus %0d, expected >0 only for deliberate faults)",
                         vi, vd, vs, vm, vsl);
                if (rc == 0 && (vi | vd | vs | vm) == 0) $display("RESULT: PASSED");
                else begin
                    if (rc) $display("[FAIL] program reported step %0d", rc);
                    $display("RESULT: FAILED");
                end
                $finish;
            end
            if ($time > maxus * 1000) begin
                $display("[FAIL] TIMEOUT after %0d us: tohost never written (%0d retired, pc in EX = 0x%08h)",
                         maxus, n_retire, dut.u_soc.u_core.xe_pc);
                $display("RESULT: FAILED");
                $finish;
            end
        end
    end
endmodule
