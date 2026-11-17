// =============================================================================
// GARUDA SoC - chip boundary
// garuda_chip_top.v - clk_div (21) + reset_ctrl (22) + garuda_soc_top
//
// Pins: exactly GARUDA-PHYS-SPEC-001 Sec.3.1 / yaml pins.allocation - the
// 28-pin baseline, 26 signals allocated (ADR-0020, D-10). No pad cells: the pad
// ring is a physical-design handoff item; tri-state and open-drain pins are
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

module garuda_chip_core
    import garuda_pkg::*;
    import soc_map_pkg::*;
#(
    parameter         BROM_INIT_FILE = "",
    parameter integer         CORE_CLK_GATE  = 32'd1,
    // Block 14, the ESP-NOW companion link. ADR-0020 Rev 2 makes it REQUIRED;
    // whether its four pins are additive or reclaimed is OPEN-2, the PD
    // mentor's call against the pad frame (PHYS [N-3.6], SPIS OPEN-S1). The
    // RTL is present either way - set this to 0 and the block is not
    // instantiated, window 0 stays masked and the pins sit at safe idle,
    // which is exactly the 28-pin build.
    parameter integer         WITH_SPI_SLAVE = 32'd1,
    // Per-window APB access-rate divider (2 bits each, /1 /2 /4 /8). The escape
    // hatch for a peripheral IP whose INTERFACE timing cannot take an 8 ns
    // access; it does not slow the IP's own flops (AHB2APB [N-7.10]).
    parameter [23:0]  APB_DIV        = 24'h000000,
    parameter [15:0]  APB_WINDOW_MASK = (16'd1 << WIN_DMA)    |
                                        (16'd1 << WIN_RESET_CTRL) |
                                        (16'd1 << WIN_CLIC)   |
                                        (16'd1 << WIN_TIMERS) |
                                        (16'd1 << WIN_SPI_MASTER) |
                                        (16'd1 << WIN_UART_ZERO)      |
                                        (16'd1 << WIN_UART_ONE)      |
                                        (16'd1 << WIN_UART_TWO)      |
                                        (16'd1 << WIN_I2C)        |
                                        (16'd1 << WIN_GPIO)       |
                                        (16'd1 << WIN_PWM)        |
                                        (WITH_SPI_SLAVE
                                            ? (16'd1 << WIN_SPI_SLAVE) : 16'd0)
)(
    input wire refclk,  //  1  500 MHz reference
    input wire ext_rst_n,  //  2  board supervisor reset
    input wire tck,  //  3
    input wire tms,  //  4
    input wire tdi,  //  5
    output wire tdo_o,  //  6  tdo data      (pad: tri-state)
    output wire tdo_oe_o,  //  6  tdo enable
    output wire spim_sclk,  //  7
    output wire spim_mosi,  //  8
    input wire spim_miso,  //  9
    output wire spim_cs_flash_n,  // 10
    output wire spim_cs_imu_n,  // 11
    input wire i2c_scl_i,  // 12  open-drain pad: in
    output wire i2c_scl_o,  // 12                  out
    output wire i2c_scl_oe_o,  // 12                  enable
    input wire i2c_sda_i,  // 13  open-drain pad: in
    output wire i2c_sda_o,  // 13                  out
    output wire i2c_sda_oe_o,  // 13                  enable
    input wire uart0_rx,  // 14
    output wire uart0_tx,  // 15
    input wire uart1_rx,  // 16
    output wire uart1_tx,  // 17
    input wire uart2_rx,  // 18
    output wire uart2_tx,  // 19
    output wire pwm0,  // 20
    output wire pwm1,  // 21
    output wire pwm2,  // 22
    output wire pwm3,  // 23
    input wire [GPIO_W-1:0] gpio_i,  // 24/25 pad in
    output wire [GPIO_W-1:0] gpio_o,  // 24/25 pad out
    output wire [GPIO_W-1:0] gpio_oe_o,  // 24/25 pad enable
    input wire boot_sel,  // 26  pull-down at the pad
    // ---- pins 29-32, block 14 (PHYS Sec.3.2). Bonded only in the 36-pin
    //      variant; harmless and driven to safe idle when WITH_SPI_SLAVE = 0.
    input wire spis_sclk,  // 29
    input wire spis_mosi,  // 30
    output wire spis_miso_o,  // 31  data   (pad: tri-state)
    output wire spis_miso_oe_o,  // 31  enable
    // 32
    input wire spis_cs_n
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned UART_PRDATA_W = 32'd3;
    localparam int unsigned UART_PREADY_W = 32'd3;
    localparam int unsigned UART_PSLVERR_W = 32'd3;
    localparam int unsigned UART_IRQ_W = 32'd3;
    localparam int unsigned UART_DMA_REQ_W = 32'd3;
    localparam int unsigned UART_TX_W = 32'd3;
    localparam int unsigned UART_RX_W = 32'd3;
    localparam int unsigned PWM_PINS_W = 32'd4;

    // =========================================================================
    // Block 21: clock divider
    // =========================================================================
    wire aon_clk;
    wire hclk;
    wire pclk;
    wire pclk_phase;
    wire div_busy;
    wire [DIV_SEL_W-1:0] div_sel;
    wire [DIV_SEL_W-1:0] div_act;

    clk_div u_clk_div (
        .refclk(refclk), .ext_rst_n(ext_rst_n), .div_sel_i(div_sel),
        .aon_clk(aon_clk), .hclk(hclk), .pclk(pclk), .pclk_phase_o(pclk_phase),
        .div_act_o(div_act), .div_busy_o(div_busy));

    // =========================================================================
    // Block 22: reset controller (+ its APB registers on window 9)
    // =========================================================================
    wire hreset_n;
    wire preset_n;
    wire core_rst_n;
    wire dm_rst_n;
    wire ext_hrst_n;
    wire ilock;
    wire wdt_rst_req;
    wire ndmreset;
    wire hartreset;

    wire [APB_NWIN-1:0] ext_psel;
    wire [PADDR_W-1:0] ext_paddr;
    wire ext_penable;
    wire ext_pwrite;
    wire [WORD_W-1:0] ext_pwdata;
    wire [WORD_W-1:0] rst_prdata;
    wire rst_pready;
    wire rst_pslverr;

    reset_ctrl u_reset_ctrl (
        .aon_clk(aon_clk), .hclk(hclk), .pclk(pclk),
        .ext_rst_n(ext_rst_n), .wdt_rst_req_i(wdt_rst_req),
        .ndm_rst_req_i(ndmreset), .hartreset_req_i(hartreset),
            .boot_sel_i(boot_sel),
        .psel_i(ext_psel[WIN_RESET_CTRL]), .penable_i(ext_penable),
        .pwrite_i(ext_pwrite), .paddr_i(ext_paddr), .pwdata_i(ext_pwdata),
        .prdata_o(rst_prdata), .pready_o(rst_pready), .pslverr_o(rst_pslverr),
        .div_sel_o(div_sel), .div_act_i(div_act), .div_busy_i(div_busy),
        .ilock_o(ilock),
        .hreset_n(hreset_n), .preset_n(preset_n), .core_rst_n(core_rst_n),
        .dm_rst_n(dm_rst_n), .ext_hrst_n(ext_hrst_n));

    // =========================================================================
    // Block 13: SPI master (window 1) - boot flash and the IMU
    // =========================================================================
    wire [DMA_NCH-1:0]  dma_ack;
    wire [WORD_W-1:0] spim_prdata;
    wire spim_pready;
    wire spim_pslverr;
    wire spim_irq;
    wire spim_dma_req;

    garuda_spim_top u_spim (
        .pclk(pclk), .preset_n(preset_n),
        .psel_i(ext_psel[WIN_SPI_MASTER]), .penable_i(ext_penable),
        .pwrite_i(ext_pwrite), .paddr_i(ext_paddr), .pwdata_i(ext_pwdata),
        .prdata_o(spim_prdata), .pready_o(spim_pready),
            .pslverr_o(spim_pslverr),
        .irq_o(spim_irq), .dma_req_o(spim_dma_req), .dma_ack_i(dma_ack[0]),
        .spim_sclk_o(spim_sclk), .spim_mosi_o(spim_mosi),
            .spim_miso_i(spim_miso),
        .spim_cs_flash_n_o(spim_cs_flash_n), .spim_cs_imu_n_o(spim_cs_imu_n));

    // =========================================================================
    // Block 15: I2C master (window 2) - sensors on an open-drain bus
    // =========================================================================
    wire [WORD_W-1:0] i2c_prdata;
    wire i2c_pready;
    wire i2c_pslverr;
    wire i2c_irq;
    wire i2c_dma_req;
    wire i2c_scl_out;
    wire i2c_scl_oe;
    wire i2c_sda_out;
    wire i2c_sda_oe;

    garuda_i2c_top u_i2c (
        .pclk(pclk), .preset_n(preset_n),
        .psel_i(ext_psel[WIN_I2C]), .penable_i(ext_penable),
        .pwrite_i(ext_pwrite), .paddr_i(ext_paddr), .pwdata_i(ext_pwdata),
        .prdata_o(i2c_prdata), .pready_o(i2c_pready), .pslverr_o(i2c_pslverr),
        .irq_o(i2c_irq), .dma_req_o(i2c_dma_req), .dma_ack_i(dma_ack[1]),
        .i2c_scl_i(i2c_scl_i), .i2c_scl_o(i2c_scl_out), .i2c_scl_oe(i2c_scl_oe),
        .i2c_sda_i(i2c_sda_i), .i2c_sda_o(i2c_sda_out),
            .i2c_sda_oe(i2c_sda_oe));

    // =========================================================================
    // Blocks 16/17/18: UART x3 (windows 3, 4, 6) - one design, three instances
    // =========================================================================
    wire [WORD_W-1:0] uart_prdata [0:UART_PRDATA_W-1];
    wire [UART_PREADY_W-1:0] uart_pready;
    wire [UART_PSLVERR_W-1:0] uart_pslverr;
    wire [UART_IRQ_W-1:0] uart_irq;
    wire [UART_DMA_REQ_W-1:0] uart_dma_req;
    wire [UART_TX_W-1:0] uart_tx;
    wire [UART_RX_W-1:0] uart_rx;

    assign uart_rx = {uart2_rx, uart1_rx, uart0_rx};
    assign uart0_tx = uart_tx[0];
    assign uart1_tx = uart_tx[1];
    assign uart2_tx = uart_tx[2];

    // Window and DMA channel per instance. uart2 sits on window 6 and channel
    // 5, not 5 and 4, because window 5 is dma_cfg and channel 4 is the SPI
    // slave. Ternary chains rather than a parameter array: this file is
    // Verilog-2001, and each expression is still a constant within its generate
    // iteration.
    genvar u;
    generate for (u = 0; u < 3; u = u + 1) begin : g_uart
        localparam integer APB_WIN = (u == 32'd0) ? WIN_UART_ZERO :
                                 (u == 1) ? WIN_UART_ONE :
                                            WIN_UART_TWO;
        localparam integer DMA_CHAN = (u == 32'd0) ? 2 : (u == 32'd1) ? 3 : 5;

        garuda_uart_top #(.BLOCK_NUM(8'd16 + u[7:0])) u_uart (
            .pclk(pclk), .preset_n(preset_n),
            .psel_i(ext_psel[APB_WIN]), .penable_i(ext_penable),
            .pwrite_i(ext_pwrite), .paddr_i(ext_paddr), .pwdata_i(ext_pwdata),
            .prdata_o(uart_prdata[u]), .pready_o(uart_pready[u]),
            .pslverr_o(uart_pslverr[u]),
            .irq_o(uart_irq[u]), .dma_req_o(uart_dma_req[u]),
            .dma_ack_i(dma_ack[DMA_CHAN]),
            .uart_tx_o(uart_tx[u]), .uart_rx_i(uart_rx[u]));
    end endgenerate

    // =========================================================================
    // Block 19: GPIO (window 7) - two bidirectional pins
    // =========================================================================
    wire [WORD_W-1:0] gpio_prdata;
    wire gpio_pready;
    wire gpio_pslverr;
    wire gpio_irq;
    wire [GPIO_W-1:0] gpio_out;
    wire [GPIO_W-1:0] gpio_oe;
    wire [GPIO_W-1:0] gpio_in;

    assign gpio_in = gpio_i;

    garuda_gpio_top #(.BLOCK_NUM(8'd19), .PAD_NUM(2)) u_gpio (
        .pclk(pclk), .preset_n(preset_n),
        .psel_i(ext_psel[WIN_GPIO]), .penable_i(ext_penable),
        .pwrite_i(ext_pwrite), .paddr_i(ext_paddr), .pwdata_i(ext_pwdata),
        .prdata_o(gpio_prdata), .pready_o(gpio_pready),
            .pslverr_o(gpio_pslverr),
        .irq_o(gpio_irq),
        .gpio_i(gpio_in), .gpio_o(gpio_out), .gpio_oe(gpio_oe));

    // =========================================================================
    // Block 20: PWM (window 8) - four ESC outputs
    // =========================================================================
    wire [WORD_W-1:0] pwm_prdata;
    wire pwm_pready;
    wire pwm_pslverr;
    wire pwm_irq;
    wire [PWM_PINS_W-1:0]  pwm_pins;

    garuda_pwm_top #(.BLOCK_NUM(8'd20), .NUM_CHAN(4)) u_pwm (
        .pclk(pclk), .preset_n(preset_n),
        .psel_i(ext_psel[WIN_PWM]), .penable_i(ext_penable),
        .pwrite_i(ext_pwrite), .paddr_i(ext_paddr), .pwdata_i(ext_pwdata),
        .prdata_o(pwm_prdata), .pready_o(pwm_pready), .pslverr_o(pwm_pslverr),
        .irq_o(pwm_irq), .pwm_o(pwm_pins));

    // =========================================================================
    // Block 14: SPI slave (window 0) - the ESP32 / ESP-NOW companion link
    // =========================================================================
    wire [WORD_W-1:0] spis_prdata;
    wire spis_pready;
    wire spis_pslverr;
    wire spis_irq;
    wire spis_dma_req;
    wire spis_miso_d;
    wire spis_miso_oe;

    generate if (WITH_SPI_SLAVE) begin : g_spis
        garuda_spis_top #(.BLOCK_NUM(8'd14), .FIFO_DEPTH(16)) u_spis (
            .pclk(pclk), .preset_n(preset_n),
            .psel_i(ext_psel[WIN_SPI_SLAVE]), .penable_i(ext_penable),
            .pwrite_i(ext_pwrite), .paddr_i(ext_paddr), .pwdata_i(ext_pwdata),
            .prdata_o(spis_prdata), .pready_o(spis_pready),
            .pslverr_o(spis_pslverr),
            .irq_o(spis_irq), .dma_req_o(spis_dma_req),
                .dma_ack_i(dma_ack[DMA_CH_SPIS]),
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

    assign spis_miso_o    = spis_miso_d;
    assign spis_miso_oe_o = spis_miso_oe;

    // =========================================================================
    // APB expansion return path: window 0 = spi_slave, 1 = spi_master,
    // 3/4/6 = uart0/1/2,
    // window 9 = reset_ctrl;
    // every other external window has no IP yet (masked in the bridge, so an
    // access faults rather than hangs; answers SLVERR if unmasked).
    // =========================================================================
    wire [APB_NWIN*WORD_W-1:0] ext_prdata;
    wire [APB_NWIN-1:0] ext_pready;
    wire [APB_NWIN-1:0] ext_pslverr;
    genvar w;
    generate for (w = 0; w < 12; w = w + 1) begin : g_ext
        if (w == WIN_RESET_CTRL) begin : g_rst
            assign ext_prdata[32*w +: 32] = rst_prdata;
            assign ext_pready[w]          = rst_pready;
            assign ext_pslverr[w]         = rst_pslverr;
        end else if (w == 0) begin : g_spis_rt
            assign ext_prdata[32*w +: 32] = spis_prdata;
            assign ext_pready[w]          = spis_pready;
            assign ext_pslverr[w]         = spis_pslverr;
        end else if (w == WIN_SPI_MASTER) begin : g_spim
            assign ext_prdata[32*w +: 32] = spim_prdata;
            assign ext_pready[w]          = spim_pready;
            assign ext_pslverr[w]         = spim_pslverr;
        end else if (w == WIN_I2C) begin : g_i2c
            assign ext_prdata[32*w +: 32] = i2c_prdata;
            assign ext_pready[w]          = i2c_pready;
            assign ext_pslverr[w]         = i2c_pslverr;
        end else if (w == WIN_UART_ZERO) begin : g_uart0
            assign ext_prdata[32*w +: 32] = uart_prdata[0];
            assign ext_pready[w]          = uart_pready[0];
            assign ext_pslverr[w]         = uart_pslverr[0];
        end else if (w == WIN_UART_ONE) begin : g_uart1
            assign ext_prdata[32*w +: 32] = uart_prdata[1];
            assign ext_pready[w]          = uart_pready[1];
            assign ext_pslverr[w]         = uart_pslverr[1];
        end else if (w == WIN_UART_TWO) begin : g_uart2
            assign ext_prdata[32*w +: 32] = uart_prdata[2];
            assign ext_pready[w]          = uart_pready[2];
            assign ext_pslverr[w]         = uart_pslverr[2];
        end else if (w == WIN_GPIO) begin : g_gpio
            assign ext_prdata[32*w +: 32] = gpio_prdata;
            assign ext_pready[w]          = gpio_pready;
            assign ext_pslverr[w]         = gpio_pslverr;
        end else if (w == WIN_PWM) begin : g_pwm
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
    wire tdo_q;
    wire tdo_oe;

    // Peripheral interrupts (CLIC IDs 15..21) and DMA channels; one bit per
    // block, zero where the IP has not landed yet.
    //   periph_irq[0] = spi_master (CLIC 15)   dma_req[0] = spi_master
    //   periph_irq[2..4] = uart0/1/2 (17/18/19)  dma_req[2,3,5] = uart0/1/2
    //   periph_irq[5] = gpio (CLIC 20)   periph_irq[6] = pwm (CLIC 21)
    wire [PERIPH_IRQ_W-1:0] periph_irq = {pwm_irq, gpio_irq,
                             uart_irq[2], uart_irq[1], uart_irq[0],
                             i2c_irq, spim_irq};
    //   dma_req[4] = spi_slave (ADR-0020 Rev 2) - no longer tied low
    wire [5:0] dma_req    = {uart_dma_req[2], spis_dma_req,
                             uart_dma_req[1], uart_dma_req[0], i2c_dma_req,
                                 spim_dma_req};

    garuda_soc_top #(
        .BROM_INIT_FILE(BROM_INIT_FILE), .APB_WINDOW_MASK(APB_WINDOW_MASK),
        .APB_DIV(APB_DIV), .CORE_CLK_GATE(CORE_CLK_GATE)
    ) u_soc (
        .hclk(hclk), .pclk(pclk), .pclk_phase_i(pclk_phase),
        .hreset_n(hreset_n), .preset_n(preset_n), .core_rst_n(core_rst_n),
        .dm_rst_n(dm_rst_n), .ext_hrst_n(ext_hrst_n), .ext_rst_n(ext_rst_n),
        .wdt_rst_req_o(wdt_rst_req), .ndmreset_o(ndmreset),
            .hartreset_o(hartreset),
        .ilock_i(ilock),
        .tck(tck), .tms_i(tms), .tdi_i(tdi), .tdo_o(tdo_q), .tdo_oe_o(tdo_oe),
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
    assign tdo_o    = tdo_q;
    assign tdo_oe_o = tdo_oe;

    // spim_* are driven by u_spim above; the rest are deferred peripherals
    // still at safe idle.
    // I2C is open drain: the block only ever pulls a line low or releases it,
    // so these become pad OE controls with the output tied low at PD.
    assign i2c_scl_o = i2c_scl_out;
    assign i2c_scl_oe_o = i2c_scl_oe;
    assign i2c_sda_o = i2c_sda_out;
    assign i2c_sda_oe_o = i2c_sda_oe;
    assign pwm0 = pwm_pins[0];
    assign pwm1 = pwm_pins[1];
    assign pwm2 = pwm_pins[2];
    assign pwm3 = pwm_pins[3];

    // GPIO is bidirectional: driven when its direction bit says output,
    // released otherwise. Becomes a pad OE control at PD.
    assign gpio_o    = gpio_out;
    assign gpio_oe_o = gpio_oe;

endmodule

// =============================================================================
// garuda_chip_top: the pin-level model. It keeps the exact ports and behaviour
// of the previous garuda_chip_top, so every testbench still instantiates it
// unchanged. It adds only the tri-state / open-drain pin behaviour. For
// physical design these lines become pad cells, and the core-only flow
// synthesises garuda_chip_core.
// =============================================================================
module garuda_chip_top
    import garuda_pkg::*;
    import soc_map_pkg::*;
#(
    parameter         BROM_INIT_FILE = "",
    parameter integer         CORE_CLK_GATE  = 32'd1,
    parameter integer         WITH_SPI_SLAVE = 32'd1,
    parameter [23:0]  APB_DIV        = 24'h000000,
    parameter [15:0]  APB_WINDOW_MASK = (16'd1 << WIN_DMA)    |
                                        (16'd1 << WIN_RESET_CTRL) |
                                        (16'd1 << WIN_CLIC)   |
                                        (16'd1 << WIN_TIMERS) |
                                        (16'd1 << WIN_SPI_MASTER) |
                                        (16'd1 << WIN_UART_ZERO)      |
                                        (16'd1 << WIN_UART_ONE)      |
                                        (16'd1 << WIN_UART_TWO)      |
                                        (16'd1 << WIN_I2C)        |
                                        (16'd1 << WIN_GPIO)       |
                                        (16'd1 << WIN_PWM)        |
                                        (WITH_SPI_SLAVE
                                            ? (16'd1 << WIN_SPI_SLAVE) : 16'd0)
)(
    input wire refclk,
    input wire ext_rst_n,
    input wire tck,
    input wire tms,
    input wire tdi,
    output wire tdo,
    output wire spim_sclk,
    output wire spim_mosi,
    input wire spim_miso,
    output wire spim_cs_flash_n,
    output wire spim_cs_imu_n,
    inout wire i2c_scl,
    inout wire i2c_sda,
    input wire uart0_rx,
    output wire uart0_tx,
    input wire uart1_rx,
    output wire uart1_tx,
    input wire uart2_rx,
    output wire uart2_tx,
    output wire pwm0,
    output wire pwm1,
    output wire pwm2,
    output wire pwm3,
    inout wire gpio0,
    inout wire gpio1,
    input wire boot_sel,
    input wire spis_sclk,
    input wire spis_mosi,
    output wire spis_miso,
    input wire spis_cs_n
);
    timeunit 1ns;
    timeprecision 1ps;
    wire tdo_o;
    wire tdo_oe;
    wire scl_o;
    wire scl_oe;
    wire sda_o;
    wire sda_oe;
    wire miso_o;
    wire miso_oe;
    wire [GPIO_W-1:0] gpio_o;
    wire [GPIO_W-1:0] gpio_oe;

    garuda_chip_core #(
        .BROM_INIT_FILE(BROM_INIT_FILE), .CORE_CLK_GATE(CORE_CLK_GATE),
        .WITH_SPI_SLAVE(WITH_SPI_SLAVE), .APB_DIV(APB_DIV),
        .APB_WINDOW_MASK(APB_WINDOW_MASK)
    ) u_core (
        .refclk(refclk), .ext_rst_n(ext_rst_n),
        .tck(tck), .tms(tms), .tdi(tdi), .tdo_o(tdo_o), .tdo_oe_o(tdo_oe),
        .spim_sclk(spim_sclk), .spim_mosi(spim_mosi), .spim_miso(spim_miso),
        .spim_cs_flash_n(spim_cs_flash_n), .spim_cs_imu_n(spim_cs_imu_n),
        .i2c_scl_i(i2c_scl), .i2c_scl_o(scl_o), .i2c_scl_oe_o(scl_oe),
        .i2c_sda_i(i2c_sda), .i2c_sda_o(sda_o), .i2c_sda_oe_o(sda_oe),
        .uart0_rx(uart0_rx), .uart0_tx(uart0_tx),
        .uart1_rx(uart1_rx), .uart1_tx(uart1_tx),
        .uart2_rx(uart2_rx), .uart2_tx(uart2_tx),
        .pwm0(pwm0), .pwm1(pwm1), .pwm2(pwm2), .pwm3(pwm3),
        .gpio_i({gpio1, gpio0}), .gpio_o(gpio_o), .gpio_oe_o(gpio_oe),
        .boot_sel(boot_sel),
        .spis_sclk(spis_sclk), .spis_mosi(spis_mosi),
        .spis_miso_o(miso_o), .spis_miso_oe_o(miso_oe), .spis_cs_n(spis_cs_n));

    assign tdo       = tdo_oe     ? tdo_o     : 1'bz;
    assign i2c_scl   = scl_oe     ? scl_o     : 1'bz;
    assign i2c_sda   = sda_oe     ? sda_o     : 1'bz;
    assign gpio0     = gpio_oe[0] ? gpio_o[0] : 1'bz;
    assign gpio1     = gpio_oe[1] ? gpio_o[1] : 1'bz;
    assign spis_miso = miso_oe    ? miso_o    : 1'bz;
endmodule
