`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Blocks 16/17/18 : UART (one design, three instances)
// garuda_uart_top.v - GARUDA wrapper around pulp-platform/apb_uart_sv
//
// Spec: GARUDA-UART-SPEC-001 Rev 1.0; rulings D-21 (peripheral contract),
//       D-22 (vendored IP is never edited), D-23 (integrate against the
//       upstream RTL that uses a port, not against its name).
//
// The vendored block is a 16550 register file over a start/data/parity/stop
// shifter pair with 16-byte FIFOs. It ties PREADY high and zero-extends every
// read, which is what makes it usable behind our bridge. Three things it does
// NOT do, which this wrapper supplies:
//
//   1. Word addressing. Upstream decodes register_adr = PADDR[2:0] - eight
//      registers at BYTE offsets. Our bridge rejects sub-word accesses before
//      they reach a peripheral, so the shim is configured ADDR_SHIFT=2 and our
//      word offset 4n arrives as byte offset n ([N-6.1]).
//
//   2. A usable interrupt. Upstream's uart_interrupt is instantiated but its
//      output is LEFT UNCONNECTED, because upstream wires the receiver-data-
//      available input to the wrong flag:
//          .RDA_i ( regs_n[LSR][5] )   <- THRE, the TRANSMIT fifo empty bit
//      where regs_n[LSR][0] (DR) belongs. Every event this block reports is
//      derived here from LSR instead ([N-7.5], errata ERR-U1, Docs/BUGS.md).
//
//   3. FIFO state as a level. tx_elements/rx_elements are internal signals,
//      not ports, so - exactly as garuda_spim_top does with the SPI STATUS
//      register - this wrapper reads LSR in the cycles when the SoC is not
//      using the window ([N-7.4]). An LSR read has no data side effect: it
//      does not pop a FIFO and does not alter regs_q[LSR]. It only pulses
//      clr_int into uart_interrupt, which is harmless precisely because that
//      unit's output is unused.
//
// LSR (offset 0x14, byte index 5) bit meanings, all levels recomputed every
// pclk from FIFO occupancy:
//   [0] DR   RX FIFO not empty      [5] THRE TX FIFO empty
//   [2] PE   parity error at head   [6] TEMT TX FIFO and shifter empty
//   [3] FE   framing error at head  (both come from patch 0001 - see below)
// =============================================================================

module garuda_uart_top #(
    parameter [7:0] BLOCK_NUM = 8'd16       // 16 = uart0, 17 = uart1, 18 = uart2
)(
    input  wire        pclk_i,
    input  wire        preset_n_i,

    // ---- APB slave, window 3 / 4 / 6 -----------------------------------------
    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [11:0] paddr_i,
    input  wire [31:0] pwdata_i,
    output wire [31:0] prdata_o,
    output wire        pready_o,
    output wire        pslverr_o,

    // ---- CLIC ID 17/18/19, DMA channel 2/3/5 ---------------------------------
    output wire        irq_o,
    output wire        dma_req_o,
    input  wire        dma_ack_i,

    // ---- pins ------------------------------------------------------------------
    output wire        uart_tx_o,
    input  wire        uart_rx_i
);

    localparam [11:0] IP_LIMIT = 12'h020;   // our word offsets 0x00..0x1C
    localparam [11:0] A_LCR    = 12'h00C;   // word offset of LCR (byte index 3)
    localparam [11:0] B_LSR    = 12'h005;   // BYTE index of LSR, for the poll

    wire        ip_psel, ip_penable, ip_pwrite;
    wire [11:0] ip_paddr;
    wire [31:0] ip_pwdata, ip_prdata;
    wire        ip_pready;
    wire        rx_sync;
    wire [1:0]  dmactl;
    wire        shim_dma_req;

    // SYNC_RESET=1: an idle serial line is HIGH. A synchroniser that reset to
    // zero would hand the receiver a start bit at power-on, and the garbage
    // byte it framed would sit at the head of the RX FIFO for ever after,
    // offsetting every read by one byte ([N-9.3]).

    // =========================================================================
    // Line status, sampled in the window's idle cycles ([N-7.4])
    // =========================================================================
    wire poll = ~psel_i;                    // window idle: our cycle to use

    reg [7:0] lsr_q;
    always @(posedge pclk_i or negedge preset_n_i)
        if (!preset_n_i)  lsr_q <= 8'h60;   // THRE | TEMT: nothing to send
        else if (poll)    lsr_q <= ip_prdata[7:0];

    wire lsr_dr   = lsr_q[0];               // a received byte is waiting
    wire lsr_pe   = lsr_q[2];               // parity error on that byte
    wire lsr_fe   = lsr_q[3];               // framing error on that byte
    wire lsr_thre = lsr_q[5];               // the TX FIFO has room

    // One "line error" event covers both. Firmware reads LSR to tell them
    // apart - parity says noise, framing says the baud rate is wrong - but the
    // interrupt only has to say "the byte at the head of the FIFO is suspect".
    wire lsr_err  = lsr_pe | lsr_fe;

    // =========================================================================
    // DLAB shadow ([N-6.2a])
    // -------------------------------------------------------------------------
    // While LCR[7] is set, offsets 0x00/0x04 are the baud divisor rather than
    // the data register. The wrapper sees every write to this window, so it
    // shadows that bit and forces dma_req low while it is set: a driver that
    // forgets to clear DLAB then gets a visible stall instead of a baud rate
    // silently overwritten with payload bytes.
    // =========================================================================
    reg dlab_q;
    always @(posedge pclk_i or negedge preset_n_i)
        if (!preset_n_i)                                            dlab_q <= 1'b0;
        else if (psel_i & penable_i & pwrite_i & (paddr_i == A_LCR)) dlab_q <= pwdata_i[7];

    // =========================================================================
    // Shim: decode, tail registers, sticky IRQ, DMA hold-off, rx sync
    // =========================================================================
    wire [2:0] evt;
    assign evt[0] = lsr_dr;                 // RX data available
    assign evt[1] = lsr_thre;               // TX holding register empty
    assign evt[2] = lsr_err;                // line error: parity or framing

    garuda_apb_shim #(
        .N_EVT(3), .SYNC_W(1), .SYNC_RESET(8'h01), .IP_LIMIT(IP_LIMIT),
        .ADDR_SHIFT(2), .BLOCK_NUM(BLOCK_NUM), .BLOCK_REV(8'd1)
    ) u_shim (
        .pclk_i(pclk_i), .preset_n_i(preset_n_i),
        .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i),
        .paddr_i(paddr_i), .pwdata_i(pwdata_i), .prdata_o(prdata_o),
        .pready_o(pready_o), .pslverr_o(pslverr_o),
        .ip_psel_o(ip_psel), .ip_penable_o(ip_penable), .ip_pwrite_o(ip_pwrite),
        .ip_paddr_o(ip_paddr), .ip_pwdata_o(ip_pwdata), .ip_prdata_i(ip_prdata),
        .ip_pready_i(ip_pready),
        .evt_i(evt), .irq_o(irq_o),
        .rx_avail_i(lsr_dr),
        .tx_space_i(lsr_thre),
        .dma_ack_i(dma_ack_i), .dma_req_o(shim_dma_req), .dmactl_o(dmactl),
        .pad_async_i(uart_rx_i), .pad_sync_o(rx_sync));

    // The divisor latch is never a DMA target ([N-7.6b]). Gating outside the
    // shim is safe: it can only hold the request lower, never longer.
    assign dma_req_o = shim_dma_req & ~dlab_q;

    // =========================================================================
    // The vendored UART. PWRITE is forced low on a poll cycle so the poll can
    // never write, and the poll address is the BYTE index of LSR - the shim's
    // ADDR_SHIFT has already been applied to ip_paddr, so this is the same
    // number space.
    // =========================================================================
    wire        eff_psel    = poll ? 1'b1  : ip_psel;
    wire        eff_penable = poll ? 1'b1  : ip_penable;
    wire        eff_pwrite  = poll ? 1'b0  : ip_pwrite;
    wire [11:0] eff_paddr   = poll ? B_LSR : ip_paddr;

    apb_uart_sv #(
        .APB_ADDR_WIDTH(12)
    ) u_uart (
        .CLK(pclk_i), .RSTN(preset_n_i),
        .PADDR(eff_paddr), .PWDATA(ip_pwdata), .PWRITE(eff_pwrite),
        .PSEL(eff_psel), .PENABLE(eff_penable),
        .PRDATA(ip_prdata), .PREADY(ip_pready), .PSLVERR(),
        .rx_i(rx_sync), .tx_o(uart_tx_o),
        .event_o());                        // unused on purpose - ERR-U1

    wire _unused = |{dmactl, lsr_q[7:6], lsr_q[4], lsr_q[1]};

endmodule

`default_nettype wire
