`timescale 1ns/1ps
`default_nettype none
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

module garuda_spis_top #(
    parameter [7:0]   BLOCK_NUM = 8'd14,
    parameter integer FIFO_DEPTH = 16
)(
    input  wire        pclk_i,
    input  wire        preset_n_i,

    // ---- APB slave, window 0 -------------------------------------------------
    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [11:0] paddr_i,
    input  wire [31:0] pwdata_i,
    output wire [31:0] prdata_o,
    output wire        pready_o,
    output wire        pslverr_o,

    // ---- CLIC ID 14 / DMA channel 4 ------------------------------------------
    output wire        irq_o,
    output wire        dma_req_o,
    input  wire        dma_ack_i,

    // ---- pins 29-32 ------------------------------------------------------------
    input  wire        spis_sclk_i,
    input  wire        spis_mosi_i,
    input  wire        spis_cs_n_i,
    output wire        spis_miso_o,
    output wire        spis_miso_oe_o
);

    localparam [11:0] A_RXDATA = 12'h000, A_TXDATA = 12'h004,
                      A_CTRL   = 12'h008, A_STATUS = 12'h00C;
    localparam [11:0] IP_LIMIT = 12'h020;

    wire        ip_psel, ip_penable, ip_pwrite;
    wire [11:0] ip_paddr;
    wire [31:0] ip_pwdata;
    wire [1:0]  dmactl;
    wire [2:0]  pad_sync;

    wire sclk_s = pad_sync[0];
    wire mosi_s = pad_sync[1];
    wire cs_n_s = pad_sync[2];

    wire wr_hit = ip_psel & ip_penable & ip_pwrite;
    wire        tail_w1c;
    wire [2:0]  irqstat_clr;
    wire rd_hit = ip_psel & ip_penable & ~ip_pwrite;

    // =========================================================================
    // Registers
    // =========================================================================
    reg        en_q;
    reg [7:0]  txdata_q;
    reg        ovr_q, done_q;

    wire rxflush = wr_hit & (ip_paddr == A_CTRL) & pwdata_i[1];

    // =========================================================================
    // The shift engine
    // =========================================================================
    wire [7:0] rx_byte;
    wire       rx_push, cs_active, cs_rise, cs_fall;

    garuda_spis_core u_core (
        .pclk_i(pclk_i), .preset_n_i(preset_n_i), .en_i(en_q),
        .sclk_s_i(sclk_s), .mosi_s_i(mosi_s), .cs_n_s_i(cs_n_s),
        .miso_o(spis_miso_o), .miso_oe_o(spis_miso_oe_o),
        .txdata_i(txdata_q),
        .rx_byte_o(rx_byte), .rx_push_o(rx_push),
        .cs_active_o(cs_active), .cs_rise_o(cs_rise), .cs_fall_o(cs_fall));

    // =========================================================================
    // RX FIFO. On overrun the NEW byte is dropped, not the oldest: that
    // truncates a packet rather than interleaving it, and a truncated packet
    // fails its checksum while an interleaved one might not ([N-7.5]).
    // =========================================================================
    localparam integer AW = (FIFO_DEPTH <= 16) ? 4 : 5;

    reg [7:0]    fifo [0:FIFO_DEPTH-1];
    reg [AW:0]   wptr, rptr;
    wire [AW:0]  level = wptr - rptr;
    wire         full  = (level == FIFO_DEPTH[AW:0]);
    wire         empty = (level == 0);

    wire pop  = rd_hit & (ip_paddr == A_RXDATA) & ~empty;
    wire push = rx_push & ~full;

    integer k;
    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            wptr <= 0; rptr <= 0;
            for (k = 0; k < FIFO_DEPTH; k = k + 1) fifo[k] <= 8'd0;
        end else if (rxflush) begin
            wptr <= 0; rptr <= 0;
        end else begin
            if (push) begin
                fifo[wptr[AW-1:0]] <= rx_byte;
                wptr <= wptr + 1'b1;
            end
            if (pop) rptr <= rptr + 1'b1;
        end
    end

    wire rxvalid = ~empty;

    // =========================================================================
    // Status and control
    // =========================================================================
    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            en_q <= 1'b0; txdata_q <= 8'd0; ovr_q <= 1'b0; done_q <= 1'b0;
        end else begin
            if (wr_hit) begin
                case (ip_paddr)
                    A_CTRL:   en_q     <= pwdata_i[0];
                    A_TXDATA: txdata_q <= pwdata_i[7:0];
                    default: ;
                endcase
            end
            if (rx_push & full) ovr_q  <= 1'b1;      // sticky ([N-7.5])
            if (cs_rise)        done_q <= 1'b1;      // sticky
            // both clear with their interrupt bits, so there is one place to
            // acknowledge a fault rather than two
            if (irqstat_clr[2]) ovr_q  <= 1'b0;
            if (irqstat_clr[1]) done_q <= 1'b0;
        end
    end

    assign tail_w1c    = psel_i & penable_i & pwrite_i & (paddr_i == 12'hFE0);
    assign irqstat_clr = tail_w1c ? pwdata_i[2:0] : 3'd0;

    // =========================================================================
    // Events (D-21)
    // =========================================================================
    wire [2:0] evt;
    assign evt[0] = rx_push;                  // a byte arrived
    assign evt[1] = cs_rise;                  // packet complete
    assign evt[2] = rx_push & full;           // overrun

    // =========================================================================
    // Read mux
    // =========================================================================
    wire [31:0] reg_rdata =
        (ip_paddr == A_RXDATA) ? {24'd0, empty ? 8'd0 : fifo[rptr[AW-1:0]]} :
        (ip_paddr == A_TXDATA) ? {24'd0, txdata_q}                          :
        (ip_paddr == A_CTRL)   ? {31'd0, en_q}                              :
        (ip_paddr == A_STATUS) ? {23'd0, level[4:0], done_q, ovr_q,
                                         cs_active, rxvalid}                :
                                 32'd0;

    garuda_apb_shim #(
        .N_EVT(3), .SYNC_W(3), .SYNC_RESET(8'h04), // cs_n idles HIGH
        .IP_LIMIT(IP_LIMIT), .ADDR_SHIFT(0),
        .BLOCK_NUM(BLOCK_NUM), .BLOCK_REV(8'd1)
    ) u_shim (
        .pclk_i(pclk_i), .preset_n_i(preset_n_i),
        .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i),
        .paddr_i(paddr_i), .pwdata_i(pwdata_i), .prdata_o(prdata_o),
        .pready_o(pready_o), .pslverr_o(pslverr_o),
        .ip_psel_o(ip_psel), .ip_penable_o(ip_penable), .ip_pwrite_o(ip_pwrite),
        .ip_paddr_o(ip_paddr), .ip_pwdata_o(ip_pwdata), .ip_prdata_i(reg_rdata),
        .ip_pready_i(1'b1),
        .evt_i(evt), .irq_o(irq_o),
        .rx_avail_i(rxvalid), .tx_space_i(1'b0),
        .dma_ack_i(dma_ack_i), .dma_req_o(dma_req_o), .dmactl_o(dmactl),
        .pad_async_i({spis_cs_n_i, spis_mosi_i, spis_sclk_i}),
        .pad_sync_o(pad_sync));

    wire _unused = |{dmactl, ip_pwdata, cs_fall};

endmodule

`default_nettype wire
