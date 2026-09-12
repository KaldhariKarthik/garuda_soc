`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 6: AHB-Lite Interconnect
// ahb_arbiter.v - fixed-priority master arbiter + address/data phase tracker
//
// Spec reference: GARUDA-AHB-SPEC-001 Rev 2.0, Sec. 3.1, Sec. 7.2, Sec. 7.3,
//                 Sec. 7.4, Sec. 7.5, Sec. 8.5, Sec. 8.6
//
// This module owns every piece of state in the interconnect: which master
// holds the ADDRESS phase (grant_o), which master owns the DATA phase now in
// flight (dph_master_o / dph_valid_o), and whether the address phase currently
// presented has been accepted yet (the grant freeze).
//
// -----------------------------------------------------------------------------
// 1. WHY THE GRANT MUST BE FROZEN WHILE HREADY IS LOW  (Sec. 7.2)
// -----------------------------------------------------------------------------
// The priority pick is combinational, but the winner cannot be allowed to
// change while an address phase is being held. The DMA is the concrete threat:
// dma_ahb_master leaves S_IDLE on its internal beat-start handshake, which is
// NOT qualified with the external HREADY. So the DMA can raise HTRANS from
// IDLE to NONSEQ in the middle of another master's wait state. A combinational
// grant would then swing HADDR/HSIZE/HWRITE under a live address phase that
// the slave has not yet accepted - the exact "two transfers corrupted, no
// error flagged anywhere" failure Sec. 7.2 describes.
//
// hold_r freezes grant_o from the first cycle an address phase is presented
// until the cycle the slave accepts it (HREADY high). Within that window no
// request change, from any master, can move the bus.
//
// -----------------------------------------------------------------------------
// 2. WHY THE GRANT IS *NOT* PINNED TO THE DATA-PHASE OWNER  (ERRATUM AHB-2)
// -----------------------------------------------------------------------------
// Sec. 7.2 says: on each HREADY-high boundary, "if any master still requests,
// re-sample and re-latch". Sec. 7.3 says an ungranted master is held by driving
// its HREADY low. Applied literally, together, they lose read data - because an
// AHB-Lite master has no HGRANT and so cannot tell "your data phase completed"
// apart from "your address phase was accepted". The full argument, and the
// response-capture mechanism that resolves it, are in ahb_master_port.v.
//
// What matters HERE is the rule this arbiter does NOT implement, and why it was
// removed after being written:
//
//     force_owner = dph_valid && req[dph_master]      // <-- DELETED
//
// Keeping the bus pinned to whichever master owns the data phase for as long as
// it is still requesting makes the hand-off trivially safe, and it starves the
// DMA. garuda_iport_ahb_master sustains one fetch per cycle whenever the
// prefetch buffer is popped every cycle - straight-line code at 1 IPC - so the
// LOWEST-priority master would hold an unbounded lock on the bus and the DMA
// would never get a beat. That defeats the entire rationale for fixed priority
// in Sec. 7.1 ("a stalled DMA can overflow a peripheral RX FIFO and lose sensor
// data"), and it defeats it silently: every transfer still completes correctly,
// just far too late for a 1 kHz sensor loop.
//
// With the response hold in ahb_master_port.v, priority applies unconditionally
// at every HREADY-high boundary and this arbiter is a plain priority encoder
// plus the freeze above. Do not reintroduce force_owner.
//
// -----------------------------------------------------------------------------
// 3. BURST CONTINUITY ACROSS A GRANT CHANGE  (ERRATUM AHB-3, Sec. 8.5)
// -----------------------------------------------------------------------------
// Sec. 8.5 says an interrupted I-Port INCR burst "resumes later with a fresh
// NONSEQ". The frozen I-Port RTL does not do that: garuda_iport_ahb_master
// only re-arms need_nonseq on paths where it drives IDLE. When it is merely
// held by HREADY=0 it keeps presenting the same SEQ beat, and re-presents it
// unchanged when re-granted. The slave side would then see
//
//     NONSEQ(I) ... NONSEQ(DMA) NONSEQ(DMA) ... SEQ(I)
//
// - a SEQ with no open burst from the slave's point of view, which
// tb/ahb/ahb_lite_checker.v flags as v_seq_no_burst and which a slave doing
// burst-address prediction would mispredict.
//
// Fixed on the interconnect side rather than by touching the frozen core
// boundary: seq_break_o is raised for the first accepted transfer after the
// address-phase owner changes, and the master mux rewrites HTRANS SEQ->NONSEQ
// for that one transfer. The rewrite is one-way and therefore always safe -
// NONSEQ is legal at any address and simply opens a new undefined-length INCR
// burst - whereas the converse (forcing SEQ) never happens.
// =============================================================================

`include "ahb_defs.vh"

module ahb_arbiter (
    input  wire        hclk_i,
    input  wire        hreset_n_i,

    // Per-master HTRANS, flattened: htrans_i[2*m +: 2] is master m.
    input  wire [`AHB_NMASTERS*2-1:0] htrans_i,

    // Shared HREADY from the data-phase slave (ahb_slave_mux).
    input  wire        hready_i,

    // ---- address phase ----
    output wire [1:0]  grant_o,       // master owning the address phase
    output wire        seq_break_o,   // rewrite this transfer's SEQ to NONSEQ

    // ---- data phase ----
    output reg         dph_valid_o,   // a data phase is in flight
    output reg  [1:0]  dph_master_o   // ... and this master owns it
);

    // -----------------------------------------------------------------------
    // Requests. HTRANS[1] is set for NONSEQ and SEQ, clear for IDLE and BUSY.
    // BUSY counts as "not requesting": none of the three GARUDA masters ever
    // emits it, and treating it as a request would hand the bus to a master
    // that has explicitly said it has nothing to transfer this cycle.
    // -----------------------------------------------------------------------
    wire [`AHB_NMASTERS-1:0] req;
    genvar g;
    generate
        for (g = 0; g < `AHB_NMASTERS; g = g + 1) begin : g_req
            assign req[g] = htrans_i[2*g + 1];
        end
    endgenerate

    // -----------------------------------------------------------------------
    // Fixed priority: DMA > D-Port > I-Port (Sec. 7.1). Written as a plain
    // descending cascade rather than a loop so the priority order is legible
    // in the source and cannot be inverted by an off-by-one in a scan.
    // With no requester the winner is the I-Port, whose HTRANS is IDLE in that
    // case, so the slave side sees an idle bus.
    // -----------------------------------------------------------------------
    wire [1:0] winner = req[`AHB_M_DMA]   ? `AHB_M_DMA   :
                        req[`AHB_M_DPORT] ? `AHB_M_DPORT :
                                            `AHB_M_IPORT ;

    // -----------------------------------------------------------------------
    // Grant freeze (see header Sec. 1). hold_r is set for every cycle that
    // follows an unaccepted address phase, and cleared by acceptance.
    // -----------------------------------------------------------------------
    reg [1:0] grant_r;
    reg       hold_r;

    assign grant_o = hold_r ? grant_r : winner;

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            grant_r <= `AHB_M_IPORT;
            hold_r  <= 1'b0;
        end else begin
            grant_r <= grant_o;
            hold_r  <= ~hready_i;   // not accepted this cycle -> freeze it
        end
    end

    // -----------------------------------------------------------------------
    // Data-phase tracking (Sec. 7.4, Sec. 7.5).
    //
    // An address phase is accepted on a cycle where HREADY is high. What is
    // captured is the transfer that was on the bus in THAT cycle: its owner
    // and whether it was a real transfer at all. Everything downstream that
    // has to answer "whose data phase is this?" - the HWDATA mux, the HRDATA
    // return, the HRESP return, the per-master HREADY gate - reads these two
    // registers and nothing else.
    //
    // The HWDATA mux in particular MUST use dph_master_o, not grant_o. See
    // ERRATUM AHB-1 in ahb_master_mux.v.
    // -----------------------------------------------------------------------
    wire [1:0] granted_htrans = htrans_i[2*grant_o +: 2];

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            dph_valid_o  <= 1'b0;
            dph_master_o <= `AHB_M_IPORT;
        end else if (hready_i) begin
            dph_valid_o  <= granted_htrans[1];
            dph_master_o <= grant_o;
        end
    end

    // -----------------------------------------------------------------------
    // ERRATUM AHB-3 (see header Sec. 3): flag the first accepted transfer
    // after the address-phase owner changes, so the master mux can turn a
    // stale SEQ into a fresh NONSEQ.
    //
    // last_owner_r tracks the master of the last ACCEPTED transfer (HTRANS[1]
    // high on an HREADY-high cycle). Idle cycles do not update it, because an
    // idle cycle does not interrupt a burst on the slave side - only another
    // master's transfer does.
    // -----------------------------------------------------------------------
    reg [1:0] last_owner_r;
    reg       last_owner_v;

    assign seq_break_o = ~last_owner_v || (last_owner_r != grant_o);

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            last_owner_r <= `AHB_M_IPORT;
            last_owner_v <= 1'b0;
        end else if (hready_i && granted_htrans[1]) begin
            last_owner_r <= grant_o;
            last_owner_v <= 1'b1;
        end
    end

endmodule

`default_nettype wire
