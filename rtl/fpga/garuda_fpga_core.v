`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA on KV260 - board-independent FPGA core
// rtl/fpga/garuda_fpga_core.v
//
// garuda_chip_top, unmodified, plus what the board needs around it:
//   * MMCM: 100 MHz pl_clk0 -> hclk-rate refclk for clk_div_fpga
//   * host control: one 32-bit output word and one 32-bit input word. On the
//     board they are AXI GPIO channels 1/2, driven from Linux on the A53. In
//     simulation the testbench drives them directly.
//   * board substitutes for the things tb_chip puts on the pins
//
// Everything with a pull resistor on the real board goes to a real pad
// (I2C, GPIO) so the pad's PULLUP/PULLDOWN supplies it. An internal 'z'
// has no defined value in an FPGA. Everything else is looped back or idled
// in fabric, the same way tb_chip does it.
//
// ctrl_i (host -> chip)                 stat_o (chip -> host)
//   [0] tck                               [0]  tdo
//   [1] tms                               [1]  MMCM locked
//   [2] tdi                               [2]  hclk heartbeat (hclk / 2^21)
//   [3] ext_rst_n  (1 = run)              [3]  uart0_tx
//   [4] boot_sel                          [7:4] pwm3..0
//   [5] uart0 loopback (1 = tx->rx,       [9:8] gpio1..0 pad levels
//       0 = rx from the host UART)        [10] i2c_scl pad level
//                                         [11] i2c_sda pad level
//                                         [31:16] 0x6A5D signature
// =============================================================================
module garuda_fpga_core #(
    parameter        BROM_INIT_FILE = "",
    parameter        CORE_CLK_GATE  = 1,
    parameter        WITH_SPI_SLAVE = 1,
    // MMCM: VCO = 100 MHz * MULT / DIVCLK, must be 800..1600 MHz (ZU+ -2LV).
    // hclk = VCO / OUT_DIV.  Default: 1200 / 24 = 50 MHz, pclk 25 MHz.
    parameter real   MMCM_MULT      = 12.0,
    parameter real   MMCM_OUT_DIV   = 24.0
)(
    input  wire        clk_100_i,          // PS pl_clk0
    input  wire        rst_100_n_i,        // PS pl_resetn0
    input  wire [31:0] ctrl_i,
    output wire [31:0] stat_o,
    input  wire        host_uart_txd_i,    // host UART TX -> GARUDA uart0 RX
    output wire        host_uart_rxd_o,    // GARUDA uart0 TX -> host UART RX
    // real pads
    inout  wire        i2c_scl,
    inout  wire        i2c_sda,
    inout  wire        gpio0,
    inout  wire        gpio1,
    output wire        pwm0,
    output wire        pwm1,
    output wire        pwm2,
    output wire        pwm3
);
    // =========================================================================
    // Clocking
    // =========================================================================
    wire clkfb, refclk_raw, locked;

    MMCME4_BASE #(
        .CLKIN1_PERIOD   (10.0),
        .DIVCLK_DIVIDE   (1),
        .CLKFBOUT_MULT_F (MMCM_MULT),
        .CLKOUT0_DIVIDE_F(MMCM_OUT_DIV)
    ) u_mmcm (
        .CLKIN1(clk_100_i), .CLKFBIN(clkfb), .CLKFBOUT(clkfb), .CLKFBOUTB(),
        .CLKOUT0(refclk_raw), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(),
        .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .LOCKED(locked), .PWRDWN(1'b0), .RST(~rst_100_n_i));

    // TCK: a bit in the AXI GPIO register, promoted to a global clock.
    // Constrained as its own async clock in the XDC. The host toggles TMS/TDI
    // and TCK in separate register writes, so data is always stable at the
    // TCK edge.
    wire tck;
    wire tck_src = ctrl_i[0];
    BUFG u_bufg_tck (.I(tck_src), .O(tck));

    // =========================================================================
    // Pin substitutes
    // =========================================================================
    wire ext_rst_n = ctrl_i[3] & locked & rst_100_n_i;
    wire boot_sel  = ctrl_i[4];
    wire u0_lb     = ctrl_i[5];

    wire tdo;
    wire uart0_tx, uart1_tx, uart2_tx;
    wire spim_sclk, spim_mosi, spim_cs_flash_n, spim_cs_imu_n;
    wire spis_miso;

    // UARTs: each tx looped to its own rx, as tb_chip does. uart0 can take its
    // rx from the host UART instead, which makes it a console.
    wire uart0_rx = u0_lb ? uart0_tx : host_uart_txd_i;
    assign host_uart_rxd_o = uart0_tx;

    // SPI master: MOSI looped to MISO. There is no flash on the board yet.
    // Flash boot (t_chip_flash) needs a real SPI flash on the RPi header.
    wire spim_miso = spim_mosi;

    garuda_chip_top #(
        .BROM_INIT_FILE(BROM_INIT_FILE),
        .CORE_CLK_GATE (CORE_CLK_GATE),
        .WITH_SPI_SLAVE(WITH_SPI_SLAVE)
    ) u_chip (
        .refclk(refclk_raw), .ext_rst_n(ext_rst_n),
        .tck(tck), .tms(ctrl_i[1]), .tdi(ctrl_i[2]), .tdo(tdo),
        .spim_sclk(spim_sclk), .spim_mosi(spim_mosi), .spim_miso(spim_miso),
        .spim_cs_flash_n(spim_cs_flash_n), .spim_cs_imu_n(spim_cs_imu_n),
        .i2c_scl(i2c_scl), .i2c_sda(i2c_sda),
        .uart0_rx(uart0_rx), .uart0_tx(uart0_tx),
        .uart1_rx(uart1_tx), .uart1_tx(uart1_tx),
        .uart2_rx(uart2_tx), .uart2_tx(uart2_tx),
        .pwm0(pwm0), .pwm1(pwm1), .pwm2(pwm2), .pwm3(pwm3),
        .gpio0(gpio0), .gpio1(gpio1), .boot_sel(boot_sel),
        // block 14: no ESP32 on the board -> bus idle (CS high, SCLK low)
        .spis_sclk(1'b0), .spis_mosi(1'b0), .spis_miso(spis_miso), .spis_cs_n(1'b1));

    // =========================================================================
    // Heartbeat: proves hclk runs, without JTAG
    // =========================================================================
    // Own BUFG off the same MMCM output (no hierarchical reference into the
    // chip, which synthesis does not accept).
    wire hb_clk;
    BUFG u_bufg_hb (.I(refclk_raw), .O(hb_clk));
    reg [21:0] hb = 22'd0;
    always @(posedge hb_clk) hb <= hb + 22'd1;

    assign stat_o = {16'h6A5D, 4'd0,
                     i2c_sda, i2c_scl, gpio1, gpio0,
                     pwm3, pwm2, pwm1, pwm0,
                     uart0_tx, hb[21], locked, tdo};

    wire _unused = &{1'b0, spim_sclk, spim_cs_flash_n, spim_cs_imu_n, spis_miso};
endmodule

`default_nettype wire
