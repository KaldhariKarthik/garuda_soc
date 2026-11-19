// MUTANT A12 (bus plan B1 A9): default slave: one-cycle ERROR
// =============================================================================
// GARUDA SoC - Block 6: AHB-Lite Interconnect
// ahb_dflt_slave.v - two-cycle ERROR responder for unmapped addresses
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

module ahb_dflt_slave
    import garuda_pkg::*;
    import ahb_pkg::*;
(
    input wire hclk,
    input wire hreset_n,
    input wire hsel_i,
    input wire req_i,  // HTRANS[1]: a NONSEQ or SEQ transfer
    input wire hready_i,  // global HREADY (address phase accepted)
    output logic hreadyout_o,
    output logic hresp_o
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned STATE_W = 32'd2;

    // F4 (2026-11-17): the state register and one block for the next state
    // and the outputs (HAL BADFSM); no HRDATA (it was a constant 0, which the
    // slave mux now returns for this slave itself)
    localparam [1:0] S_IDLE = 2'd0,
                     S_ERR1 = 2'd1,
                     S_ERR2 = 2'd2;

    reg [STATE_W-1:0] state;
    logic [STATE_W-1:0] state_next;

    wire accept = hsel_i && hready_i && req_i;

    always_comb begin : c_next
        state_next = state;
        hreadyout_o = 1'b1;
        hresp_o = AHB_RESP_OKAY;
        case (state)
            S_IDLE: begin
                if (accept) begin
                    state_next = S_ERR1;
                end
            end
            S_ERR1: begin
                hreadyout_o = 1'b1;
                hresp_o = AHB_RESP_ERROR;
                state_next = S_ERR2;
            end
            S_ERR2: begin
                hresp_o = AHB_RESP_ERROR;
                state_next = accept ? S_ERR1 : S_IDLE;
            end
            default: begin
                state_next = S_IDLE;
            end
        endcase
    end

    always_ff @(posedge hclk or negedge hreset_n) begin : p_state
        if (!hreset_n) begin
            state <= S_IDLE;
        end else begin
            state <= state_next;
        end
    end

endmodule
