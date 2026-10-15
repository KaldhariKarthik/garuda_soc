`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 12 : properties for the debug block
// debug_sva.sv
//
// Spec: GARUDA-DEBUG-SPEC-001, IEEE 1149.1 (the TAP), RISC-V Debug 0.13 (the
// DTM, the DM, system bus access) and AHB-Lite (the SBA master). Bound to
// debug_top; the TAP and DTM properties are on tck, the DM, SBA and the hclk
// side of the crossing on hclk. tck and hclk are unrelated.
// Property set of flow/formal/debug/debug_fpv.tcl.
// Not compiled for synthesis or lint, and not under Icarus (TOOL-B2).
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module debug_sva (
    input wire        tck_i, tms_i, por_n_i, hclk_i, dm_rst_n_i,
    input wire        tdo_oe_o,
    input wire [31:0] haddr_o,
    input wire [1:0]  htrans_o,
    input wire        hwrite_o, hready_i, hresp_i,
    input wire [2:0]  hsize_o, hburst_o,
    input wire        ndmreset_o, hartreset_o,
    // TAP
    input wire [3:0]  tap_st,
    input wire [4:0]  ir_q, ir_sh,
    // DTM
    input wire        req_tgl, ack_seen, update_dr, capture_dr, tlr,
    input wire [1:0]  dmistat,
    input wire [6:0]  req_addr,
    input wire [31:0] req_data,
    input wire [1:0]  req_op,
    input wire [40:0] dtm_sh,
    input wire [4:0]  dtm_ir,
    // crossing, hclk side
    input wire        req_pulse, ack_tgl, ack_pulse, armed,
    // DM
    input wire        req_i, done_o, dmactive, sbbusy, sbbusyerror, sbautoinc,
    input wire [2:0]  sberror, sbaccess,
    input wire [31:0] sbaddr,
    input wire        sba_start, sba_done, sba_err, dm_wr, dm_rd,
    input wire [6:0]  dm_addr,
    // SBA master
    input wire [1:0]  sba_st,
    input wire        sba_busy
);
    localparam [3:0] TLR = 4'h0, SHDR = 4'h4, UPDR = 4'h8, CAPIR = 4'hA, SHIR = 4'hB;
    localparam [6:0] A_SBADDR0 = 7'h39, A_SBDATA0 = 7'h3C, A_DMCONTROL = 7'h10;
    wire busy = (req_tgl != ack_seen);

    // ---- surroundings --------------------------------------------------------
    assume_slave_error2: assume property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        (hresp_i && !hready_i) |=> (hresp_i && hready_i) );
    assume_slave_okay_idle: assume property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        (sba_st == 2'd0) |-> !hresp_i );

    // ======================= TAP (IEEE 1149.1), tck ===========================
    // five TCK with TMS high reach Test-Logic-Reset from any state
    a_tap_five_tms: assert property (@(posedge tck_i) disable iff (!por_n_i)
        tms_i [*5] |=> tap_st == TLR )
        else $error("[SVA-FAIL] a_tap_five_tms: five TMS=1 did not reach Test-Logic-Reset");
    // Test-Logic-Reset selects IDCODE
    a_tap_tlr_idcode: assert property (@(posedge tck_i) disable iff (!por_n_i)
        tap_st == TLR |=> ir_q == 5'h01 )
        else $error("[SVA-FAIL] a_tap_tlr_idcode: Test-Logic-Reset did not select IDCODE");
    // Capture-IR loads ...01 into the instruction shift register
    a_tap_capture_ir: assert property (@(posedge tck_i) disable iff (!por_n_i)
        tap_st == CAPIR |=> ir_sh[1:0] == 2'b01 )
        else $error("[SVA-FAIL] a_tap_capture_ir: Capture-IR did not load 01");
    // TDO is driven only in Shift-IR and Shift-DR (it changes on the falling edge, so at a rising
    // edge it shows the state the TAP had in the half period before)
    a_tap_tdo_oe: assert property (@(posedge tck_i) disable iff (!por_n_i)
        $past(por_n_i) |-> tdo_oe_o == (tap_st == SHIR || tap_st == SHDR) )
        else $error("[SVA-FAIL] a_tap_tdo_oe: TDO enable outside the shift states");

    // ======================= DTM (Debug 0.13 section 6.1), tck ================
    // one DMI request at a time: a new request only when the last was answered
    a_dtm_one_outstanding: assert property (@(posedge tck_i) disable iff (!por_n_i)
        ($past(por_n_i) && $changed(req_tgl)) |-> !$past(busy) )
        else $error("[SVA-FAIL] a_dtm_one_outstanding: a DMI request while one was outstanding");
    // the request fields do not change while it is outstanding (the hclk side samples them)
    a_dtm_payload_held: assert property (@(posedge tck_i) disable iff (!por_n_i)
        ($past(por_n_i) && $past(busy) && busy) |-> $stable({req_addr, req_data, req_op}) )
        else $error("[SVA-FAIL] a_dtm_payload_held: the DMI payload moved while outstanding");
    // a scan that finds the DTM busy is refused and the busy status is sticky (DBG-1)
    a_dtm_busy_sticky: assert property (@(posedge tck_i) disable iff (!por_n_i)
        (capture_dr && dtm_ir == 5'h11 && busy && !tlr) |=> dmistat == 2'd3 )
        else $error("[SVA-FAIL] a_dtm_busy_sticky: a busy capture did not set dmistat = 3");
    a_dtm_no_req_when_sticky: assert property (@(posedge tck_i) disable iff (!por_n_i)
        ($past(por_n_i) && $changed(req_tgl)) |-> $past(dmistat) == 2'd0 )
        else $error("[SVA-FAIL] a_dtm_no_req_when_sticky: a request was issued with a sticky error");
    // Test-Logic-Reset clears the DMI status
    a_dtm_tlr_clears: assert property (@(posedge tck_i) disable iff (!por_n_i)
        tlr |=> dmistat == 2'd0 )
        else $error("[SVA-FAIL] a_dtm_tlr_clears: Test-Logic-Reset did not clear dmistat");
    // IDCODE capture
    a_dtm_idcode: assert property (@(posedge tck_i) disable iff (!por_n_i)
        (capture_dr && dtm_ir == 5'h01 && !tlr) |=> dtm_sh[31:0] == 32'h0000_0DB1 )
        else $error("[SVA-FAIL] a_dtm_idcode: IDCODE captured wrong");

    // ======================= crossing, hclk side ==============================
    // one hclk pulse per request toggle, never two in a row
    a_cdc_single_pulse: assert property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        req_pulse |=> !req_pulse )
        else $error("[SVA-FAIL] a_cdc_single_pulse: two request pulses in a row");
    // the payload the DM uses has been stable for the two synchroniser cycles
    a_cdc_payload_settled: assert property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        req_pulse |-> ($stable({req_addr, req_data, req_op}) && $past($stable({req_addr, req_data, req_op}))) )
        else $error("[SVA-FAIL] a_cdc_payload_settled: the DM took a payload that was still moving");
    // the acknowledge toggles only for a finished DM access
    a_cdc_ack_only_done: assert property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        ($past(dm_rst_n_i) && $changed(ack_tgl) && $past(armed)) |-> $past(ack_pulse) )
        else $error("[SVA-FAIL] a_cdc_ack_only_done: ack toggled without a finished access");

    // ======================= DM (Debug 0.13 section 3.12), hclk ===============
    a_dm_done_follows_req: assert property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        req_i |=> done_o )
        else $error("[SVA-FAIL] a_dm_done_follows_req: a DMI access was not answered");
    a_dm_done_only_req: assert property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        done_o |-> $past(req_i) )
        else $error("[SVA-FAIL] a_dm_done_only_req: an answer without an access");
    // dmactive = 0 holds the DM in reset: no reset request out, no SBA transfer (DBG-3)
    a_dm_inactive_quiet: assert property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        !dmactive |-> (!ndmreset_o && !hartreset_o) )
        else $error("[SVA-FAIL] a_dm_inactive_quiet: a reset request while dmactive = 0");
    a_dm_no_sba_inactive: assert property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        sba_start |-> $past(dmactive) )
        else $error("[SVA-FAIL] a_dm_no_sba_inactive: an SBA transfer started with the DM inactive");
    // [N-7.6] an SBA transfer starts only when idle, word sized, aligned, with no error pending
    a_dm_start_idle: assert property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        sba_start |-> !$past(sbbusy) )
        else $error("[SVA-FAIL] a_dm_start_idle: an SBA transfer started while one was running");
    a_dm_start_legal: assert property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        sba_start |-> (sbaddr[1:0] == 2'b00 && sbaccess == 3'd2 && $past(sberror) == 3'd0 && !$past(sbbusyerror)) )
        else $error("[SVA-FAIL] a_dm_start_legal: an SBA transfer started that should have been refused");
    // a DMI write to sbaddress0 or sbdata0 while busy sets sbbusyerror
    a_dm_busyerror: assert property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        (dm_wr && dmactive && sbbusy && (dm_addr == A_SBADDR0 || dm_addr == A_SBDATA0)) |=> sbbusyerror )
        else $error("[SVA-FAIL] a_dm_busyerror: an access while busy did not set sbbusyerror");
    // a bus error sets sberror = 4
    a_dm_bus_error: assert property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        (sba_done && sba_err && dmactive && !(dm_wr && dm_addr == A_DMCONTROL)) |=> sberror == 3'd4 )
        else $error("[SVA-FAIL] a_dm_bus_error: an SBA bus error did not set sberror = 4");
    // sbautoincrement adds 4 after a good transfer
    a_dm_autoinc: assert property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        (sba_done && !sba_err && dmactive && sbautoinc && !(dm_wr && (dm_addr == A_SBADDR0 || dm_addr == A_DMCONTROL)))
        |=> sbaddr == $past(sbaddr) + 32'd4 )
        else $error("[SVA-FAIL] a_dm_autoinc: sbautoincrement did not add 4");

    // ======================= SBA master (AHB-Lite), hclk ======================
    a_sba_single_word: assert property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        (hsize_o == 3'b010 && hburst_o == 3'b000 && htrans_o != 2'b11 && htrans_o != 2'b01) )
        else $error("[SVA-FAIL] a_sba_single_word: SBA transfer not a single word");
    a_sba_addr_stable: assert property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        (htrans_o[1] && !hready_i) |=> $stable({haddr_o, htrans_o, hwrite_o}) )
        else $error("[SVA-FAIL] a_sba_addr_stable: the SBA address phase changed before acceptance");
    a_sba_aligned: assert property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        htrans_o[1] |-> haddr_o[1:0] == 2'b00 )
        else $error("[SVA-FAIL] a_sba_aligned: an unaligned SBA transfer");
    a_sba_one_done: assert property (@(posedge hclk_i) disable iff (!dm_rst_n_i)
        sba_done |-> $past(sba_st) == 2'd2 )
        else $error("[SVA-FAIL] a_sba_one_done: done without a data phase");

    // ---- reachability --------------------------------------------------------
    c_dmi_write:   cover property (@(posedge tck_i) $changed(req_tgl) && req_op == 2'd2);
    c_dmi_read:    cover property (@(posedge tck_i) $changed(req_tgl) && req_op == 2'd1);
    c_busy_sticky: cover property (@(posedge tck_i) $rose(dmistat == 2'd3));
    c_dm_access:   cover property (@(posedge hclk_i) req_i);
    c_sba_read:    cover property (@(posedge hclk_i) sba_done && !hwrite_o && !sba_err);
    c_sba_write:   cover property (@(posedge hclk_i) sba_start && hwrite_o == 1'b0 && 1'b1);
    c_sba_error:   cover property (@(posedge hclk_i) sba_done && sba_err);
    c_busyerror:   cover property (@(posedge hclk_i) $rose(sbbusyerror));
    c_autoinc:     cover property (@(posedge hclk_i) sba_done && sbautoinc && !sba_err);
    c_ndmreset:    cover property (@(posedge hclk_i) $rose(ndmreset_o));
    c_hartreset:   cover property (@(posedge hclk_i) $rose(hartreset_o));
    c_unaligned_refused: cover property (@(posedge hclk_i) $rose(sberror == 3'd2));
endmodule

bind debug_top debug_sva u_debug_sva (
    .tck_i(tck_i), .tms_i(tms_i), .por_n_i(por_n_i), .hclk_i(hclk_i), .dm_rst_n_i(dm_rst_n_i),
    .tdo_oe_o(tdo_oe_o), .haddr_o(haddr_o), .htrans_o(htrans_o), .hwrite_o(hwrite_o),
    .hready_i(hready_i), .hresp_i(hresp_i), .hsize_o(hsize_o), .hburst_o(hburst_o),
    .ndmreset_o(ndmreset_o), .hartreset_o(hartreset_o),
    .tap_st(u_tap.st), .ir_q(u_tap.ir_q), .ir_sh(u_tap.ir_sh),
    .req_tgl(req_tgl), .ack_seen(u_dtm.ack_seen), .update_dr(up_dr), .capture_dr(cap_dr), .tlr(tlr),
    .dmistat(u_dtm.dmistat), .req_addr(req_addr), .req_data(req_data), .req_op(req_op),
    .dtm_sh(u_dtm.sh), .dtm_ir(ir),
    .req_pulse(req_pulse), .ack_tgl(ack_tgl), .ack_pulse(dm_done), .armed(u_cdc.armed),
    .req_i(req_pulse), .done_o(dm_done), .dmactive(u_dm.dmactive), .sbbusy(u_dm.sbbusy),
    .sbbusyerror(u_dm.sbbusyerror), .sbautoinc(u_dm.sbautoinc), .sberror(u_dm.sberror),
    .sbaccess(u_dm.sbaccess), .sbaddr(u_dm.sbaddr),
    .sba_start(sba_start), .sba_done(sba_done), .sba_err(sba_err),
    .dm_wr(u_dm.wr), .dm_rd(u_dm.rd), .dm_addr(req_addr),
    .sba_st(u_sba.st), .sba_busy(sba_busy));
`endif
`endif
