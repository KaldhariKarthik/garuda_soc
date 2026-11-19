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
// derived here from LSR instead ([N-7.5], errata ERR-U1,
// Docs/bugs/archive/BUGS_HISTORY.md).
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

module garuda_uart_top
    import garuda_pkg::*;
#(
    parameter [7:0] BLOCK_NUM = 8'd16  // 16 = uart0, 17 = uart1, 18 = uart2
)(
    input wire pclk,
    input wire preset_n,
    // ---- APB slave, window 3 / 4 / 6 ----------------------------------------
    input wire psel_i,
    input wire penable_i,
    input wire pwrite_i,
    input wire [PADDR_W-1:0] paddr_i,
    input wire [WORD_W-1:0] pwdata_i,
    output wire [WORD_W-1:0] prdata_o,
    output wire pready_o,
    output wire pslverr_o,
    // ---- CLIC ID 17/18/19, DMA channel 2/3/5 --------------------------------
    output wire irq_o,
    output wire dma_req_o,
    input wire dma_ack_i,
    // ---- pins ---------------------------------------------------------------
    output wire uart_tx_o,
    input wire uart_rx_i
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned EVT_W = 32'd3;

    localparam [11:0] IP_LIMIT = 12'h020;  // our word offsets 0x00..0x1C
    // all eight words are 16550 register positions. MCR, MSR and SCR (0x10,
    // 0x18, 0x1C) are not implemented upstream and read 0; they stay registers,
    // so a 16550 driver that writes MCR gets no bus error (UART [N-13.1],
    // [N-13.2]).
    localparam [63:0] IP_MAP   = 64'h0000_0000_0000_00FF;
    localparam [11:0] A_LCR    = 12'h00C;  // word offset of LCR (byte index 3)
    localparam [11:0] B_LSR    = 12'h005;  // BYTE index of LSR, for the poll

    wire ip_psel;
    // the UART's register offsets are word indices (the shim's ADDR_SHIFT of 2
    // went in F4: the wrapper takes the word address itself)
    wire [PADDR_W-1:0] ip_paddr = {2'b00, paddr_i[11:2]};
    wire [WORD_W-1:0] ip_prdata;
    wire        rx_sync;
    wire        shim_dma_req;

    // SYNC_RESET=1: an idle serial line is HIGH. A synchroniser that reset to
    // zero would hand the receiver a start bit at power-on, and the garbage
    // byte it framed would sit at the head of the RX FIFO for ever after,
    // offsetting every read by one byte ([N-9.3]).

    // =========================================================================
    // Line status, sampled in the window's idle cycles ([N-7.4])
    // =========================================================================
    wire poll = ~psel_i;  // window idle: our cycle to use

    // the four LSR bits the wrapper uses (F4: the others were held and never
    // read)
    reg lsr_dr;    // a received byte is waiting
    reg lsr_pe;    // parity error on that byte
    reg lsr_fe;    // framing error on that byte
    reg lsr_thre;  // the TX FIFO has room
    always_ff @(posedge pclk or negedge preset_n) begin : p_lsr
        if (!preset_n) begin
            lsr_dr <= 1'b0;
            lsr_pe <= 1'b0;
            lsr_fe <= 1'b0;
            lsr_thre <= 1'b1;  // nothing to send
        end else if (poll) begin
            lsr_dr <= ip_prdata[0];
            lsr_pe <= ip_prdata[2];
            lsr_fe <= ip_prdata[3];
            lsr_thre <= ip_prdata[5];
        end
    end

    // One "line error" event covers both. Firmware reads LSR to tell them
    // apart - parity says noise, framing says the baud rate is wrong - but the
    // interrupt only has to say "the byte at the head of the FIFO is suspect".
    //
    // UART-5: only while a byte is there. The vendored LSR takes bits 2 and 3
    // straight from the FIFO's output, and with the FIFO empty that output is
    // the slot the next byte will go into, still holding the flags of the byte
    // that was in it sixteen bytes ago (or of the byte just read, right after a
    // FIFO clear). Without the gate the event was raised in every cycle with
    // nothing in the FIFO, and firmware could not clear the interrupt.
    wire lsr_err  = lsr_dr & (lsr_pe | lsr_fe);

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
    always_ff @(posedge pclk or negedge preset_n) begin : p_dlab
        if (!preset_n) begin
            dlab_q <= 1'b0;
        end else if (psel_i & penable_i & pwrite_i & at12(paddr_i, A_LCR)) begin
            dlab_q <= pwdata_i[7];
        end
    end

    // =========================================================================
    // Shim: decode, tail registers, sticky IRQ, DMA hold-off, rx sync
    // =========================================================================
    wire [EVT_W-1:0] evt;
    assign evt[0] = lsr_dr;  // RX data available
    assign evt[1] = lsr_thre;  // TX holding register empty
    assign evt[2] = lsr_err;  // line error: parity or framing

    wire [WORD_W-1:0] shim_prdata;
    wire [WORD_W-1:0] dma_rdata;
    garuda_apb_shim #(
        .N_EVT(3), .IP_LIMIT(IP_LIMIT),
            .IP_MAP(IP_MAP), .BLOCK_NUM(BLOCK_NUM), .BLOCK_REV(8'd1)
    ) u_shim (
        .pclk(pclk), .preset_n(preset_n),
        .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i),
        .paddr_i(paddr_i), .pwdata_i(pwdata_i), .prdata_o(shim_prdata),
        .pready_o(pready_o), .pslverr_o(pslverr_o),
        .ip_psel_o(ip_psel), .ip_prdata_i(ip_prdata),
        .evt_i(evt), .irq_o(irq_o));

    // DMACTL and the request (D-39: only the blocks with a DMA channel)
    garuda_apb_dma u_dma (
        .pclk(pclk), .preset_n(preset_n),
        .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i),
        .paddr_i(paddr_i), .pwdata_i(pwdata_i), .rdata_o(dma_rdata),
        .src_i({lsr_thre, lsr_dr}), .dma_ack_i(dma_ack_i), .dma_req_o(shim_dma_req));
    assign prdata_o = shim_prdata | dma_rdata;

    // pad input synchronisers (F4: out of the shim)
    // RX idles HIGH
    garuda_sync_bit #(.IDLE(1'b1)) u_sync (
        .pclk(pclk), .preset_n(preset_n), .pad_i(uart_rx_i),
        .sync_o(rx_sync)
    );

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
    wire        eff_penable = poll ? 1'b1  : penable_i;
    wire        eff_pwrite  = poll ? 1'b0  : pwrite_i;
    wire [PADDR_W-1:0] eff_paddr   = poll ? B_LSR : ip_paddr;

    apb_uart_sv #(
        .APB_ADDR_WIDTH(12)
    ) u_uart (
        .pclk(pclk), .preset_n(preset_n),
        .PADDR(eff_paddr), .PWDATA(pwdata_i), .PWRITE(eff_pwrite),
        .PSEL(eff_psel), .PENABLE(eff_penable),
        .PRDATA(ip_prdata), .PREADY(), .PSLVERR(),
        .rx_i(rx_sync), .tx_o(uart_tx_o),
        .event_o());  // unused on purpose - ERR-U1


endmodule
