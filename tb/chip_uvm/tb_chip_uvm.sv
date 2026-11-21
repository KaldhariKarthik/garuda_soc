`timescale 1ns/1ps
// =============================================================================
// tb_chip_uvm.sv - the UVM bench of the whole chip (G6 6.1, D-42).
//
// tb_chip (compiled with GARUDA_CHIP_UVM) holds the chip, its clock, reset, boot
// flash, I2C model and the program load; it hands the program's verdict to the
// UVM test instead of ending the run. This top adds the UVM side: for each
// peripheral, its environment's interfaces tapped onto the block inside the chip
// (APB port, outputs) and its pin agents on the chip's pads.
//
//   +UVM_TESTNAME=chip_base_test +MODE=<tb_chip mode> +TEST=<hex>  (tb_chip's plusargs)
// =============================================================================
module tb_chip_uvm;
    import uvm_pkg::*;
    import chip_uvm_pkg::*;

    tb_chip u_tb ();

    chip_ctl_if ctl ();
    assign ctl.prog_done = u_tb.prog_done;
    assign ctl.prog_rc   = u_tb.prog_rc;

    // ---- the three UARTs (blocks 16, 17, 18) --------------------------------------
    genvar g;
    generate for (g = 0; g < 3; g = g + 1) begin : g_u
        garuda_apb_if apb (.pclk(u_tb.dut.u_core.g_uart[g].u_uart.pclk), .preset_n(u_tb.dut.u_core.g_uart[g].u_uart.preset_n));
        // the request side has a driver clocking block (the active agent's): forced, not assigned
        initial force apb.psel = u_tb.dut.u_core.g_uart[g].u_uart.psel_i;
        initial force apb.penable = u_tb.dut.u_core.g_uart[g].u_uart.penable_i;
        initial force apb.pwrite = u_tb.dut.u_core.g_uart[g].u_uart.pwrite_i;
        initial force apb.paddr = u_tb.dut.u_core.g_uart[g].u_uart.paddr_i;
        initial force apb.pwdata = u_tb.dut.u_core.g_uart[g].u_uart.pwdata_i;
        assign apb.prdata  = u_tb.dut.u_core.g_uart[g].u_uart.prdata_o;
        assign apb.pready  = u_tb.dut.u_core.g_uart[g].u_uart.pready_o;
        assign apb.pslverr = u_tb.dut.u_core.g_uart[g].u_uart.pslverr_o;
        uart_if uif (.pclk(apb.pclk), .preset_n(apb.preset_n), .psel(apb.psel), .penable(apb.penable),
                     .pwrite(apb.pwrite), .paddr(apb.paddr), .pwdata(apb.pwdata));
        assign uif.prdata  = apb.prdata;
        assign uif.pready  = apb.pready;
        assign uif.pslverr = apb.pslverr;
        // Power-up: until the reset controller drives preset_n at all (X for the first
        // cycle after the pin reset), the block's outputs are X too and nothing is
        // defined to check; from the first known preset_n on, every cycle is checked.
        wire pu = (apb.preset_n !== 1'bx);
        assign uif.tx      = pu ? u_tb.dut.u_core.g_uart[g].u_uart.uart_tx_o : 1'b1;
        assign uif.irq     = pu ? u_tb.dut.u_core.g_uart[g].u_uart.irq_o : 1'b0;
        assign uif.dma_req = u_tb.dut.u_core.g_uart[g].u_uart.dma_req_o;
        initial force uif.dma_ack = u_tb.dut.u_core.g_uart[g].u_uart.dma_ack_i;   // the chip's DMA answers
        initial uif.inst = g;                                                     // block 16 + g: the ID it predicts
        assign u_tb.uart_rx_pin[g] = uif.rx;                                      // the line agent drives rx
    end endgenerate

    // ---- GPIO (block 19) and PWM (block 20) ---------------------------------------
`define GARUDA_TAP_APB(A, B) \
    initial force A.psel = B.psel_i; initial force A.penable = B.penable_i; initial force A.pwrite = B.pwrite_i; \
    initial force A.paddr = B.paddr_i; initial force A.pwdata = B.pwdata_i; \
    assign A.prdata = B.prdata_o; assign A.pready = B.pready_o; assign A.pslverr = B.pslverr_o;
    garuda_apb_if gpio_apb (.pclk(u_tb.dut.u_core.u_gpio.pclk), .preset_n(u_tb.dut.u_core.u_gpio.preset_n));
    `GARUDA_TAP_APB(gpio_apb, u_tb.dut.u_core.u_gpio)
    gpio_if gif (.pclk(gpio_apb.pclk), .preset_n(gpio_apb.preset_n), .psel(gpio_apb.psel), .penable(gpio_apb.penable),
                 .pwrite(gpio_apb.pwrite), .paddr(gpio_apb.paddr), .pwdata(gpio_apb.pwdata));
    assign gif.prdata = gpio_apb.prdata; assign gif.pready = gpio_apb.pready; assign gif.pslverr = gpio_apb.pslverr;
    wire gpio_pu = (gpio_apb.preset_n !== 1'bx);              // power-up, as for the UARTs
    assign gif.pad     = u_tb.dut.u_core.u_gpio.gpio_i;       // what the block sees
    assign gif.gpio_o  = gpio_pu ? u_tb.dut.u_core.u_gpio.gpio_o  : 2'b00;
    assign gif.gpio_oe = gpio_pu ? u_tb.dut.u_core.u_gpio.gpio_oe : 2'b00;
    assign gif.irq     = gpio_pu ? u_tb.dut.u_core.u_gpio.irq_o   : 1'b0;
    // the pad agent drives the chip's pads (tb_chip holds them low with weak pull-downs)
    assign u_tb.gpio0 = gif.ext_force[0] ? gif.ext_val[0] : 1'bz;
    assign u_tb.gpio1 = gif.ext_force[1] ? gif.ext_val[1] : 1'bz;

    garuda_apb_if pwm_apb (.pclk(u_tb.dut.u_core.u_pwm.pclk), .preset_n(u_tb.dut.u_core.u_pwm.preset_n));
    `GARUDA_TAP_APB(pwm_apb, u_tb.dut.u_core.u_pwm)
    pwm_if pif (.pclk(pwm_apb.pclk), .preset_n(pwm_apb.preset_n), .psel(pwm_apb.psel), .penable(pwm_apb.penable),
                .pwrite(pwm_apb.pwrite), .paddr(pwm_apb.paddr), .pwdata(pwm_apb.pwdata));
    assign pif.prdata = pwm_apb.prdata; assign pif.pready = pwm_apb.pready; assign pif.pslverr = pwm_apb.pslverr;
    wire pwm_pu = (pwm_apb.preset_n !== 1'bx);
    assign pif.pwm = pwm_pu ? u_tb.dut.u_core.u_pwm.pwm_o : 4'h0;
    assign pif.irq = pwm_pu ? u_tb.dut.u_core.u_pwm.irq_o : 1'b0;

    // ---- I2C (block 13) -------------------------------------------------------------
    garuda_apb_if i2c_apb (.pclk(u_tb.dut.u_core.u_i2c.pclk), .preset_n(u_tb.dut.u_core.u_i2c.preset_n));
    `GARUDA_TAP_APB(i2c_apb, u_tb.dut.u_core.u_i2c)
    i2c_if iif (.pclk(i2c_apb.pclk), .preset_n(i2c_apb.preset_n), .psel(i2c_apb.psel), .penable(i2c_apb.penable),
                .pwrite(i2c_apb.pwrite), .paddr(i2c_apb.paddr), .pwdata(i2c_apb.pwdata));
    assign iif.prdata = i2c_apb.prdata; assign iif.pready = i2c_apb.pready; assign iif.pslverr = i2c_apb.pslverr;
    wire i2c_pu = (i2c_apb.preset_n !== 1'bx);
    assign iif.scl_o = 1'b0;                                   // open drain: only enables leave the block
    assign iif.sda_o = 1'b0;
    assign iif.scl_oe  = i2c_pu ? u_tb.dut.u_core.u_i2c.i2c_scl_oe : 1'b0;
    assign iif.sda_oe  = i2c_pu ? u_tb.dut.u_core.u_i2c.i2c_sda_oe : 1'b0;
    assign iif.irq     = i2c_pu ? u_tb.dut.u_core.u_i2c.irq_o      : 1'b0;
    assign iif.dma_req = i2c_pu ? u_tb.dut.u_core.u_i2c.dma_req_o  : 1'b0;
    initial force iif.dma_ack = u_tb.dut.u_core.u_i2c.dma_ack_i;
    // the bus is the board's (pull-ups, the slave model at 0x48): the interface's lines are
    // the pads, and the agents' pull-downs go onto the pads
    initial force iif.scl = u_tb.i2c_scl;
    initial force iif.sda = u_tb.i2c_sda;
    assign u_tb.i2c_scl = (iif.slv_scl_low | iif.oth_scl_low) ? 1'b0 : 1'bz;
    assign u_tb.i2c_sda = (iif.slv_sda_low | iif.oth_sda_low) ? 1'b0 : 1'bz;

    // ---- SPI slave (block 14) ---------------------------------------------------------
    garuda_apb_if spis_apb (.pclk(u_tb.dut.u_core.g_spis.u_spis.pclk), .preset_n(u_tb.dut.u_core.g_spis.u_spis.preset_n));
    `GARUDA_TAP_APB(spis_apb, u_tb.dut.u_core.g_spis.u_spis)
    spis_if sif (.pclk(spis_apb.pclk), .preset_n(spis_apb.preset_n), .psel(spis_apb.psel), .penable(spis_apb.penable),
                 .pwrite(spis_apb.pwrite), .paddr(spis_apb.paddr), .pwdata(spis_apb.pwdata));
    assign sif.prdata = spis_apb.prdata; assign sif.pready = spis_apb.pready; assign sif.pslverr = spis_apb.pslverr;
    wire spis_pu = (spis_apb.preset_n !== 1'bx);
    // MISO and its enable from the block (the scoreboard checks both every cycle; the pad
    // itself is tri-state when not enabled)
    assign sif.miso    = spis_pu ? u_tb.dut.u_core.g_spis.u_spis.spis_miso_o    : 1'b0;
    assign sif.miso_oe = spis_pu ? u_tb.dut.u_core.g_spis.u_spis.spis_miso_oe_o : 1'b0;
    assign sif.irq     = spis_pu ? u_tb.dut.u_core.g_spis.u_spis.irq_o          : 1'b0;
    assign sif.dma_req = spis_pu ? u_tb.dut.u_core.g_spis.u_spis.dma_req_o      : 1'b0;
    initial force sif.dma_ack = u_tb.dut.u_core.g_spis.u_spis.dma_ack_i;
    // the master agent is the companion on the chip's pins
    assign u_tb.spis_sclk = sif.sclk;
    assign u_tb.spis_mosi = sif.mosi;
    assign u_tb.spis_cs_n = sif.cs_n;
    assign ctl.gpio1      = u_tb.gpio1;

    // ---- timers (block 9), CLIC (block 8), DMA (block 7): in garuda_soc_top ------------
`define SOC u_tb.dut.u_core.u_soc
    garuda_apb_if tmr_apb (.pclk(`SOC.u_timers.pclk), .preset_n(`SOC.u_timers.preset_n));
    `GARUDA_TAP_APB(tmr_apb, `SOC.u_timers)
    timers_if tif (.hclk(`SOC.u_timers.hclk), .psel(tmr_apb.psel), .penable(tmr_apb.penable), .pwrite(tmr_apb.pwrite),
                   .paddr(tmr_apb.paddr), .pwdata(tmr_apb.pwdata));
    assign tif.ext_rst_n = `SOC.u_timers.ext_hrst_n;
    assign tif.hreset_n  = `SOC.u_timers.hreset_n;
    assign tif.preset_n  = `SOC.u_timers.preset_n;
    assign tif.mtip      = `SOC.u_timers.mtip_o;
    assign tif.warn      = `SOC.u_timers.wdt_warn_irq_o;
    assign tif.req       = `SOC.u_timers.wdt_rst_req_o;

    garuda_apb_if clic_apb (.pclk(`SOC.u_clic.pclk), .preset_n(`SOC.u_clic.preset_n));
    `GARUDA_TAP_APB(clic_apb, `SOC.u_clic)
    clic_src_if csif (.hclk(`SOC.hclk));
    initial begin
        force csif.rst_n   = `SOC.u_clic.preset_n;
        force csif.irq_src = `SOC.u_clic.irq_src_i;          // the chip's 32 sources
    end
    assign csif.valid = `SOC.u_clic.clic_irq_valid_o;
    assign csif.id    = `SOC.u_clic.clic_irq_id_o;
    assign csif.level = `SOC.u_clic.clic_irq_level_o;

    garuda_apb_if dma_apb (.pclk(`SOC.u_dma.pclk), .preset_n(`SOC.u_dma.preset_n));
    `GARUDA_TAP_APB(dma_apb, `SOC.u_dma)
    dma_if dif (.hclk(`SOC.u_dma.hclk), .pclk(`SOC.u_dma.pclk));
    initial begin                                            // the chip's fabric answers, its blocks request
        force dif.rst_n  = `SOC.u_dma.hreset_n;
        force dif.hrdata = `SOC.u_dma.hrdata_i;
        force dif.hready = `SOC.u_dma.hready_i;
        force dif.hresp  = `SOC.u_dma.hresp_i;
        force dif.req    = `SOC.u_dma.dma_req_i;
    end
    assign dif.haddr    = `SOC.u_dma.haddr_o;
    assign dif.htrans   = `SOC.u_dma.htrans_o;
    assign dif.hwrite   = `SOC.u_dma.hwrite_o;
    assign dif.hsize    = `SOC.u_dma.hsize_o;
    assign dif.hburst   = 3'b000;                            // HBURST left the bus (D-38)
    assign dif.hwdata   = `SOC.u_dma.hwdata_o;
    assign dif.ack      = `SOC.u_dma.dma_ack_o;
    assign dif.complete = `SOC.u_dma.dma_complete_o;
    assign dif.error    = `SOC.u_dma.dma_error_o;

    // ---- clock and reset generation (blocks 1, 2: clk_div and reset_ctrl) --------------
`define CORE u_tb.dut.u_core
    garuda_apb_if crg_apb (.pclk(`CORE.u_reset_ctrl.pclk), .preset_n(`CORE.u_reset_ctrl.preset_n));
    `GARUDA_TAP_APB(crg_apb, `CORE.u_reset_ctrl)
    crg_if cif (.refclk(`CORE.u_clk_div.refclk), .psel(crg_apb.psel), .penable(crg_apb.penable), .pwrite(crg_apb.pwrite),
                .paddr(crg_apb.paddr), .pwdata(crg_apb.pwdata));
    initial begin                                            // the chip's pins and request sources
        force cif.ext_rst_n = `CORE.u_reset_ctrl.ext_rst_n;
        force cif.wdt_req   = `CORE.u_reset_ctrl.wdt_rst_req_i;
        force cif.ndm_req   = `CORE.u_reset_ctrl.ndm_rst_req_i;
        force cif.hart_req  = `CORE.u_reset_ctrl.hartreset_req_i;
        force cif.boot_sel  = `CORE.u_reset_ctrl.boot_sel_i;
        force cif.refclk_en = 1'b1;
    end
    assign cif.aon = `CORE.u_clk_div.aon_clk; assign cif.hclk = `CORE.u_clk_div.hclk; assign cif.pclk = `CORE.u_clk_div.pclk;
    assign cif.pclk_phase = `CORE.u_clk_div.pclk_phase_o;
    assign cif.div_busy = `CORE.u_clk_div.div_busy_o; assign cif.div_act = `CORE.u_clk_div.div_act_o;
    assign cif.div_sel  = `CORE.u_reset_ctrl.div_sel_o;
    assign cif.hreset_n = `CORE.u_reset_ctrl.hreset_n; assign cif.preset_n = `CORE.u_reset_ctrl.preset_n;
    assign cif.core_rst_n = `CORE.u_reset_ctrl.core_rst_n; assign cif.dm_rst_n = `CORE.u_reset_ctrl.dm_rst_n;
    assign cif.ext_hrst_n = `CORE.u_reset_ctrl.ext_hrst_n; assign cif.ilock = `CORE.u_reset_ctrl.ilock_o;
    assign cif.prdata = crg_apb.prdata; assign cif.pready = crg_apb.pready; assign cif.pslverr = crg_apb.pslverr;
    assign cif.phase = {`CORE.u_clk_div.t4_q, `CORE.u_clk_div.t3_q, `CORE.u_clk_div.t2_q, `CORE.u_clk_div.aon_clk};

    // ---- planted defects (negative controls, tb/chip_uvm/plants.txt) --------------------
    // +PLANT=<name> injects a defect the firmware cannot see, so the program still reports
    // success; the run must fail on the named scoreboard check. sweep.sh runs each one.
    string plant = "";
    initial if ($value$plusargs("PLANT=%s", plant)) begin
        $display("tb_chip_uvm: PLANTED DEFECT %s", plant);
        case (plant)
            "pwm": begin                      // the four PWM pins stuck low
                @(posedge u_tb.dut.u_core.u_pwm.preset_n);
                force u_tb.dut.u_core.u_pwm.pwm_o = 4'h0;
            end
            "spis_miso": forever begin        // MISO stuck high while the companion is selected
                @(negedge u_tb.spis_cs_n);
                force u_tb.dut.u_core.g_spis.u_spis.spis_miso_o = 1'b1;
                @(posedge u_tb.spis_cs_n);
                release u_tb.dut.u_core.g_spis.u_spis.spis_miso_o;
            end
            "uart_dma": begin                 // UART2's DMA request stuck high (no channel uses it)
                @(posedge u_tb.dut.u_core.g_uart[2].u_uart.preset_n);
                #1000 force u_tb.dut.u_core.g_uart[2].u_uart.dma_req_o = 1'b1;
            end
            default: $fatal(1, "tb_chip_uvm: unknown +PLANT=%s", plant);
        endcase
    end

    initial begin
        uvm_config_db #(virtual chip_ctl_if)::set(null, "uvm_test_top", "ctl", ctl);
        uvm_config_db #(virtual garuda_apb_if)::set(null, "uvm_test_top.env.uart0.*", "vif",  g_u[0].apb);
        uvm_config_db #(virtual garuda_apb_if)::set(null, "uvm_test_top.env.uart1.*", "vif",  g_u[1].apb);
        uvm_config_db #(virtual garuda_apb_if)::set(null, "uvm_test_top.env.uart2.*", "vif",  g_u[2].apb);
        uvm_config_db #(virtual uart_if)::set(null, "uvm_test_top.env.uart0.*", "uvif", g_u[0].uif);
        uvm_config_db #(virtual uart_if)::set(null, "uvm_test_top.env.uart1.*", "uvif", g_u[1].uif);
        uvm_config_db #(virtual uart_if)::set(null, "uvm_test_top.env.uart2.*", "uvif", g_u[2].uif);
        uvm_config_db #(virtual garuda_apb_if)::set(null, "uvm_test_top.env.gpio.*", "vif", gpio_apb);
        uvm_config_db #(virtual gpio_if)::set(null, "uvm_test_top.env.gpio.*", "gvif", gif);
        uvm_config_db #(virtual garuda_apb_if)::set(null, "uvm_test_top.env.pwm.*", "vif", pwm_apb);
        uvm_config_db #(virtual pwm_if)::set(null, "uvm_test_top.env.pwm.*", "pvif", pif);
        uvm_config_db #(virtual garuda_apb_if)::set(null, "uvm_test_top.env.i2c.*", "vif", i2c_apb);
        uvm_config_db #(virtual i2c_if)::set(null, "uvm_test_top.env.i2c.*", "ivif", iif);
        uvm_config_db #(virtual garuda_apb_if)::set(null, "uvm_test_top.env.spis.*", "vif", spis_apb);
        uvm_config_db #(virtual spis_if)::set(null, "uvm_test_top.env.spis.*", "svif", sif);
        uvm_config_db #(virtual garuda_apb_if)::set(null, "uvm_test_top.env.timers.*", "vif", tmr_apb);
        uvm_config_db #(virtual timers_if)::set(null, "uvm_test_top.env.timers.*", "tvif", tif);
        uvm_config_db #(virtual garuda_apb_if)::set(null, "uvm_test_top.env.clic.*", "vif", clic_apb);
        uvm_config_db #(virtual clic_src_if)::set(null, "uvm_test_top.env.clic.*", "svif", csif);
        uvm_config_db #(virtual garuda_apb_if)::set(null, "uvm_test_top.env.dma.*", "vif", dma_apb);
        uvm_config_db #(virtual dma_if)::set(null, "uvm_test_top.env.dma.*", "dvif", dif);
        uvm_config_db #(virtual garuda_apb_if)::set(null, "uvm_test_top.env.crg.*", "vif", crg_apb);
        uvm_config_db #(virtual crg_if)::set(null, "uvm_test_top.env.crg.*", "cvif", cif);
        run_test();
    end
endmodule
