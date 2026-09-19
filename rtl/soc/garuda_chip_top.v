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
// DEFERRED PERIPHERALS (spi_master, i2c, uart0/1/2, gpio, pwm - sourced IP):
// their pins exist, driven to the SAFE IDLE state below, and their APB
// windows are masked in the bridge so an access faults rather than hangs.
// When an IP lands: instantiate it here on apb_ext_* window n, connect its
// pins, IRQ (periph_irq[k]) and DMA request/ack, and add bit n to
// APB_WINDOW_MASK. Nothing else in the chip changes.
//
//   window  block        IRQ (CLIC)          DMA ch   pins
//   1       spi_master   periph_irq[0] (15)  0        spim_*
//   2       i2c          periph_irq[1] (16)  1        i2c_scl, i2c_sda
//   3       uart0        periph_irq[2] (17)  2        uart0_rx/tx
//   4       uart1        periph_irq[3] (18)  3        uart1_rx/tx
//   6       uart2        periph_irq[4] (19)  5        uart2_rx/tx
//   7       gpio         periph_irq[5] (20)  -        gpio0..1
//   8       pwm          periph_irq[6] (21)  -        pwm0..3
//
// Safe idle: PWM low (ESCs see no pulse - motors off), SPI chip selects high,
// SCLK/MOSI low, UART TX high (line idle), I2C released (board pull-ups),
// GPIO released (input). JTAG TDO is tri-stated outside Shift-IR/DR.
// =============================================================================
`include "garuda_map.vh"

module garuda_chip_top #(
    parameter         BROM_INIT_FILE = "",
    parameter         CORE_CLK_GATE  = 1,
    parameter [15:0]  APB_WINDOW_MASK = (16'd1 << `GARUDA_APB_WIN_DMA_CFG)    |
                                        (16'd1 << `GARUDA_APB_WIN_RESET_CTRL) |
                                        (16'd1 << `GARUDA_APB_WIN_CLIC_CFG)   |
                                        (16'd1 << `GARUDA_APB_WIN_TIMERS_CFG)
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
    input  wire boot_sel             // 26  pull-down at the pad
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
    // APB expansion return path: window 9 = reset_ctrl, every other external
    // window has no IP yet (masked in the bridge; answers SLVERR if unmasked).
    // =========================================================================
    wire [12*32-1:0] ext_prdata;
    wire [11:0]      ext_pready, ext_pslverr;
    genvar w;
    generate for (w = 0; w < 12; w = w + 1) begin : g_ext
        if (w == `GARUDA_APB_WIN_RESET_CTRL) begin : g_rst
            assign ext_prdata[32*w +: 32] = rst_prdata;
            assign ext_pready[w]          = rst_pready;
            assign ext_pslverr[w]         = rst_pslverr;
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
    wire [5:0] dma_ack;

    garuda_soc_top #(
        .BROM_INIT_FILE(BROM_INIT_FILE), .APB_WINDOW_MASK(APB_WINDOW_MASK),
        .CORE_CLK_GATE(CORE_CLK_GATE)
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
        .periph_irq_i(7'd0), .dma_req_i(6'd0), .dma_ack_o(dma_ack),
        .core_sleep_o());

    // =========================================================================
    // Pins
    // =========================================================================
    assign tdo = tdo_oe ? tdo_q : 1'bz;

    // deferred peripherals: safe idle
    assign spim_sclk       = 1'b0;
    assign spim_mosi       = 1'b0;
    assign spim_cs_flash_n = 1'b1;
    assign spim_cs_imu_n   = 1'b1;
    assign i2c_scl         = 1'bz;
    assign i2c_sda         = 1'bz;
    assign uart0_tx        = 1'b1;
    assign uart1_tx        = 1'b1;
    assign uart2_tx        = 1'b1;
    assign pwm0            = 1'b0;
    assign pwm1            = 1'b0;
    assign pwm2            = 1'b0;
    assign pwm3            = 1'b0;
    assign gpio0           = 1'bz;
    assign gpio1           = 1'bz;

    wire _unused = |{spim_miso, uart0_rx, uart1_rx, uart2_rx, i2c_scl, i2c_sda,
                     gpio0, gpio1, dma_ack};

endmodule

`default_nettype wire
