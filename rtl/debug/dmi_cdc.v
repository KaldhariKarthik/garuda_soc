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
    // tck side is NOT reset by it) the synchroniser re-arms by ADOPTING the
    // current request toggle rather than treating it as new: otherwise the
    // last DMI request (possibly a dmcontrol.ndmreset write) would replay, or
    // ack would sit permanently out of step and the DTM would report busy
    // forever. Three hclk cycles fill the synchroniser, then ack is set equal
    // to the settled request toggle ("already served") and pulses are enabled.
    (* ASYNC_REG = "TRUE" *) reg [2:0] req_s;
    reg [1:0] arm_cnt;
    wire      armed = (arm_cnt == 2'd3);
    always @(posedge hclk_i or negedge hrst_n_i)
        if (!hrst_n_i) begin req_s <= 3'd0; arm_cnt <= 2'd0; end
        else begin
            req_s <= {req_s[1:0], req_tgl_i};
            if (!armed) arm_cnt <= arm_cnt + 2'd1;
        end
    assign req_pulse_o = armed && (req_s[2] ^ req_s[1]);

    always @(posedge hclk_i or negedge hrst_n_i)
        if (!hrst_n_i)                  ack_tgl_o <= 1'b0;
        else if (!armed)                ack_tgl_o <= req_s[1];
        else if (ack_pulse_i)           ack_tgl_o <= ~ack_tgl_o;

    // hclk -> tck
    (* ASYNC_REG = "TRUE" *) reg [1:0] ack_s;
    always @(posedge tck_i or negedge tck_rst_n_i)
        if (!tck_rst_n_i) ack_s <= 2'd0;
        else              ack_s <= {ack_s[0], ack_tgl_o};
    assign ack_tgl_sync_o = ack_s[1];

endmodule

`default_nettype wire
