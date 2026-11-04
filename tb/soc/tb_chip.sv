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
    reg refclk = 0, ext_rst_n = 1, boot_sel = 1;
    // TB-30 (the TB-22 class): the reset pin must FALL. Declared `= 0` it is
    // low from time 0 with no edge, RSTREASON.EXT is set only by the async
    // branch of reset_ctrl and aon_clk is stopped while the pin is low, so
    // EXT read 1 only on a simulator that invents an edge at time 0 (Xcelium
    // does, Verilator and Icarus do not). Start high, fall at 0.5 ns.
    initial #0.5 ext_rst_n = 1'b0;
    reg tck = 0, tms = 1, tdi = 0;
    always #1 refclk = ~refclk;

    wire tdo, spim_sclk, spim_mosi, spim_cs_flash_n, spim_cs_imu_n, spim_miso;
    wire i2c_scl, i2c_sda, gpio0, gpio1;
    wire uart0_tx, uart1_tx, uart2_tx, pwm0, pwm1, pwm2, pwm3;
    wire spis_sclk, spis_mosi, spis_miso, spis_cs_n;
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
        .gpio0(gpio0), .gpio1(gpio1), .boot_sel(boot_sel),
        .spis_sclk(spis_sclk), .spis_mosi(spis_mosi),
        .spis_miso(spis_miso), .spis_cs_n(spis_cs_n));

    // ---- AHB-Lite protocol checkers --------------------------------------------
    wire hclk = dut.u_core.hclk;
    wire hrst = dut.u_core.hreset_n;
    wire [31:0] vi, vd, vs, vm, vsl;
    ahb_lite_checker u_ci (.clk_i(hclk), .rst_n_i(hrst),
        .haddr_i(dut.u_core.u_soc.i_haddr), .htrans_i(dut.u_core.u_soc.i_htrans), .hsize_i(dut.u_core.u_soc.i_hsize),
        .hburst_i(dut.u_core.u_soc.i_hburst), .hwrite_i(dut.u_core.u_soc.i_hwrite), .hwdata_i(dut.u_core.u_soc.i_hwdata),
        .hready_i(dut.u_core.u_soc.i_hready), .hresp_i(dut.u_core.u_soc.i_hresp), .viol_count_o(vi));
    ahb_lite_checker u_cd (.clk_i(hclk), .rst_n_i(hrst),
        .haddr_i(dut.u_core.u_soc.d_haddr), .htrans_i(dut.u_core.u_soc.d_htrans), .hsize_i(dut.u_core.u_soc.d_hsize),
        .hburst_i(dut.u_core.u_soc.d_hburst), .hwrite_i(dut.u_core.u_soc.d_hwrite), .hwdata_i(dut.u_core.u_soc.d_hwdata),
        .hready_i(dut.u_core.u_soc.d_hready), .hresp_i(dut.u_core.u_soc.d_hresp), .viol_count_o(vd));
    ahb_lite_checker u_cs (.clk_i(hclk), .rst_n_i(hrst),
        .haddr_i(dut.u_core.u_soc.s_haddr), .htrans_i(dut.u_core.u_soc.s_htrans), .hsize_i(dut.u_core.u_soc.s_hsize),
        .hburst_i(dut.u_core.u_soc.s_hburst), .hwrite_i(dut.u_core.u_soc.s_hwrite), .hwdata_i(dut.u_core.u_soc.s_hwdata),
        .hready_i(dut.u_core.u_soc.s_hready), .hresp_i(dut.u_core.u_soc.s_hresp), .viol_count_o(vs));
    ahb_lite_checker u_cm (.clk_i(hclk), .rst_n_i(hrst),
        .haddr_i(dut.u_core.u_soc.m_haddr), .htrans_i(dut.u_core.u_soc.m_htrans), .hsize_i(dut.u_core.u_soc.m_hsize),
        .hburst_i(dut.u_core.u_soc.m_hburst), .hwrite_i(dut.u_core.u_soc.m_hwrite), .hwdata_i(dut.u_core.u_soc.m_hwdata),
        .hready_i(dut.u_core.u_soc.m_hready), .hresp_i(dut.u_core.u_soc.m_hresp), .viol_count_o(vm));
    // the slave-side stream: misaligned/unmapped accesses are deliberately issued
    // by t_chip_basic, so this one reports but only the master checkers gate
    ahb_lite_checker u_csl (.clk_i(hclk), .rst_n_i(hrst),
        .haddr_i(dut.u_core.u_soc.haddr), .htrans_i(dut.u_core.u_soc.htrans), .hsize_i(dut.u_core.u_soc.hsize),
        .hburst_i(dut.u_core.u_soc.hburst), .hwrite_i(dut.u_core.u_soc.hwrite), .hwdata_i(dut.u_core.u_soc.hwdata),
        .hready_i(dut.u_core.u_soc.hready),
        .hresp_i(dut.u_core.u_soc.hresp_isram | dut.u_core.u_soc.hresp_rom | dut.u_core.u_soc.hresp_dsram |
                 dut.u_core.u_soc.hresp_bridge | dut.u_core.u_soc.u_ahb.hresp_df),
        .viol_count_o(vsl));

    // ---- statistics ----------------------------------------------------------------------
    integer n_retire = 0, n_sleep = 0, n_hreset_fall = 0;
    always @(posedge hclk) if (hrst) begin
        if (dut.u_core.u_soc.u_core.mw_retire) n_retire++;
        if (dut.u_core.u_soc.core_sleep_o)     n_sleep++;
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
    reg [16*8-1:0] mode;   // 16 characters (Track A 2026-11-01: "bootfault" is 9)
    reg [31:0] img [0:16383];
    reg [31:0] img2 [0:16383];                    // TB-A1: the second load (other fill)
    integer maxus, nwords, i;
    // ---- Track A boot checks (2026-11-01, memories vPlan F15-F24) ------------------------------
    //   +MODE=bootfault +FLASH=<flash image> +TEST=<recovery program> +FAULT=<kind> [options]
    //   FAULT: flip (+FBYTE +FBIT) | blank | hdr (+HWORD +HVAL) | miso0 | miso1 |
    //          stop (+FSTOP_US: the flash stops answering) | buserr (the first SPI-master access
    //          answers PSLVERR: a bus ERROR inside the ROM, [N-8.12])
    //   The ROM must report BOOTFAIL within +BFUS us; then the recovery program is loaded over
    //   JTAG SBA and run, as a debugger would (F16).
    reg [1023:0] flash_hex, fault, fregion;
    integer fbyte, fbit, hword, hval, fstop_us, bfus, k;
    reg     boot_entered = 1'b0;
    reg [31:0] th, r;
    integer rc;

    localparam [31:0] TOHOST = 32'h2000_F000, MBOX = 32'h2000_FFF0, MBOX_MAGIC = 32'h4A54_4147;

    // The ESP32 companion on block 14's pins, present in every mode.
    spi_master_model u_esp (.sclk(spis_sclk), .mosi(spis_mosi),
                            .cs_n(spis_cs_n), .miso(spis_miso));

    // +TRAPLOG prints every trap the core takes: the first thing to look at when
    // a chip test hangs.
    always @(posedge hclk)
        if (dut.u_core.u_soc.u_core.u_csr.trap_enter_i && $test$plusargs("TRAPLOG"))
            $display("[trap] %0t cause=0x%08h pc=0x%08h tval=0x%08h mscratch=%0d", $time,
                     dut.u_core.u_soc.u_core.u_csr.trap_cause_i, dut.u_core.u_soc.u_core.u_csr.trap_pc_i,
                     dut.u_core.u_soc.u_core.u_csr.trap_tval_i, dut.u_core.u_soc.u_core.u_csr.mscratch_r);

    // The companion sends a two-byte frame when firmware raises gpio1, which is
    // how a real one is asked for data (a ready line). Only t_chip_integ drives
    // gpio1; in every other test the pin stays an input on its pull-down.
    byte unsigned esp_got;
    always @(posedge gpio1) begin
        u_esp.open_frame();
        u_esp.xfer(8'hA5, esp_got);
        u_esp.xfer(8'h3C, esp_got);
        u_esp.close_frame();
    end

    // An I2C slave on the real open-drain bus, and pull-downs on the GPIO pins
    // so a released pin reads a defined level. Present in every mode; nothing
    // touches them unless firmware does.
    // A pull primitive takes no strength under Verilator; the default (pull)
    // strength is used there. Nothing in the bench drives at pull strength.
`ifdef VERILATOR
    pullup p_scl (i2c_scl);
    pullup p_sda (i2c_sda);
`else
    pullup (weak1) p_scl (i2c_scl);
    pullup (weak1) p_sda (i2c_sda);
`endif
    i2c_slave_model #(.ADDR(7'h48)) u_i2c_slv (.scl(i2c_scl), .sda(i2c_sda));
`ifdef VERILATOR
    pulldown p_g0 (gpio0);
    pulldown p_g1 (gpio1);
`else
    pulldown (weak0) p_g0 (gpio0);
    pulldown (weak0) p_g1 (gpio1);
`endif

    // The boot flash. Present in every mode - in the others nothing ever
    // selects it - so the pin path is always the real one.
    spi_flash_model #(.MAX_MHZ(20.0)) u_flash (
        .cs_n(spim_cs_flash_n), .sclk(spim_sclk), .mosi(spim_mosi), .miso(spim_miso));

    // Track A debug F32: the debugger reads every region and sees what the CPU saw
    task automatic sba_rd(input [31:0] a, output [31:0] v);
        dmw(7'h38, (2 << 17) | (1 << 20)); dmw(7'h39, a); dmr(7'h3C, v);
    endtask
    task automatic region_checks(inout integer rc_);
        reg [31:0] v, e;
        #0.5;                     // TB-A9: off the hclk grid (this runs from the verdict loop's 1 us poll)
        sba_rd(32'h0000_0000, v);  if (v !== img[0])          begin rc_ = 101; $display("[FAIL] F32 ISRAM word 0 over SBA %h, image %h", v, img[0]); end
        sba_rd(32'h2000_8000, v);  if (v !== 32'hC0FFEE01)    begin rc_ = 102; $display("[FAIL] F32 DSRAM marker over SBA %h", v); end
        sba_rd(32'h2000_8014, e); sba_rd(32'h1000_0000, v);
                                   if (v !== e)               begin rc_ = 103; $display("[FAIL] F32 Boot ROM word 0 over SBA %h, CPU read %h", v, e); end
        sba_rd(32'h2000_800C, e); sba_rd(32'h4000_9000, v);
                                   if (v !== e)               begin rc_ = 104; $display("[FAIL] F32 RSTREASON over SBA %h, CPU read %h", v, e); end
        sba_rd(32'h4000_5004, v);  if (v !== 32'h2000_8004)   begin rc_ = 105; $display("[FAIL] F32 DMA SAR0 over SBA %h", v); end
        sba_rd(32'h4000_5008, v);  if (v !== 32'h2000_8008)   begin rc_ = 106; $display("[FAIL] F32 DMA DAR0 over SBA %h", v); end
        if (rc_ == 0) $display("[tb_chip] F32: ISRAM, DSRAM, Boot ROM, reset_ctrl and DMA registers all read over SBA as the CPU saw them");
    endtask
    // CRC-32/IEEE 802.3 (reflected 0xEDB88320, init and xorout all ones) of the boot header's
    // first 24 bytes in the flash model: the HDR_CRC of MEM-5, as tools/mkbootimg.py writes it
    function automatic [31:0] hdr_crc();
        reg [31:0] c; integer b, j;
        c = 32'hFFFF_FFFF;
        for (b = 0; b < 24; b++) begin
            c = c ^ {24'd0, u_flash.mem[b]};
            for (j = 0; j < 8; j++) c = (c >> 1) ^ (32'hEDB8_8320 & {32{c[0]}});
        end
        hdr_crc = ~c;
    endfunction
    task automatic post_mailbox;
        dut.u_core.u_soc.u_dsram.bd_write(MBOX + 4, 32'h0000_0000);     // entry = ISRAM base
        dut.u_core.u_soc.u_dsram.bd_write(MBOX,     MBOX_MAGIC);
    endtask

    initial begin : boot_fault_drivers
        #1;
        if (mode == "bootfault") begin
            if (fault == "miso0") force u_flash.miso = 1'b0;
            if (fault == "miso1") force u_flash.miso = 1'b1;
            if (fault == "stop") begin
                if (!$value$plusargs("FSTOP_US=%d", fstop_us)) fstop_us = 200;
                #(fstop_us * 1000);
                force u_flash.miso = 1'b0;
                $display("[tb_chip] bootfault stop: the flash stops answering at %0t", $time);
            end
            if (fault == "buserr") begin
                // PSLVERR is legal only in the access phase (PSEL and PENABLE): wait for it
                wait (dut.u_core.u_spim.psel_i && dut.u_core.u_spim.penable_i);
                // after the shim (window 1 = GARUDA_APB_WIN_SPI_MASTER, rtl/include/garuda_map.vh),
                // the bridge's view, so the shim's own
                // SVA does not see an error it did not make
                force dut.u_core.ext_pslverr[1] = 1'b1;
                @(negedge dut.u_core.u_spim.penable_i);
                release dut.u_core.ext_pslverr[1];
                $display("[tb_chip] bootfault buserr: PSLVERR on the first SPI-master access at %0t", $time);
            end
        end
    end

    // F23 a_locked_at_entry / F24 boot time: after a flash boot the first fetch from ISRAM
    // happens with ILOCK set (8.2 step 10), and the time to it is recorded
    always @(posedge dut.u_core.hclk) if (mode == "flash" && !boot_entered && dut.u_core.hreset_n
                                          && dut.u_core.u_soc.i_htrans[1] && dut.u_core.u_soc.i_haddr < 32'h0001_0000) begin
        boot_entered <= 1'b1;
        if (!dut.u_core.u_reset_ctrl.u_apb.ilock_q)
            $display("[FAIL] a_locked_at_entry: first ISRAM fetch (%h) after the flash boot with ILOCK clear at %0t", dut.u_core.u_soc.i_haddr, $time);
        else
            $display("[tb_chip] F23/F24: first ISRAM fetch at %h, ILOCK set, boot time %0t ns", dut.u_core.u_soc.i_haddr, $time / 1000);
    end

    always @(negedge dut.u_core.hreset_n) if (ext_rst_n) begin
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
        dut.u_core.u_soc.u_dsram.bd_write(TOHOST, 32'h0);
        dut.u_core.u_soc.u_dsram.bd_write(MBOX, 32'h0);

        if (mode == "flash") begin
            // Nothing is placed anywhere and no mailbox is posted: the ROM
            // reads the image off the SPI bus itself. boot_sel low selects the
            // flash path instead of recovery.
            boot_sel = 1'b0;
            u_flash.bd_load_hex(test_hex);
            $display("[tb_chip] flash image %0s loaded, booting from SPI", test_hex);
        end
        if (mode == "bootfault") begin                         // Track A F15-F21: a faulty flash
            boot_sel = 1'b0;
            if (!$value$plusargs("FLASH=%s", flash_hex)) flash_hex = "sw/build/flash.hex";
            if (!$value$plusargs("FAULT=%s", fault))     fault = "flip";
            u_flash.bd_load_hex(flash_hex);
            if (fault == "flip") begin                     // +FREGION=hdr|text|data +FOFF=<byte> +FBIT=<0..7>
                if (!$value$plusargs("FREGION=%s", fregion)) fregion = "text";
                if (!$value$plusargs("FOFF=%d", fbyte)) fbyte = 8;
                if (!$value$plusargs("FBIT=%d", fbit))  fbit = 0;
                hval = {u_flash.mem[7], u_flash.mem[6], u_flash.mem[5], u_flash.mem[4]};   // TEXT_LEN
                if (fregion == "text")      fbyte = 32 + fbyte;
                else if (fregion == "data") fbyte = 32 + hval + fbyte;
                u_flash.mem[fbyte] = u_flash.mem[fbyte] ^ (8'd1 << fbit);
                $display("[tb_chip] bootfault flip: %0s byte %0d bit %0d (flash offset %0d)", fregion, fbyte, fbit, fbyte);
            end else if (fault == "blank") begin
                for (k = 0; k < u_flash.SIZE_BYTES; k++) u_flash.mem[k] = 8'hFF;
            end else if (fault == "hdr") begin
                if (!$value$plusargs("HWORD=%d", hword)) hword = 0;
                if (!$value$plusargs("HVAL=%h", hval))   hval = 0;
                for (k = 0; k < 4; k++) u_flash.mem[4 * hword + k] = hval[8*k +: 8];   // little endian
                // +HFIXCRC: re-seal HDR_CRC (word 6, MEM-5) so the ROM's own range check is what
                // refuses the field, not the header CRC
                if ($test$plusargs("HFIXCRC")) begin
                    hval = hdr_crc();
                    for (k = 0; k < 4; k++) u_flash.mem[24 + k] = hval[8*k +: 8];
                end
            end
            $display("[tb_chip] bootfault: flash %0s, FAULT=%0s", flash_hex, fault);
        end
        if (mode != "flash") begin
            // TB-A1 (fixed 2026-10-16): the image length was found with an X sentinel, which a
            // two-state simulator (Verilator) reads as 0, so every one of the 16384 words was
            // streamed over JTAG (42 ms) and +MAXUS expired. Now the image is read twice, over
            // two different fills: a word belongs to the image when it differs from either fill.
            for (i = 0; i < 16384; i++) begin img[i] = 32'hDEAD_BEEF; img2[i] = 32'h2152_4110; end
            $readmemh(test_hex, img);
            $readmemh(test_hex, img2);
            nwords = 0;
            for (i = 0; i < 16384; i++) if (img[i] != 32'hDEAD_BEEF || img2[i] != 32'h2152_4110) nwords = i + 1;
            if (mode != "jtag" && mode != "jtag_reg" && mode != "jtagbulk" && mode != "jtagilck" && mode != "bootfault") begin
                for (i = 0; i < nwords; i++) dut.u_core.u_soc.u_isram.bd_write(4 * i, img[i]);
                post_mailbox();
            end
        end

        #50 ext_rst_n = 1;

        if (mode == "jtag" || mode == "jtag_reg" || mode == "jtagbulk" || mode == "jtagilck" || mode == "bootfault") begin
            @(posedge dut.u_core.hreset_n);
            if (mode == "bootfault") begin
                // the Boot ROM must give up and say so (8.2 steps 5, 6, 9; [N-8.12])
                if (!$value$plusargs("BFUS=%d", bfus)) bfus = 3000;
                for (k = 0; k < bfus && !dut.u_core.u_reset_ctrl.bootfail_q; k++) #1000;
                if (!dut.u_core.u_reset_ctrl.bootfail_q) begin
                    $display("[FAIL] bootfault %0s: the Boot ROM did not set RSTREASON.BOOTFAIL within %0d us (ILOCK=%b, mailbox mcause=%h)",
                             fault, bfus, dut.u_core.u_reset_ctrl.u_apb.ilock_q, dut.u_core.u_soc.u_dsram.bd_read(MBOX + 8));
                    $display("RESULT: FAILED"); $finish;
                end
                $display("[tb_chip] bootfault %0s: BOOTFAIL set at %0t (mailbox mcause %h), ILOCK %b; loading the recovery program over JTAG",
                         fault, $time, dut.u_core.u_soc.u_dsram.bd_read(MBOX + 8), dut.u_core.u_reset_ctrl.u_apb.ilock_q);
                if (fault == "buserr" && !(dut.u_core.u_soc.u_dsram.bd_read(MBOX + 8) inside {32'd5, 32'd7}))
                    $display("[FAIL] buserr: the ROM's trap record (mailbox word 2) is %h, not a load/store access fault",
                             dut.u_core.u_soc.u_dsram.bd_read(MBOX + 8));
                #20000;                                          // the ROM is in its recovery loop
            end
            // TB-A9 (2026-10-16): start the JTAG traffic off the hclk grid. With #200 every tck
            // edge (25 ns half period) met an hclk edge exactly once per 100 ns, a zero-delay
            // race in which the synchroniser took a toggle in the same time step as the payload
            // moved while the SVA sampled the old payload (a_cdc_payload_settled fired falsely).
            // Real tck and hclk are unrelated and never coincide exactly.
            #200.5;
            tap_reset();
            shift_ir(5'h11);
            dmw(7'h10, 32'h0000_0001);                           // dmactive
            dmw(7'h10, 32'h8000_0001);                           // haltreq: hold the hart
            dmw(7'h38, (2 << 17) | (1 << 16));                   // 32-bit, autoincrement
            dmw(7'h39, 32'h0000_0000);
            for (i = 0; i < nwords; i++) dmw(7'h3C, img[i]);     // stream the image
            if (mode == "jtagbulk") begin                        // Track A F34: 1024 data words at 0x8000
                dmw(7'h39, 32'h0000_8000);
                for (i = 0; i < 1024; i++) dmw(7'h3C, (i * 32'h9E37_79B1) ^ 32'hA5A5_A5A5);
            end
            dmw(7'h39, MBOX + 4); dmw(7'h3C, 32'h0);             // entry
            dmw(7'h39, MBOX);     dmw(7'h3C, MBOX_MAGIC);        // post
            dmr(7'h11, r);
            if (!r[9]) begin $display("[FAIL] hart not halted during the JTAG load"); $display("RESULT: FAILED"); $finish; end
            dmw(7'h10, 32'h4000_0001);                           // resumereq: run
            $display("[tb_chip] %0d words loaded over JTAG SBA, hart resumed at %0t", nwords, $time);
            if (mode == "jtagilck") begin                        // Track A mem F12: SBA writes locked ISRAM
                dmw(7'h38, (2 << 17) | (1 << 20));               // 32-bit, read on address
                r = 0;
                for (i = 0; i < 4000 && r != 1; i++) begin dmw(7'h39, 32'h2000_8010); dmr(7'h3C, r); end
                if (r !== 32'd1) $display("[FAIL] jtagilck: the firmware never signalled ILOCK set (DSRAM 0x2000_8010 = %h after 4000 polls)", r);
                dmw(7'h38, (2 << 17));
                $display("[tb_chip] ISRAM locked by firmware; debugger writing 0x8004 over SBA at %0t", $time);
                dmw(7'h39, 32'h0000_8004); dmw(7'h3C, 32'h5BA0_5BA0);
            end
        end
    end

    // ---- verdict ---------------------------------------------------------------------------
    initial begin
        #100;
        forever begin
            #1000;
            th = dut.u_core.u_soc.u_dsram.bd_read(TOHOST);
            if (th != 0) begin
                rc = (th == 1) ? 0 : (th >> 1);
                if (mode == "jtag_reg" && rc == 0) region_checks(rc);
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
                         maxus, n_retire, dut.u_core.u_soc.u_core.xe_pc);
                // a program can leave a breadcrumb with `csrw mscratch, n`
                $display("        mscratch = %0d, mcause = 0x%08h, mepc = 0x%08h, asleep = %0b",
                         dut.u_core.u_soc.u_core.u_csr.mscratch_r, dut.u_core.u_soc.u_core.u_csr.mcause_r,
                         dut.u_core.u_soc.u_core.u_csr.mepc_r, dut.u_core.u_soc.core_sleep_o);
                $display("RESULT: FAILED");
                $finish;
            end
        end
    end
endmodule
