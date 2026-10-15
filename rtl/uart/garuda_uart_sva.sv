`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Blocks 16, 17, 18 : properties for the UART wrapper
// garuda_uart_sva.sv
//
// Spec: GARUDA-UART-SPEC-001. Plan: tb/uart/GARUDA_UART_vplan.csv; each property
// names its feature. Bound to garuda_uart_top, so the properties run in the block
// bench, in the UVM environment and in every chip simulation, on each of the
// three instances. The register-port properties are those of the shared shim
// (rtl/common/garuda_apb_shim_sva.sv). Not compiled for synthesis or lint.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
// Icarus Verilog does not parse concurrent assertions; under it this file is
// empty and the block is simulated without its properties (TOOL-B2).
module garuda_uart_sva (
    input wire        pclk_i,
    input wire        preset_n_i,
    input wire        psel_i, penable_i, pwrite_i,
    input wire [11:0] paddr_i,
    input wire        pready_o,
    input wire        irq_o,
    input wire        dma_req_o,
    input wire        dma_ack_i,
    input wire        uart_tx_o,
    input wire        rx_sync,
    input wire        dlab_q,
    input wire [7:0]  lcr,             // the vendored LCR
    input wire [7:0]  lsr,             // the vendored LSR
    input wire [4:0]  rx_elements,
    input wire        rx_push,         // a received byte enters the FIFO
    input wire        rx_clr,          // FCR is emptying the receive FIFO
    input wire        ip_psel, eff_psel, eff_penable, eff_pwrite,
    input wire [11:0] ip_paddr, eff_paddr,
    input wire [2:0]  irqstat, irqen, evt
);
    // ---- F11: an access never waits
    a_pready: assert property (@(posedge pclk_i) pready_o)
        else $error("[SVA-FAIL] a_pready: pready_o low");

    // ---- F11: with the window selected the vendored block sees the bus access, not the wrapper's poll
    a_poll_never_blocks: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        psel_i |-> (eff_psel == ip_psel && eff_penable == penable_i && eff_pwrite == pwrite_i && eff_paddr == ip_paddr))
        else $error("[SVA-FAIL] a_poll_never_blocks: the vendored block was not given the bus access");
    // and the poll itself is a read of LSR, which changes nothing ([N-6.3a])
    a_poll_is_lsr_read: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !psel_i |-> (eff_psel && eff_penable && !eff_pwrite && eff_paddr == 12'h005))
        else $error("[SVA-FAIL] a_poll_is_lsr_read: the poll is not a read of LSR");

    // ---- F06: a read of LSR, by the bus or by the poll, takes nothing out of the receive FIFO
    a_lsr_read_no_pop: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (eff_psel && eff_penable && !eff_pwrite && eff_paddr[2:0] == 3'd5 && !rx_clr) |=> (rx_elements >= $past(rx_elements)))
        else $error("[SVA-FAIL] a_lsr_read_no_pop: the receive FIFO lost a byte on a read of LSR");

    // ---- F03, F25: the interrupt is the OR of the enabled flags, whatever the 16550's IER says
    a_irq_held: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        irq_o == |(irqstat & irqen))
        else $error("[SVA-FAIL] a_irq_held: irq_o %0b, IRQSTAT %03b, IRQEN %03b", irq_o, irqstat, irqen);
    genvar e;
    generate for (e = 0; e < 3; e = e + 1) begin : g_evt
        a_set_beats_clear: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
            (preset_n_i && evt[e]) |=> irqstat[e])     // preset_n_i as sampled: the flops were out of reset at that edge
            else $error("[SVA-FAIL] a_set_beats_clear: event %0d was lost", e);
    end endgenerate

    // ---- F24 (UART-5): a line error is reported only for a byte that is there
    a_err_needs_byte: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        evt[2] |-> evt[0])
        else $error("[SVA-FAIL] a_err_needs_byte: line-error event with no byte waiting");

    // ---- F22: tx is high in reset and while nothing is being sent
    a_tx_idle_high: assert property (@(posedge pclk_i)
        ((!preset_n_i && $past(!preset_n_i)) || (preset_n_i && lsr[6])) |-> uart_tx_o)
        else $error("[SVA-FAIL] a_tx_idle_high: tx low in reset or with TEMT set");

    // ---- F22: no byte is received until the line has been low
    reg seen_low;
    always @(posedge pclk_i or negedge preset_n_i)
        if (!preset_n_i)   seen_low <= 1'b0;
        else if (!rx_sync) seen_low <= 1'b1;
    a_no_byte_after_reset: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !seen_low |-> (rx_elements == 5'd0 && !rx_push))
        else $error("[SVA-FAIL] a_no_byte_after_reset: a byte was received with rx never low");

    // ---- F26: the request is low with the acknowledge and in the pclk after it
    a_dma_drop: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        dma_ack_i |-> (!dma_req_o ##1 !dma_req_o))
        else $error("[SVA-FAIL] a_dma_drop: dma_req_o high during or right after dma_ack_i");

    // ---- F28: no request while DLAB is set; the wrapper's shadow is LCR bit 7
    a_dma_dlab: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (dlab_q |-> !dma_req_o) and (dlab_q == lcr[7]))
        else $error("[SVA-FAIL] a_dma_dlab: request %0b with the shadow %0b, LCR bit 7 %0b", dma_req_o, dlab_q, lcr[7]);

    c_poll_then_access:  cover property (@(posedge pclk_i) preset_n_i && !psel_i ##1 psel_i);
    c_rx_full:           cover property (@(posedge pclk_i) preset_n_i && rx_elements == 5'd16);
endmodule

bind garuda_uart_top garuda_uart_sva u_uart_sva (
    .pclk_i(pclk_i), .preset_n_i(preset_n_i), .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i),
    .paddr_i(paddr_i), .pready_o(pready_o), .irq_o(irq_o), .dma_req_o(dma_req_o), .dma_ack_i(dma_ack_i),
    .uart_tx_o(uart_tx_o), .rx_sync(rx_sync), .dlab_q(dlab_q),
    .lcr(u_uart.regs_q[3]), .lsr(u_uart.regs_q[5]), .rx_elements(u_uart.rx_elements),
    .rx_push(u_uart.rx_valid & u_uart.rx_ready), .rx_clr(u_uart.rx_fifo_clr_q),
    .ip_psel(ip_psel), .eff_psel(eff_psel), .eff_penable(eff_penable), .eff_pwrite(eff_pwrite),
    .ip_paddr(ip_paddr), .eff_paddr(eff_paddr),
    .irqstat(u_shim.irqstat_q), .irqen(u_shim.irqen_q), .evt(evt));
`endif
`endif
