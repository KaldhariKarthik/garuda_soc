// =============================================================================
// GARUDA SoC - shared peripheral shim (APB window front end)
// garuda_apb_shim.v
//
// Spec: Docs/DECISIONS.md D-21 (peripheral IRQ / DMA contract), D-6 (window
//       map), D-16 (dma_ack width), D-17 (held level interrupts);
//       GARUDA-AHB2APB-SPEC-001 Sec.7.4 (word-only), Sec.7.5 (16-pclk timeout),
// Sec.7.7 (PSLVERR); GARUDA-CLIC-SPEC-001 Sec.7.2 (level-triggered sources).
//
// Every peripheral window in this chip presents the same front end, whatever
// the IP behind it does natively. This module is that front end, instantiated
// once per block, so the contract is implemented once and reviewed once.
//
// -----------------------------------------------------------------------------
// WHAT IT DOES
// -----------------------------------------------------------------------------
//  1. Decode. A word-aligned offset below IP_LIMIT whose bit is set in IP_MAP
//     goes to the IP; 0xFE0..0xFEC are the GARUDA tail below; anything else
//     answers PSLVERR. The upstream IPs all tie PSLVERR low, so without this an
//     access to an unmapped offset inside a window would read garbage instead
//     of faulting.
//     IP_MAP is the register map of the IP, one bit per word: bit n set means
//     offset 4n is a register. Before 2026-10-13 everything below IP_LIMIT was
//     passed on, so a hole in the vendored register file (GPIO 0x20, 0x2C to
//     0x7C; SPI master 0x1C, 0x2C to 0xFC; I2C 0x1C) and every offset that is
// not word aligned answered without an error (Docs/bugs/archive/BUGS_HISTORY.md
// AUD-13, GPIO-2).
//     The rule of the chip is one: PSLVERR exactly where there is no register.
//  2. PREADY is driven high, always. The bridge abandons a transfer after 16
//     pclk ([N-7.15]), so a peripheral must never stall; ip_pready_i is
//     ignored for the response and watched by an assertion instead.
//  3. Interrupts. evt_i may be a pulse (SPI events_o), a read-to-clear level
//     (GPIO) or a state bit (16550 IIR). Each bit is captured STICKY here, so
//     the line the CLIC sees is a held level that only firmware clears - the
//     D-17 rule, applied uniformly rather than per IP.
//  4. (D-39, 2026-11-18) DMA request and DMACTL: garuda_apb_dma, only in the
//     blocks with a DMA channel; DMACTL reads 0 in the others. Before:
//     DMA request with hold-off. dma_chan.v takes exactly one beat per request
//     assertion (its taken_q clears only when req drops), so a FIFO-level
//     request that stays high would move one beat and then stall forever.
//     req_o therefore drops for one pclk after every dma_ack_i.
//  5. (F4) Pad input synchronisers: garuda_pad_sync / garuda_sync_bit, in the
//     wrappers with pads. Before: Pad input synchronisers, (SYNC_W bits). Their
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
// 0xFE8 DMACTL RW [0] request on RX data, [1] request on TX space
//   0xFEC ID       RO            {16'h6A5D, block number, revision}
//
// DMACTL[1:0] are meant to be used one at a time: a window owns one DMA
// channel, and that channel's MODE already fixes the direction. Setting both
// ORs the two conditions.
// =============================================================================

module garuda_apb_shim
    import garuda_pkg::*;
#(
    parameter int unsigned N_EVT = 32'd4,  // interrupt sources from the IP
    // offsets < IP_LIMIT belong to the IP (at most 0x100)
    parameter [11:0]  IP_LIMIT  = 12'h100,
    // bit n: offset 4n is a register of the IP
    parameter [63:0]  IP_MAP    = {64{1'b1}},
                                            //     byte-addressed IP (16550)
    parameter [7:0]   BLOCK_NUM = 8'd0,
    parameter [7:0]   BLOCK_REV = 8'd1
)(
    input wire pclk,
    input wire preset_n,
    // ---- APB from the bridge ------------------------------------------------
    input wire psel_i,
    input wire penable_i,
    input wire pwrite_i,
    input wire [PADDR_W-1:0] paddr_i,
    input wire [WORD_W-1:0] pwdata_i,
    output reg [WORD_W-1:0] prdata_o,
    output wire pready_o,
    output wire pslverr_o,
    // ---- APB to the vendored IP ---------------------------------------------
    output wire ip_psel_o,
    input wire [WORD_W-1:0] ip_prdata_i,
    // ---- interrupts ---------------------------------------------------------
    input wire [N_EVT - 1:0] evt_i,
    output wire irq_o
);
    timeunit 1ns;
    timeprecision 1ps;

    localparam [11:0] A_IRQSTAT = 12'hFE0, A_IRQEN = 12'hFE4,
                      A_DMACTL  = 12'hFE8, A_ID    = 12'hFEC;

    wire apb_access = psel_i & penable_i;
    wire wr     = apb_access & pwrite_i;

    // a register of the IP: below the limit, word aligned, and in the map
    // (IP_LIMIT is at most 0x100: below it means [11:8] zero and, unless the
    // limit is 0x100, [7:0] below its low byte; two compares of 8 bits or less)
    wire below = ~|paddr_i[11:8]
        && (IP_LIMIT[8] || (paddr_i[7:0] < IP_LIMIT[7:0]));
    wire in_ip = below && (paddr_i[1:0] == 2'b00) && IP_MAP[paddr_i[7:2]];
    wire in_tail = at12(paddr_i, A_IRQSTAT) | at12(paddr_i, A_IRQEN) |
                   at12(paddr_i, A_DMACTL)  | at12(paddr_i, A_ID);
    wire hit     = in_ip | in_tail;

    // =========================================================================
    // IP-side APB. ADDR_SHIFT=2 turns our word offsets 0x00,0x04,... into the
    // 16550's byte register indices 0,1,2,... (apb_uart_sv uses PADDR[2:0]).
    // =========================================================================
    assign ip_psel_o    = psel_i & in_ip;
    // the IP takes PENABLE, PWRITE, PADDR and PWDATA from the bus itself (F4:
    // the shim's copies were feedthroughs); only its PSEL is decoded here

    // =========================================================================
    // Interrupt status: sticky capture, W1C
    // =========================================================================
    reg [N_EVT-1:0] irqstat_q;
    reg [N_EVT-1:0] irqen_q;
    wire [N_EVT-1:0] w1c = (wr && at12(paddr_i, A_IRQSTAT)) ? pwdata_i[N_EVT-1:0]
                                                        : {N_EVT{1'b0}};
    always_ff @(posedge pclk or negedge preset_n) begin : p_irqstat
        if (!preset_n) begin
            irqstat_q <= {N_EVT {1'b0}};
            irqen_q <= {N_EVT {1'b0}};
        end else begin
            // set beats clear: an event arriving in the same cycle as its W1C
            // is not lost (the DSU's FLAG-E rule, applied here)
            irqstat_q <= (irqstat_q & ~w1c) | evt_i;
            if (wr && at12(paddr_i, A_IRQEN)) begin
                irqen_q <= pwdata_i[N_EVT - 1:0];
            end
        end
    end
    assign irq_o = (irqstat_q & irqen_q) != '0;

    // =========================================================================
    // Response
    // =========================================================================
    always_comb begin : c_prdata
        if (in_ip) begin
            prdata_o = ip_prdata_i;
        end else if (at12(paddr_i, A_IRQSTAT)) begin
            prdata_o = {{(32 - N_EVT) {1'b0}}, irqstat_q};
        end else if (at12(paddr_i, A_IRQEN)) begin
            prdata_o = {{(32 - N_EVT) {1'b0}}, irqen_q};
        // A_DMACTL reads 0 here: the blocks with a DMA channel OR in their
        // DMACTL from garuda_apb_dma (D-39)
        end else if (at12(paddr_i, A_ID)) begin
            prdata_o = {16'h6A5D, BLOCK_NUM, BLOCK_REV};
        end else begin
            prdata_o = 32'd0;
        end
    end

    assign pready_o  = 1'b1;  // never stall the bridge
    assign pslverr_o = apb_access & ~hit;

    // IP_MAP covers 0x000..0x0FC: a larger IP_LIMIT stops elaboration (F4: a
    // generate check, not a simulation-only $finish)
    generate if (IP_LIMIT > 12'h100) begin : g_ip_limit_above_0x100
        // no such module: elaboration stops here
        garuda_apb_shim_IP_LIMIT_must_be_at_most_0x100 u_stop ();
    end endgenerate

endmodule
