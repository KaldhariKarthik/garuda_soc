// =============================================================================
// GARUDA SoC - Block 14 : SPI slave (ESP32 / ESP-NOW companion link)
// garuda_spis_top.v - register file + RX FIFO over garuda_spis_core
//
// Spec: GARUDA-SPIS-SPEC-001 Rev 1.0; rulings D-17, D-21, D-25,
//       ADR-0020 Rev 2.
//
// This block was held as a reserved block number by ADR-0020 and restored as
// REQUIRED by ADR-0020 Rev 2: ESP-NOW is the neighbour-position source for APF
// collision avoidance, which is the workload the DSU exists to accelerate.
// Window 0, CLIC ID 14 and DMA channel 4 were all left in place for it rather
// than compacting the maps - this is the block they were held for.
//
// In-house (D-25). The interesting decision in an SPI slave is how SCLK enters
// the chip, and this design has already answered that elsewhere: see
// garuda_spis_core.v [N-7.1]. Vendoring would have imported someone else's
// answer and, with it, a second asynchronous crossing.
// =============================================================================

module garuda_spis_top
    import garuda_pkg::*;
#(
    parameter [7:0]   BLOCK_NUM = 8'd14,
    parameter int unsigned FIFO_DEPTH = 32'd16
)(
    input wire pclk,
    input wire preset_n,
    // ---- APB slave, window 0 ------------------------------------------------
    input wire psel_i,
    input wire penable_i,
    input wire pwrite_i,
    input wire [PADDR_W-1:0] paddr_i,
    input wire [WORD_W-1:0] pwdata_i,
    output wire [WORD_W-1:0] prdata_o,
    output wire pready_o,
    output wire pslverr_o,
    // ---- CLIC ID 14 / DMA channel 4 -----------------------------------------
    output wire irq_o,
    output wire dma_req_o,
    input wire dma_ack_i,
    // ---- pins 29-32 ---------------------------------------------------------
    input wire spis_sclk_i,
    input wire spis_mosi_i,
    input wire spis_cs_n_i,
    output wire spis_miso_o,
    output wire spis_miso_oe_o
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned PAD_SYNC_W = 32'd3;
    localparam int unsigned IRQSTAT_CLR_W = 32'd3;
    localparam int unsigned EVT_W = 32'd3;

    localparam [11:0] A_RXDATA = 12'h000, A_TXDATA = 12'h004,
                      A_CTRL   = 12'h008, A_STATUS = 12'h00C;
    // SPIS-7: four registers, 0x00..0x0C. This was 12'h020 (copied from the PWM
    // block, which has eight), so 0x10..0x1C answered a read with 0 and
    // swallowed a write instead of raising PSLVERR (AHB2APB [N-7.20]).
    localparam [11:0] IP_LIMIT = 12'h010;
    localparam [63:0] IP_MAP   = 64'h0000_0000_0000_000F;  // 0x00 to 0x0C

    wire ip_psel;
    wire [PAD_SYNC_W-1:0]  pad_sync;

    wire sclk_s = pad_sync[0];
    wire mosi_s = pad_sync[1];
    wire cs_n_s = pad_sync[2];

    wire wr_hit = ip_psel & penable_i & pwrite_i;
    wire        tail_w1c;
    wire [IRQSTAT_CLR_W-1:0]  irqstat_clr;
    wire rd_hit = ip_psel & penable_i & ~pwrite_i;

    // =========================================================================
    // Registers
    // =========================================================================
    reg        en_q;
    reg [BYTE_W-1:0]  txdata_q;
    reg ovr_q;
    reg done_q;

    wire rxflush = wr_hit & at12(paddr_i, A_CTRL) & pwdata_i[1];

    // =========================================================================
    // The shift engine
    // =========================================================================
    wire [BYTE_W-1:0] rx_byte;
    wire rx_push;
    wire cs_active;
    wire cs_rise;

    garuda_spis_core u_core (
        .pclk(pclk), .preset_n(preset_n), .en_i(en_q),
        .sclk_s_i(sclk_s), .mosi_s_i(mosi_s), .cs_n_s_i(cs_n_s),
        .miso_o(spis_miso_o), .miso_oe_o(spis_miso_oe_o),
        .txdata_i(txdata_q),
        .rx_byte_o(rx_byte), .rx_push_o(rx_push),
        .cs_active_o(cs_active), .cs_rise_o(cs_rise));

    // =========================================================================
    // RX FIFO. On overrun the NEW byte is dropped, not the oldest: that
    // truncates a packet rather than interleaving it, and a truncated packet
    // fails its checksum while an interleaved one might not ([N-7.5]).
    // =========================================================================
    localparam int unsigned ADDR_W = (FIFO_DEPTH <= 32'd16) ? 32'd4 : 32'd5;
    localparam int unsigned PTR_W = ADDR_W + 32'd1;

    reg [BYTE_W-1:0]    fifo [0:FIFO_DEPTH-1];
    reg [PTR_W-1:0] wptr;
    reg [PTR_W-1:0] rptr;
    wire [PTR_W-1:0]  level = PTR_W'(wptr - rptr);
    wire         full  = (level == PTR_W'(FIFO_DEPTH));
    wire         empty = (level == '0);

    wire pop  = rd_hit && at12(paddr_i, A_RXDATA) && !empty;
    wire push = rx_push && !full;

    // F4 (2026-11-17): pointers, data and the control registers each in a
    // process of their own (HAL MULNBA); the FIFO words need no reset (they
    // are read only when written)
    always_ff @(posedge pclk or negedge preset_n) begin : p_ptr
        if (!preset_n) begin
            wptr <= '0;
            rptr <= '0;
        end else if (rxflush) begin
            wptr <= '0;
            rptr <= '0;
        end else begin
            if (push) begin
                wptr <= PTR_W'(wptr + 1'b1);
            end
            if (pop) begin
                rptr <= PTR_W'(rptr + 1'b1);
            end
        end
    end

    always_ff @(posedge pclk) begin : p_fifo
        if (push && !rxflush) begin
            fifo[wptr[ADDR_W - 1:0]] <= rx_byte;
        end
    end

    wire rxvalid = !empty;

    always_ff @(posedge pclk or negedge preset_n) begin : p_ctrl
        if (!preset_n) begin
            en_q <= 1'b0;
            txdata_q <= 8'd0;
        end else if (wr_hit && at12(paddr_i, A_CTRL)) begin
            en_q <= pwdata_i[0];
        end else if (wr_hit && at12(paddr_i, A_TXDATA)) begin
            txdata_q <= pwdata_i[7:0];
        end
    end

    // OVERRUN and DONE are sticky; the IRQSTAT W1C clears them unless the
    // event repeats on the same edge
    always_ff @(posedge pclk or negedge preset_n) begin : p_ovr
        if (!preset_n) begin
            ovr_q <= 1'b0;
        end else if (rx_push && full) begin
            ovr_q <= 1'b1;  // [N-7.5]
        end else if (irqstat_clr[2]) begin
            ovr_q <= 1'b0;
        end
    end

    always_ff @(posedge pclk or negedge preset_n) begin : p_done
        if (!preset_n) begin
            done_q <= 1'b0;
        end else if (cs_rise) begin
            done_q <= 1'b1;
        end else if (irqstat_clr[1]) begin
            done_q <= 1'b0;
        end
    end

    assign tail_w1c    = psel_i & penable_i & pwrite_i & at12(paddr_i, 12'hFE0);
    assign irqstat_clr = tail_w1c ? pwdata_i[2:0] : 3'd0;

    // =========================================================================
    // Events (D-21)
    // =========================================================================
    wire [EVT_W-1:0] evt;
    assign evt[0] = rx_push;  // a byte arrived
    assign evt[1] = cs_rise;  // packet complete
    assign evt[2] = rx_push & full;  // overrun

    // =========================================================================
    // Read mux
    // =========================================================================
    wire [WORD_W-1:0] reg_rdata =
        at12(paddr_i, A_RXDATA)
            ? {24'd0, empty ? 8'd0 : fifo[rptr[ADDR_W - 1:0]]} :
        at12(paddr_i, A_TXDATA) ? {24'd0, txdata_q}                          :
        at12(paddr_i, A_CTRL)   ? {31'd0, en_q}                              :
        at12(paddr_i, A_STATUS) ? {23'd0, level[4:0], done_q, ovr_q,
                                         cs_active, rxvalid}                :
                                 32'd0;

    // the pads to synchronise: {cs_n, mosi, sclk}
    wire [PAD_SYNC_W-1:0] pads = {spis_cs_n_i, spis_mosi_i, spis_sclk_i};

    // the DMA source: a received byte waiting (the SPI slave has no TX DMA)
    wire [DMACTL_W-1:0] dma_src = {1'b0, rxvalid};
    wire [WORD_W-1:0] shim_prdata;
    wire [WORD_W-1:0] dma_rdata;
    garuda_apb_shim #(
        .N_EVT(3),
        .IP_LIMIT(IP_LIMIT), .IP_MAP(IP_MAP), .BLOCK_NUM(BLOCK_NUM), .BLOCK_REV(8'd1)
    ) u_shim (
        .pclk(pclk), .preset_n(preset_n),
        .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i),
        .paddr_i(paddr_i), .pwdata_i(pwdata_i), .prdata_o(shim_prdata),
        .pready_o(pready_o), .pslverr_o(pslverr_o),
        .ip_psel_o(ip_psel), .ip_prdata_i(reg_rdata),
        .evt_i(evt), .irq_o(irq_o));

    // DMACTL and the request (D-39: only the blocks with a DMA channel)
    garuda_apb_dma u_dma (
        .pclk(pclk), .preset_n(preset_n),
        .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i),
        .paddr_i(paddr_i), .pwdata_i(pwdata_i), .rdata_o(dma_rdata),
        .src_i(dma_src), .dma_ack_i(dma_ack_i), .dma_req_o(dma_req_o));
    assign prdata_o = shim_prdata | dma_rdata;

    // pad input synchronisers (F4: out of the shim)
    // cs_n idles HIGH
    garuda_pad_sync #(.WIDTH(PAD_SYNC_W), .IDLE(8'h04)) u_sync (
        .pclk(pclk), .preset_n(preset_n), .pad_i(pads), .sync_o(pad_sync)
    );


endmodule
