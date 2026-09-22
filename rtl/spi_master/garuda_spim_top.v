`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 13 : SPI master (boot flash + IMU)
// garuda_spim_top.v - GARUDA wrapper around pulp-platform/apb_spi_master
//
// Spec: GARUDA-SPIM-SPEC-001 Rev 1.0; rulings D-21 (peripheral contract),
//       D-22 (vendored IP is never edited - every GARUDA-specific behaviour
//       below lives here, not upstream).
//
// The vendored engine already does the hard part: a command / address / dummy /
// data length model that is exactly a flash read, with the chip select held for
// the whole transfer (SPIM [N-6.3]) and PREADY tied high. This wrapper adds
// what GARUDA's fabric requires:
//
//   - the window decode, PSLVERR and register tail (garuda_apb_shim)
//   - sticky level interrupts: upstream events_o is a PULSE (D-17)
//   - a DMA request that drops after every ack (D-21) and is driven from the
//     engine's own RX/TX FIFO occupancy, read out of the STATUS word
//   - a two-flop synchroniser on miso, which is asynchronous to pclk
//   - chip-select mapping: upstream has four, GARUDA has two pins
//   - single-bit mode: sdo1..3 / sdi1..3 are not brought out (no pins)
//
// STATUS (offset 0x00) read layout, from the vendored register file:
//   [0] engine idle   [20:16] RX FIFO words   [28:24] TX FIFO words
// =============================================================================

module garuda_spim_top #(
    parameter integer BUFFER_DEPTH = 10,
    parameter [7:0]   BLOCK_NUM    = 8'd13
)(
    input  wire        pclk_i,
    input  wire        preset_n_i,

    // ---- APB slave, window 1 -------------------------------------------------
    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [11:0] paddr_i,
    input  wire [31:0] pwdata_i,
    output wire [31:0] prdata_o,
    output wire        pready_o,
    output wire        pslverr_o,

    // ---- CLIC ID 15 / DMA channel 0 ------------------------------------------
    output wire        irq_o,
    output wire        dma_req_o,
    input  wire        dma_ack_i,

    // ---- pins ------------------------------------------------------------------
    output wire        spim_sclk_o,
    output wire        spim_mosi_o,
    input  wire        spim_miso_i,
    output wire        spim_cs_flash_n_o,
    output wire        spim_cs_imu_n_o
);

    // =========================================================================
    // Shim: decode, tail registers, sticky IRQ, DMA hold-off, miso sync
    // =========================================================================
    wire        ip_psel, ip_penable, ip_pwrite;
    wire [11:0] ip_paddr;
    wire [31:0] ip_pwdata, ip_prdata;
    wire        ip_pready;
    wire [2:0]  evt;
    wire        miso_sync;
    wire [1:0]  dmactl;

    // =========================================================================
    // FIFO occupancy without touching the IP (D-22)
    // -------------------------------------------------------------------------
    // The DMA request needs a LEVEL ("the RX FIFO has a word"), but upstream
    // only exposes events_o, which is a pulse from a threshold FSM: with the
    // FIFO still non-empty it does not fire again, so a level cannot be built
    // from it. The occupancy lives in the engine's STATUS register, which is a
    // pure read mux with no side effect (unlike INTSTA, whose read clears).
    //
    // So the wrapper - which is the only APB master into the IP - reads STATUS
    // in the cycles when the SoC is not accessing this window. No upstream
    // change, no hierarchical reference, and the occupancy is never more than
    // one pclk stale.
    // =========================================================================
    wire poll = ~psel_i;                       // window idle: our cycle to use

    reg [31:0] status_q;
    always @(posedge pclk_i or negedge preset_n_i)
        if (!preset_n_i)  status_q <= 32'd0;
        else if (poll)    status_q <= ip_prdata;

    wire [4:0] rx_words = status_q[20:16];
    wire [4:0] tx_words = status_q[28:24];

    garuda_apb_shim #(
        .N_EVT(3), .SYNC_W(1), .IP_LIMIT(12'h100), .ADDR_SHIFT(0),
        .BLOCK_NUM(BLOCK_NUM), .BLOCK_REV(8'd1)
    ) u_shim (
        .pclk_i(pclk_i), .preset_n_i(preset_n_i),
        .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i),
        .paddr_i(paddr_i), .pwdata_i(pwdata_i), .prdata_o(prdata_o),
        .pready_o(pready_o), .pslverr_o(pslverr_o),
        .ip_psel_o(ip_psel), .ip_penable_o(ip_penable), .ip_pwrite_o(ip_pwrite),
        .ip_paddr_o(ip_paddr), .ip_pwdata_o(ip_pwdata), .ip_prdata_i(ip_prdata),
        .ip_pready_i(ip_pready),
        .evt_i(evt), .irq_o(irq_o),
        .rx_avail_i(|rx_words),
        .tx_space_i(tx_words < BUFFER_DEPTH[4:0]),
        .dma_ack_i(dma_ack_i), .dma_req_o(dma_req_o), .dmactl_o(dmactl),
        .pad_async_i(spim_miso_i), .pad_sync_o(miso_sync));

    // =========================================================================
    // Interrupt sources (SPIM [N-7.7])
    //   [0] transfer complete (upstream events_o[1] = end of transfer)
    //   [1] RX threshold, [2] TX threshold (upstream events_o[0], split by
    //       which FIFO is non-empty when it fires)
    // =========================================================================
    wire [1:0] events;
    assign evt[0] = events[1];
    assign evt[1] = events[0] & (|rx_words);
    assign evt[2] = events[0] & ~(|rx_words);

    // =========================================================================
    // The vendored engine
    // =========================================================================
    wire csn0, csn1, csn2, csn3;
    wire sdo0, sdo1, sdo2, sdo3;

    // IP APB: the shim's access when the SoC is using the window, our STATUS
    // poll otherwise. PWRITE is forced low on a poll so it can never write.
    wire        eff_psel    = poll ? 1'b1    : ip_psel;
    wire        eff_penable = poll ? 1'b1    : ip_penable;
    wire        eff_pwrite  = poll ? 1'b0    : ip_pwrite;
    wire [11:0] eff_paddr   = poll ? 12'h000 : ip_paddr;

    apb_spi_master #(
        .BUFFER_DEPTH(BUFFER_DEPTH), .APB_ADDR_WIDTH(12)
    ) u_spi (
        .HCLK(pclk_i), .HRESETn(preset_n_i),
        .PADDR(eff_paddr), .PWDATA(ip_pwdata), .PWRITE(eff_pwrite),
        .PSEL(eff_psel), .PENABLE(eff_penable),
        .PRDATA(ip_prdata), .PREADY(ip_pready), .PSLVERR(),
        .events_o(events),
        .spi_clk(spim_sclk_o),
        .spi_csn0(csn0), .spi_csn1(csn1), .spi_csn2(csn2), .spi_csn3(csn3),
        .spi_mode(),                                  // single-bit only ([N-7.6])
        .spi_sdo0(sdo0), .spi_sdo1(sdo1), .spi_sdo2(sdo2), .spi_sdo3(sdo3),
        // MISO goes to sdi1, NOT sdi0. Upstream's lanes are the quad-SPI pads:
        // in single-bit mode spi_master_tx drives IO0 (sdo0) and spi_master_rx
        // shifts in IO1 (`data_int_next = {data_int[30:0], sdi1}`), which is
        // where MISO sits on a real quad-capable flash. sdi0 on GARUDA is the
        // MOSI pad, an output, so nothing drives it back.
        .spi_sdi0(1'b0), .spi_sdi1(miso_sync), .spi_sdi2(1'b0), .spi_sdi3(1'b0));

    // =========================================================================
    // Pins. Upstream has four chip selects; GARUDA has two (PHYS [N-3.5]).
    // csn2/csn3 and sdo1..3 are deliberately unused - no pins exist for them.
    // =========================================================================
    assign spim_cs_flash_n_o = csn0;
    assign spim_cs_imu_n_o   = csn1;
    assign spim_mosi_o       = sdo0;

    wire _unused = |{csn2, csn3, sdo1, sdo2, sdo3, dmactl, status_q[0]};

endmodule

`default_nettype wire
