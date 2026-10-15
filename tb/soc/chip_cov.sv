`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - chip : functional coverage of what passes between the blocks
// chip_cov.sv
//
// From GARUDA-SYS-001 / the TRM: the interrupt map, the DMA handshakes, the
// resets and their causes, the clock ratio, sleep, the pads. Bound to
// garuda_chip_core, so it samples in every chip program (tb_chip).
// The blocks' own behaviour is covered by their own covergroups; this is only
// "did every wire between two blocks carry its event at least once".
// Not for synthesis, not under Icarus or Verilator.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
`ifndef VERILATOR
module chip_cov (
    input wire        hclk, hreset_n, aon_clk,
    input wire [31:0] irq_src,
    input wire [5:0]  dma_req, dma_ack,
    input wire        wdt_rst_req, ndmreset, hartreset, core_rst_n, ilock, core_sleep,
    input wire [3:0]  reason,
    input wire [1:0]  div_act,
    input wire        div_busy,
    input wire [1:0]  gpio_oe,
    input wire        scl_oe, sda_oe, tdo_oe
);
    // every interrupt source of the map raised at least once (rising edge on its line)
    reg [31:0] irq_d = 32'd0;
    always @(posedge hclk) irq_d <= irq_src;
    wire [31:0] irq_rise = irq_src & ~irq_d;
    covergroup cg_irq_lines @(posedge hclk iff (hreset_n && (|irq_rise)));
        option.per_instance = 1;
        cp_dma_done:  coverpoint irq_rise[6:1]   { bins ch[] = {6'b000001, 6'b000010, 6'b000100, 6'b001000, 6'b010000, 6'b100000}; }
        cp_dma_error: coverpoint irq_rise[13:8]  { bins ch[] = {6'b000001, 6'b000010, 6'b000100, 6'b001000, 6'b010000, 6'b100000}; }
        cp_spis:      coverpoint irq_rise[14];
        cp_periph:    coverpoint irq_rise[21:15] { bins spim = {7'b0000001}; bins i2c = {7'b0000010}; bins uart0 = {7'b0000100};
                                                   bins uart1 = {7'b0001000}; bins uart2 = {7'b0010000}; bins gpio = {7'b0100000}; bins pwm = {7'b1000000}; }
        cp_wdt_warn:  coverpoint irq_rise[22];
    endgroup
    // every DMA channel's request answered by its acknowledge
    covergroup cg_dma @(posedge hclk iff (hreset_n && (|dma_ack)));
        option.per_instance = 1;
        cp_ack: coverpoint dma_ack { bins ch[] = {6'b000001, 6'b000010, 6'b000100, 6'b001000, 6'b010000, 6'b100000}; }
        cp_req_still_high: coverpoint |(dma_req & dma_ack);
    endgroup
    // resets: every cause, as the reset controller records it
    reg [3:0] reason_d = 4'd0;
    always @(posedge aon_clk) reason_d <= reason;
    covergroup cg_reset @(posedge aon_clk iff (reason != reason_d));
        option.per_instance = 1;
        cp_cause: coverpoint reason { bins ext = {4'b0001}; bins wdt = {4'b0010}; bins ndm = {4'b0100}; bins sw = {4'b1000}; bins cleared = {4'b0000}; }
    endgroup
    covergroup cg_misc @(posedge hclk iff hreset_n);
        option.per_instance = 1;
        cp_hartreset: coverpoint hartreset;
        cp_ilock: coverpoint ilock;
        cp_sleep: coverpoint core_sleep;
        cp_ratio: coverpoint div_act { bins div2 = {0}; bins div4 = {1}; bins div8 = {2}; bins div16 = {3}; }
        cp_ratio_change: coverpoint div_busy;
        cp_gpio_out: coverpoint gpio_oe;
        cp_i2c_drive: coverpoint {scl_oe, sda_oe};
        cp_tdo: coverpoint tdo_oe;
    endgroup
    cg_irq_lines ci = new(); cg_dma cd = new(); cg_reset cr = new(); cg_misc cm = new();
endmodule

bind garuda_chip_core chip_cov u_chip_cov (
    .hclk(hclk), .hreset_n(hreset_n), .aon_clk(aon_clk),
    .irq_src(u_soc.irq_src), .dma_req(dma_req), .dma_ack(dma_ack),
    .wdt_rst_req(wdt_rst_req), .ndmreset(ndmreset), .hartreset(hartreset), .core_rst_n(core_rst_n),
    .ilock(ilock), .core_sleep(u_soc.core_sleep_o), .reason(u_reset_ctrl.reason_q),
    .div_act(div_act), .div_busy(div_busy), .gpio_oe(gpio_oe_o), .scl_oe(i2c_scl_oe_o), .sda_oe(i2c_sda_oe_o), .tdo_oe(tdo_oe_o));
`endif
`endif
`endif
