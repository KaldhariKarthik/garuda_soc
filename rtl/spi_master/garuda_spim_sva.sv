`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 13 : properties for the SPI master wrapper
// garuda_spim_sva.sv
//
// Spec: GARUDA-SPIM-SPEC-001 (the [N-x] numbers). Bound to garuda_spim_top, so
// the properties run in the block bench and in every chip simulation (the boot
// flash read). The register-port and DMA-request properties are those of the
// shared shim (rtl/common/garuda_apb_shim_sva.sv). The SPI engine itself is
// vendored (D-22): these properties are on what it puts on the pins.
// Property set of flow/formal/spim/spim_fpv.tcl.
// Not compiled for synthesis or lint, and not under Icarus (TOOL-B2).
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module garuda_spim_sva #(parameter integer BUFFER_DEPTH = 10) (
    input wire        pclk_i, preset_n_i,
    input wire        psel_i, penable_i, pwrite_i,
    input wire [11:0] paddr_i,
    input wire        pready_o,
    input wire        spim_sclk_o, spim_mosi_o, spim_cs_flash_n_o, spim_cs_imu_n_o,
    input wire        dma_req_o, dma_ack_i,
    // internals
    input wire        poll, eff_psel, eff_penable, eff_pwrite,
    input wire [11:0] eff_paddr, ip_paddr,
    input wire        ip_psel, ip_penable, ip_pwrite,
    input wire [4:0]  rx_words, tx_words,
    input wire [31:0] pwdata_i,
    input wire        en_quad, engine_idle,
    input wire [7:0]  clk_div
);
    wire cs_any = !spim_cs_flash_n_o || !spim_cs_imu_n_o;

    // R-5: never stall the APB
    a_pready: assert property (@(posedge pclk_i) disable iff (!preset_n_i) pready_o )
        else $error("[SVA-FAIL] a_pready: the SPI master stalled the APB");
    // the wrapper's STATUS poll uses only idle cycles, and is a read of STATUS
    a_poll_never_blocks: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        psel_i |-> (eff_psel == ip_psel && eff_penable == ip_penable && eff_pwrite == ip_pwrite && eff_paddr == ip_paddr) )
        else $error("[SVA-FAIL] a_poll_never_blocks: the engine was not given the bus access");
    a_poll_is_status_read: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !psel_i |-> (eff_psel && eff_penable && !eff_pwrite && eff_paddr == 12'h000) )
        else $error("[SVA-FAIL] a_poll_is_status_read: the poll is not a read of STATUS");
    // PHYS [N-3.5]: two devices, never selected together
    a_cs_exclusive: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !(!spim_cs_flash_n_o && !spim_cs_imu_n_o) )
        else $error("[SVA-FAIL] a_cs_exclusive: flash and IMU selected together");
    // [N-7.4] mode 0: while the engine is idle SCLK is low. Not "and no device selected", as the
    // spec's suggested a_cs_idle says: the controller reports idle (STATUS[0]) while it already
    // holds a chip select low at the start of a transfer (SPIM-5)
    a_sclk_idle_low: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (engine_idle && $past(engine_idle) && $past(engine_idle, 2)) |-> !spim_sclk_o )
        else $error("[SVA-FAIL] a_sclk_idle_low: engine idle with SCLK %b, CS flash %b, CS imu %b", spim_sclk_o, spim_cs_flash_n_o, spim_cs_imu_n_o);
    // [N-7.4] data is launched on the falling edge: MOSI is stable across a rising edge
    a_mosi_stable_on_rise: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        $rose(spim_sclk_o) |-> $stable(spim_mosi_o) )
        else $error("[SVA-FAIL] a_mosi_stable_on_rise: MOSI changed at a rising SCLK edge");
    // [N-6.3] the chip select is not released in an SCLK high phase: once it is high, SCLK is low
    // (the engine drops SCLK and releases the chip select on the same edge, which mode 0 allows:
    // the last bit was sampled on the rising edge before)
    a_cs_not_released_high: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        $rose(spim_cs_flash_n_o) |-> !spim_sclk_o )
        else $error("[SVA-FAIL] a_cs_not_released_high: the flash chip select rose with SCLK high");
    // [N-7.5] SPIM-4: the engine never enters a quad mode, whatever firmware writes to STATUS
    a_single_bit_mode: assert property (@(posedge pclk_i) disable iff (!preset_n_i) !en_quad )
        else $error("[SVA-FAIL] a_single_bit_mode: the engine entered a quad mode");

`ifdef FORMAL
    // The firmware rule a free APB master must keep for the pin properties to mean anything
    // (SPIM-5): no write to STATUS while a transfer is in flight. "In flight" is from the
    // write that starts it until the engine is seen idle again after being busy; STATUS[0]
    // still reads idle for the first cycles after the start, so it alone is not the rule.
    reg inflight = 1'b0, seen_busy = 1'b0;
    wire st_write = psel_i && penable_i && pwrite_i && paddr_i == 12'h000;
    always @(posedge pclk_i or negedge preset_n_i)
        if (!preset_n_i) begin inflight <= 1'b0; seen_busy <= 1'b0; end
        else if (st_write && (pwdata_i[1:0] != 2'b00)) begin inflight <= 1'b1; seen_busy <= 1'b0; end
        else if (inflight && !engine_idle) seen_busy <= 1'b1;
        else if (inflight && seen_busy && engine_idle) inflight <= 1'b0;
    assume_fw_no_status_write_in_flight: assume property (@(posedge pclk_i) disable iff (!preset_n_i)
        (psel_i && pwrite_i && paddr_i == 12'h000) |-> !inflight );
    // [N-6.2], R-4: SCLK at most 20 MHz needs CLKDIV >= 3; it resets to 0, so firmware programs
    // it before the first transfer and never below 3
    assume_fw_clkdiv: assume property (@(posedge pclk_i) disable iff (!preset_n_i)
        (psel_i && pwrite_i && paddr_i == 12'h004) |-> pwdata_i[7:0] >= 8'd3 );
    assume_fw_start_after_clkdiv: assume property (@(posedge pclk_i) disable iff (!preset_n_i)
        (psel_i && pwrite_i && paddr_i == 12'h000 && pwdata_i[1:0] != 2'b00) |-> clk_div >= 8'd3 );
    // a soft reset is its own STATUS write, not combined with a start
    assume_fw_reset_alone: assume property (@(posedge pclk_i) disable iff (!preset_n_i)
        (psel_i && pwrite_i && paddr_i == 12'h000 && pwdata_i[4]) |-> pwdata_i[1:0] == 2'b00 );
`endif

    // FIFO occupancy, as polled, never above the depth
    a_fifo_bound: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (rx_words <= BUFFER_DEPTH && tx_words <= BUFFER_DEPTH) )
        else $error("[SVA-FAIL] a_fifo_bound: a FIFO occupancy above the depth");

    c_flash_transfer: cover property (@(posedge pclk_i) $fell(spim_cs_flash_n_o));
    c_imu_transfer:   cover property (@(posedge pclk_i) $fell(spim_cs_imu_n_o));
    c_sclk_toggles:   cover property (@(posedge pclk_i) cs_any && $rose(spim_sclk_o));
    c_rx_full:        cover property (@(posedge pclk_i) rx_words == BUFFER_DEPTH);
    c_dma_req:        cover property (@(posedge pclk_i) dma_req_o && dma_ack_i);
endmodule

bind garuda_spim_top garuda_spim_sva #(.BUFFER_DEPTH(BUFFER_DEPTH)) u_spim_sva (
    .pclk_i(pclk_i), .preset_n_i(preset_n_i), .psel_i(psel_i), .penable_i(penable_i),
    .pwrite_i(pwrite_i), .paddr_i(paddr_i), .pready_o(pready_o),
    .spim_sclk_o(spim_sclk_o), .spim_mosi_o(spim_mosi_o),
    .spim_cs_flash_n_o(spim_cs_flash_n_o), .spim_cs_imu_n_o(spim_cs_imu_n_o),
    .dma_req_o(dma_req_o), .dma_ack_i(dma_ack_i),
    .poll(poll), .eff_psel(eff_psel), .eff_penable(eff_penable), .eff_pwrite(eff_pwrite),
    .eff_paddr(eff_paddr), .ip_paddr(ip_paddr), .ip_psel(ip_psel), .ip_penable(ip_penable),
    .ip_pwrite(ip_pwrite), .rx_words(rx_words), .tx_words(tx_words),
    .pwdata_i(pwdata_i), .en_quad(u_spi.u_spictrl.en_quad), .engine_idle(u_spi.spi_ctrl_status[0]), .clk_div(u_spi.spi_clk_div));
`endif
`endif
