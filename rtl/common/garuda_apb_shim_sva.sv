`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - properties of the shared peripheral shim
// garuda_apb_shim_sva.sv
//
// Source: DECISIONS.md D-21 (interrupt and DMA contract of every peripheral
// window), D-17 (held level interrupts), D-16 (DMA acknowledge), and
// GARUDA-AHB2APB-SPEC-001 section 7.5 (a peripheral never stalls).
// Bound to garuda_apb_shim, so every peripheral window in every simulation,
// block or chip, is checked by the same properties. Not compiled for synthesis
// or lint.
// =============================================================================
`ifndef SYNTHESIS
// The file is named in the filelist of every block that has a shim, and the chip
// compiles all of those: the guard makes the second and later copies empty, so
// the properties are bound once.
`ifndef GARUDA_APB_SHIM_SVA_SV
`define GARUDA_APB_SHIM_SVA_SV
module garuda_apb_shim_sva #(
    parameter integer N_EVT = 4
)(
    input wire             pclk_i,
    input wire             preset_n_i,
    input wire             psel_i, penable_i, pwrite_i,
    input wire [11:0]      paddr_i,
    input wire [31:0]      pwdata_i,
    input wire             pready_o, pslverr_o,
    input wire             ip_psel_o,
    input wire [N_EVT-1:0] evt_i,
    input wire             irq_o,
    input wire             rx_avail_i, tx_space_i, dma_ack_i, dma_req_o,
    input wire [N_EVT-1:0] irqstat_q, irqen_q,
    input wire [1:0]       dmactl_q
);
    wire wr = psel_i && penable_i && pwrite_i;
    wire [N_EVT-1:0] clr = (wr && paddr_i == 12'hFE0) ? pwdata_i[N_EVT-1:0] : {N_EVT{1'b0}};

    // a property that looks one cycle back takes the sampled reset in its
    // antecedent, so no attempt starts on the edge that releases the reset
    a_shim_pready: assert property (@(posedge pclk_i) disable iff (preset_n_i !== 1'b1) pready_o)
        else $error("[SVA-FAIL] a_shim_pready: a peripheral window stalled");

    // the interrupt line is a level: the OR of the captured events that are enabled
    a_shim_irq_level: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        irq_o == |(irqstat_q & irqen_q))
        else $error("[SVA-FAIL] a_shim_irq_level");

    genvar k;
    generate for (k = 0; k < N_EVT; k = k + 1) begin : g_evt
        // an event is always captured, also in the cycle firmware clears that bit
        a_shim_capture: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
            (preset_n_i && evt_i[k]) |=> irqstat_q[k])
            else $error("[SVA-FAIL] a_shim_capture: event %0d lost", k);
        a_shim_set_beats_clear: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
            (preset_n_i && evt_i[k] && clr[k]) |=> irqstat_q[k])
            else $error("[SVA-FAIL] a_shim_set_beats_clear: event %0d lost to its own clear", k);
        // a captured event is held until firmware writes 1 to it
        a_shim_sticky: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
            (preset_n_i && irqstat_q[k] && !clr[k]) |=> irqstat_q[k])
            else $error("[SVA-FAIL] a_shim_sticky: status bit %0d dropped without a clear", k);
        a_shim_clear: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
            (preset_n_i && clr[k] && !evt_i[k]) |=> !irqstat_q[k])
            else $error("[SVA-FAIL] a_shim_clear: status bit %0d not cleared by a write of 1", k);
        // and nothing but an event sets a bit
        a_shim_no_spurious: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
            (preset_n_i && !irqstat_q[k] && !evt_i[k]) |=> !irqstat_q[k])
            else $error("[SVA-FAIL] a_shim_no_spurious: status bit %0d set with no event", k);
        c_shim_evt:           cover property (@(posedge pclk_i) preset_n_i && evt_i[k]);
        c_shim_clear:         cover property (@(posedge pclk_i) preset_n_i && clr[k] && irqstat_q[k]);
    end endgenerate

    // the line to the CLIC falls only because firmware wrote IRQSTAT or IRQEN (D-17)
    a_shim_irq_held: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (preset_n_i && $fell(irq_o)) |-> $past(wr && (paddr_i == 12'hFE0 || paddr_i == 12'hFE4)))
        else $error("[SVA-FAIL] a_shim_irq_held: the interrupt dropped with no write to IRQSTAT or IRQEN");

    // an access that answers with an error reaches neither the IP nor a shim register
    a_shim_err_no_select: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        pslverr_o |-> !ip_psel_o)
        else $error("[SVA-FAIL] a_shim_err_no_select");
    a_shim_err_no_change: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (preset_n_i && pslverr_o) |=> ($stable(irqen_q) && $stable(dmactl_q)))
        else $error("[SVA-FAIL] a_shim_err_no_change");

    // DMA request: only when enabled, never together with the acknowledge, and
    // low for one pclk after it so the channel sees a new request per beat (D-16)
    a_shim_dma_gate: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        dma_req_o |-> ((dmactl_q[0] && rx_avail_i) || (dmactl_q[1] && tx_space_i)))
        else $error("[SVA-FAIL] a_shim_dma_gate: request with nothing enabled");
    a_shim_dma_holdoff: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (preset_n_i && dma_ack_i) |-> (!dma_req_o ##1 !dma_req_o))
        else $error("[SVA-FAIL] a_shim_dma_holdoff");

    // in reset nothing is pending or enabled
    a_shim_reset: assert property (@(posedge pclk_i)
        !preset_n_i |-> (irqstat_q == '0 && irqen_q == '0 && dmactl_q == 2'b00 && !irq_o))
        else $error("[SVA-FAIL] a_shim_reset");

    c_shim_err:     cover property (@(posedge pclk_i) preset_n_i && pslverr_o);
    c_shim_irq:     cover property (@(posedge pclk_i) preset_n_i && $rose(irq_o));
endmodule

bind garuda_apb_shim garuda_apb_shim_sva #(.N_EVT(N_EVT)) u_shim_sva (
    .pclk_i(pclk_i), .preset_n_i(preset_n_i),
    .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i), .paddr_i(paddr_i), .pwdata_i(pwdata_i),
    .pready_o(pready_o), .pslverr_o(pslverr_o), .ip_psel_o(ip_psel_o),
    .evt_i(evt_i), .irq_o(irq_o),
    .rx_avail_i(rx_avail_i), .tx_space_i(tx_space_i), .dma_ack_i(dma_ack_i), .dma_req_o(dma_req_o),
    .irqstat_q(irqstat_q), .irqen_q(irqen_q), .dmactl_q(dmactl_q));
`endif
`endif
