`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 14 : properties for the SPI slave
// garuda_spis_sva.sv
//
// Spec: GARUDA-SPIS-SPEC-001. Plan: tb/spi_slave/GARUDA_SPIS_vplan.csv; each
// property names its feature. Bound to garuda_spis_top, so the properties run in
// the block bench, in the UVM environment and in every chip simulation. The
// register-port properties are those of the shared shim
// (rtl/common/garuda_apb_shim_sva.sv). Not compiled for synthesis or lint.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
// Icarus Verilog does not parse concurrent assertions; under it this file is
// empty and the block is simulated without its properties (TOOL-B2).
module garuda_spis_sva (
    input wire       pclk_i,
    input wire       preset_n_i,
    input wire       pready_o,
    input wire       irq_o,
    input wire       dma_req_o,
    input wire       dma_ack_i,
    input wire       miso_o,
    input wire       miso_oe_o,
    input wire       en_q,
    input wire       ovr_q,
    input wire       done_q,
    input wire       full,
    input wire [2:0] irqstat,
    input wire [2:0] irqen,
    input wire [2:0] evt,
    input wire       cs_n_s,          // the chip select after the synchroniser
    input wire       cs_active,
    input wire       cs_fall_now,     // the cycle a falling edge of chip select is seen
    input wire       cs_fall,         // one cycle later: the shifter is loaded
    input wire       cs_rise,
    input wire       sclk_rise,
    input wire       sclk_fall,
    input wire       rx_push,
    input wire [2:0] bitcnt,
    input wire [7:0] rx_sh
);
    // ---- F06: an access never waits
    a_pready: assert property (@(posedge pclk_i) pready_o)
        else $error("[SVA-FAIL] a_pready: pready_o low");

    // ---- F04: the two sticky STATUS bits are the same flags as their interrupt bits
    a_status_irqstat_agree: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (ovr_q == irqstat[2]) && (done_q == irqstat[1]))
        else $error("[SVA-FAIL] a_status_irqstat_agree: STATUS overrun %0b done %0b, IRQSTAT %03b", ovr_q, done_q, irqstat);

    // ---- F09: MISO moves only when the shifter is loaded or shifted: in the cycle
    // after a packet start, or after a falling edge of SCLK inside a packet
    a_miso_stable: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !(cs_fall || (cs_active && sclk_fall)) |=> $stable(miso_o))
        else $error("[SVA-FAIL] a_miso_stable: MISO changed with no load and no falling edge of SCLK");

    // ---- F12: a packet starts byte aligned, whatever came before
    a_packet_start_aligned: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        cs_fall_now |-> (bitcnt == 3'd0) && (rx_sh == 8'd0))
        else $error("[SVA-FAIL] a_packet_start_aligned: bit counter %0d, shifter %02h at a packet start", bitcnt, rx_sh);

    // ---- F14: a byte is pushed only after eight rising edges of SCLK since the
    // packet start or the push before it
    reg [3:0] n_rise;
    always @(posedge pclk_i or negedge preset_n_i)
        if (!preset_n_i)     n_rise <= 4'd0;
        else if (!cs_active) n_rise <= 4'd0;
        else if (sclk_rise)  n_rise <= (n_rise == 4'd8) ? 4'd1 : n_rise + 4'd1;
    a_no_partial_push: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        rx_push |-> $past(n_rise == 4'd7 && sclk_rise && cs_active))
        else $error("[SVA-FAIL] a_no_partial_push: a byte was pushed without eight rising edges");

    // ---- F16: nothing is pushed while the chip is not selected
    a_no_push_unselected: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        rx_push |-> $past(!cs_n_s && en_q))
        else $error("[SVA-FAIL] a_no_push_unselected: a byte was pushed with chip select high or EN clear");

    // ---- F21: MISO is driven only while enabled and selected, and never in reset
    a_miso_released: assert property (@(posedge pclk_i)
        miso_oe_o |-> (preset_n_i && en_q && !cs_n_s))
        else $error("[SVA-FAIL] a_miso_released: MISO driven with reset %0b EN %0b chip select %0b", !preset_n_i, en_q, cs_n_s);

    // ---- F22: the interrupt is the OR of the enabled flags, in every cycle
    a_irq_held: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        irq_o == |(irqstat & irqen))
        else $error("[SVA-FAIL] a_irq_held: irq_o %0b, IRQSTAT %03b, IRQEN %03b", irq_o, irqstat, irqen);

    // ---- F22 (SPIS-6): an event in the cycle of its own clear leaves the flag set
    genvar e;
    generate for (e = 0; e < 3; e = e + 1) begin : g_evt
        a_set_beats_clear: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
            (preset_n_i && evt[e]) |=> irqstat[e])     // preset_n_i as sampled: the flops were out of reset at that edge
            else $error("[SVA-FAIL] a_set_beats_clear: event %0d was lost", e);
    end endgenerate
    a_set_beats_clear_status: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        ((rx_push && full) |=> ovr_q) and (cs_rise |=> done_q))
        else $error("[SVA-FAIL] a_set_beats_clear_status: a STATUS flag was lost");

    // ---- F23: the request is low with the acknowledge and in the pclk after it
    a_dma_drop: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        dma_ack_i |-> (!dma_req_o ##1 !dma_req_o))
        else $error("[SVA-FAIL] a_dma_drop: dma_req_o high during or right after dma_ack_i");

    c_overrun:           cover property (@(posedge pclk_i) preset_n_i && rx_push && full);
    c_start_with_clock:  cover property (@(posedge pclk_i) preset_n_i && cs_fall_now && sclk_rise);
    c_packet_no_byte:    cover property (@(posedge pclk_i) preset_n_i && cs_fall ##1 cs_rise);
endmodule

bind garuda_spis_top garuda_spis_sva u_spis_sva (
    .pclk_i(pclk_i), .preset_n_i(preset_n_i), .pready_o(pready_o), .irq_o(irq_o),
    .dma_req_o(dma_req_o), .dma_ack_i(dma_ack_i), .miso_o(spis_miso_o), .miso_oe_o(spis_miso_oe_o),
    .en_q(en_q), .ovr_q(ovr_q), .done_q(done_q), .full(full),
    .irqstat(u_shim.irqstat_q), .irqen(u_shim.irqen_q), .evt(evt),
    .cs_n_s(cs_n_s), .cs_active(cs_active), .cs_fall_now(u_core.cs_fall_now), .cs_fall(cs_fall),
    .cs_rise(cs_rise), .sclk_rise(u_core.sclk_rise), .sclk_fall(u_core.sclk_fall),
    .rx_push(rx_push), .bitcnt(u_core.bitcnt), .rx_sh(u_core.rx_sh));
`endif
`endif
