`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 8: AHB-to-APB Bridge
// ahb2apb_hclk_fsm.v - AHB-Lite slave front end and hclk-side sequencer
//
// Spec reference: GARUDA-BRG-SPEC-001 Rev 2.0, Sec. 7.1, Sec. 7.2, Sec. 7.3.1,
//                 Sec. 7.5, Sec. 8.1-8.5, Sec. 10
//
// =============================================================================
// ADDRESS PHASE AND DATA PHASE ARE NOT THE SAME CYCLE (Sec. 7.1)
// =============================================================================
// AHB-Lite is pipelined. HADDR/HWRITE/HSIZE are valid in the address phase;
// HWDATA is valid in the FOLLOWING cycle. This FSM therefore captures them at
// two different times and must never treat them as simultaneous. Launching the
// crossing before capturing HWDATA would send whatever the master happened to
// be driving during the address phase - which is the shape of ERRATUM DMA-1,
// one block over, and it corrupts every write silently.
//
// So: for a WRITE the request launches after the data-phase capture; for a READ
// there is nothing to capture and it launches immediately.
//
// =============================================================================
// ERRATUM BRG-1: COMPLETION STATES MUST ALSO ACCEPT (departure from Sec. 7.5)
// =============================================================================
// Sec. 7.5 says "the bridge accepts a new transaction only from H_IDLE". Taken
// literally that DROPS TRANSFERS, and the drop is silent.
//
// H_RESP_OKAY and H_ERROR_2 both drive hreadyout_o HIGH - they have to, that is
// how the transfer completes. A high HREADY is exactly the condition under
// which the master's next address phase IS ACCEPTED, by definition, in that
// same cycle. A bridge that only latches from H_IDLE would see the master
// consider the transfer accepted and move on, while the bridge quietly ignored
// it: the access never reaches APB, HREADYOUT stays high, and the master gets
// stale or zero read data with no error anywhere. Back-to-back peripheral
// accesses - the normal pattern when firmware configures a peripheral with a
// run of stores - would lose every second one.
//
// This RTL therefore accepts a new address phase in EVERY state where
// hreadyout_o is high: H_IDLE, H_RESP_OKAY and H_ERROR_2. rtl/ahb/
// ahb_default_slave.v already reasons this way for exactly the same reason
// ("S_ERR2 can accept a new transfer directly, without passing through
// S_IDLE"), so the bridge is now consistent with the block it sits next to.
//
// Logged as BRG-1 in docs/BUGS.md. Sec. 7.5 should be amended to "only states
// asserting HREADYOUT accept work", which is the property actually intended.
//
// =============================================================================
// THE BUNDLED-DATA INVARIANT (Sec. 7.3.1)
// =============================================================================
// All request payload registers are written BEFORE req_tog changes and are not
// touched again until the acknowledge is observed. The pclk side may sample
// them only after it has seen the synchronised req_tog edge, by which time they
// have been stable for at least two pclk cycles.
//
// This holds BY CONSTRUCTION, not by timing assumption: the bridge is
// single-outstanding and non-posted (Sec. 13.3), so the FSM structurally cannot
// launch a second request until the first has been acknowledged. That is the
// main reason not to add a write buffer here - it would turn an invariant that
// is true by construction into one that depends on getting a second set of
// pointers right across a clock boundary.
//
// =============================================================================
// RESET (Sec. 10.2, Sec. 10.3)
// =============================================================================
// Reset forces H_IDLE and clears req_tog with its synchronisers, so no stale
// toggle survives to be edge-detected as a spurious request. An in-flight
// transfer is ABANDONED and no terminal OKAY or ERROR is manufactured for it -
// correct precisely because reset is coordinated (Sec. 10.1): the master that
// issued the access is being reset in the same event, so there is no master
// left waiting for a response to receive.
// =============================================================================

`include "ahb2apb_defs.vh"

module ahb2apb_hclk_fsm (
    input  wire        hclk_i,
    input  wire        hreset_n_i,

    // ---- AHB-Lite slave port (frozen bundle, interconnect Sec. 5.3) --------
    input  wire        hsel_i,
    input  wire [31:0] haddr_i,
    input  wire [1:0]  htrans_i,
    input  wire        hwrite_i,
    input  wire [2:0]  hsize_i,
    input  wire [31:0] hwdata_i,
    input  wire        hready_i,          // GLOBAL HREADY
    output wire [31:0] hrdata_o,
    output wire        hreadyout_o,
    output wire        hresp_o,

    // ---- request payload, read by the pclk side after the req edge ---------
    output reg  [15:0] req_addr_o,
    output reg         req_write_o,
    output reg  [3:0]  req_strb_o,
    output reg  [31:0] req_wdata_o,
    output reg         req_tog_o,

    // ---- response payload, written by the pclk side before the ack edge ----
    input  wire [31:0] rsp_rdata_i,
    input  wire        rsp_err_i,
    input  wire        ack_pulse_i,

    // ---- decode (combinational, from the address being captured) ----------
    output wire [3:0]  dec_win_o,
    input  wire        dec_err_i
);

    reg [2:0]  state;
    reg [31:0] rdata_q;
    reg        err_q;
    reg        dec_err_q;

    // -----------------------------------------------------------------------
    // Acceptance. hready_i is the interconnect's GLOBAL HREADY: the address
    // phase completes this cycle only if the bus as a whole is ready.
    // -----------------------------------------------------------------------
    wire ready_state = (state == `BRG_H_IDLE)      ||
                       (state == `BRG_H_RESP_OKAY) ||
                       (state == `BRG_H_ERROR_2);     // ERRATUM BRG-1

    wire accept = hsel_i && hready_i && htrans_i[1] && ready_state;

    // The window being decoded is the one on the bus during the address phase.
    assign dec_win_o = haddr_i[15:12];

    // -----------------------------------------------------------------------
    // Byte-lane strobes for APB4 (Sec. 8.4)
    //
    // PSTRB is derived from the ADDRESS-phase HSIZE and HADDR[1:0], captured
    // together with the address. GARUDA requires naturally-aligned accesses, so
    // no lane pattern can straddle a word boundary.
    // -----------------------------------------------------------------------
    function [3:0] strb_of;
        input [2:0] sz;
        input [1:0] off;
        begin
            case (sz)
                `BRG_SIZE_BYTE: strb_of = 4'b0001 << off;
                `BRG_SIZE_HALF: strb_of = off[1] ? 4'b1100 : 4'b0011;
                default:        strb_of = 4'b1111;
            endcase
        end
    endfunction

    // -----------------------------------------------------------------------
    // Moore outputs. Every AHB response signal is a pure function of state, so
    // the response waveform cannot depend on what the address phase is doing
    // around it - which is what makes the two-cycle ERROR reliably two cycles.
    // -----------------------------------------------------------------------
    assign hreadyout_o = ready_state;
    assign hresp_o     = ((state == `BRG_H_ERROR_1) || (state == `BRG_H_ERROR_2))
                           ? `BRG_RESP_ERROR : `BRG_RESP_OKAY;
    assign hrdata_o    = rdata_q;

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            state       <= `BRG_H_IDLE;
            req_addr_o  <= 16'b0;
            req_write_o <= 1'b0;
            req_strb_o  <= 4'b0;
            req_wdata_o <= 32'b0;
            req_tog_o   <= 1'b0;
            rdata_q     <= 32'b0;
            err_q       <= 1'b0;
            dec_err_q   <= 1'b0;
        end else begin
            case (state)

                // ---------------------------------------------------------
                // Idle. Capture address/control on an accepted address phase.
                // ---------------------------------------------------------
                `BRG_H_IDLE: begin
                    if (accept) begin
                        req_addr_o  <= haddr_i[15:0];
                        req_write_o <= hwrite_i;
                        req_strb_o  <= strb_of(hsize_i, haddr_i[1:0]);
                        dec_err_q   <= dec_err_i;
                        state       <= `BRG_H_CAPTURE;
                    end
                end

                // ---------------------------------------------------------
                // Data-phase capture and request launch.
                //
                // HWDATA is valid in THIS cycle (one after the address phase).
                // An unmapped window never reaches APB at all: the decode
                // error short-circuits straight to the two-cycle ERROR with no
                // PSEL asserted and no toggle flipped (Sec. 8.5).
                // ---------------------------------------------------------
                `BRG_H_CAPTURE: begin
                    if (dec_err_q) begin
                        err_q   <= 1'b1;
                        rdata_q <= 32'h0000_0000;
                        state   <= `BRG_H_ERROR_1;
                    end else begin
                        if (req_write_o) req_wdata_o <= hwdata_i;
                        req_tog_o <= ~req_tog_o;
                        state     <= `BRG_H_WAIT_ACK;
                    end
                end

                // ---------------------------------------------------------
                // Crossing in flight. HREADYOUT is low throughout, so the
                // master simply sees a slow slave and holds its address and
                // control stable per AHB-Lite rules.
                // ---------------------------------------------------------
                `BRG_H_WAIT_ACK: begin
                    if (ack_pulse_i) begin
                        rdata_q <= rsp_rdata_i;
                        err_q   <= rsp_err_i;
                        state   <= rsp_err_i ? `BRG_H_ERROR_1 : `BRG_H_RESP_OKAY;
                    end
                end

                // ---------------------------------------------------------
                // Normal completion, one cycle. HREADYOUT is high here, so a
                // new address phase can and must be accepted in this same
                // cycle - see ERRATUM BRG-1 in the header.
                // ---------------------------------------------------------
                `BRG_H_RESP_OKAY: begin
                    err_q <= 1'b0;
                    if (accept) begin
                        req_addr_o  <= haddr_i[15:0];
                        req_write_o <= hwrite_i;
                        req_strb_o  <= strb_of(hsize_i, haddr_i[1:0]);
                        dec_err_q   <= dec_err_i;
                        state       <= `BRG_H_CAPTURE;
                    end else begin
                        state <= `BRG_H_IDLE;
                    end
                end

                // ---------------------------------------------------------
                // Two-cycle ERROR. Cycle 1 is HREADYOUT=0/HRESP=ERROR - the
                // only warning the DMA beat engine gets, and what it uses to
                // drive HTRANS=IDLE so the pipelined write address is
                // retracted rather than committed (Sec. 1.4).
                // ---------------------------------------------------------
                `BRG_H_ERROR_1: begin
                    state <= `BRG_H_ERROR_2;
                end

                // Cycle 2 is HREADYOUT=1/HRESP=ERROR, and like H_RESP_OKAY it
                // accepts: a master faulting twice in a row - a runaway
                // pointer walking unmapped peripheral space - must not have
                // its second fault swallowed.
                `BRG_H_ERROR_2: begin
                    err_q <= 1'b0;
                    if (accept) begin
                        req_addr_o  <= haddr_i[15:0];
                        req_write_o <= hwrite_i;
                        req_strb_o  <= strb_of(hsize_i, haddr_i[1:0]);
                        dec_err_q   <= dec_err_i;
                        state       <= `BRG_H_CAPTURE;
                    end else begin
                        state <= `BRG_H_IDLE;
                    end
                end

                default: state <= `BRG_H_IDLE;
            endcase
        end
    end

    // err_q is the latched error used for waveform debug and for coverage of
    // the error path; the response itself is driven from state (Moore).
    wire _unused_err = err_q;

endmodule

`default_nettype wire
