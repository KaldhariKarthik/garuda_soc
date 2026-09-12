`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 6: AHB-Lite Interconnect
// ahb_default_slave.v - two-cycle ERROR responder for unmapped addresses
//
// Spec reference: GARUDA-AHB-SPEC-001 Rev 2.0, Sec. 1.4, Sec. 3.1, Sec. 8.4,
//                 Sec. 13.3
//
// Sec. 13.3 states the case for this block better than a comment can: without
// it an unmapped address leaves HREADY never asserted and the master hangs
// forever, which on a bring-up board looks like a dead CPU and costs days. A
// compliant ERROR turns it into a precise instruction/load/store access fault
// with mepc pointing at the offending instruction.
//
// -----------------------------------------------------------------------------
// WHY THE RESPONSE IS EXACTLY TWO CYCLES, AND WHY THAT IS NOT NEGOTIABLE
// -----------------------------------------------------------------------------
//   cycle 1 (S_ERR1):  HREADYOUT=0, HRESP=ERROR
//                      the address phase in flight is NOT accepted this cycle
//   cycle 2 (S_ERR2):  HREADYOUT=1, HRESP=ERROR
//                      the transfer completes with an error
//
// Sec. 1.4 makes this normative for every slave in the SoC, and the reason is
// dma_ahb_master.v: during a DMA read data phase the WRITE address phase of
// the same beat is already being presented. S_ERR1 is the only warning the DMA
// gets; it uses it to drive HTRANS=IDLE on the next edge so that S_ERR2
// retracts the write instead of committing it. A slave that signalled ERROR in
// a single cycle (HRESP=1 with HREADYOUT=1, no preceding HREADYOUT=0) would
// let one spurious write of stale buffer contents reach the destination after
// the source read had already failed - silent data corruption on a bus fault,
// which is worse than the hang this block exists to prevent.
//
// S_ERR2 can accept a new transfer directly, without passing through S_IDLE:
// HREADYOUT is high in that cycle, so an address phase presented against it IS
// accepted, and a master that faults twice in a row (a runaway PC walking
// through unmapped space is the obvious case) must not have its second fault
// silently swallowed.
//
// This slave takes the shared HREADY like any other slave, so it only latches
// a transfer on an accepted address phase. When idle or deselected it answers
// HREADYOUT=1 / HRESP=OKAY, as AMBA requires - a deselected slave that holds
// HREADYOUT low stalls the whole shared layer.
// =============================================================================

`include "ahb_defs.vh"

module ahb_default_slave (
    input  wire        hclk_i,
    input  wire        hreset_n_i,

    input  wire        hsel_i,
    input  wire [1:0]  htrans_i,
    input  wire        hready_i,      // global HREADY (address phase accepted)

    output wire [31:0] hrdata_o,
    output reg         hreadyout_o,
    output reg         hresp_o
);

    localparam [1:0] S_IDLE = 2'd0,
                     S_ERR1 = 2'd1,
                     S_ERR2 = 2'd2;

    reg [1:0] state;

    // A transfer is taken when this slave is selected, the global HREADY is
    // high (so the address phase completes this cycle) and HTRANS is
    // NONSEQ/SEQ. HTRANS=BUSY is not a transfer and must not be answered.
    wire accept = hsel_i && hready_i && htrans_i[1];

    // Moore outputs: a pure function of state, so the response waveform is
    // identical whatever the address phase is doing around it.
    always @(*) begin
        case (state)
            S_ERR1:  begin hreadyout_o = 1'b0; hresp_o = `AHB_RESP_ERROR; end
            S_ERR2:  begin hreadyout_o = 1'b1; hresp_o = `AHB_RESP_ERROR; end
            default: begin hreadyout_o = 1'b1; hresp_o = `AHB_RESP_OKAY;  end
        endcase
    end

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE:  if (accept) state <= S_ERR1;
                // In S_ERR1 the global HREADY is low (this slave is driving
                // it low), so no address phase can be accepted - `accept` is
                // structurally impossible here and is not tested.
                S_ERR1:  state <= S_ERR2;
                S_ERR2:  state <= accept ? S_ERR1 : S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end

    // Nothing is readable here. Driven to a constant rather than left
    // undriven so no X reaches a master's write-back path on a faulting load.
    assign hrdata_o = 32'h0000_0000;

endmodule

`default_nettype wire
