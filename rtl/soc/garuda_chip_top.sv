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
    parameter bit             WITH_SPI_SLAVE = 1'b1,
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
    wire scl_oe;
    wire sda_oe;
    wire miso_o;
    wire miso_oe;
    wire [GPIO_W-1:0] gpio_o;
    wire [GPIO_W-1:0] gpio_oe;

    wire [1:0] gpio_in = {gpio1, gpio0};  // the GPIO pads' input side

    garuda_chip_core #(
        .BROM_INIT_FILE(BROM_INIT_FILE), .CORE_CLK_GATE(CORE_CLK_GATE),
        .WITH_SPI_SLAVE(WITH_SPI_SLAVE), .APB_DIV(APB_DIV),
        .APB_WINDOW_MASK(APB_WINDOW_MASK)
    ) u_core (
        .refclk(refclk), .ext_rst_n(ext_rst_n),
        .tck(tck), .tms(tms), .tdi(tdi), .tdo_o(tdo_o), .tdo_oe_o(tdo_oe),
        .spim_sclk(spim_sclk), .spim_mosi(spim_mosi), .spim_miso(spim_miso),
        .spim_cs_flash_n(spim_cs_flash_n), .spim_cs_imu_n(spim_cs_imu_n),
        .i2c_scl_i(i2c_scl), .i2c_scl_oe_o(scl_oe),
        .i2c_sda_i(i2c_sda), .i2c_sda_oe_o(sda_oe),
        .uart0_rx(uart0_rx), .uart0_tx(uart0_tx),
        .uart1_rx(uart1_rx), .uart1_tx(uart1_tx),
        .uart2_rx(uart2_rx), .uart2_tx(uart2_tx),
        .pwm0(pwm0), .pwm1(pwm1), .pwm2(pwm2), .pwm3(pwm3),
        .gpio_i(gpio_in), .gpio_o(gpio_o), .gpio_oe_o(gpio_oe),
        .boot_sel(boot_sel),
        .spis_sclk(spis_sclk), .spis_mosi(spis_mosi),
        .spis_miso_o(miso_o), .spis_miso_oe_o(miso_oe), .spis_cs_n(spis_cs_n));

    assign tdo       = tdo_oe     ? tdo_o     : 1'bz;
    // I2C is open drain: 0 when enabled, released otherwise
    assign i2c_scl   = scl_oe     ? 1'b0      : 1'bz;
    assign i2c_sda   = sda_oe     ? 1'b0      : 1'bz;
    assign gpio0     = gpio_oe[0] ? gpio_o[0] : 1'bz;
    assign gpio1     = gpio_oe[1] ? gpio_o[1] : 1'bz;
    assign spis_miso = miso_oe    ? miso_o    : 1'bz;
endmodule
