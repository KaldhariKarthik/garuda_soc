// MUTANT no_adopt (GENERATED, gen_dmi_cdc_models.py): adopt-on-reset removed: ack not set to the settled request toggle on re-arm
`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 12 : DMI clock-domain crossing, tck <-> hclk
// dmi_cdc.v
//
// Spec: GARUDA-DEBUG-SPEC-001 Rev 2.0 §7.5 [N-7.15]..[N-7.17]
//
// THE ONLY ASYNCHRONOUS CROSSING IN THE CHIP ([N-7.16]). Everything a CDC
// reviewer needs is in this file.
//
// Toggle handshake, two-flop synchroniser in each direction:
//   tck -> hclk : req_tgl changes AFTER the payload (addr/data/op) is stable in
//                 tck flops; the payload is held until the ack returns, so the
//                 hclk side may sample it on any cycle after the synchronised
//                 toggle arrives. The payload itself is NOT synchronised - it
//                 is a stable multi-bit bus qualified by a synchronised strobe.
//   hclk -> tck : the response data is stable in hclk flops before ack_tgl
//                 changes, and held until the next request.
// The hclk side never waits on tck ([N-7.17]): it completes its work and
// toggles ack; a stopped tck merely delays when the debugger sees it.
// =============================================================================

module dmi_cdc (
    // ---- tck side --------------------------------------------------------------
    input  wire        tck_i,
    input  wire        tck_rst_n_i,
    input  wire        req_tgl_i,
    output wire        ack_tgl_sync_o,       // ack toggle, synchronised into tck

    // ---- hclk side ----------------------------------------------------------------
    input  wire        hclk_i,
    input  wire        hrst_n_i,
    output wire        req_pulse_o,          // one hclk pulse per request
    input  wire        ack_pulse_i,          // DM finished: toggles ack
    output reg         ack_tgl_o
);

    // tck -> hclk
    // After an hclk-side reset (e.g. a watchdog reset during a session - the
    // tck side is NOT reset by it, and since DBG-6 neither is ack_tgl) the
    // synchroniser re-arms by ADOPTING the current request toggle rather than
    // treating it as new: otherwise the
    // last DMI request (possibly a dmcontrol.ndmreset write) would replay, or
    // ack would sit permanently out of step and the DTM would report busy
    // forever. Three hclk cycles fill the synchroniser, then ack is set equal
    // to the settled request toggle ("already served") and pulses are enabled.
    //
    // ERRATUM DBG-9 (fixed 2026-11-01): since DBG-6, ack_tgl is on POR while the arming state
    // is reset by hrst_n (dm_rst_n), which reset_ctrl asserts at a time unrelated to hclk.
    // ack_tgl's enables were DECODES of arm_cnt (== 2 adopt, == 3 armed): a DM reset landing
    // near an hclk edge clears the two bits at slightly different times, so arm_cnt passes
    // 11 -> 10 -> 00 and the "== 2" decode pulsed; ack_tgl then loaded a half-cleared req_s[1],
    // the 1 -> 0 -> 1 ack pulse of DBG-6 again (a reset-domain crossing; found by the review,
    // shown by tools/run/rdc_check.py). Now each enable is ONE flop that resets to its inactive
    // value (adopt_q, armed_r): an asynchronous reset can only take it 1 -> 0, never through a
    // decoded "active" state, so ack_tgl no longer depends on arm_cnt. Same cycle timing as
    // before (adopt in the third arming cycle, armed from the fourth).
    (* ASYNC_REG = "TRUE" *) reg [2:0] req_s;
    reg [1:0] arm_cnt;
    reg       adopt_q, armed_r;
    wire      armed = armed_r;
    always @(posedge hclk_i or negedge hrst_n_i)
        if (!hrst_n_i) begin req_s <= 3'd0; arm_cnt <= 2'd0; adopt_q <= 1'b0; armed_r <= 1'b0; end
        else begin
            req_s <= {req_s[1:0], req_tgl_i};
            if (!armed) arm_cnt <= arm_cnt + 2'd1;
            adopt_q <= (arm_cnt == 2'd1);                // high while arm_cnt == 2
            if (arm_cnt == 2'd2) armed_r <= 1'b1;         // armed from arm_cnt == 3 on
        end
    assign req_pulse_o = armed && (req_s[2] ^ req_s[1]);

    // ERRATUM DBG-6 (fixed 2026-10-16): ack_tgl was reset by the DM reset and re-adopted on
    // every arming edge, the first two from req_s[1] still holding its reset value. A DM-only
    // reset (watchdog, software) therefore pulsed ack 1 -> 0 -> 1; the tck synchroniser
    // could catch the 0, and the debugger's next request (toggle to 0) was acknowledged
    // before the DM executed it, with a stale response, and the next read out of step.
    // Now ack_tgl is reset by POR only (a DM-only reset holds it) and the request toggle is
    // adopted once, at the arming edge where req_s[1] holds a real synchronised sample.
    always @(posedge hclk_i or negedge tck_rst_n_i)
        if (!tck_rst_n_i)               ack_tgl_o <= 1'b0;
        else if (armed && ack_pulse_i)  ack_tgl_o <= ~ack_tgl_o;

    // hclk -> tck
    (* ASYNC_REG = "TRUE" *) reg [1:0] ack_s;
    always @(posedge tck_i or negedge tck_rst_n_i)
        if (!tck_rst_n_i) ack_s <= 2'd0;
        else              ack_s <= {ack_s[0], ack_tgl_o};
    assign ack_tgl_sync_o = ack_s[1];

endmodule

`default_nettype wire
