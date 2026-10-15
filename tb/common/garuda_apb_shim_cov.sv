`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - APB shim : functional coverage of the shim every peripheral uses
// garuda_apb_shim_cov.sv
//
// From D-21 (the peripheral contract) and the AUD-13 register map. Bound to
// garuda_apb_shim, one instance per peripheral (per_instance), so each wrapper
// shows whether its own window, interrupts and DMA handshake were exercised.
// Not for synthesis, not under Icarus or Verilator.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
`ifndef VERILATOR
module garuda_apb_shim_cov #(parameter integer N_EVT = 4) (
    input wire        pclk_i, preset_n_i,
    input wire        access, pwrite_i, in_ip, in_tail, pslverr_o,
    input wire [11:0] paddr_i,
    input wire [N_EVT-1:0] evt_i, w1c, irqstat_q, irqen_q,
    input wire        irq_o, dma_req_o, dma_ack_i, holdoff_q,
    input wire [1:0]  dmactl_q
);
    covergroup cg_access @(posedge pclk_i iff (preset_n_i && access));
        option.per_instance = 1;
        cp_target: coverpoint {in_ip, in_tail} { bins ip_register = {2'b10}; bins tail_register = {2'b01}; bins hole = {2'b00}; }
        cp_tail: coverpoint paddr_i iff (in_tail) { bins irqstat = {12'hFE0}; bins irqen = {12'hFE4}; bins dmactl = {12'hFE8}; bins id = {12'hFEC}; }
        cp_dir: coverpoint pwrite_i;
        cp_err: coverpoint pslverr_o;
        x_target_dir: cross cp_target, cp_dir;
        x_tail_dir: cross cp_tail, cp_dir;
    endgroup
    // [D-17] every event captured, enabled and cleared; and the event in the cycle of its own clear
    covergroup cg_irq @(posedge pclk_i iff preset_n_i);
        option.per_instance = 1;
        cp_captured: coverpoint |evt_i;
        cp_clear: coverpoint |w1c;
        cp_event_during_clear: coverpoint |(evt_i & w1c);
        cp_irq: coverpoint irq_o;
        cp_pending_masked: coverpoint |(irqstat_q & ~irqen_q);
    endgroup
    covergroup cg_dma @(posedge pclk_i iff (preset_n_i && (dma_ack_i || dma_req_o)));
        option.per_instance = 1;
        cp_mode: coverpoint dmactl_q { bins rx = {1}; bins tx = {2}; bins both = {3}; }
        cp_ack: coverpoint dma_ack_i;
        cp_holdoff: coverpoint holdoff_q;
    endgroup
    cg_access ca = new(); cg_irq ci = new(); cg_dma cd = new();
endmodule

bind garuda_apb_shim garuda_apb_shim_cov #(.N_EVT(N_EVT)) u_shim_cov (
    .pclk_i(pclk_i), .preset_n_i(preset_n_i), .access(access), .pwrite_i(pwrite_i),
    .in_ip(in_ip), .in_tail(in_tail), .pslverr_o(pslverr_o), .paddr_i(paddr_i),
    .evt_i(evt_i), .w1c(w1c), .irqstat_q(irqstat_q), .irqen_q(irqen_q), .irq_o(irq_o),
    .dma_req_o(dma_req_o), .dma_ack_i(dma_ack_i), .holdoff_q(holdoff_q), .dmactl_q(dmactl_q));
`endif
`endif
`endif
