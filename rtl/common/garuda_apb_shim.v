`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - shared peripheral shim (APB window front end)
// garuda_apb_shim.v
//
// Spec: Docs/DECISIONS.md D-21 (peripheral IRQ / DMA contract), D-6 (window
//       map), D-16 (dma_ack width), D-17 (held level interrupts);
//       GARUDA-AHB2APB-SPEC-001 §7.4 (word-only), §7.5 (16-pclk timeout),
//       §7.7 (PSLVERR); GARUDA-CLIC-SPEC-001 §7.2 (level-triggered sources).
//
// Every peripheral window in this chip presents the same front end, whatever
// the IP behind it does natively. This module is that front end, instantiated
// once per block, so the contract is implemented once and reviewed once.
//
// -----------------------------------------------------------------------------
// WHAT IT DOES
// -----------------------------------------------------------------------------
//  1. Decode. Offsets below IP_LIMIT go to the IP; 0xFE0..0xFEC are the GARUDA
//     tail below; anything else answers PSLVERR. The upstream IPs all tie
//     PSLVERR low, so without this an access to an unmapped offset inside a
//     window would read garbage instead of faulting.
//  2. PREADY is driven high, always. The bridge abandons a transfer after 16
//     pclk ([N-7.15]), so a peripheral must never stall; ip_pready_i is
//     ignored for the response and watched by an assertion instead.
//  3. Interrupts. evt_i may be a pulse (SPI events_o), a read-to-clear level
//     (GPIO) or a state bit (16550 IIR). Each bit is captured STICKY here, so
//     the line the CLIC sees is a held level that only firmware clears - the
//     D-17 rule, applied uniformly rather than per IP.
//  4. DMA request with hold-off. dma_chan.v takes exactly one beat per request
//     assertion (its taken_q clears only when req drops), so a FIFO-level
//     request that stays high would move one beat and then stall forever.
//     req_o therefore drops for one pclk after every dma_ack_i.
//  5. Pad input synchronisers, for the wrapper to use (SYNC_W bits). Their
//     RESET VALUE is SYNC_RESET, one bit per pad, because a synchroniser that
//     resets to the wrong idle level presents a false signal to the IP for two
//     pclk out of reset. For a UART that is a low rx line, which is a start
//     bit: the receiver frames a garbage byte at power-on and every read from
//     then on returns the previous byte. Set it to the pad's idle state.
//
// -----------------------------------------------------------------------------
// REGISTER TAIL (same in every window)
// -----------------------------------------------------------------------------
//   0xFE0 IRQSTAT  W1C, sticky   one bit per evt_i
//   0xFE4 IRQEN    RW            irq_o = |(IRQSTAT & IRQEN)
//   0xFE8 DMACTL   RW            [0] request on RX data, [1] request on TX space
//   0xFEC ID       RO            {16'h6A5D, block number, revision}
//
// DMACTL[1:0] are meant to be used one at a time: a window owns one DMA
// channel, and that channel's MODE already fixes the direction. Setting both
// ORs the two conditions.
// =============================================================================

module garuda_apb_shim #(
    parameter integer N_EVT     = 4,        // interrupt sources from the IP
    parameter integer SYNC_W    = 1,        // asynchronous pad inputs to sync
    parameter [7:0]   SYNC_RESET = 8'h00,   // idle level of each synced pad
    parameter [11:0]  IP_LIMIT  = 12'h100,  // offsets < IP_LIMIT belong to the IP
    parameter integer ADDR_SHIFT = 0,       // 2 = re-map word offsets onto a
                                            //     byte-addressed IP (16550)
    parameter [7:0]   BLOCK_NUM = 8'd0,
    parameter [7:0]   BLOCK_REV = 8'd1
)(
    input  wire        pclk_i,
    input  wire        preset_n_i,

    // ---- APB from the bridge ------------------------------------------------
    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [11:0] paddr_i,
    input  wire [31:0] pwdata_i,
    output reg  [31:0] prdata_o,
    output wire        pready_o,
    output wire        pslverr_o,

    // ---- APB to the vendored IP ---------------------------------------------
    output wire        ip_psel_o,
    output wire        ip_penable_o,
    output wire        ip_pwrite_o,
    output wire [11:0] ip_paddr_o,
    output wire [31:0] ip_pwdata_o,
    input  wire [31:0] ip_prdata_i,
    input  wire        ip_pready_i,        // watched, not used (see assertion)

    // ---- interrupts ---------------------------------------------------------
    input  wire [N_EVT-1:0] evt_i,
    output wire             irq_o,

    // ---- DMA ----------------------------------------------------------------
    input  wire        rx_avail_i,         // IP has a byte/word to read
    input  wire        tx_space_i,         // IP can accept a byte/word
    input  wire        dma_ack_i,          // 2 hclk = 1 pclk (D-16)
    output wire        dma_req_o,
    output wire [1:0]  dmactl_o,           // exposed so the wrapper can gate

    // ---- pad input synchronisers --------------------------------------------
    input  wire [SYNC_W-1:0] pad_async_i,
    output wire [SYNC_W-1:0] pad_sync_o
);

    localparam [11:0] A_IRQSTAT = 12'hFE0, A_IRQEN = 12'hFE4,
                      A_DMACTL  = 12'hFE8, A_ID    = 12'hFEC;

    wire access = psel_i & penable_i;
    wire wr     = access & pwrite_i;

    wire in_ip   = (paddr_i < IP_LIMIT);
    wire in_tail = (paddr_i == A_IRQSTAT) | (paddr_i == A_IRQEN) |
                   (paddr_i == A_DMACTL)  | (paddr_i == A_ID);
    wire hit     = in_ip | in_tail;

    // =========================================================================
    // IP-side APB. ADDR_SHIFT=2 turns our word offsets 0x00,0x04,... into the
    // 16550's byte register indices 0,1,2,... (apb_uart_sv uses PADDR[2:0]).
    // =========================================================================
    assign ip_psel_o    = psel_i & in_ip;
    assign ip_penable_o = penable_i;
    assign ip_pwrite_o  = pwrite_i;
    assign ip_paddr_o   = (ADDR_SHIFT == 0) ? paddr_i : (paddr_i >> ADDR_SHIFT);
    assign ip_pwdata_o  = pwdata_i;

    // =========================================================================
    // Interrupt status: sticky capture, W1C
    // =========================================================================
    reg [N_EVT-1:0] irqstat_q, irqen_q;
    wire [N_EVT-1:0] w1c = (wr && paddr_i == A_IRQSTAT) ? pwdata_i[N_EVT-1:0]
                                                        : {N_EVT{1'b0}};
    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            irqstat_q <= {N_EVT{1'b0}};
            irqen_q   <= {N_EVT{1'b0}};
        end else begin
            // set beats clear: an event arriving in the same cycle as its W1C
            // is not lost (the DSU's FLAG-E rule, applied here)
            irqstat_q <= (irqstat_q & ~w1c) | evt_i;
            if (wr && paddr_i == A_IRQEN) irqen_q <= pwdata_i[N_EVT-1:0];
        end
    end
    assign irq_o = |(irqstat_q & irqen_q);

    // =========================================================================
    // DMA request with one-pclk hold-off after every ack (D-21)
    // =========================================================================
    reg [1:0] dmactl_q;
    reg       holdoff_q;
    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            dmactl_q  <= 2'b00;
            holdoff_q <= 1'b0;
        end else begin
            if (wr && paddr_i == A_DMACTL) dmactl_q <= pwdata_i[1:0];
            holdoff_q <= dma_ack_i;          // one pclk of guaranteed deassertion
        end
    end
    assign dmactl_o  = dmactl_q;
    assign dma_req_o = ((dmactl_q[0] & rx_avail_i) | (dmactl_q[1] & tx_space_i)) &
                       ~holdoff_q & ~dma_ack_i;

    // =========================================================================
    // Pad input synchronisers
    // =========================================================================
    localparam [SYNC_W-1:0] SYNC_IDLE = SYNC_RESET[SYNC_W-1:0];

    reg [SYNC_W-1:0] sync0_q, sync1_q;
    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            sync0_q <= SYNC_IDLE;
            sync1_q <= SYNC_IDLE;
        end else begin
            sync0_q <= pad_async_i;
            sync1_q <= sync0_q;
        end
    end
    assign pad_sync_o = sync1_q;

    // =========================================================================
    // Response
    // =========================================================================
    always @(*) begin
        if      (in_ip)                 prdata_o = ip_prdata_i;
        else if (paddr_i == A_IRQSTAT)  prdata_o = {{(32-N_EVT){1'b0}}, irqstat_q};
        else if (paddr_i == A_IRQEN)    prdata_o = {{(32-N_EVT){1'b0}}, irqen_q};
        else if (paddr_i == A_DMACTL)   prdata_o = {30'd0, dmactl_q};
        else if (paddr_i == A_ID)       prdata_o = {16'h6A5D, BLOCK_NUM, BLOCK_REV};
        else                            prdata_o = 32'd0;
    end

    assign pready_o  = 1'b1;                       // never stall the bridge
    assign pslverr_o = access & ~hit;

`ifndef SYNTHESIS
    // The one upstream behaviour that would break the SoC rather than a test:
    // an IP that deasserts PREADY while it finishes a wire transaction. All
    // four vendored IPs tie it high; this fires if a re-vendor changes that.
    always @(posedge pclk_i)
        if (preset_n_i && ip_psel_o && !ip_pready_i)
            $display("[SHIM-ASSERT] block %0d: IP deasserted PREADY at %0t - the bridge will time out",
                     BLOCK_NUM, $time);
`endif

endmodule

`default_nettype wire
