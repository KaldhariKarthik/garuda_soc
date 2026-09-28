`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA on KV260 - board top
// rtl/fpga/garuda_kv260_top.v
//
//   Zynq US+ PS (block design garuda_ps, built by fpga/kv260/build.tcl)
//     pl_clk0 100 MHz, pl_resetn0
//     M_AXI_HPM0_FPD -> AXI GPIO  @ 0xA000_0000  ch1 = ctrl (out), ch2 = stat (in)
//                    -> UartLite  @ 0xA001_0000  115200 8N1, GARUDA uart0 console
//   garuda_fpga_core (MMCM + unmodified garuda_chip_top)
//
// Pads (PMOD J2, 3.3 V): I2C and GPIO need real pull resistors, and PWM is
// scope-able. Everything else is looped or idled in fabric (see
// garuda_fpga_core). The fan is forced on.
// =============================================================================
module garuda_kv260_top #(
    parameter BROM_INIT_FILE = "",
    parameter CORE_CLK_GATE  = 1
)(
    inout  wire i2c_scl,     // PMOD J2.1  PULLUP
    inout  wire i2c_sda,     // PMOD J2.2  PULLUP
    inout  wire gpio0,       // PMOD J2.3  PULLDOWN
    inout  wire gpio1,       // PMOD J2.4  PULLDOWN
    output wire pwm0,        // PMOD J2.7
    output wire pwm1,        // PMOD J2.8
    output wire pwm2,        // PMOD J2.9
    output wire pwm3,        // PMOD J2.10
    output wire fan_en_b     // KV260 fan, active low
);
    wire        pl_clk0, pl_resetn0;
    wire [31:0] ctrl, stat;
    wire        uart_txd, uart_rxd;

    garuda_ps_wrapper u_ps (
        .pl_clk0   (pl_clk0),
        .pl_resetn0(pl_resetn0),
        .ctrl_o    (ctrl),
        .stat_i    (stat),
        .uart_txd  (uart_txd),     // UartLite TX -> GARUDA uart0 RX
        .uart_rxd  (uart_rxd));    // GARUDA uart0 TX -> UartLite RX

    garuda_fpga_core #(
        .BROM_INIT_FILE(BROM_INIT_FILE),
        .CORE_CLK_GATE (CORE_CLK_GATE),
        .WITH_SPI_SLAVE(1)
    ) u_core (
        .clk_100_i(pl_clk0), .rst_100_n_i(pl_resetn0),
        .ctrl_i(ctrl), .stat_o(stat),
        .host_uart_txd_i(uart_txd), .host_uart_rxd_o(uart_rxd),
        .i2c_scl(i2c_scl), .i2c_sda(i2c_sda), .gpio0(gpio0), .gpio1(gpio1),
        .pwm0(pwm0), .pwm1(pwm1), .pwm2(pwm2), .pwm3(pwm3));

    assign fan_en_b = 1'b0;
endmodule

`default_nettype wire
