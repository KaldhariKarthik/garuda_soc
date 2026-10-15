`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 8 : properties for the AHB-to-APB bridge
// ahb2apb_bridge_sva.sv
//
// Spec: GARUDA-AHB2APB-SPEC-001 Rev 2.0, sections 7 and 9 (the [N-x] numbers
// below). Bound to ahb2apb_bridge, so the properties run in the block bench and
// in every chip simulation. pclk is hclk divided by two from a toggle flop
// (D-5), so the AHB side is sampled on hclk and the APB side on pclk, and every
// pclk edge is an hclk edge.
//
// The same file is the property set of the formal run
// flow/formal/ahb2apb/bridge_fpv.tcl: every a_* is an assertion to prove, every
// c_* a cover to reach, and the assume_* are the legal behaviour of the master
// and of the APB slaves, which the formal tool must be told.
// Not compiled for synthesis or lint, and not under Icarus (TOOL-B2).
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module ahb2apb_bridge_sva #(
    parameter [15:0] WINDOW_MASK = 16'h0FFE,
    parameter [23:0] APB_DIV     = 24'h0,
    parameter integer TIMEOUT    = 16
)(
    input wire        hclk_i, hreset_n_i, pclk_i, preset_n_i,
    // AHB-Lite slave side
    input wire        hsel_i, hready_i, hwrite_i,
    input wire [1:0]  htrans_i,
    input wire [2:0]  hsize_i,
    input wire [31:0] haddr_i,
    input wire        hreadyout_o, hresp_o,
    // APB master side
    input wire [11:0] psel_o, paddr_o,
    input wire        penable_o, pwrite_o,
    input wire [31:0] pwdata_o,
    input wire [11:0] pready_i, pslverr_i,
    // internals: the hclk side machine, the toggles, the APB side machine
    input wire [2:0]  hstate,
    input wire        prst_ok_q, win_ok, word_ok, xfer,
    input wire        req_tgl, ack_tgl, ack_new, apb_err,
    input wire [3:0]  win_cap,
    input wire [11:0] addr_cap,
    input wire        write_cap,
    input wire [1:0]  pstate,
    input wire [2:0]  div_cnt,
    input wire [4:0]  to_cnt
);
    localparam [2:0] H_IDLE = 3'd0, H_CAPT = 3'd1, H_WAIT = 3'd2,
                     H_OK   = 3'd3, H_ERR1 = 3'd4, H_ERR2 = 3'd5;
    localparam [1:0] P_IDLE = 2'd0, P_SETUP = 2'd1, P_ACCESS = 2'd2, P_DONE = 2'd3;
    // the longest legal access: setup, the divider (1 << 2 = 8 cycles at /8), the
    // timeout, done; twice for the hclk side and a margin of the toggle handshake
    localparam integer MAXWAIT = 2 * (TIMEOUT + 8 + 4) + 4;

    // ======================= what the surroundings must do (formal) ===========
    // AHB-Lite master: an address phase is stable until accepted. Only needed to keep
    // the formal tool from inventing an illegal master; in simulation these are the
    // BFM's behaviour and are asserted, not assumed, by the AHB interconnect.
    assume_htrans_stable: assume property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (htrans_i[1] && !hready_i) |=> $stable({htrans_i, haddr_i, hwrite_i, hsize_i}) );
    assume_hsel_window: assume property (@(posedge hclk_i) hsel_i |-> haddr_i[31:28] == 4'h4);

    // ======================= AHB side =========================================
    // [N-7.21] an error is exactly two cycles: not ready with ERROR, then ready with ERROR
    a_err_two_cycles: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hresp_o && !hreadyout_o) |=> (hresp_o && hreadyout_o) )
        else $error("[SVA-FAIL] a_err_two_cycles: ERROR response is not a two-cycle response");
    // ... and it ends there, unless the access accepted in that last cycle is itself bad
    // (two bad accesses back to back give two ERROR responses in a row)
    a_err_ends: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hresp_o && hreadyout_o) |=> (!hresp_o || $past(xfer && (!win_ok || !word_ok))) )
        else $error("[SVA-FAIL] a_err_ends: ERROR lasts more than two cycles");
    // [N-9.2], [N-9.3] no ready while the APB side is still in reset
    a_no_ready_in_reset: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !prst_ok_q |-> !hreadyout_o )
        else $error("[SVA-FAIL] a_no_ready_in_reset: HREADYOUT high while preset_n is not released");
    // a good transfer produces exactly one APB request
    a_good_one_request: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        hstate == H_CAPT |=> req_tgl != $past(req_tgl) )
        else $error("[SVA-FAIL] a_good_one_request: capture without a request toggle");
    // [N-7.12], [N-7.19] a sub-word access or an absent window makes no APB transfer
    a_bad_no_request: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hstate inside {H_IDLE, H_OK, H_ERR2}) && !(hstate == H_ERR2 && !prst_ok_q)
        && xfer && (!win_ok || !word_ok) |=> ($stable(req_tgl) && hstate == H_ERR1) )
        else $error("[SVA-FAIL] a_bad_no_request: an illegal access started an APB transfer");
    // [N-7.20] a slave error, a timeout, becomes ERROR on the bus; otherwise OKAY
    a_slverr_to_error: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hstate == H_WAIT && ack_new && apb_err) |=> hstate == H_ERR1 )
        else $error("[SVA-FAIL] a_slverr_to_error: an APB error did not become an AHB ERROR");
    a_ok_to_okay: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hstate == H_WAIT && ack_new && !apb_err) |=> (hstate == H_OK && !hresp_o) )
        else $error("[SVA-FAIL] a_ok_to_okay: a good APB transfer did not give OKAY");
    // [N-7.8] a_capture_stable_at_phase: the captures do not move while the APB side works
    a_capture_stable: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hstate == H_WAIT && $past(hstate) == H_WAIT) |-> $stable({win_cap, addr_cap, write_cap}) )
        else $error("[SVA-FAIL] a_capture_stable: capture moved during an APB transfer");
    // [N-7.15] a_no_hang: the bus is given back within the access budget
    a_no_hang: assert property (@(posedge hclk_i) disable iff (!hreset_n_i || !prst_ok_q)
        hstate == H_WAIT |-> ##[1:MAXWAIT] hstate != H_WAIT )
        else $error("[SVA-FAIL] a_no_hang: HREADYOUT low for longer than the timeout allows");

    // ======================= APB side (pclk) ==================================
    // [N-7.1] PSEL one-hot, only for windows that exist
    a_psel_onehot: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        $onehot0(psel_o) )
        else $error("[SVA-FAIL] a_psel_onehot: two windows selected");
    a_psel_present: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (psel_o & ~WINDOW_MASK[11:0]) == 12'd0 )
        else $error("[SVA-FAIL] a_psel_present: PSEL for a window that is not in the mask");
    // APB3: SETUP is one cycle with PENABLE low, ACCESS follows with PENABLE high
    a_setup_then_access: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        $rose(|psel_o) |-> (!penable_o ##1 (penable_o && |psel_o)) )
        else $error("[SVA-FAIL] a_setup_then_access: APB SETUP is not one PENABLE-low cycle");
    a_penable_needs_psel: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        penable_o |-> |psel_o )
        else $error("[SVA-FAIL] a_penable_needs_psel: PENABLE without PSEL");
    // APB3: address, direction and write data hold from SETUP to the end of ACCESS
    a_apb_stable: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        ((|psel_o) && $past(|psel_o)) |-> ($stable(paddr_o) && $stable(pwrite_o) && $stable(pwdata_o)) )
        else $error("[SVA-FAIL] a_apb_stable: address, direction or data moved inside a transfer");
    // the write data lines are zero for a read
    a_read_wdata_zero: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !pwrite_o |-> pwdata_o == 32'd0 )
        else $error("[SVA-FAIL] a_read_wdata_zero: write data present on a read");
    // [N-7.15] ACCESS ends within the divider plus the timeout (the 16th PREADY-low cycle)
    a_access_bounded: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        $rose(penable_o) |-> ##[1:TIMEOUT + 9] !penable_o )
        else $error("[SVA-FAIL] a_access_bounded: ACCESS lasts longer than divider plus timeout");
    // the timeout counter never counts past the limit
    a_timeout_counter: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        to_cnt <= TIMEOUT - 1 )
        else $error("[SVA-FAIL] a_timeout_counter: the timeout counter passed its limit");

    // ======================= reachability: one cover per feature ==============
    c_read_ok:       cover property (@(posedge hclk_i) hstate == H_WAIT && ack_new && !apb_err && !write_cap);
    c_write_ok:      cover property (@(posedge hclk_i) hstate == H_WAIT && ack_new && !apb_err && write_cap);
    c_slave_error:   cover property (@(posedge hclk_i) hstate == H_WAIT && ack_new && apb_err);
    c_absent_window: cover property (@(posedge hclk_i) hstate == H_IDLE && xfer && !win_ok && word_ok);
    c_subword:       cover property (@(posedge hclk_i) hstate == H_IDLE && xfer && win_ok && !word_ok);
    c_timeout:       cover property (@(posedge pclk_i) pstate == P_ACCESS && div_cnt == 3'd0 && !(|(pready_i & psel_o))
                                     && to_cnt == TIMEOUT - 1);
    c_div_extra:     cover property (@(posedge pclk_i) pstate == P_ACCESS && div_cnt != 3'd0);
    c_back_to_back:  cover property (@(posedge hclk_i) hstate == H_OK && xfer && win_ok && word_ok);
    c_after_error:   cover property (@(posedge hclk_i) hstate == H_ERR2 && xfer && win_ok && word_ok);
    c_in_reset:      cover property (@(posedge hclk_i) !prst_ok_q && xfer);
    c_apb_wait:      cover property (@(posedge pclk_i) pstate == P_ACCESS && div_cnt == 3'd0 && !(|(pready_i & psel_o)) && to_cnt != 0);
endmodule

bind ahb2apb_bridge ahb2apb_bridge_sva #(
    .WINDOW_MASK(WINDOW_MASK), .APB_DIV(APB_DIV), .TIMEOUT(TIMEOUT)
) u_bridge_sva (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .pclk_i(pclk_i), .preset_n_i(preset_n_i),
    .hsel_i(hsel_i), .hready_i(hready_i), .hwrite_i(hwrite_i), .htrans_i(htrans_i),
    .hsize_i(hsize_i), .haddr_i(haddr_i), .hreadyout_o(hreadyout_o), .hresp_o(hresp_o),
    .psel_o(psel_o), .paddr_o(paddr_o), .penable_o(penable_o), .pwrite_o(pwrite_o),
    .pwdata_o(pwdata_o), .pready_i(pready_i), .pslverr_i(pslverr_i),
    .hstate(hstate), .prst_ok_q(prst_ok_q), .win_ok(win_ok), .word_ok(word_ok), .xfer(xfer),
    .req_tgl(req_tgl), .ack_tgl(ack_tgl), .ack_new(ack_new), .apb_err(apb_err),
    .win_cap(win_cap), .addr_cap(addr_cap), .write_cap(write_cap),
    .pstate(u_fsm.state), .div_cnt(u_fsm.div_cnt), .to_cnt(u_fsm.to_cnt));
`endif
`endif
