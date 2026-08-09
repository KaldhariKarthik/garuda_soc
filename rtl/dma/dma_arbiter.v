`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 9: DMA Controller
// dma_arbiter.v - 8-level fixed-priority arbiter, purely combinational
//
// Spec reference: GARUDA-DMA-SPEC-001 Rev 2.0, Sec. 3.1 (#4), Sec. 8, Sec. 16.2
//
// ALGORITHM (Sec. 8.2, transcribed exactly)
//   Scan channels 0 through 5. Track the highest priority seen so far. If a
//   requesting channel's priority EXCEEDS the current winner, it becomes the
//   new winner. If equal, the earlier channel (lower index) wins because the
//   scan started there.
// The strict ">" is what implements the lowest-index tiebreak of Sec. 2 and
// Sec. 8.2 - changing it to ">=" silently inverts the tiebreak to highest
// index and breaks the "Multi-ch - Tiebreak" test in Sec. 14.
//
// NO STATE, BY DESIGN (Sec. 16.2)
// Fixed priority with no round-robin pointer means this block holds nothing
// across cycles. Starvation is argued away in Sec. 16.2 on bus-utilisation
// grounds (<4%), not prevented by construction - that is the spec's decision
// and it is recorded here so nobody "fixes" it into a round-robin later and
// breaks the IMU latency guarantee of Sec. 1.3.
//
// WHAT THIS BLOCK DOES **NOT** DO - READ THIS BEFORE CHANGING dma_top
// The arbiter re-evaluates every cycle (Sec. 3.1). That is NOT the same as the
// bus switching owner every cycle. If ch_sel_o were wired straight to the AHB
// master's address mux, a higher-priority channel raising its request in the
// middle of a beat would swing HADDR mid-transaction and corrupt both
// transfers. The grant is therefore LATCHED for the duration of a beat by
// dma_ahb_master (ch_lock_o), and a new beat can only start when that master
// is idle. Per-beat re-evaluation (Sec. 8.3) is delivered by the beat
// boundary, not by the arbiter's own timing.
//
// Priorities arrive as each channel's LATCHED working copy (pri_r, captured in
// CONFIGURED) rather than a live CR.PRI read. Functionally identical - Sec.
// 16.5 states priority is set once at init and never changed mid-flight - but
// it keeps a pclk-domain register out of an hclk combinational path.
// =============================================================================

`include "dma_defs.vh"

module dma_arbiter (
    // One bit per channel: asserted while that channel is in
    // WAITING_FOR_REQUEST *and* its transfer trigger is present (Sec. 7.5).
    input  wire [`DMA_NCH-1:0]   ch_req_i,

    // Flattened 3-bit priority per channel: ch_pri_i[3*n +: 3] is channel n.
    // Verilog-2001 has no 2-D ports, hence the flattening.
    input  wire [`DMA_NCH*3-1:0] ch_pri_i,

    output reg                   grant_o,    // 1 = some channel wins
    output reg  [2:0]            ch_sel_o    // binary index of the winner
);

    integer      n;
    reg [2:0]    best_pri;
    reg [2:0]    this_pri;

    always @(*) begin
        grant_o  = 1'b0;
        ch_sel_o = 3'd0;
        best_pri = 3'd0;

        for (n = 0; n < `DMA_NCH; n = n + 1) begin
            this_pri = ch_pri_i[3*n +: 3];
            // First requester seen wins outright (grant_o still low); after
            // that only a STRICTLY higher priority displaces the incumbent.
            if (ch_req_i[n] && (!grant_o || (this_pri > best_pri))) begin
                grant_o  = 1'b1;
                ch_sel_o = n[2:0];
                best_pri = this_pri;
            end
        end
    end

endmodule

`default_nettype wire
