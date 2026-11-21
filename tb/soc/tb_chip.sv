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
//   +MODE=basic | irq | watchdog | jtag | flash | cov
//                 cov: t_chip_cov's four runs. The program asks through fromhost
//                 (0x2000_F004): 1 pulse boot_sel low, 3 ndmreset over JTAG,
//                 4 pulse ext_rst_n; the bench writes 0 when done and re-posts
//                 the mailbox after every reset.
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
    wire [2:0] uart_rx_pin;
`ifdef GARUDA_CHIP_UVM
    // driven by tb/chip_uvm/tb_chip_uvm.sv (the UART line agents)
`else
    assign uart_rx_pin = {uart2_tx, uart1_tx, uart0_tx};
`endif
    // GARUDA_CHIP_UVM: the verdict is handed to the UVM test instead of ending the run
    reg prog_done = 1'b0;
    integer prog_rc = -1;

    garuda_chip_top #(.BROM_INIT_FILE("sw/build/bootrom.hex")) dut (
        .refclk(refclk), .ext_rst_n(ext_rst_n),
        .tck(tck), .tms(tms), .tdi(tdi), .tdo(tdo),
        .spim_sclk(spim_sclk), .spim_mosi(spim_mosi), .spim_miso(spim_miso),
        .spim_cs_flash_n(spim_cs_flash_n), .spim_cs_imu_n(spim_cs_imu_n),
        .i2c_scl(i2c_scl), .i2c_sda(i2c_sda),
        // Each UART's tx is looped back to its own rx. Nothing else in the chip
        // depends on these pins, and it lets t_chip_uart prove both directions
        // AND that the three instances do not talk to each other, with no
        // model on the board. Under the UVM chip bench (GARUDA_CHIP_UVM,
        // tb/chip_uvm) the rx pins are the UART agents' instead.
        .uart0_rx(uart_rx_pin[0]), .uart0_tx(uart0_tx),
        .uart1_rx(uart_rx_pin[1]), .uart1_tx(uart1_tx),
        .uart2_rx(uart_rx_pin[2]), .uart2_tx(uart2_tx),
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
        .hburst_i(3'b001), .hwrite_i(dut.u_core.u_soc.i_hwrite), .hwdata_i(dut.u_core.u_soc.i_hwdata),
        .hready_i(dut.u_core.u_soc.i_hready), .hresp_i(dut.u_core.u_soc.i_hresp), .viol_count_o(vi));
    ahb_lite_checker u_cd (.clk_i(hclk), .rst_n_i(hrst),
        .haddr_i(dut.u_core.u_soc.d_haddr), .htrans_i(dut.u_core.u_soc.d_htrans), .hsize_i(dut.u_core.u_soc.d_hsize),
        .hburst_i(3'b000), .hwrite_i(dut.u_core.u_soc.d_hwrite), .hwdata_i(dut.u_core.u_soc.d_hwdata),
        .hready_i(dut.u_core.u_soc.d_hready), .hresp_i(dut.u_core.u_soc.d_hresp), .viol_count_o(vd));
    ahb_lite_checker u_cs (.clk_i(hclk), .rst_n_i(hrst),
        .haddr_i(dut.u_core.u_soc.s_haddr), .htrans_i(dut.u_core.u_soc.s_htrans), .hsize_i(dut.u_core.u_soc.s_hsize),
        .hburst_i(3'b000), .hwrite_i(dut.u_core.u_soc.s_hwrite), .hwdata_i(dut.u_core.u_soc.s_hwdata),
        .hready_i(dut.u_core.u_soc.s_hready), .hresp_i(dut.u_core.u_soc.s_hresp), .viol_count_o(vs));
    ahb_lite_checker u_cm (.clk_i(hclk), .rst_n_i(hrst),
        .haddr_i(dut.u_core.u_soc.m_haddr), .htrans_i(dut.u_core.u_soc.m_htrans), .hsize_i(dut.u_core.u_soc.m_hsize),
        .hburst_i(3'b000), .hwrite_i(dut.u_core.u_soc.m_hwrite), .hwdata_i(dut.u_core.u_soc.m_hwdata),
        .hready_i(dut.u_core.u_soc.m_hready), .hresp_i(dut.u_core.u_soc.m_hresp), .viol_count_o(vm));
    // the slave-side stream: misaligned/unmapped accesses are deliberately issued
    // by t_chip_basic, so this one reports but only the master checkers gate
    ahb_lite_checker u_csl (.clk_i(hclk), .rst_n_i(hrst),
        .haddr_i(dut.u_core.u_soc.haddr), .htrans_i(dut.u_core.u_soc.htrans), .hsize_i(dut.u_core.u_soc.hsize),
        .hburst_i(dut.u_core.u_soc.u_ahb.grant == 2'd0 ? 3'b001 : 3'b000), .hwrite_i(dut.u_core.u_soc.hwrite), .hwdata_i(dut.u_core.u_soc.hwdata),
        .hready_i(dut.u_core.u_soc.hready),
        .hresp_i(dut.u_core.u_soc.hresp_isram | dut.u_core.u_soc.hresp_rom | dut.u_core.u_soc.hresp_dsram |
                 dut.u_core.u_soc.hresp_bridge | dut.u_core.u_soc.u_ahb.hresp_df),
        .viol_count_o(vsl));

    // ---- statistics ----------------------------------------------------------------------
    integer n_retire = 0, n_sleep = 0, n_hreset_fall = 0;
    always @(posedge hclk) if (hrst) begin
        if (dut.u_core.u_soc.u_core.mw_retire) n_retire++;
        if (dut.u_core.u_soc.u_core.quiescent)     n_sleep++;
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
    reg [31:0] img_ones [0:16383];  // the same image over all-ones: see the load below
    integer maxus, nwords, i;
    reg [31:0] th, r;
    integer rc;

    localparam [31:0] TOHOST = 32'h2000_F000, MBOX = 32'h2000_FFF0, MBOX_MAGIC = 32'h4A54_4147;
    localparam [31:0] FROMHOST = 32'h2000_F004, NOINIT = 32'h2000_E000;

    // The ESP32 companion on block 14's pins, present in every mode. In the UVM chip
    // bench (tb/chip_uvm) the SPI slave environment's master agent is the companion
    // and drives these pins instead, with the same frame on the same trigger.
`ifndef GARUDA_CHIP_UVM
    spi_master_model u_esp (.sclk(spis_sclk), .mosi(spis_mosi),
                            .cs_n(spis_cs_n), .miso(spis_miso));
`endif

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
`ifndef GARUDA_CHIP_UVM
    byte unsigned esp_got;
    always @(posedge gpio1) begin
        u_esp.open_frame();
        u_esp.xfer(8'hA5, esp_got);
        u_esp.xfer(8'h3C, esp_got);
        u_esp.close_frame();
    end
`endif

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

    task automatic post_mailbox;
        dut.u_core.u_soc.u_dsram.bd_write(MBOX + 4, 32'h0000_0000);     // entry = ISRAM base
        dut.u_core.u_soc.u_dsram.bd_write(MBOX,     MBOX_MAGIC);
    endtask

    always @(negedge dut.u_core.hreset_n) if (ext_rst_n) begin
        n_hreset_fall++;
        $display("[tb_chip] system reset observed at %0t (RSTREASON source will say why)", $time);
        if (mode == "watchdog" || mode == "cov") post_mailbox();     // the next run
    end

    initial begin
        if (!$value$plusargs("TEST=%s", test_hex)) test_hex = "sw/build/t_chip_basic.hex";
        if (!$value$plusargs("MODE=%s", mode))     mode     = "basic";
        if (!$value$plusargs("MAXUS=%d", maxus))   maxus    = 400;
        $display("=== tb_chip: garuda_chip_top, MODE=%0s TEST=%0s ===", mode, test_hex);

        // SRAM is not reset: start from a known tohost and an empty mailbox
        dut.u_core.u_soc.u_dsram.bd_write(TOHOST, 32'h0);
        dut.u_core.u_soc.u_dsram.bd_write(MBOX, 32'h0);
        dut.u_core.u_soc.u_dsram.bd_write(FROMHOST, 32'h0);
        if (mode == "cov") dut.u_core.u_soc.u_dsram.bd_write(NOINIT, 32'h0);   // t_chip_cov's run marker

        if (mode == "flash") begin
            // Nothing is placed anywhere and no mailbox is posted: the ROM
            // reads the image off the SPI bus itself. boot_sel low selects the
            // flash path instead of recovery.
            boot_sel = 1'b0;
            u_flash.bd_load_hex(test_hex);
            $display("[tb_chip] flash image %0s loaded, booting from SPI", test_hex);
        end else begin
            // TB-B7 (2026-11-20): the image ends at the first word $readmemh did
            // not write. It was found as the first X word, which a 2-state
            // simulator reads as 0: under Verilator the JTAG load streamed all
            // 16384 words and timed out. A word is loaded where two copies of the
            // image, one over zeros and one over all-ones, agree.
            for (i = 0; i < 16384; i++) begin
                img[i] = 32'h0000_0000;
                img_ones[i] = 32'hFFFF_FFFF;
            end
            $readmemh(test_hex, img);
            $readmemh(test_hex, img_ones);
            for (nwords = 0; nwords < 16384 && img[nwords] == img_ones[nwords]; nwords++) ;
            if (mode != "jtag") begin
                for (i = 0; i < nwords; i++) dut.u_core.u_soc.u_isram.bd_write(4 * i, img[i]);
                post_mailbox();
            end
        end

        #50 ext_rst_n = 1;

        if (mode == "jtag") begin
            @(posedge dut.u_core.hreset_n);
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
            // SBA reads across the address map while the hart is held (2026-11-20, coverage of
            // the SBA address bits and [N-7.13]): the ISRAM through its alias at the top of the
            // segment, the boot ROM, a peripheral ID register through the bridge, and an address
            // in no region, which the default slave answers ERROR: sberror 4, cleared by W1C.
            dmw(7'h38, (1 << 20) | (2 << 17));                   // 32-bit, read on address
            dmw(7'h39, 32'h0FFF_0000); dmr(7'h3C, r);
            if (r !== img[0]) begin $display("[FAIL] SBA read of the ISRAM alias: %h, expected %h", r, img[0]); $display("RESULT: FAILED"); $finish; end
            dmw(7'h39, 32'h1000_0000); dmr(7'h3C, r);
            if (r !== dut.u_core.u_soc.u_brom.bd_read(0)) begin $display("[FAIL] SBA read of the boot ROM: %h", r); $display("RESULT: FAILED"); $finish; end
            dmw(7'h39, 32'h4000_3FEC); dmr(7'h3C, r);
            if (r[31:16] !== 16'h6A5D) begin $display("[FAIL] SBA read of the UART0 ID register: %h", r); $display("RESULT: FAILED"); $finish; end
            dmw(7'h39, 32'hF000_0000); dmr(7'h3C, r); dmr(7'h38, r);
            if (r[14:12] !== 3'd4) begin $display("[FAIL] SBA read of an address in no region: sberror %0d, expected 4", r[14:12]); $display("RESULT: FAILED"); $finish; end
            dmw(7'h38, (7 << 12) | (2 << 17)); dmr(7'h38, r);
            if (r[14:12] !== 3'd0) begin $display("[FAIL] sberror not cleared by W1C"); $display("RESULT: FAILED"); $finish; end
            dmw(7'h38, (1 << 20) | (2 << 17)); dmw(7'h39, 32'h0000_0000); dmr(7'h3C, r);
            if (r !== img[0]) begin $display("[FAIL] SBA read of ISRAM word 0 after the error: %h", r); $display("RESULT: FAILED"); $finish; end
            // every SBA data bit both ways (2026-11-21): all ones, then all zeros, through a no-init DSRAM word
            for (int k = 0; k < 2; k++) begin
                dmw(7'h38, 2 << 17); dmw(7'h39, NOINIT + 32'h100); dmw(7'h3C, k ? 32'h0 : 32'hFFFF_FFFF);
                dmw(7'h38, (1 << 20) | (2 << 17)); dmw(7'h39, NOINIT + 32'h100); dmr(7'h3C, r);
                if (r !== (k ? 32'h0 : 32'hFFFF_FFFF)) begin $display("[FAIL] SBA write/read of DSRAM: %h", r); $display("RESULT: FAILED"); $finish; end
            end
            dmw(7'h10, 32'h4000_0001);                           // resumereq: run
            $display("[tb_chip] %0d words loaded over JTAG SBA, hart resumed at %0t", nwords, $time);
        end
    end

    // ---- cov mode: the program's requests -------------------------------------------------------
    reg [31:0] req;
    initial begin
        #100;
        if (mode == "cov") forever begin
            #1000;
            req = dut.u_core.u_soc.u_dsram.bd_read(FROMHOST);
            if (req == 32'd1) begin                       // boot_sel low for 5 us, CLKSTAT[8] must follow
                boot_sel = 1'b0; #5000; boot_sel = 1'b1; #1000;
                dut.u_core.u_soc.u_dsram.bd_write(FROMHOST, 32'h0);
            end else if (req == 32'd3) begin              // the debugger's ndmreset, over the pins
                dut.u_core.u_soc.u_dsram.bd_write(FROMHOST, 32'h0);
                tap_reset();
                shift_ir(5'h11);
                dmw(7'h10, 32'h0000_0001);                // dmactive
                dmw(7'h10, 32'h0000_0003);                // ndmreset
                dmw(7'h10, 32'h0000_0001);                // released
                dmw(7'h10, 32'h0000_0000);
                $display("[tb_chip] ndmreset over JTAG at %0t", $time);
            end else if (req == 32'd4) begin              // the external reset pin
                dut.u_core.u_soc.u_dsram.bd_write(FROMHOST, 32'h0);
                ext_rst_n = 1'b0; #200; ext_rst_n = 1'b1;
                post_mailbox();
                $display("[tb_chip] ext_rst_n pulsed at %0t", $time);
            end else if (req != 32'd0) begin
                $display("[FAIL] unknown request %0d in fromhost", req); $display("RESULT: FAILED"); $finish;
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
                $display("[tb_chip] tohost = 0x%08h at %0t: %0d retired, %0d hclk cycles clock-gated, %0d system resets",
                         th, $time, n_retire, n_sleep, n_hreset_fall);
                $display("[tb_chip] AHB checker violations: I=%0d D=%0d SBA=%0d DMA=%0d (slave bus %0d, expected >0 only for deliberate faults)",
                         vi, vd, vs, vm, vsl);
`ifdef GARUDA_CHIP_UVM
                if (rc) $display("[FAIL] program reported step %0d", rc);
                if ((vi | vd | vs | vm) != 0) $display("[FAIL] AHB checker violations");
                prog_rc = (rc == 0 && (vi | vd | vs | vm) == 0) ? 0 : (rc ? rc : 99);
                prog_done = 1'b1;
                wait (0);
`else
                if (rc == 0 && (vi | vd | vs | vm) == 0) $display("RESULT: PASSED");
                else begin
                    if (rc) $display("[FAIL] program reported step %0d", rc);
                    $display("RESULT: FAILED");
                end
                $finish;
`endif
            end
            if ($time > maxus * 1000) begin
                $display("[FAIL] TIMEOUT after %0d us: tohost never written (%0d retired, pc in EX = 0x%08h)",
                         maxus, n_retire, dut.u_core.u_soc.u_core.xe_pc);
                // a program can leave a breadcrumb with `csrw mscratch, n`
                $display("        mscratch = %0d, mcause = 0x%08h, mepc = 0x%08h, asleep = %0b",
                         dut.u_core.u_soc.u_core.u_csr.mscratch_r, dut.u_core.u_soc.u_core.u_csr.mcause_r,
                         dut.u_core.u_soc.u_core.u_csr.mepc_r, dut.u_core.u_soc.u_core.quiescent);
                $display("RESULT: FAILED");
                $finish;
            end
        end
    end
endmodule
