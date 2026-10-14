`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Blocks 7/8 : bound properties of the AHB-to-APB bridge + fabric
// ahb2apb_sva.sv
//
// Spec: GARUDA-AHB2APB-SPEC-001 section 10 (the 16 named properties, all "NOT
// IMPLEMENTED as SVA" in tb/ahb2apb/GARUDA_AHB2APB_vplan.csv until now), R-1..R-8,
// [N-7.x]; garuda_system.yaml (48 KiB aperture, 12 windows, word only, 16-pclk
// timeout); APB-2 (aperture). Track A bus plan B2. Portable form of
// Docs/handbook/H4_coding.md (no |-> / |=>; $past gated by past_ok; a cover on
// every antecedent).
//
// HOW IT CHECKS. A spec model from the ports:
//   - every AHB transfer the bridge accepts is LEGAL (window present in WINDOW_MASK,
//     word size, HADDR[27:16] == 0) or not; a legal one must cause exactly one APB
//     transfer, an illegal one none, and either ends in exactly one AHB completion;
//   - each APB transfer is timed in ACCESS cycles: the window's APB_DIV extension,
//     then PREADY samples; it ends on the first sampled PREADY or after TIMEOUT
//     samples, never earlier and never later;
//   - the AHB response is ERROR exactly when the transfer was illegal, the target
//     answered PSLVERR or the timeout fired; a read that completes OKAY returns the
//     PRDATA the target gave.
// White-box (named in each property): the bridge's hclk state and capture
// registers, the fabric's selected return.
// =============================================================================

`ifdef FORMAL
  `define GARUDA_APB_SVA
`elsif SYNTHESIS
`else
  `define GARUDA_APB_SVA
`endif

`ifdef GARUDA_APB_SVA
module ahb2apb_sva #(
    parameter [15:0] WINDOW_MASK = 16'h0FFE,
    parameter [23:0] APB_DIV     = 24'h0,
    parameter integer TIMEOUT    = 16
)(
    input wire        hclk_i,
    input wire        hreset_n_i,
    input wire        pclk_i,
    input wire        preset_n_i,
    input wire        hsel_i,
    input wire [31:0] haddr_i,
    input wire [1:0]  htrans_i,
    input wire        hwrite_i,
    input wire [2:0]  hsize_i,
    input wire        hready_i,
    input wire [31:0] hrdata_o,
    input wire        hreadyout_o,
    input wire        hresp_o,
    input wire [11:0] psel_o,
    input wire        penable_o,
    input wire        pwrite_o,
    input wire [11:0] paddr_o,
    input wire [31:0] pwdata_o,
    input wire [12*32-1:0] prdata_i,
    input wire [11:0] pready_i,
    input wire [11:0] pslverr_i,
    // white-box
    input wire [2:0]  hstate,
    input wire [3:0]  win_cap,
    input wire [11:0] addr_cap,
    input wire        write_cap,
    input wire [31:0] wdata_cap,
    input wire [31:0] prdata_sel,
    input wire        pready_sel,
    input wire        pslverr_sel,
    input wire [4:0]  to_cnt,           // the pclk FSM's timeout counter (coverage evidence)
    input wire [1:0]  pstate            // the pclk FSM's state
);
    localparam [2:0] H_WAIT = 3'd2;
    localparam integer HANG_MAX = 2 * (4 + 7 + TIMEOUT) + 8;   // hclk cycles, worst legal transfer + margin

    // ---- AHB side model (hclk) ------------------------------------------------------
    wire acc   = hsel_i && htrans_i[1] && hready_i;
    wire win_p = WINDOW_MASK[haddr_i[15:12]];
    wire legal = win_p && (hsize_i == 3'b010) && (haddr_i[27:16] == 12'h000);
    reg  hlive, past_ok;
    reg  dp, dp_legal, dp_write;          // the bridge's data phase in flight and what it was
    reg  [1:0] n_start, n_end;            // APB transfers started / ended inside this data phase
    reg  end_err;                         // the last APB transfer ended in PSLVERR or a timeout
    reg  [31:0] end_rdata;                // ... and the PRDATA it returned
    reg  [7:0]  low_run;                  // consecutive cycles of HREADYOUT low (prst ok)
    reg  psel_any_h;
    reg  end_seen_q;                      // pclk model's end event, seen on hclk

    // ---- APB side model (pclk) ------------------------------------------------------
    function automatic [3:0] widx(input [11:0] p);
        widx = 4'd0;
        for (int i = 0; i < 12; i++) if (p[i]) widx = i[3:0];
    endfunction
    function automatic [3:0] ext_of(input [3:0] w);          // ACCESS cycles before PREADY is sampled
        logic [1:0] d;
        d = (w < 4'd12) ? APB_DIV[2*w +: 2] : 2'b00;
        ext_of = (4'd1 << d) - 4'd1;                         // 0, 1, 3, 7
    endfunction
    reg        plive, ppast_ok;
    reg  [5:0] acc_cnt;                   // ACCESS cycles already spent (0 in the first ACCESS cycle)
    reg        end_evt;                   // toggles at every APB end (cross-domain event)
    reg        end_err_p;
    reg [31:0] end_rdata_p;
    wire [3:0] w   = widx(psel_o);
    wire [3:0] ext = ext_of(w);
    wire       in_access = penable_o && (|psel_o);
    // the first ext ACCESS cycles are the APB_DIV extension; PREADY is sampled from then on
    wire       sample    = in_access && (acc_cnt >= {2'b0, ext});
    wire       rdy_w     = pready_i[w];
    // the TIMEOUT-th sample without PREADY ends the transfer ([N-7.15])
    wire       timeout   = in_access && (acc_cnt == {2'b0, ext} + TIMEOUT[5:0] - 6'd1) && !rdy_w;
    wire       ends      = (sample && rdy_w) || timeout;            // the transfer ends at this pclk edge

    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            plive <= 1'b0; ppast_ok <= 1'b0; acc_cnt <= 6'd0; end_evt <= 1'b0;
            end_err_p <= 1'b0; end_rdata_p <= 32'd0;
        end else begin
            plive <= 1'b1; ppast_ok <= plive;
            acc_cnt <= in_access ? acc_cnt + 6'd1 : 6'd0;
            if (in_access && ends) begin
                end_evt     <= ~end_evt;
                end_err_p   <= timeout || pslverr_i[w];
                end_rdata_p <= timeout ? 32'd0 : prdata_i[32*w +: 32];
            end
        end
    end

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            hlive <= 1'b0; past_ok <= 1'b0; dp <= 1'b0; dp_legal <= 1'b0; dp_write <= 1'b0;
            n_start <= 2'd0; n_end <= 2'd0; end_err <= 1'b0; end_rdata <= 32'd0; low_run <= 8'd0;
            psel_any_h <= 1'b0; end_seen_q <= 1'b0;
        end else begin
            hlive <= 1'b1; past_ok <= hlive;
            psel_any_h <= |psel_o;
            end_seen_q <= end_evt;
            if (end_evt != end_seen_q) begin
                end_err <= end_err_p; end_rdata <= end_rdata_p;
                if (dp) n_end <= n_end + 2'd1;
            end
            if ((|psel_o) && !psel_any_h && dp) n_start <= n_start + 2'd1;
            if (dp && hreadyout_o) dp <= 1'b0;                     // data phase completes
            if (acc) begin
                dp <= 1'b1; dp_legal <= legal; dp_write <= hwrite_i; n_start <= 2'd0; n_end <= 2'd0;
            end
            low_run <= (hreadyout_o || !preset_n_i) ? 8'd0 : (low_run == 8'hFF ? 8'hFF : low_run + 8'd1);
        end
    end

    // =========================================================================
    // APB protocol (pclk): a_apb_setup, a_penable_needs_psel, a_psel_onehot,
    // a_apb_addr_stable, a_apb_wdata_stable  (R-1, section 10)
    // =========================================================================
    a_psel_onehot: assert property (@(posedge pclk_i) disable iff (!preset_n_i) $onehot0(psel_o));
    a_penable_needs_psel: assert property (@(posedge pclk_i) disable iff (!preset_n_i) !penable_o || (|psel_o));
    // a transfer starts with SETUP (PSEL, no PENABLE) ...
    a_apb_setup_first: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !(ppast_ok && (|psel_o) && !$past(|psel_o)) || !penable_o);
    // ... which lasts exactly one cycle and is followed by ACCESS on the same window
    a_apb_setup: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !(ppast_ok && $past((|psel_o) && !penable_o)) || (penable_o && psel_o == $past(psel_o)));
    a_apb_addr_stable: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !(ppast_ok && $past(|psel_o) && (|psel_o)) ||
        (paddr_o == $past(paddr_o) && pwrite_o == $past(pwrite_o) && psel_o == $past(psel_o)));
    a_apb_wdata_stable: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !(ppast_ok && $past(|psel_o && pwrite_o) && (|psel_o)) || pwdata_o == $past(pwdata_o));
    // a_unmapped: no PSEL on a window the chip does not have
    a_unmapped: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (psel_o & ~WINDOW_MASK[11:0]) == 12'd0);

    // =========================================================================
    // Timing of ACCESS (pclk): a_apb_div, a_timeout_at_16 (R-5, R-7, [N-7.15])
    // =========================================================================
    // the transfer leaves ACCESS exactly when the model says it ends, never earlier
    // (a PREADY during the APB_DIV extension is not taken) and never later
    a_apb_div: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !(ppast_ok && $past(in_access) && !$past(ends)) || in_access);
    a_access_ends: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !(ppast_ok && $past(in_access && ends)) || !(|psel_o));
    a_timeout_at_16: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !in_access || acc_cnt <= {2'b0, ext} + TIMEOUT[5:0] - 6'd1);
    c_div_ready_early: cover property (@(posedge pclk_i) disable iff (!preset_n_i) in_access && !sample && rdy_w && ext != 0);
    c_timeout:         cover property (@(posedge pclk_i) disable iff (!preset_n_i) timeout);
    c_ready_last:      cover property (@(posedge pclk_i) disable iff (!preset_n_i)
        sample && rdy_w && acc_cnt == {2'b0, ext} + TIMEOUT[5:0] - 6'd1);
    c_slverr:          cover property (@(posedge pclk_i) disable iff (!preset_n_i) sample && rdy_w && pslverr_i[w]);

    // a_resp_from_active_window (white-box fabric): the return is the selected window's
    a_resp_from_active_window: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !(|psel_o) || (pready_sel == pready_i[w] && pslverr_sel == pslverr_i[w] && prdata_sel == prdata_i[32*w +: 32]));

    // =========================================================================
    // AHB side (hclk): one-to-one, no APB activity for a rejected request,
    // the response, the two-cycle ERROR, no hang, the reset gap
    // =========================================================================
    // a_subword_no_apb / a_unmapped / APB-2 aperture: an illegal transfer starts no APB transfer
    a_subword_no_apb: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(dp && !dp_legal) || n_start == 2'd0);
    // a_one_to_one: a legal transfer causes exactly one APB transfer before it completes
    a_one_to_one: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(dp && hreadyout_o && dp_legal && hlive) ||
        (n_start + ((|psel_o) && !psel_any_h ? 2'd1 : 2'd0) == 2'd1 &&
         n_end + ((end_evt != end_seen_q) ? 2'd1 : 2'd0) == 2'd1));
    a_one_apb_at_a_time: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) n_start <= 2'd1);
    // a_subword_error / a_slverr_prop / timeout: the response follows the model
    a_resp: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(dp && hreadyout_o) || hresp_o == (!dp_legal || end_err));
    a_rdata: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(dp && hreadyout_o && dp_legal && !dp_write && !hresp_o) || hrdata_o == end_rdata);
    // a_error_two_cycle: every ERROR is HREADY low then HREADY high
    a_error_two_cycle: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(past_ok && $past(hresp_o && !hreadyout_o) && preset_n_i && $past(preset_n_i)) || (hresp_o && hreadyout_o));
    a_error_first_cycle: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(past_ok && hresp_o && hreadyout_o) || $past(hresp_o && !hreadyout_o));
    a_okay_outside_error: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(hresp_o && hreadyout_o) || dp);
    // a_no_hang (R-7): a data phase never waits more than HANG_MAX cycles
    a_no_hang: assert property (@(posedge hclk_i) disable iff (!hreset_n_i || !preset_n_i) low_run <= HANG_MAX[7:0]);
    // a_dual_reset_hold ([N-9.2], [N-9.3]): HREADYOUT low while the APB side is in reset
    a_dual_reset_hold: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(past_ok && $past(!preset_n_i)) || !hreadyout_o);
    // a_capture_stable_at_phase (white-box, was a $display in the RTL): the captured
    // window / address / direction / data do not move while the APB side works on them
    a_capture_stable_at_phase: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(past_ok && hstate == H_WAIT && $past(hstate == H_WAIT)) ||
        (win_cap == $past(win_cap) && addr_cap == $past(addr_cap) && write_cap == $past(write_cap) &&
         wdata_cap == $past(wdata_cap)));

    // white-box invariants, the evidence for coverage waivers (tb/ahb2apb/cov):
    // the hclk FSM uses six of its eight codes; only legal windows are captured; the
    // timeout counter never passes TIMEOUT-1 (bit 4 of the 5-bit counter stays 0)
    a_hstate_legal: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) hstate <= 3'd5);
    a_win_cap_legal: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        hstate != H_WAIT || (win_cap < 4'd12 && WINDOW_MASK[win_cap]));
    a_to_cnt_max: assert property (@(posedge pclk_i) disable iff (!preset_n_i) to_cnt <= TIMEOUT[4:0] - 5'd1);
    c_legal_read:   cover property (@(posedge hclk_i) disable iff (!hreset_n_i) acc && legal && !hwrite_i);
    c_legal_write:  cover property (@(posedge hclk_i) disable iff (!hreset_n_i) acc && legal && hwrite_i);
    c_subword:      cover property (@(posedge hclk_i) disable iff (!hreset_n_i) acc && win_p && hsize_i != 3'b010);
    c_absent:       cover property (@(posedge hclk_i) disable iff (!hreset_n_i) acc && !win_p);
    c_aperture:     cover property (@(posedge hclk_i) disable iff (!hreset_n_i) acc && win_p && hsize_i == 3'b010 && haddr_i[27:16] != 0);
    c_back_to_back: cover property (@(posedge hclk_i) disable iff (!hreset_n_i) dp && hreadyout_o && acc);
    c_err_resp:     cover property (@(posedge hclk_i) disable iff (!hreset_n_i) dp && hreadyout_o && hresp_o && dp_legal);
    c_reset_gap:    cover property (@(posedge hclk_i) disable iff (!hreset_n_i) !preset_n_i && acc);
endmodule

bind ahb2apb_bridge ahb2apb_sva #(.WINDOW_MASK(WINDOW_MASK), .APB_DIV(APB_DIV), .TIMEOUT(TIMEOUT)) u_apb_sva (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .pclk_i(pclk_i), .preset_n_i(preset_n_i),
    .hsel_i(hsel_i), .haddr_i(haddr_i), .htrans_i(htrans_i), .hwrite_i(hwrite_i), .hsize_i(hsize_i),
    .hready_i(hready_i), .hrdata_o(hrdata_o), .hreadyout_o(hreadyout_o), .hresp_o(hresp_o),
    .psel_o(psel_o), .penable_o(penable_o), .pwrite_o(pwrite_o), .paddr_o(paddr_o), .pwdata_o(pwdata_o),
    .prdata_i(prdata_i), .pready_i(pready_i), .pslverr_i(pslverr_i),
    .hstate(hstate), .win_cap(win_cap), .addr_cap(addr_cap), .write_cap(write_cap), .wdata_cap(wdata_cap),
    .prdata_sel(prdata_sel), .pready_sel(pready_sel), .pslverr_sel(pslverr_sel),
    .to_cnt(u_fsm.to_cnt), .pstate(u_fsm.state));
`endif
