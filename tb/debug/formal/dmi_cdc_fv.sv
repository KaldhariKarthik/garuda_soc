// =============================================================================
// dmi_cdc_fv.sv -- the tck <-> hclk crossing proof (Track A plan 6A.5 step G2, the
// "CDC proof" section of the plan: classes A-D). SymbiYosys, `multiclock on`.
//
// Harnesses (both use the REAL rtl/debug/dmi_cdc.v and a DM stub that answers the
// next hclk cycle with a free value, which is the DM's proven contract:
// a_dm_done_follows_req / a_dm_done_only_req in fv_debug):
//   dmi_fv_abs   an abstract requester on tck with the DTM's protocol (toggle only
//                when not busy, payload held while busy, ack seen the DTM's way);
//                short traces, so every cover is reachable cheaply
//   dmi_fv_real  the real jtag_tap + dtm in front of the crossing, driven by free
//                TMS / TDI: the DTM's own obligations are proved, not assumed
//
// Environment (assumptions, all stated):
//   FC-0 the proof starts in reset: por_n and dm_rst_n low for the first RST_TICKS
//        solver steps with both clocks driven; afterwards both clocks are FREE (any
//        ratio, any phase, either may stop for ever) and so are both resets.
//   FC-1 POR asserts the DM reset (!por_n -> !dm_rst_n): reset_ctrl drives dm_rst_n
//        low for the external reset (GARUDA-CLKRST-SPEC; checked at chip level).
//        Task cdc_no_fc1 drops it and shows why it is needed.
//   FC-2 (D1 task cdc_meta_prove only) the DM reset ends at least 2 hclk edges after POR
//        ends. Holds by construction: reset_ctrl sets dm_req_q with the pin reset and
//        releases dm_rst_n through the 2-flop hclk synchroniser dm_q after its stretch
//        counter (rtl/reset_ctrl/reset_ctrl.v, dm_q); contract item for Karthik.
//   FC-3 (D1 task only) POR lasts longer than 3 solver steps (the injection's "changed
//        just before the edge" window): POR is the external pin reset, never a glitch.
//   So the D1 task adds behaviour (the injection) AND removes some (FC-2, FC-3): its
//   proof is a result under FC-0..FC-3, not a pure over-approximation (2026-11-01).
// No assumption about clock progress anywhere: the bounded-response properties count
// edges of the clock they talk about, so a stopped clock just never reaches the bound.
//
// Properties (dmi_cdc_props), counted in the solver's step clock gclk:
//   a_cdc_no_phantom      every request the DM consumes was issued (a toggle of req_tgl)
//                         and not yet delivered: no phantom, no duplicate, no replay
//                         after an hclk reset
//   a_cdc_deliver_bound   a request issued while the hclk side is armed and out of reset
//                         is consumed within N_REQ hclk edges (needs no tck edge)
//   a_cdc_ack_bound       a consumed request toggles ack within N_ACK hclk edges
//   a_cdc_ack_only_done   ack changes only for a consumed request, while (re)arming, or
//                         in reset
//   a_cdc_hside_done      whenever req and ack differ with the hclk side armed and out of
//                         reset, they agree again within N_REQ + N_ACK hclk edges: the hclk
//                         side never waits for tck [N-7.17]; it also covers C3 (an hclk
//                         reset never leaves the DTM busy for ever)
//   a_cdc_dtm_sees_ack    once ack equals req, a busy requester sees it within N_DTM tck
//                         edges (C2: no hang, no second acknowledgement)
//   a_req_payload_held    (requester side) the payload does not move while busy
// Requests "may be dropped" (at most once) when issued while the hclk side is in reset
// or still arming: that is the adopt-on-reset rule of dmi_cdc.v (contract item 5).
// =============================================================================
`timescale 1ns/1ps

// ---- DM stub: answers every consumed request on the next hclk cycle -------------------
module dmi_dm_stub (
    input  wire        hclk_i, rst_n_i, req_i,
    input  wire [31:0] free_i,
    output reg         done_o,
    output reg  [31:0] rdata_o
);
    always @(posedge hclk_i or negedge rst_n_i)
        if (!rst_n_i) begin done_o <= 1'b0; rdata_o <= 32'd0; end
        else begin done_o <= req_i; if (req_i) rdata_o <= free_i; end
endmodule

// ---- abstract requester with the DTM's protocol ------------------------------------------
module dmi_req_abs (
    input  wire        tck_i, por_n_i, issue_i,
    input  wire [40:0] payload_i,
    input  wire        ack_tgl_sync_i,
    output reg         req_tgl_o,
    output reg  [40:0] payload_o,
    output wire        busy_o
);
    reg ack_seen;
    assign busy_o = (req_tgl_o != ack_seen);
    always @(posedge tck_i or negedge por_n_i)
        if (!por_n_i) begin req_tgl_o <= 1'b0; ack_seen <= 1'b0; payload_o <= 41'd0; end
        else begin
            if (busy_o && ack_tgl_sync_i == req_tgl_o) ack_seen <= ack_tgl_sync_i;
            if (issue_i && !busy_o) begin req_tgl_o <= ~req_tgl_o; payload_o <= payload_i; end
        end
endmodule

// ---- the step-clocked environment and properties live in dmi_cdc_props.v (read first,
// with Yosys's Verilog frontend); here only their ports, so yosys-slang can elaborate
(* blackbox *) module dmi_fv_env #(parameter integer RST_TICKS = 8) (
    input wire tck_i, hclk_i, por_n_i, dm_rst_n_i);
endmodule
(* blackbox *) module dmi_cdc_props #(parameter integer N_REQ = 4, N_ACK = 2, N_DTM = 3, ARM_EDGES = 3) (
    input wire tck_i, hclk_i, por_n_i, dm_rst_n_i,
    input wire req_tgl, req_pulse, ack_tgl, busy,
    input wire [40:0] payload,
    output wire chg_req, chg_ack);
endmodule

// ---- harness 1: abstract requester -----------------------------------------------------------------
module dmi_fv_abs (
    input wire tck_i, hclk_i, por_n_i, dm_rst_n_i, issue_i,
    input wire [40:0] payload_i,
    input wire [31:0] dm_free_i
);
    wire chg_req, chg_ack;
    wire req_tgl, ack_tgl_sync, req_pulse, ack_tgl, busy, dm_done;
    wire [40:0] payload;
    wire [31:0] dm_rdata;
    dmi_req_abs u_req (.tck_i(tck_i), .por_n_i(por_n_i), .issue_i(issue_i), .payload_i(payload_i),
        .ack_tgl_sync_i(ack_tgl_sync), .req_tgl_o(req_tgl), .payload_o(payload), .busy_o(busy));
    dmi_cdc u_cdc (.tck_i(tck_i), .tck_rst_n_i(por_n_i), .req_tgl_i(req_tgl), .ack_tgl_sync_o(ack_tgl_sync),
        .hclk_i(hclk_i), .hrst_n_i(dm_rst_n_i), .req_pulse_o(req_pulse), .ack_pulse_i(dm_done), .ack_tgl_o(ack_tgl));
    dmi_dm_stub u_dm (.hclk_i(hclk_i), .rst_n_i(dm_rst_n_i), .req_i(req_pulse), .free_i(dm_free_i),
        .done_o(dm_done), .rdata_o(dm_rdata));
    dmi_fv_env u_env (.tck_i(tck_i), .hclk_i(hclk_i), .por_n_i(por_n_i), .dm_rst_n_i(dm_rst_n_i));
`ifdef DMI_FV_META
    dmi_cdc_props #(.N_REQ(5), .N_ACK(2), .N_DTM(4)) u_props (   // D1: one edge more on each synchroniser
`else
    dmi_cdc_props u_props (
`endif.tck_i(tck_i), .hclk_i(hclk_i), .por_n_i(por_n_i), .dm_rst_n_i(dm_rst_n_i),
        .req_tgl(req_tgl), .req_pulse(req_pulse), .ack_tgl(ack_tgl), .busy(busy),
        .payload(payload), .chg_req(chg_req), .chg_ack(chg_ack));
`ifdef DMI_FV_META
    // D1: the first synchroniser stage may take a change late only when the input changed
    // just before the edge (a change long before an edge, e.g. while a clock was stopped,
    // cannot be caught metastable)
    always_comb begin assume (!u_cdc.meta_r || chg_req); assume (!u_cdc.meta_a || chg_ack); end
    // the injection really happens (the proof is not vacuously free of late samples)
    c_meta_req_late: cover property (@(posedge hclk_i) u_cdc.meta_r && req_tgl != u_cdc.req_in_q);
    c_meta_ack_late: cover property (@(posedge tck_i) u_cdc.meta_a && ack_tgl != u_cdc.ack_in_q);
`endif
endmodule

// ---- harness 2: the real TAP and DTM ----------------------------------------------------------------
module dmi_fv_real (
    input wire tck_i, tms_i, tdi_i, hclk_i, por_n_i, dm_rst_n_i,
    input wire [31:0] dm_free_i
);
    wire chg_req, chg_ack;
    wire [4:0]  ir;
    wire        tlr, cap_dr, sh_dr, up_dr, dr_tdo, tdo, tdo_oe;
    wire        req_tgl, ack_tgl_sync, ack_tgl, req_pulse, dm_done;
    wire [6:0]  req_addr;
    wire [31:0] req_data, dm_rdata;
    wire [1:0]  req_op;
    jtag_tap u_tap (.tck_i(tck_i), .tms_i(tms_i), .tdi_i(tdi_i), .por_n_i(por_n_i),
        .tdo_o(tdo), .tdo_oe_o(tdo_oe), .ir_o(ir), .tlr_o(tlr),
        .capture_dr_o(cap_dr), .shift_dr_o(sh_dr), .update_dr_o(up_dr), .dr_tdo_i(dr_tdo));
    dtm u_dtm (.tck_i(tck_i), .por_n_i(por_n_i), .tdi_i(tdi_i), .ir_i(ir), .tlr_i(tlr),
        .capture_dr_i(cap_dr), .shift_dr_i(sh_dr), .update_dr_i(up_dr), .dr_tdo_o(dr_tdo),
        .req_tgl_o(req_tgl), .req_addr_o(req_addr), .req_data_o(req_data), .req_op_o(req_op),
        .ack_tgl_i(ack_tgl_sync), .rsp_data_i(dm_rdata), .rsp_err_i(1'b0));
    dmi_cdc u_cdc (.tck_i(tck_i), .tck_rst_n_i(por_n_i), .req_tgl_i(req_tgl), .ack_tgl_sync_o(ack_tgl_sync),
        .hclk_i(hclk_i), .hrst_n_i(dm_rst_n_i), .req_pulse_o(req_pulse), .ack_pulse_i(dm_done), .ack_tgl_o(ack_tgl));
    dmi_dm_stub u_dm (.hclk_i(hclk_i), .rst_n_i(dm_rst_n_i), .req_i(req_pulse), .free_i(dm_free_i),
        .done_o(dm_done), .rdata_o(dm_rdata));
    dmi_fv_env u_env (.tck_i(tck_i), .hclk_i(hclk_i), .por_n_i(por_n_i), .dm_rst_n_i(dm_rst_n_i));
`ifdef DMI_FV_META
    dmi_cdc_props #(.N_REQ(5), .N_ACK(2), .N_DTM(4)) u_props (   // D1: one edge more on each synchroniser
`else
    dmi_cdc_props u_props (
`endif.tck_i(tck_i), .hclk_i(hclk_i), .por_n_i(por_n_i), .dm_rst_n_i(dm_rst_n_i),
        .req_tgl(req_tgl), .req_pulse(req_pulse), .ack_tgl(ack_tgl),
        .busy(req_tgl != u_dtm.ack_seen), .payload({req_addr, req_data, req_op}),
        .chg_req(chg_req), .chg_ack(chg_ack));
`ifdef DMI_FV_META
    always_comb begin assume (!u_cdc.meta_r || chg_req); assume (!u_cdc.meta_a || chg_ack); end
`endif
endmodule
