`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 16: CLIC
// clic_present.v - winner register + take-condition comparison to the core
//
// Spec reference: GARUDA-CLIC-SPEC-001 Rev 2.0, Sec. 7.3, Sec. 8.2, Sec. 8.6
//
// =============================================================================
// THE ID/LEVEL/SHV ARE REGISTERED. THE REQUEST IS NOT. THIS IS DELIBERATE.
// =============================================================================
// Sec. 7.3 is normative on this and the two constructions are easy to conflate,
// so both halves are spelled out here.
//
// REGISTERED (id, level, shv): the arbiter is a combinational reduction tree
// that ripples while a source changes. Registering its result means the core
// never samples a mid-resolution transient - it sees a settled winner or the
// previous one, never a mixture of the two.
//
// COMBINATIONAL (clic_irq_o): the request is the comparison of the REGISTERED
// winner level against the core-supplied mintthresh_i. Two reasons it must not
// be registered as well:
//
//   1. mintthresh is a core CSR that firmware can change at any time.
//      Registering the comparison would delay every threshold change by a
//      cycle, so a firmware write that unmasks a level would not take effect
//      until the cycle after the CSR updated - which the core's take-condition
//      model (core Sec. 14.3) does not expect.
//
//   2. It is what makes the one-cycle latency of Sec. 9.1 true. A source going
//      pending reaches clic_irq_o through the combinational arbiter, ONE
//      registration stage, and one combinational comparator. Registering the
//      request too would make it two cycles.
//
// The output is glitch-free despite being combinational, because both of its
// inputs are stable registered values: the winner level comes from the register
// below and mintthresh_i comes from a core CSR flop. The comparator settles
// once per cycle and the core samples it synchronously. Only the request is
// combinational; every value that ACCOMPANIES it is registered, so the core can
// never see a request qualified by a level that has not settled.
//
// =============================================================================
// THE COMPARISON IS STRICTLY GREATER THAN
// =============================================================================
// A source at exactly the threshold does NOT interrupt (Sec. 1.4, Sec. 10.3).
// Setting mintthresh=7 masks everything except a level-7 source; mintthresh=0
// admits any non-zero-level source. The same strictly-greater rule applied to
// the ACTIVE HANDLER's level is what bounds nesting depth to 7 - two handlers
// can never share a level, and level 0 can never own a handler at all. That
// arithmetic is what the 7 x 140 byte stack budget is sized against
// (Sec. 13.4), so relaxing this to >= would silently overflow the stack budget
// as well as changing the preemption semantics.
//
// The final take decision belongs to the CORE, which additionally checks
// mstatus.MIE and the active handler's level (Sec. 8.3). This block's job is to
// present the correct highest source and its level, and to never present a
// level-0 source or an id that does not correspond to the level on the level
// port.
// =============================================================================

`include "clic_defs.vh"

module clic_present #(
    parameter integer ID_W = 5
)(
    input  wire                      clk_i,
    input  wire                      rst_n_i,

    // ---- from the arbiter (combinational) ---------------------------------
    input  wire                      winner_valid_i,
    input  wire [ID_W-1:0]           winner_id_i,
    input  wire [`CLIC_LVL_W-1:0]    winner_lvl_i,
    input  wire                      winner_shv_i,

    // ---- from the core ----------------------------------------------------
    input  wire [`CLIC_CORE_LVL_W-1:0] mintthresh_i,

    // ---- to the core (frozen names, core Sec. 4.1) ------------------------
    output wire                      clic_irq_o,      // COMBINATIONAL
    output reg  [`CLIC_CORE_ID_W-1:0]  clic_irq_id_o,   // registered
    output reg  [`CLIC_CORE_LVL_W-1:0] clic_irq_lvl_o,  // registered
    output reg                       clic_irq_shv_o   // registered
);

    reg valid_q;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            valid_q        <= 1'b0;
            clic_irq_id_o  <= {`CLIC_CORE_ID_W{1'b0}};
            clic_irq_lvl_o <= {`CLIC_CORE_LVL_W{1'b0}};
            clic_irq_shv_o <= 1'b0;
        end else begin
            valid_q        <= winner_valid_i;
            // Zero-extend the 3-bit level onto the 8-bit core port, and the
            // ID_W-bit index onto the 12-bit core id port.
            clic_irq_id_o  <= {{(`CLIC_CORE_ID_W-ID_W){1'b0}}, winner_id_i};
            clic_irq_lvl_o <= {{(`CLIC_CORE_LVL_W-`CLIC_LVL_W){1'b0}}, winner_lvl_i};
            clic_irq_shv_o <= winner_shv_i;
        end
    end

    // Strictly greater than - see header.
    assign clic_irq_o = valid_q && (clic_irq_lvl_o > mintthresh_i);

endmodule

`default_nettype wire
