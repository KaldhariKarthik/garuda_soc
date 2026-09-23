`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 19 : GPIO (2 pins)
// garuda_gpio_top.v - GARUDA wrapper around pulp-platform/apb_gpio
//
// Spec: GARUDA-GPIO-SPEC-001 Rev 1.0; rulings D-17, D-21, D-22, D-23.
//
// The closest thing to a drop-in of the four vendored IPs: already word
// addressed (s_apb_addr = PADDR[6:2]), PREADY tied high, PSLVERR tied low. Two
// things the wrapper still has to do:
//
//   1. Make the interrupt HELD. Upstream's `interrupt` is cleared by READING
//      INTSTATUS, and the CLIC needs a level that only firmware drops (D-17).
//      It goes into the shim's sticky IRQSTAT[0] instead.
//
//   2. NOT poll a status register. The SPI and UART wrappers read a status
//      register in the window's idle cycles to recover FIFO occupancy. Doing
//      that here would read INTSTATUS every idle cycle and silently eat every
//      interrupt before firmware ever saw it. GPIO has no FIFO and no DMA, so
//      there is nothing to poll for, and this wrapper deliberately does none
//      ([N-7.3a]). Worth stating, because "do what the last wrapper did" is
//      exactly how that bug would arrive.
// =============================================================================

module garuda_gpio_top #(
    parameter [7:0]   BLOCK_NUM = 8'd19,
    parameter integer PAD_NUM   = 2
)(
    input  wire        pclk_i,
    input  wire        preset_n_i,

    // ---- APB slave, window 7 -------------------------------------------------
    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [11:0] paddr_i,
    input  wire [31:0] pwdata_i,
    output wire [31:0] prdata_o,
    output wire        pready_o,
    output wire        pslverr_o,

    // ---- CLIC ID 20 (no DMA channel - see [N-13.2]) --------------------------
    output wire        irq_o,

    // ---- pins ------------------------------------------------------------------
    input  wire [PAD_NUM-1:0] gpio_i,
    output wire [PAD_NUM-1:0] gpio_o,
    output wire [PAD_NUM-1:0] gpio_oe
);

    localparam [11:0] IP_LIMIT = 12'h080;   // the vendored register file

    wire        ip_psel, ip_penable, ip_pwrite;
    wire [11:0] ip_paddr;
    wire [31:0] ip_pwdata, ip_prdata;
    wire        ip_pready;
    wire [1:0]  dmactl;
    wire [PAD_NUM-1:0] gpio_sync;
    wire        gpio_int;

    // The IP's interrupt is a read-to-clear pulse-ish level; the shim holds it.
    wire [0:0] evt;
    assign evt[0] = gpio_int;

    garuda_apb_shim #(
        .N_EVT(1), .SYNC_W(PAD_NUM), .SYNC_RESET(8'h00), .IP_LIMIT(IP_LIMIT),
        .ADDR_SHIFT(0), .BLOCK_NUM(BLOCK_NUM), .BLOCK_REV(8'd1)
    ) u_shim (
        .pclk_i(pclk_i), .preset_n_i(preset_n_i),
        .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i),
        .paddr_i(paddr_i), .pwdata_i(pwdata_i), .prdata_o(prdata_o),
        .pready_o(pready_o), .pslverr_o(pslverr_o),
        .ip_psel_o(ip_psel), .ip_penable_o(ip_penable), .ip_pwrite_o(ip_pwrite),
        .ip_paddr_o(ip_paddr), .ip_pwdata_o(ip_pwdata), .ip_prdata_i(ip_prdata),
        .ip_pready_i(ip_pready),
        .evt_i(evt), .irq_o(irq_o),
        .rx_avail_i(1'b0), .tx_space_i(1'b0),          // no DMA channel
        .dma_ack_i(1'b0), .dma_req_o(), .dmactl_o(dmactl),
        .pad_async_i(gpio_i), .pad_sync_o(gpio_sync));

    // =========================================================================
    // The vendored GPIO. No idle-cycle poll: ip_psel passes straight through,
    // so INTSTATUS is only ever read when firmware reads it.
    // =========================================================================
    wire [PAD_NUM-1:0] gpio_dir;
    wire [PAD_NUM*4-1:0] padcfg_unused;

    apb_gpio #(
        .APB_ADDR_WIDTH(12), .PAD_NUM(PAD_NUM), .NBIT_PADCFG(4)
    ) u_gpio (
        .HCLK(pclk_i), .HRESETn(preset_n_i),
        .dft_cg_enable_i(1'b0),                        // OPEN-G1: DFT must drive this
        .PADDR(ip_paddr), .PWDATA(ip_pwdata), .PWRITE(ip_pwrite),
        .PSEL(ip_psel), .PENABLE(ip_penable),
        .PRDATA(ip_prdata), .PREADY(ip_pready), .PSLVERR(),
        .gpio_in(gpio_sync), .gpio_in_sync(),
        .gpio_out(gpio_o), .gpio_dir(gpio_dir),
        .gpio_padcfg(padcfg_unused),
        .interrupt(gpio_int));

    // PADDIR[n] = 1 means "output", which is the pad's output enable.
    assign gpio_oe = gpio_dir;

    wire _unused = |{dmactl, padcfg_unused};

endmodule

`default_nettype wire
