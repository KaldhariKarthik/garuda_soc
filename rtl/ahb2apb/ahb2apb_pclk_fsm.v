`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 8: AHB-to-APB Bridge
// ahb2apb_pclk_fsm.v - APB4 master sequencer (pclk domain)
//
// Spec reference: GARUDA-BRG-SPEC-001 Rev 2.0, Sec. 7.3.1, Sec. 7.4, Sec. 8.3,
//                 Sec. 13.5, Sec. 13.7
//
// THE APB TWO-PHASE ACCESS IS NORMATIVE (Sec. 1.4)
// Every APB transfer presents SETUP (PSEL=1, PENABLE=0) for exactly one pclk
// cycle, then ACCESS (PSEL=1, PENABLE=1) held until PREADY=1. PENABLE is never
// asserted in the same cycle PSEL first rises. P_SETUP exists solely to
// guarantee that one-cycle separation; it has no condition on it and cannot be
// optimised away without breaking APB compliance.
//
// APB4, NOT APB3 (Sec. 13.5)
// The downstream interface carries PSTRB, so byte and half-word register writes
// reach a peripheral as byte-lane strobes rather than forcing firmware into a
// read-modify-write on every sub-word store. Peripherals that implement only
// word registers tie off the unused strobes and say so in their own specs; the
// bridge always drives correct strobes. This is why the model in tb/ahb/ that
// this block replaces could not express a sub-word access at all - it was APB3.
//
// ACCESS ENDS ON PREADY AND ON NOTHING ELSE (Sec. 13.7)
// There is deliberately no timeout in the baseline. A timeout would be a third
// termination mechanism alongside PREADY and PSLVERR and, to be safe, would
// need a fully specified count, width, reset value and defined behaviour on
// expiry on both buses. None of that is justified for the current peripheral
// set, all of which respond in bounded time. The consequence is explicit: the
// worst-case latency is bounded only to the extent each peripheral bounds its
// own PREADY. If a genuinely unbounded peripheral is ever added, a timeout may
// be introduced with that full specification - it must not be added implicitly.
//
// THE RESPONSE-PATH INVARIANT (Sec. 7.3.1)
// PRDATA and PSLVERR are latched into the response registers BEFORE ack_tog
// flips, and are not touched again until the hclk side has consumed them. That
// is what lets the hclk side read them combinationally one synchronised edge
// later: read data always comes from a register that was filled and frozen in a
// completed APB access, never from a live APB bus the hclk domain cannot safely
// sample.
// =============================================================================

`include "ahb2apb_defs.vh"

module ahb2apb_pclk_fsm #(
    parameter [15:0] WINDOW_MASK = `BRG_WINDOW_MASK_DEFAULT
)(
    input  wire        pclk_i,
    input  wire        preset_n_i,

    // ---- request payload, held stable by the hclk side -------------------
    input  wire [15:0] req_addr_i,
    input  wire        req_write_i,
    input  wire [3:0]  req_strb_i,
    input  wire [31:0] req_wdata_i,
    input  wire        req_pulse_i,       // synchronised req_tog edge

    // ---- response payload, consumed by the hclk side after ack -----------
    output reg  [31:0] rsp_rdata_o,
    output reg         rsp_err_o,
    output reg         ack_tog_o,

    // ---- APB4 master port -------------------------------------------------
    output reg  [15:0] psel_o,            // one-hot, one bit per 4 KB window
    output reg         penable_o,
    output reg         pwrite_o,
    output reg  [15:0] paddr_o,
    output reg  [31:0] pwdata_o,
    output reg  [3:0]  pstrb_o,
    input  wire [31:0] prdata_i,
    input  wire        pready_i,
    input  wire        pslverr_i
);

    reg [1:0] state;

    // Decode of the captured request address. Safe to compute combinationally
    // from the payload registers: they are stable for the whole crossing.
    wire [15:0] sel_onehot;
    wire        dec_err_unused;

    ahb2apb_decoder #(.WINDOW_MASK(WINDOW_MASK)) u_dec (
        .win_i     (req_addr_i[15:12]),
        .psel_o    (sel_onehot),
        .dec_err_o (dec_err_unused)
    );

    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            state       <= `BRG_P_IDLE;
            psel_o      <= 16'b0;
            penable_o   <= 1'b0;
            pwrite_o    <= 1'b0;
            paddr_o     <= 16'b0;
            pwdata_o    <= 32'b0;
            pstrb_o     <= 4'b0;
            rsp_rdata_o <= 32'b0;
            rsp_err_o   <= 1'b0;
            ack_tog_o   <= 1'b0;
        end else begin
            case (state)

                // ---------------------------------------------------------
                // Waiting for a request. The payload is read HERE, after the
                // synchronised toggle edge - never before it.
                // ---------------------------------------------------------
                `BRG_P_IDLE: begin
                    psel_o    <= 16'b0;
                    penable_o <= 1'b0;
                    if (req_pulse_i) begin
                        psel_o    <= sel_onehot;
                        penable_o <= 1'b0;          // SETUP: PSEL without PENABLE
                        pwrite_o  <= req_write_i;
                        paddr_o   <= req_addr_i;
                        pwdata_o  <= req_wdata_i;
                        pstrb_o   <= req_write_i ? req_strb_i : 4'b0000;
                        state     <= `BRG_P_SETUP;
                    end
                end

                // ---------------------------------------------------------
                // SETUP, exactly one pclk cycle, unconditional.
                // ---------------------------------------------------------
                `BRG_P_SETUP: begin
                    penable_o <= 1'b1;
                    state     <= `BRG_P_ACCESS;
                end

                // ---------------------------------------------------------
                // ACCESS. Extended for as long as the peripheral holds PREADY
                // low; that latency passes transparently upstream as AHB wait
                // states, because HREADYOUT is already low for the crossing.
                // ---------------------------------------------------------
                `BRG_P_ACCESS: begin
                    if (pready_i) begin
                        rsp_rdata_o <= prdata_i;
                        rsp_err_o   <= pslverr_i;
                        ack_tog_o   <= ~ack_tog_o;   // flipped AFTER the payload
                        psel_o      <= 16'b0;
                        penable_o   <= 1'b0;
                        state       <= `BRG_P_IDLE;
                    end
                end

                default: state <= `BRG_P_IDLE;
            endcase
        end
    end

    wire _unused = dec_err_unused;

endmodule

`default_nettype wire
