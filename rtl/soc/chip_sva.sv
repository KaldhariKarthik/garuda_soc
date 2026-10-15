`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - chip : properties of the wiring between the blocks
// chip_sva.sv
//
// The maps are written here from the specs, as literals, NOT from the RTL's macros:
// GARUDA-TRM-001 / CLIC [N-6.3] (the interrupt IDs), DMA [N-6.4] (the channels),
// CLKRST section 7 (reset order). A property that reused the RTL's own `define
// would agree with the RTL whatever the map said.
// Bound to garuda_chip_core; runs in every chip program.
// Not for synthesis, not under Icarus (TOOL-B2).
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module chip_sva (
    input wire        hclk, hreset_n, preset_n, core_rst_n, dm_rst_n, ext_rst_n,
    input wire [31:0] clic_src,
    input wire [5:0]  dma_complete, dma_error,
    input wire        wdt_warn,
    input wire        spim_irq, i2c_irq, gpio_irq, pwm_irq, spis_irq,
    input wire [2:0]  uart_irq,
    // the DMA's request and acknowledge ports, and each peripheral's own
    input wire [5:0]  dmac_req, dmac_ack,
    input wire        spim_req, i2c_req, uart0_req, uart1_req, uart2_req, spis_req,
    input wire        spim_ack, i2c_ack, uart0_ack, uart1_ack, uart2_ack, spis_ack
);
    // ---- the interrupt map (TRM section 4, CLIC [N-6.3]) --------------------------------
    // ID 0 sentinel, 1-6 DMA complete ch0-5, 7 reserved (mcause 0x8000_0007 is the timer),
    // 8-13 DMA error ch0-5, 14 SPI slave, 15 SPI master, 16 I2C, 17-19 UART0-2, 20 GPIO,
    // 21 PWM, 22 watchdog warning, 23-31 none.
    wire [31:0] spec_map = {9'd0, wdt_warn, pwm_irq, gpio_irq, uart_irq[2], uart_irq[1], uart_irq[0],
                            i2c_irq, spim_irq, spis_irq, dma_error, 1'b0, dma_complete, 1'b0};
    a_irq_map: assert property (@(posedge hclk) disable iff (!hreset_n) clic_src == spec_map )
        else $error("[SVA-FAIL] a_irq_map: CLIC input %h, the map says %h", clic_src, spec_map);

    // ---- the DMA channel map (DMA [N-6.4]): 0 SPI master (IMU), 1 I2C, 2 UART0, 3 UART1,
    //      4 SPI slave, 5 UART2 ------------------------------------------------------------------
    a_dma_req_map: assert property (@(posedge hclk) disable iff (!hreset_n)
        dmac_req == {uart2_req, spis_req, uart1_req, uart0_req, i2c_req, spim_req} )
        else $error("[SVA-FAIL] a_dma_req_map: a peripheral's DMA request reaches the wrong channel");
    a_dma_ack_map: assert property (@(posedge hclk) disable iff (!hreset_n)
        {uart2_ack, spis_ack, uart1_ack, uart0_ack, i2c_ack, spim_ack} == dmac_ack )
        else $error("[SVA-FAIL] a_dma_ack_map: a DMA acknowledge reaches the wrong peripheral");

    // ---- reset order (CLKRST section 7): nothing below the bus runs while the bus is in reset ----
    a_rst_core_under_bus: assert property (@(posedge hclk) !hreset_n |-> !core_rst_n )
        else $error("[SVA-FAIL] a_rst_core_under_bus: the core out of reset while the bus is in reset");
    a_rst_apb_under_bus: assert property (@(posedge hclk) !hreset_n |-> !preset_n )
        else $error("[SVA-FAIL] a_rst_apb_under_bus: the APB out of reset while the bus is in reset");
    a_rst_pin_reaches_all: assert property (@(posedge hclk) !ext_rst_n |=> ##[0:8] (!hreset_n && !preset_n && !core_rst_n && !dm_rst_n) )
        else $error("[SVA-FAIL] a_rst_pin_reaches_all: the reset pin did not reset every domain");

    c_every_dma_ch: cover property (@(posedge hclk) dmac_ack == 6'b100000);
    c_wdt_warn:     cover property (@(posedge hclk) $rose(wdt_warn));
    c_core_reset_alone: cover property (@(posedge hclk) hreset_n && !core_rst_n);
endmodule

bind garuda_chip_core chip_sva u_chip_sva (
    .hclk(hclk), .hreset_n(hreset_n), .preset_n(preset_n), .core_rst_n(core_rst_n), .dm_rst_n(dm_rst_n),
    .ext_rst_n(u_reset_ctrl.ext_rst_n_i),
    .clic_src(u_soc.irq_src), .dma_complete(u_soc.dma_complete), .dma_error(u_soc.dma_error),
    .wdt_warn(u_soc.wdt_warn),
    .spim_irq(spim_irq), .i2c_irq(i2c_irq), .gpio_irq(gpio_irq), .pwm_irq(pwm_irq), .spis_irq(spis_irq),
    .uart_irq(uart_irq),
    .dmac_req(u_soc.u_dma.dma_req_i), .dmac_ack(u_soc.u_dma.dma_ack_o),
    .spim_req(u_spim.dma_req_o), .i2c_req(u_i2c.dma_req_o),
    .uart0_req(g_uart[0].u_uart.dma_req_o), .uart1_req(g_uart[1].u_uart.dma_req_o), .uart2_req(g_uart[2].u_uart.dma_req_o),
    .spis_req(g_spis.u_spis.dma_req_o),
    .spim_ack(u_spim.dma_ack_i), .i2c_ack(u_i2c.dma_ack_i),
    .uart0_ack(g_uart[0].u_uart.dma_ack_i), .uart1_ack(g_uart[1].u_uart.dma_ack_i), .uart2_ack(g_uart[2].u_uart.dma_ack_i),
    .spis_ack(g_spis.u_spis.dma_ack_i));
`endif
`endif
