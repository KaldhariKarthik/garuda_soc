// =============================================================================
// dmi_cdc_props.v -- environment and properties of the crossing proof, read with
// Yosys's own Verilog frontend (read_verilog -sv -formal; manifest key pre_verilog):
// they need a real step clock, and yosys-slang ignores (* gclk *) (2026-10-15).
// Everything is documented in tb/debug/formal/dmi_cdc_fv.sv (the harnesses).
// =============================================================================
`timescale 1ns/1ps
// ---- environment FC-0 / FC-1 ------------------------------------------------------------------
module dmi_fv_env #(parameter integer RST_TICKS = 8) (
    input wire tck_i, hclk_i, por_n_i, dm_rst_n_i
);
    (* gclk *) wire gclk;
    reg [3:0] g = 4'd0;
    reg       tck_q = 1'b0, hclk_q = 1'b0;
    reg [3:0] tck_still = 4'd0;
    reg [1:0] h_since_por = 2'd0;      // hclk rising edges since POR ended (saturating)
    reg       por_q = 1'b0;
    reg [1:0] por_low = 2'd0;          // solver steps POR has been low (saturating)
    always @(posedge gclk) begin
        if (g != 4'd15) g <= g + 4'd1;
        tck_q <= tck_i; hclk_q <= hclk_i; por_q <= por_n_i;
        por_low <= por_n_i ? 2'd0 : (por_low == 2'd3 ? por_low : por_low + 2'd1);
        if (!por_n_i) h_since_por <= 2'd0;
        else if (hclk_i && !hclk_q && h_since_por != 2'd3) h_since_por <= h_since_por + 2'd1;
        tck_still <= (tck_i != tck_q) ? 4'd0 : (tck_still == 4'd15 ? tck_still : tck_still + 4'd1);
    end
    always @(*) begin
        if (g < RST_TICKS) begin
            assume (!por_n_i); assume (!dm_rst_n_i);
            assume (tck_i == g[0]); assume (hclk_i == g[0]);
        end
`ifndef DMI_FV_NO_FC1
        if (!por_n_i) assume (!dm_rst_n_i);                         // FC-1
`endif
`ifdef DMI_FV_META
        // FC-2 (D1 task only): the DM reset ends at least 2 hclk edges after POR ends --
        // reset_ctrl stretches it (~10 us, GARUDA-ADR-001), so the request toggle that POR
        // cleared is long settled when the hclk side samples it again
        if (h_since_por < 2'd2) assume (!dm_rst_n_i);
        // FC-3 (D1 task only): POR is not a glitch -- it lasts longer than the injection's
        // "changed just before the edge" window (3 solver steps), so a toggle that POR itself
        // cleared cannot be near the first edge after POR ends (the pin reset is long)
        if (por_n_i && !por_q && por_low < 2'd3) assume (1'b0);
`endif
`ifdef DMI_FV_TCK_RUNS
        // over-constraint control ONLY (task cdc_overconstrained): tck never stops; the
        // stopped-tck cover must then become unreachable, showing the cover check works
        if (g >= RST_TICKS) assume (tck_still < 4'd3);
`endif
    end
endmodule

// ---- properties ----------------------------------------------------------------------------------
module dmi_cdc_props #(parameter integer N_REQ = 4, N_ACK = 2, N_DTM = 3, ARM_EDGES = 3) (
    input wire tck_i, hclk_i, por_n_i, dm_rst_n_i,
    input wire req_tgl, req_pulse, ack_tgl, busy,
    input wire [40:0] payload,
    // D1 (metastability task): each synchroniser input changed in the step just before the
    // current one, i.e. close to a sampling edge; only then may the first stage take it late
    output wire chg_req, chg_ack
);
    (* gclk *) wire gclk;
    reg req_tgl_q2 = 1'b0, ack_tgl_q2 = 1'b0;
    // the hclk side is ready ("armed") ARM_EDGES = 3 hclk edges after the DM reset ends: the
    // spec's own description of dmi_cdc ([N-7.17a], "three hclk cycles fill the synchroniser"),
    // modelled here, not read from the RTL
    reg [2:0] acnt = 3'd0;
    always @(posedge hclk_i or negedge dm_rst_n_i)
        if (!dm_rst_n_i) acnt <= 3'd0; else if (acnt != ARM_EDGES[2:0]) acnt <= acnt + 3'd1;
    wire armed = (acnt == ARM_EDGES[2:0]);
    reg tck_q = 1'b0, hclk_q = 1'b0, req_tgl_q = 1'b0, req_pulse_q = 1'b0, ack_tgl_q = 1'b0;
    reg armed_q = 1'b0, rst_q = 1'b0, por_q = 1'b0, busy_q = 1'b0;
    reg [40:0] payload_q = 41'd0;
    reg  [2:0] cyc = 3'd0;
    always @(posedge gclk) begin
        tck_q <= tck_i; hclk_q <= hclk_i; req_tgl_q <= req_tgl; req_pulse_q <= req_pulse;
        ack_tgl_q <= ack_tgl; armed_q <= armed; req_tgl_q2 <= req_tgl_q; ack_tgl_q2 <= ack_tgl_q; rst_q <= dm_rst_n_i; por_q <= por_n_i;
        busy_q <= busy; payload_q <= payload;
        if (cyc != 3'd7) cyc <= cyc + 3'd1;
    end
    assign chg_req = (req_tgl_q != req_tgl_q2);
    assign chg_ack = (ack_tgl_q != ack_tgl_q2);
    wire h_rise   = hclk_i && !hclk_q;
    wire t_rise   = tck_i && !tck_q;
    // a request issued by the requester: req_tgl changes while out of POR (a change made by
    // POR itself is not a request)
    wire issued   = (req_tgl != req_tgl_q) && por_n_i && por_q;
    // the DM consumes a request: an hclk rising edge with the pulse high just before it
    wire consumed = h_rise && req_pulse_q && rst_q && dm_rst_n_i;
    wire ack_chg  = (ack_tgl != ack_tgl_q);

    // ---- outstanding requests: must (issued armed) and may (issued in reset / arming) ------
    reg pend_must = 1'b0, pend_may = 1'b0, pend_ack = 1'b0;
    reg [3:0] n_req = 4'd0, n_ack = 4'd0, n_hs = 4'd0, n_dtm = 4'd0, may_age = 4'd0;
    always @(posedge gclk) begin
        if (!dm_rst_n_i) begin
            // a DM reset makes an outstanding request "may": the contract is at most once, so
            // it may be dropped (adopted) or, if the synchroniser caught it late, delivered once
            pend_must <= 1'b0; pend_ack <= 1'b0; n_req <= 4'd0; n_ack <= 4'd0; n_hs <= 4'd0;
            if (issued || pend_must) pend_may <= 1'b1;
        end else begin
            if (consumed) begin pend_must <= 1'b0; pend_may <= 1'b0; end
            else if (issued) begin
                if (armed && armed_q) pend_must <= 1'b1; else pend_may <= 1'b1;
            end
            // a may-request not consumed within N_REQ hclk edges of the armed side was dropped
            if (pend_may && !consumed && armed && h_rise && may_age == N_REQ) pend_may <= 1'b0;
            if (consumed || issued) n_req <= 4'd0;
            else if (pend_must && h_rise && n_req != 4'd15) n_req <= n_req + 4'd1;
            if (consumed) pend_ack <= 1'b1; else if (ack_chg) pend_ack <= 1'b0;
            if (consumed || ack_chg) n_ack <= 4'd0;
            else if (pend_ack && h_rise && n_ack != 4'd15) n_ack <= n_ack + 4'd1;
            if (req_tgl == ack_tgl || !armed) n_hs <= 4'd0;
            else if (h_rise && n_hs != 4'd15) n_hs <= n_hs + 4'd1;
        end
        if (!pend_may || consumed || !dm_rst_n_i) may_age <= 4'd0;
        else if (armed && h_rise && may_age != 4'd15) may_age <= may_age + 4'd1;
        // the requester side: busy with ack already equal to req
        if (!por_n_i || !(busy && ack_tgl == req_tgl)) n_dtm <= 4'd0;
        else if (t_rise && n_dtm != 4'd15) n_dtm <= n_dtm + 4'd1;
    end

    reg settled = 1'b0;     // the outstanding request has been consumed or legitimately dropped
    always @(posedge gclk) begin
        if (issued)                       settled <= !dm_rst_n_i || !armed;   // may be dropped
        else if (consumed)                settled <= 1'b1;
        else if (!dm_rst_n_i)             settled <= 1'b1;                    // DM reset after it
    end
    wire acked = busy_q && !busy && por_n_i && por_q;   // the requester sees its acknowledgement

    always @(*) if (cyc > 3'd1) begin
        // the requester is told "done" only for a request the DM consumed or the contract dropped
        a_cdc_ack_genuine:   assert (!acked || settled || consumed);
        // the DM never executes a request the requester was already told is finished
        a_cdc_no_late_exec:  assert (!consumed || busy_q || !por_n_i);
        a_cdc_no_phantom:    assert (!consumed || pend_must || pend_may);
        a_cdc_deliver_bound: assert (n_req <= N_REQ);
        a_cdc_ack_bound:     assert (n_ack <= N_ACK);
        a_cdc_ack_only_done: assert (!ack_chg || pend_ack || consumed || !armed_q || !armed || !dm_rst_n_i || !rst_q);
        a_cdc_hside_done:    assert (n_hs <= N_REQ + N_ACK);
        a_cdc_dtm_sees_ack:  assert (n_dtm <= N_DTM);
        a_req_payload_held:  assert (!(busy && busy_q && por_n_i && por_q) || payload == payload_q);
    end

    // ---- reachability: the scenarios the free environment must still contain -----------------
    reg [3:0] t_idle = 4'd0, h_between_t = 4'd0, t_between_h = 4'd0;
    always @(posedge gclk) begin
        t_idle      <= (busy && !t_rise) ? (t_idle == 4'd15 ? t_idle : t_idle + 4'd1) : 4'd0;
        h_between_t <= t_rise ? 4'd0 : (h_rise && h_between_t != 4'd15 ? h_between_t + 4'd1 : h_between_t);
        t_between_h <= h_rise ? 4'd0 : (t_rise && t_between_h != 4'd15 ? t_between_h + 4'd1 : t_between_h);
    end
    always @(*) if (cyc > 3'd1) begin
        c_delivered:         cover (consumed);
        c_dm_reset_idle:     cover (!dm_rst_n_i && rst_q && !busy && req_tgl);  // DM reset, requester idle, parity 1
        c_dtm_done:          cover (busy_q && !busy && por_n_i);
        c_tck_stopped_busy:  cover (t_idle == 4'd10 && ack_tgl == req_tgl);  // tck stopped mid-handshake, hclk side finished
        c_hreset_pending:    cover (!dm_rst_n_i && rst_q && busy);           // hclk reset with a request outstanding
        c_por_pending:       cover (!por_n_i && por_q && busy_q);            // POR with a request outstanding
        c_dropped_by_reset:  cover (busy && !pend_must && !pend_may && armed && dm_rst_n_i && ack_tgl == req_tgl && !req_pulse);
        c_hclk_fast:         cover (h_between_t >= 4'd5 && busy);            // tck much slower than hclk
        c_tck_fast:          cover (t_between_h >= 4'd5 && pend_must);       // tck much faster than hclk
    end
endmodule

