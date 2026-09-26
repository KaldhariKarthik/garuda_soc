`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - chip boundary
// garuda_chip_top.v - clk_div (21) + reset_ctrl (22) + garuda_soc_top
//
// Pins: exactly GARUDA-PHYS-SPEC-001 §3.1 / yaml pins.allocation - the 28-pin
// baseline, 26 signals allocated (ADR-0020, D-10). No pad cells: the pad ring
// is a physical-design handoff item; tri-state and open-drain pins are
// modelled with 'z' here and become pad OE/PE controls at PD.
//
// ALL SEVEN PERIPHERALS ARE NOW INSTANTIATED. Window 5 (dma_cfg), 9
// (reset_ctrl + MEMCTL), 10 (CLIC) and 11 (timers) are inside garuda_soc_top;
// windows 1, 2, 3, 4, 6, 7 and 8 are the blocks below. Every window in
// APB_WINDOW_MASK answers; an access to any other faults rather than hangs.
//
//   window  block        IRQ (CLIC)          DMA ch   pins
//   0       spi_slave    CLIC 14             4        spis_*      LANDED
//   1       spi_master   periph_irq[0] (15)  0        spim_*      LANDED
//   2       i2c          periph_irq[1] (16)  1        i2c_scl/sda  LANDED
//   3       uart0        periph_irq[2] (17)  2        uart0_rx/tx  LANDED
//   4       uart1        periph_irq[3] (18)  3        uart1_rx/tx  LANDED
//   6       uart2        periph_irq[4] (19)  5        uart2_rx/tx  LANDED
//   7       gpio         periph_irq[5] (20)  -        gpio0..1    LANDED
//   8       pwm          periph_irq[6] (21)  -        pwm0..3     LANDED
//
// Safe idle out of reset, which every block below is responsible for and every
// block TB checks: PWM low (an ESC reads that as no signal - motors stopped),
// SPI chip selects high, UART TX high (line idle), I2C released (board
// pull-ups), GPIO released (input). JTAG TDO is tri-stated outside
// Shift-IR/DR.
// =============================================================================
`include "garuda_map.vh"

module garuda_chip_top #(
    parameter         BROM_INIT_FILE = "",
    parameter         CORE_CLK_GATE  = 1,
    // Block 14, the ESP-NOW companion link. ADR-0020 Rev 2 makes it REQUIRED;
    // whether its four pins are additive or reclaimed is OPEN-2, the PD
    // mentor's call against the pad frame (PHYS [N-3.6], SPIS OPEN-S1). The
    // RTL is present either way - set this to 0 and the block is not
    // instantiated, window 0 stays masked and the pins sit at safe idle,
    // which is exactly the 28-pin build.
    parameter         WITH_SPI_SLAVE = 1,
    // Per-window APB access-rate divider (2 bits each, /1 /2 /4 /8). The escape
    // hatch for a peripheral IP whose INTERFACE timing cannot take an 8 ns
    // access; it does not slow the IP's own flops (AHB2APB [N-7.10]).
    parameter [23:0]  APB_DIV        = 24'h0,
    parameter [15:0]  APB_WINDOW_MASK = (16'd1 << `GARUDA_APB_WIN_DMA_CFG)    |
                                        (16'd1 << `GARUDA_APB_WIN_RESET_CTRL) |
                                        (16'd1 << `GARUDA_APB_WIN_CLIC_CFG)   |
                                        (16'd1 << `GARUDA_APB_WIN_TIMERS_CFG) |
                                        (16'd1 << `GARUDA_APB_WIN_SPI_MASTER) |
                                        (16'd1 << `GARUDA_APB_WIN_UART0)      |
                                        (16'd1 << `GARUDA_APB_WIN_UART1)      |
                                        (16'd1 << `GARUDA_APB_WIN_UART2)      |
                                        (16'd1 << `GARUDA_APB_WIN_I2C)        |
                                        (16'd1 << `GARUDA_APB_WIN_GPIO)       |
                                        (16'd1 << `GARUDA_APB_WIN_PWM)        |
                                        (WITH_SPI_SLAVE ? 16'd1 : 16'd0)
)(
    input  wire refclk,              //  1  500 MHz reference
    input  wire ext_rst_n,           //  2  board supervisor reset
    input  wire tck,                 //  3
    input  wire tms,                 //  4
    input  wire tdi,                 //  5
    output wire tdo,                 //  6  tri-state
    output wire spim_sclk,           //  7
    output wire spim_mosi,           //  8
    input  wire spim_miso,           //  9
    output wire spim_cs_flash_n,     // 10
    output wire spim_cs_imu_n,       // 11
    inout  wire i2c_scl,             // 12  open-drain
    inout  wire i2c_sda,             // 13  open-drain
    input  wire uart0_rx,            // 14
    output wire uart0_tx,            // 15
    input  wire uart1_rx,            // 16
    output wire uart1_tx,            // 17
    input  wire uart2_rx,            // 18
    output wire uart2_tx,            // 19
    output wire pwm0,                // 20
    output wire pwm1,                // 21
    output wire pwm2,                // 22
    output wire pwm3,                // 23
    inout  wire gpio0,               // 24
    inout  wire gpio1,               // 25
    input  wire boot_sel,            // 26  pull-down at the pad
    // ---- pins 29-32, block 14 (PHYS §3.2). Bonded only in the 36-pin
    //      variant; harmless and driven to safe idle when WITH_SPI_SLAVE = 0.
    input  wire spis_sclk,           // 29
    input  wire spis_mosi,           // 30
    output wire spis_miso,           // 31  tri-state
    input  wire spis_cs_n            // 32
);

    // =========================================================================
    // Block 21: clock divider
    // =========================================================================
    wire aon_clk, hclk, pclk, pclk_phase, div_busy;
    wire [1:0] div_sel, div_act;

    clk_div u_clk_div (
        .refclk_i(refclk), .raw_rst_n_i(ext_rst_n), .div_sel_i(div_sel),
        .aon_clk_o(aon_clk), .hclk_o(hclk), .pclk_o(pclk), .pclk_phase_o(pclk_phase),
        .div_act_o(div_act), .div_busy_o(div_busy));

    // =========================================================================
    // Block 22: reset controller (+ its APB registers on window 9)
    // =========================================================================
    wire hreset_n, preset_n, core_rst_n, dm_rst_n, ext_hrst_n, ilock;
    wire wdt_rst_req, ndmreset, hartreset;

    wire [11:0] ext_psel, ext_paddr;
    wire        ext_penable, ext_pwrite;
    wire [31:0] ext_pwdata, rst_prdata;
    wire        rst_pready, rst_pslverr;

    reset_ctrl u_reset_ctrl (
        .aon_clk_i(aon_clk), .hclk_i(hclk), .pclk_i(pclk),
        .ext_rst_n_i(ext_rst_n), .wdt_rst_req_i(wdt_rst_req),
        .ndm_rst_req_i(ndmreset), .hartreset_req_i(hartreset), .boot_sel_i(boot_sel),
        .psel_i(ext_psel[`GARUDA_APB_WIN_RESET_CTRL]), .penable_i(ext_penable),
        .pwrite_i(ext_pwrite), .paddr_i(ext_paddr), .pwdata_i(ext_pwdata),
        .prdata_o(rst_prdata), .pready_o(rst_pready), .pslverr_o(rst_pslverr),
        .div_sel_o(div_sel), .div_act_i(div_act), .div_busy_i(div_busy),
        .ilock_o(ilock),
        .hreset_n_o(hreset_n), .preset_n_o(preset_n), .core_rst_n_o(core_rst_n),
        .dm_rst_n_o(dm_rst_n), .ext_hrst_n_o(ext_hrst_n));

    // =========================================================================
    // Block 13: SPI master (window 1) - boot flash and the IMU
    // =========================================================================
    wire [5:0]  dma_ack;
    wire [31:0] spim_prdata;
    wire        spim_pready, spim_pslverr, spim_irq, spim_dma_req;

    garuda_spim_top u_spim (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(ext_psel[`GARUDA_APB_WIN_SPI_MASTER]), .penable_i(ext_penable),
        .pwrite_i(ext_pwrite), .paddr_i(ext_paddr), .pwdata_i(ext_pwdata),
        .prdata_o(spim_prdata), .pready_o(spim_pready), .pslverr_o(spim_pslverr),
        .irq_o(spim_irq), .dma_req_o(spim_dma_req), .dma_ack_i(dma_ack[0]),
        .spim_sclk_o(spim_sclk), .spim_mosi_o(spim_mosi), .spim_miso_i(spim_miso),
        .spim_cs_flash_n_o(spim_cs_flash_n), .spim_cs_imu_n_o(spim_cs_imu_n));

    // =========================================================================
    // Block 15: I2C master (window 2) - sensors on an open-drain bus
    // =========================================================================
    wire [31:0] i2c_prdata;
    wire        i2c_pready, i2c_pslverr, i2c_irq, i2c_dma_req;
    wire        i2c_scl_out, i2c_scl_oe, i2c_sda_out, i2c_sda_oe;

    garuda_i2c_top u_i2c (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(ext_psel[`GARUDA_APB_WIN_I2C]), .penable_i(ext_penable),
        .pwrite_i(ext_pwrite), .paddr_i(ext_paddr), .pwdata_i(ext_pwdata),
        .prdata_o(i2c_prdata), .pready_o(i2c_pready), .pslverr_o(i2c_pslverr),
        .irq_o(i2c_irq), .dma_req_o(i2c_dma_req), .dma_ack_i(dma_ack[1]),
        .i2c_scl_i(i2c_scl), .i2c_scl_o(i2c_scl_out), .i2c_scl_oe(i2c_scl_oe),
        .i2c_sda_i(i2c_sda), .i2c_sda_o(i2c_sda_out), .i2c_sda_oe(i2c_sda_oe));

    // =========================================================================
    // Blocks 16/17/18: UART x3 (windows 3, 4, 6) - one design, three instances
    // =========================================================================
    wire [31:0] uart_prdata [0:2];
    wire [2:0]  uart_pready, uart_pslverr, uart_irq, uart_dma_req;
    wire [2:0]  uart_tx, uart_rx;

    assign uart_rx = {uart2_rx, uart1_rx, uart0_rx};
    assign uart0_tx = uart_tx[0];
    assign uart1_tx = uart_tx[1];
    assign uart2_tx = uart_tx[2];

    // Window and DMA channel per instance. uart2 sits on window 6 and channel 5,
    // not 5 and 4, because window 5 is dma_cfg and channel 4 is the SPI slave.
    // Ternary chains rather than a parameter array: this file is Verilog-2001,
    // and each expression is still a constant within its generate iteration.
    genvar u;
    generate for (u = 0; u < 3; u = u + 1) begin : g_uart
        localparam integer WIN = (u == 0) ? `GARUDA_APB_WIN_UART0 :
                                 (u == 1) ? `GARUDA_APB_WIN_UART1 :
                                            `GARUDA_APB_WIN_UART2;
        localparam integer DCH = (u == 0) ? 2 : (u == 1) ? 3 : 5;

        garuda_uart_top #(.BLOCK_NUM(8'd16 + u[7:0])) u_uart (
            .pclk_i(pclk), .preset_n_i(preset_n),
            .psel_i(ext_psel[WIN]), .penable_i(ext_penable),
            .pwrite_i(ext_pwrite), .paddr_i(ext_paddr), .pwdata_i(ext_pwdata),
            .prdata_o(uart_prdata[u]), .pready_o(uart_pready[u]),
            .pslverr_o(uart_pslverr[u]),
            .irq_o(uart_irq[u]), .dma_req_o(uart_dma_req[u]),
            .dma_ack_i(dma_ack[DCH]),
            .uart_tx_o(uart_tx[u]), .uart_rx_i(uart_rx[u]));
    end endgenerate

    // =========================================================================
    // Block 19: GPIO (window 7) - two bidirectional pins
    // =========================================================================
    wire [31:0] gpio_prdata;
    wire        gpio_pready, gpio_pslverr, gpio_irq;
    wire [1:0]  gpio_out, gpio_oe, gpio_in;

    assign gpio_in = {gpio1, gpio0};

    garuda_gpio_top #(.BLOCK_NUM(8'd19), .PAD_NUM(2)) u_gpio (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(ext_psel[`GARUDA_APB_WIN_GPIO]), .penable_i(ext_penable),
        .pwrite_i(ext_pwrite), .paddr_i(ext_paddr), .pwdata_i(ext_pwdata),
        .prdata_o(gpio_prdata), .pready_o(gpio_pready), .pslverr_o(gpio_pslverr),
        .irq_o(gpio_irq),
        .gpio_i(gpio_in), .gpio_o(gpio_out), .gpio_oe(gpio_oe));

    // =========================================================================
    // Block 20: PWM (window 8) - four ESC outputs
    // =========================================================================
    wire [31:0] pwm_prdata;
    wire        pwm_pready, pwm_pslverr, pwm_irq;
    wire [3:0]  pwm_pins;

    garuda_pwm_top #(.BLOCK_NUM(8'd20), .NCH(4)) u_pwm (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(ext_psel[`GARUDA_APB_WIN_PWM]), .penable_i(ext_penable),
        .pwrite_i(ext_pwrite), .paddr_i(ext_paddr), .pwdata_i(ext_pwdata),
        .prdata_o(pwm_prdata), .pready_o(pwm_pready), .pslverr_o(pwm_pslverr),
        .irq_o(pwm_irq), .pwm_o(pwm_pins));

    // =========================================================================
    // Block 14: SPI slave (window 0) - the ESP32 / ESP-NOW companion link
    // =========================================================================
    wire [31:0] spis_prdata;
    wire        spis_pready, spis_pslverr, spis_irq, spis_dma_req;
    wire        spis_miso_d, spis_miso_oe;

    generate if (WITH_SPI_SLAVE) begin : g_spis
        garuda_spis_top #(.BLOCK_NUM(8'd14), .FIFO_DEPTH(16)) u_spis (
            .pclk_i(pclk), .preset_n_i(preset_n),
            .psel_i(ext_psel[0]), .penable_i(ext_penable),
            .pwrite_i(ext_pwrite), .paddr_i(ext_paddr), .pwdata_i(ext_pwdata),
            .prdata_o(spis_prdata), .pready_o(spis_pready),
            .pslverr_o(spis_pslverr),
            .irq_o(spis_irq), .dma_req_o(spis_dma_req), .dma_ack_i(dma_ack[4]),
            .spis_sclk_i(spis_sclk), .spis_mosi_i(spis_mosi),
            .spis_cs_n_i(spis_cs_n),
            .spis_miso_o(spis_miso_d), .spis_miso_oe_o(spis_miso_oe));
    end else begin : g_no_spis
        // The 28-pin build: window 0 masked, pins at safe idle.
        assign spis_prdata  = 32'd0;
        assign spis_pready  = 1'b1;
        assign spis_pslverr = 1'b1;
        assign spis_irq     = 1'b0;
        assign spis_dma_req = 1'b0;
        assign spis_miso_d  = 1'b0;
        assign spis_miso_oe = 1'b0;
    end endgenerate

    assign spis_miso = spis_miso_oe ? spis_miso_d : 1'bz;

    // =========================================================================
    // APB expansion return path: window 0 = spi_slave, 1 = spi_master,
    // 3/4/6 = uart0/1/2,
    // window 9 = reset_ctrl;
    // every other external window has no IP yet (masked in the bridge, so an
    // access faults rather than hangs; answers SLVERR if unmasked).
    // =========================================================================
    wire [12*32-1:0] ext_prdata;
    wire [11:0]      ext_pready, ext_pslverr;
    genvar w;
    generate for (w = 0; w < 12; w = w + 1) begin : g_ext
        if (w == `GARUDA_APB_WIN_RESET_CTRL) begin : g_rst
            assign ext_prdata[32*w +: 32] = rst_prdata;
            assign ext_pready[w]          = rst_pready;
            assign ext_pslverr[w]         = rst_pslverr;
        end else if (w == 0) begin : g_spis_rt
            assign ext_prdata[32*w +: 32] = spis_prdata;
            assign ext_pready[w]          = spis_pready;
            assign ext_pslverr[w]         = spis_pslverr;
        end else if (w == `GARUDA_APB_WIN_SPI_MASTER) begin : g_spim
            assign ext_prdata[32*w +: 32] = spim_prdata;
            assign ext_pready[w]          = spim_pready;
            assign ext_pslverr[w]         = spim_pslverr;
        end else if (w == `GARUDA_APB_WIN_I2C) begin : g_i2c
            assign ext_prdata[32*w +: 32] = i2c_prdata;
            assign ext_pready[w]          = i2c_pready;
            assign ext_pslverr[w]         = i2c_pslverr;
        end else if (w == `GARUDA_APB_WIN_UART0) begin : g_uart0
            assign ext_prdata[32*w +: 32] = uart_prdata[0];
            assign ext_pready[w]          = uart_pready[0];
            assign ext_pslverr[w]         = uart_pslverr[0];
        end else if (w == `GARUDA_APB_WIN_UART1) begin : g_uart1
            assign ext_prdata[32*w +: 32] = uart_prdata[1];
            assign ext_pready[w]          = uart_pready[1];
            assign ext_pslverr[w]         = uart_pslverr[1];
        end else if (w == `GARUDA_APB_WIN_UART2) begin : g_uart2
            assign ext_prdata[32*w +: 32] = uart_prdata[2];
            assign ext_pready[w]          = uart_pready[2];
            assign ext_pslverr[w]         = uart_pslverr[2];
        end else if (w == `GARUDA_APB_WIN_GPIO) begin : g_gpio
            assign ext_prdata[32*w +: 32] = gpio_prdata;
            assign ext_pready[w]          = gpio_pready;
            assign ext_pslverr[w]         = gpio_pslverr;
        end else if (w == `GARUDA_APB_WIN_PWM) begin : g_pwm
            assign ext_prdata[32*w +: 32] = pwm_prdata;
            assign ext_pready[w]          = pwm_pready;
            assign ext_pslverr[w]         = pwm_pslverr;
        end else begin : g_none
            assign ext_prdata[32*w +: 32] = 32'd0;
            assign ext_pready[w]          = 1'b1;
            assign ext_pslverr[w]         = 1'b1;
        end
    end endgenerate

    // =========================================================================
    // The SoC
    // =========================================================================
    wire tdo_q, tdo_oe;

    // Peripheral interrupts (CLIC IDs 15..21) and DMA channels; one bit per
    // block, zero where the IP has not landed yet.
    //   periph_irq[0] = spi_master (CLIC 15)   dma_req[0] = spi_master
    //   periph_irq[2..4] = uart0/1/2 (17/18/19)  dma_req[2,3,5] = uart0/1/2
    //   periph_irq[5] = gpio (CLIC 20)   periph_irq[6] = pwm (CLIC 21)
    wire [6:0] periph_irq = {pwm_irq, gpio_irq,
                             uart_irq[2], uart_irq[1], uart_irq[0],
                             i2c_irq, spim_irq};
    //   dma_req[4] = spi_slave (ADR-0020 Rev 2) - no longer tied low
    wire [5:0] dma_req    = {uart_dma_req[2], spis_dma_req,
                             uart_dma_req[1], uart_dma_req[0], i2c_dma_req, spim_dma_req};

    garuda_soc_top #(
        .BROM_INIT_FILE(BROM_INIT_FILE), .APB_WINDOW_MASK(APB_WINDOW_MASK),
        .APB_DIV(APB_DIV), .CORE_CLK_GATE(CORE_CLK_GATE)
    ) u_soc (
        .hclk_i(hclk), .pclk_i(pclk), .pclk_phase_i(pclk_phase),
        .hreset_n_i(hreset_n), .preset_n_i(preset_n), .core_rst_n_i(core_rst_n),
        .dm_rst_n_i(dm_rst_n), .ext_hrst_n_i(ext_hrst_n), .por_n_i(ext_rst_n),
        .wdt_rst_req_o(wdt_rst_req), .ndmreset_o(ndmreset), .hartreset_o(hartreset),
        .ilock_i(ilock),
        .tck_i(tck), .tms_i(tms), .tdi_i(tdi), .tdo_o(tdo_q), .tdo_oe_o(tdo_oe),
        .apb_ext_psel_o(ext_psel), .apb_ext_penable_o(ext_penable),
        .apb_ext_pwrite_o(ext_pwrite), .apb_ext_paddr_o(ext_paddr),
        .apb_ext_pwdata_o(ext_pwdata),
        .apb_ext_prdata_i(ext_prdata), .apb_ext_pready_i(ext_pready),
        .apb_ext_pslverr_i(ext_pslverr),
        .periph_irq_i(periph_irq), .spis_irq_i(spis_irq),
        .dma_req_i(dma_req), .dma_ack_o(dma_ack),
        .core_sleep_o());

    // =========================================================================
    // Pins
    // =========================================================================
    assign tdo = tdo_oe ? tdo_q : 1'bz;

    // spim_* are driven by u_spim above; the rest are deferred peripherals
    // still at safe idle.
    // I2C is open drain: the block only ever pulls a line low or releases it,
    // so these become pad OE controls with the output tied low at PD.
    assign i2c_scl = i2c_scl_oe ? i2c_scl_out : 1'bz;
    assign i2c_sda = i2c_sda_oe ? i2c_sda_out : 1'bz;
    assign pwm0 = pwm_pins[0];
    assign pwm1 = pwm_pins[1];
    assign pwm2 = pwm_pins[2];
    assign pwm3 = pwm_pins[3];

    // GPIO is bidirectional: driven when its direction bit says output,
    // released otherwise. Becomes a pad OE control at PD.
    assign gpio0 = gpio_oe[0] ? gpio_out[0] : 1'bz;
    assign gpio1 = gpio_oe[1] ? gpio_out[1] : 1'bz;


endmodule

`default_nettype wire
