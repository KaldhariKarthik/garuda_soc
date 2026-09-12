`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 6: AHB-Lite Interconnect
// ahb_master_port.v - per-master hold rule + one-deep response hold
//
// Spec reference: GARUDA-AHB-SPEC-001 Rev 2.0, Sec. 7.1, Sec. 7.3, Sec. 8.2
//
// One instance per master. This is the block's slave-facing view of a single
// AHB-Lite master: it decides what HREADY/HRDATA/HRESP that master sees, and
// it is the only place in the interconnect that can make a master wait.
//
// =============================================================================
// WHY THIS MODULE EXISTS AT ALL - ERRATUM AHB-2
// =============================================================================
// AHB-Lite masters have no HGRANT. A full-AHB master knows when it does not
// own the bus and ignores HREADY; an AHB-Lite master has exactly one wire, and
// HREADY=1 means BOTH of these at once:
//
//     "the data phase you are waiting on has completed"
//     "the address phase you are presenting has been accepted"
//
// An interconnect that wants to preempt such a master mid-stream cannot
// separate them. Consider master A with a read data phase in flight, still
// presenting the next transfer, when higher-priority B arrives:
//
//   - drive A's HREADY low (Sec. 7.3, literally): A holds its address phase,
//     correct - but the slave completed A's read data phase THIS cycle and
//     drives HRDATA for one cycle only. A misses it. Silent data loss.
//   - leave A's HREADY high so it can take its data: A also concludes the
//     address phase it is presenting was accepted, and starts a data phase for
//     a transfer that never reached a slave. Silent data corruption.
//
// The first version of this interconnect dodged the choice by refusing to move
// the grant off a master that was still requesting. That is correct, and it
// starves the DMA, which is the one master that must not be starved:
//
//     garuda_iport_ahb_master sustains one fetch per cycle whenever the
//     prefetch buffer is popped every cycle - i.e. straight-line code at
//     1 IPC. projected_occ settles at 3 and room_for_new_fetch stays true
//     indefinitely, so the I-Port presents HTRANS!=IDLE on every cycle,
//     forever. "Hold the bus while the owner is still asking" then hands the
//     LOWEST-priority master an unbounded lock on the bus, and the DMA - whose
//     whole reason for being top priority is Sec. 7.1's "a stalled DMA can
//     overflow a peripheral RX FIFO and lose sensor data" - never gets a beat.
//
// So the choice has to be faced instead of dodged. This module takes the first
// option, drives A's HREADY low, AND captures the response A would have
// missed, replaying it the cycle A is next granted. From A's point of view its
// transfer simply took extra wait states; from the bus's point of view the
// slave was answered on time and the bus moved on. Fixed priority then holds
// unconditionally, at every beat boundary, exactly as Sec. 7.1 promises.
//
// =============================================================================
// WHY ONE ENTRY IS ENOUGH
// =============================================================================
// A master whose response has been captured is being held with HREADY=0. It
// therefore cannot accept its held address phase, cannot issue a new one, and
// has no further data phase in flight - the interconnect's dph_master moved to
// whoever was granted instead. So no second capture can occur before the first
// is delivered. tb/ahb/tb_ahb_interconnect.sv asserts this directly rather
// than trusting the argument.
//
// =============================================================================
// THE CAPTURED RESPONSE AND THE TWO-CYCLE ERROR
// =============================================================================
// HRESP is captured alongside HRDATA and replayed with it. It is worth being
// explicit about why that is safe, because a replayed ERROR arrives as a
// SINGLE cycle (HREADY=1, HRESP=ERROR) and the two-cycle response is normative
// in Sec. 1.4.
//
// A capture can never coincide with an error completion. Proof: an error
// completes on its second cycle, and the first cycle drove HREADY low. The
// arbiter's grant freeze (hold_r in ahb_arbiter.v) keys off exactly that - any
// cycle preceded by HREADY=0 re-uses the previous grant unchanged - so on the
// completing cycle of an error response the grant cannot have moved, and a
// capture requires the grant to have moved away from the data-phase owner.
//
// The capture is therefore always an OKAY response, and replaying HRESP is
// belt-and-braces: it costs one flop and means the argument above does not
// have to stay true for the design to stay correct. If it were ever violated,
// the master receives a single-cycle ERROR - which garuda_iport_ahb_master and
// d_port_ahb_master both handle (they qualify HRESP with their own
// outstanding-data-phase flag), and which dma_ahb_master does not - but the
// DMA is the highest-priority master and can never be the one preempted.
// =============================================================================

`include "ahb_defs.vh"

module ahb_master_port (
    input  wire        hclk_i,
    input  wire        hreset_n_i,

    // ---- this master's address phase ----
    input  wire [1:0]  htrans_i,

    // ---- arbitration context ----
    input  wire        granted_i,      // the arbiter's grant points at me
    input  wire        dph_own_i,      // the data phase in flight is mine

    // ---- shared slave-side return ----
    input  wire        hready_shared_i,
    input  wire [31:0] hrdata_shared_i,
    input  wire        hresp_shared_i,

    // ---- what this master actually sees ----
    output wire        hready_o,
    output wire [31:0] hrdata_o,
    output wire        hresp_o
);

    // An address phase is on the bus from this master.
    wire presenting = htrans_i[1];

    // Entitled to see the shared HREADY:
    //   - because I am granted, so accepting my address phase is legitimate;
    //   - or because the data phase is mine AND I am presenting nothing, so
    //     HREADY=1 can only mean "your data phase completed" and there is no
    //     address phase for me to mis-accept. This second term is what lets a
    //     master finish its transfer on the very cycle the bus is handed to
    //     somebody else, with no bubble - the common case for the D-Port,
    //     which drives HTRANS=IDLE throughout its data phase, and for the DMA
    //     in S_WDATA.
    wire entitled = granted_i || (dph_own_i && !presenting);

    // Nothing presented and nothing owed -> HREADY=1 unconditionally.
    //
    // This is the deadlock fix. Sec. 7.3 says an ungranted master sees HREADY
    // low; applied to an idle master it means garuda_iport_ahb_master, whose
    // fetch_issue_o is gated on i_hready_i, can never present the HTRANS the
    // arbiter needs in order to grant it - and the reset-vector fetch never
    // happens. A master with nothing in flight has nothing that HREADY=1 could
    // wrongly complete, so gating it buys nothing and costs the bus its
    // ability to start.
    wire pending = presenting || dph_own_i;

    // -----------------------------------------------------------------------
    // Response hold (ERRATUM AHB-2, see header)
    // -----------------------------------------------------------------------
    reg        hold_valid;
    reg [31:0] hold_data;
    reg        hold_resp;

    // The data phase is mine, it completes this cycle, and the bus has been
    // handed to someone else while I am still presenting a transfer. I will
    // not see this response, so keep it.
    wire capture = dph_own_i && !granted_i && presenting && hready_shared_i;

    assign hready_o = pending ? (hready_shared_i && entitled) : 1'b1;

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            hold_valid <= 1'b0;
            hold_data  <= 32'h0000_0000;
            hold_resp  <= `AHB_RESP_OKAY;
        end else if (capture) begin
            hold_valid <= 1'b1;
            hold_data  <= hrdata_shared_i;
            hold_resp  <= hresp_shared_i;
        end else if (hold_valid && hready_o) begin
            // Delivered: the master has taken it in this cycle.
            hold_valid <= 1'b0;
        end
    end

    // -----------------------------------------------------------------------
    // Returns (Sec. 8.2: read data goes only to the master that owned the
    // transfer). A held response outranks the live bus, because the live bus
    // now belongs to a different master's data phase.
    // -----------------------------------------------------------------------
    assign hrdata_o = hold_valid ? hold_data :
                      dph_own_i  ? hrdata_shared_i : 32'h0000_0000;

    assign hresp_o  = hold_valid ? hold_resp :
                      dph_own_i  ? hresp_shared_i : `AHB_RESP_OKAY;

endmodule

`default_nettype wire
