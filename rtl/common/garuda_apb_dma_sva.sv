`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - properties of the DMA request block
// garuda_apb_dma_sva.sv
//
// Source: DECISIONS.md D-39 (DMACTL only where there is a DMA channel), D-16
// (DMA acknowledge). Bound to garuda_apb_dma, which UART, I2C, SPI master and
// SPI slave instantiate; listed next to garuda_apb_dma.sv in their file lists,
// so PWM and GPIO (no DMA channel, D-39) never compile the bind. Split from
// garuda_apb_shim_sva.sv on 2026-11-20: bound from there, the PWM and GPIO
// benches failed to elaborate (NUNIT garuda_apb_dma). Not compiled for
// synthesis or lint.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
// the chip compiles every block's file list: the guard binds the properties once
`ifndef GARUDA_APB_DMA_SVA_SV
`define GARUDA_APB_DMA_SVA_SV
// garuda_apb_dma (D-39): DMACTL and the request
module garuda_apb_dma_sva (
    input wire        pclk,
    input wire        preset_n,
    input wire        psel_i, penable_i, pwrite_i,
    input wire [11:0] paddr_i,
    input wire [1:0]  src_i,
    input wire        dma_ack_i, dma_req_o,
    input wire [1:0]  dmactl_q
);
    wire wr_dmactl = psel_i && penable_i && pwrite_i && (paddr_i == 12'hFE8);

    // the request: only when enabled, never together with the acknowledge, and
    // low for one pclk after it so the channel sees a new request per beat (D-16)
    a_shim_dma_gate: assert property (@(posedge pclk) disable iff (!preset_n)
        dma_req_o |-> |(dmactl_q & src_i))
        else $error("[SVA-FAIL] a_shim_dma_gate: request with nothing enabled");
    a_shim_dma_holdoff: assert property (@(posedge pclk) disable iff (!preset_n)
        (preset_n && dma_ack_i) |-> (!dma_req_o ##1 !dma_req_o))
        else $error("[SVA-FAIL] a_shim_dma_holdoff");
    // DMACTL changes only on a write to it
    a_dma_write_only: assert property (@(posedge pclk) disable iff (!preset_n)
        (preset_n && !wr_dmactl) |=> $stable(dmactl_q))
        else $error("[SVA-FAIL] a_dma_write_only: DMACTL changed without a write");
    a_dma_reset: assert property (@(posedge pclk) !preset_n |-> (dmactl_q == 2'b00))
        else $error("[SVA-FAIL] a_dma_reset");
    c_dma_req: cover property (@(posedge pclk) preset_n && dma_req_o);
endmodule

bind garuda_apb_dma garuda_apb_dma_sva u_dma_sva (
    .pclk(pclk), .preset_n(preset_n),
    .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i), .paddr_i(paddr_i),
    .src_i(src_i), .dma_ack_i(dma_ack_i), .dma_req_o(dma_req_o), .dmactl_q(dmactl_q));
`endif
`endif
`endif
