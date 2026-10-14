`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 6 : bound properties of the AHB-Lite interconnect
// ahb_interconnect_sva.sv
//
// Spec: GARUDA-AHB-SPEC-001 Rev 4.0a sections 7-8, 10; errata AHB-1 (HWDATA from
// the data-phase owner), AHB-2 (response hold for a preempted master), AHB-3
// (SEQ re-opened as NONSEQ), AHB-4 (an idle master is not gated); AHB-6 (the
// SBA indication is an address-phase signal). Plan: tb/ahb/GARUDA_AHB_vplan.csv
// (R-1..R-9, the SVA rows and the Track A additions AHB.TA.*). Track A bus plan B1.
//
// Bound to ahb_interconnect at the end of this file and listed in
// rtl/ahb/filelist.f, so it runs in tb_ahb_interconnect, in the AHB environment,
// in every core / DMA / chip simulation and in SBY (tb/ahb/formal). Not compiled
// for synthesis. Portable form of Docs/handbook/H4_coding.md: no |-> / |=>,
// every implication is `!(A) || (B)`, $past is gated by past_ok, and every
// implication-style assert has a cover on its antecedent.
//
// HOW IT CHECKS. The core of this file is a small SPEC MODEL built only from the
// master-side and slave-side ports, not from the arbiter's registers:
//   acc[m]     master m's address phase is accepted (it presents NONSEQ/SEQ and
//              sees its HREADY high) -- what the master itself believes;
//   dv_q/do_q  the slave-side data phase in flight and the master it belongs to,
//              captured from acc[] when the shared HREADY is high;
//   pend_*[m]  a response the slave has given for master m that m has not yet
//              taken (AHB-2: m was preempted while presenting);
//   out[m]     master m has a data phase outstanding, from m's point of view.
// The properties then say, per master: you complete a data phase only when the
// slave has answered YOUR transfer, you get exactly that slave's data and
// response, nobody else sees it, and an ERROR reaches you as two cycles.
// White-box signals (grant, the decoder's hsel, the default slave's outputs)
// come in through the bind; every property that uses one says so.
//
// Detectors of open defects (always on; a test that reaches the scenario fails
// and is declared in its suite with the bug ID):
//   a_held_resp_okay[m], a_master_err_shape[m]   AHB-7  the response hold captures
//                                                 an ERROR (and a_slave_addr_stable
//                                                 fails when the master then cancels)
// =============================================================================

`ifdef FORMAL
  `define GARUDA_AHB_SVA
`elsif SYNTHESIS
`else
  `define GARUDA_AHB_SVA
`endif

`ifdef GARUDA_AHB_SVA
module ahb_interconnect_sva (
    input wire        hclk_i,
    input wire        hreset_n_i,
    // ---- M0 I-port ----
    input wire [31:0] i_haddr_i,  input wire [1:0] i_htrans_i, input wire i_hwrite_i,
    input wire [2:0]  i_hsize_i,  input wire [2:0] i_hburst_i, input wire [3:0] i_hprot_i,
    input wire [31:0] i_hwdata_i, input wire [31:0] i_hrdata_o, input wire i_hready_o, input wire i_hresp_o,
    // ---- M1 D-port ----
    input wire [31:0] d_haddr_i,  input wire [1:0] d_htrans_i, input wire d_hwrite_i,
    input wire [2:0]  d_hsize_i,  input wire [2:0] d_hburst_i, input wire [3:0] d_hprot_i,
    input wire [31:0] d_hwdata_i, input wire [31:0] d_hrdata_o, input wire d_hready_o, input wire d_hresp_o,
    // ---- M2 SBA ----
    input wire [31:0] s_haddr_i,  input wire [1:0] s_htrans_i, input wire s_hwrite_i,
    input wire [2:0]  s_hsize_i,  input wire [2:0] s_hburst_i,
    input wire [31:0] s_hwdata_i, input wire [31:0] s_hrdata_o, input wire s_hready_o, input wire s_hresp_o,
    // ---- M3 DMA ----
    input wire [31:0] m_haddr_i,  input wire [1:0] m_htrans_i, input wire m_hwrite_i,
    input wire [2:0]  m_hsize_i,  input wire [2:0] m_hburst_i,
    input wire [31:0] m_hwdata_i, input wire [31:0] m_hrdata_o, input wire m_hready_o, input wire m_hresp_o,
    // ---- slave side ----
    input wire        hsel_isram_o, input wire hsel_rom_o, input wire hsel_dsram_o, input wire hsel_bridge_o,
    input wire [31:0] haddr_o,  input wire [1:0] htrans_o, input wire hwrite_o,
    input wire [2:0]  hsize_o,  input wire [2:0] hburst_o, input wire [3:0] hprot_o,
    input wire [31:0] hwdata_o, input wire hready_o, input wire hmaster_is_sba_o,
    input wire [31:0] hrdata_isram_i,  input wire hreadyout_isram_i,  input wire hresp_isram_i,
    input wire [31:0] hrdata_rom_i,    input wire hreadyout_rom_i,    input wire hresp_rom_i,
    input wire [31:0] hrdata_dsram_i,  input wire hreadyout_dsram_i,  input wire hresp_dsram_i,
    input wire [31:0] hrdata_bridge_i, input wire hreadyout_bridge_i, input wire hresp_bridge_i,
    // ---- white-box ----
    input wire [1:0]  grant,          // the arbiter's address-phase owner
    input wire [4:0]  hsel,           // the decoder's one-hot select, bit 4 = default slave
    input wire        hreadyout_df,   // the default slave's outputs
    input wire        hresp_df,
    input wire [3:0]  hold_valid,     // per-master response hold (AHB-2)
    input wire        dph_valid,      // the arbiter's data-phase tracker
    input wire [1:0]  dph_master,
    input wire [1:0]  def_state       // the default slave's state (coverage evidence)
);
    localparam [1:0] T_IDLE = 2'b00, T_NONSEQ = 2'b10, T_SEQ = 2'b11;
    localparam [3:0] HPROT_CONST = 4'b0011;          // [N-5.2] SBA / DMA substitution
    localparam integer S_DEF = 4;

    // ---- the four masters as arrays (index = master number = priority) ------
    wire [3:0][31:0] m_addr  = {m_haddr_i,  s_haddr_i,  d_haddr_i,  i_haddr_i};
    wire [3:0][1:0]  m_trans = {m_htrans_i, s_htrans_i, d_htrans_i, i_htrans_i};
    wire [3:0]       m_wr    = {m_hwrite_i, s_hwrite_i, d_hwrite_i, i_hwrite_i};
    wire [3:0][2:0]  m_size  = {m_hsize_i,  s_hsize_i,  d_hsize_i,  i_hsize_i};
    wire [3:0][31:0] m_wdata = {m_hwdata_i, s_hwdata_i, d_hwdata_i, i_hwdata_i};
    wire [3:0][31:0] m_rdata = {m_hrdata_o, s_hrdata_o, d_hrdata_o, i_hrdata_o};
    wire [3:0]       m_rdy   = {m_hready_o, s_hready_o, d_hready_o, i_hready_o};
    wire [3:0]       m_err   = {m_hresp_o,  s_hresp_o,  d_hresp_o,  i_hresp_o};
    wire [3:0]       m_req;
    wire [3:0]       acc;
    genvar g;
    generate for (g = 0; g < 4; g++) begin : g_m
        assign m_req[g] = m_trans[g][1];
        assign acc[g]   = m_req[g] && m_rdy[g];
    end endgenerate

    function automatic [1:0] idx4(input [3:0] v);   // index of the (single) set bit
        idx4 = v[3] ? 2'd3 : v[2] ? 2'd2 : v[1] ? 2'd1 : 2'd0;
    endfunction
    function automatic [1:0] winner(input [3:0] r);  // fixed priority, M3 highest ([N-7.3])
        winner = r[3] ? 2'd3 : r[2] ? 2'd2 : r[1] ? 2'd1 : 2'd0;
    endfunction
    function automatic [2:0] region(input [31:0] a); // spec [N-7.11]: 0 ISRAM, 1 ROM, 2 DSRAM, 4 APB
        case (a[31:28])
            4'h0: region = 3'd0;  4'h1: region = 3'd1;  4'h2: region = 3'd2;  4'h4: region = 3'd3;
            default: region = 3'd4;
        endcase
    endfunction

    wire [1:0] acc_m   = idx4(acc);
    wire       slv_acc = hready_o && htrans_o[1];      // the slave side takes an address phase

    // ---- spec model state -----------------------------------------------------
    reg              live_q, past_ok;
    reg              dv_q, dwr_q, dfirst_q;            // data phase in flight, write, its first cycle
    reg  [1:0]       do_q;                             // ... and its owner
    reg  [2:0]       dslv_q;                           // ... and the slave it went to
    reg  [3:0]       out;                              // per master: a data phase outstanding
    reg  [3:0]       pend_v, pend_wr, pend_resp;       // per master: slave answered, master not yet
    reg  [3:0][31:0] pend_data;
    reg              la_v;                             // the last accepted transfer and its owner
    reg  [1:0]       la_m;

    // live response of the slave owning the data phase (white-box for the default slave)
    reg        sl_rdy, sl_resp;
    reg [31:0] sl_data;
    always @(*) begin
        case (dslv_q)
            3'd0: begin sl_rdy = hreadyout_isram_i;  sl_resp = hresp_isram_i;  sl_data = hrdata_isram_i;  end
            3'd1: begin sl_rdy = hreadyout_rom_i;    sl_resp = hresp_rom_i;    sl_data = hrdata_rom_i;    end
            3'd2: begin sl_rdy = hreadyout_dsram_i;  sl_resp = hresp_dsram_i;  sl_data = hrdata_dsram_i;  end
            3'd3: begin sl_rdy = hreadyout_bridge_i; sl_resp = hresp_bridge_i; sl_data = hrdata_bridge_i; end
            default: begin sl_rdy = hreadyout_df;    sl_resp = hresp_df;       sl_data = 32'd0;           end
        endcase
    end
    wire slave_done = dv_q && hready_o;                // the slave completes do_q's data phase now

    wire [3:0] mdone;                                  // master m takes a data-phase completion now
    wire [3:0] exp_ok;                                 // ... and a response exists for it
    wire [3:0] exp_resp;
    wire [3:0][31:0] exp_data;
    wire [3:0] exp_wr;
    generate for (g = 0; g < 4; g++) begin : g_exp
        wire live_mine = slave_done && do_q == g;
        assign mdone[g]    = out[g] && m_rdy[g];
        assign exp_ok[g]   = pend_v[g] || live_mine;
        assign exp_resp[g] = pend_v[g] ? pend_resp[g] : sl_resp;
        assign exp_data[g] = pend_v[g] ? pend_data[g] : sl_data;
        assign exp_wr[g]   = pend_v[g] ? pend_wr[g]   : dwr_q;
    end endgenerate

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            live_q <= 1'b0; past_ok <= 1'b0;
            dv_q <= 1'b0; dwr_q <= 1'b0; dfirst_q <= 1'b0; do_q <= 2'd0; dslv_q <= 3'd0;
            out <= 4'd0; pend_v <= 4'd0; pend_wr <= 4'd0; pend_resp <= 4'd0; pend_data <= '0;
            la_v <= 1'b0; la_m <= 2'd0;
        end else begin
            live_q  <= 1'b1;
            past_ok <= live_q;
            dfirst_q <= 1'b0;
            if (hready_o) begin
                dv_q     <= slv_acc;
                dfirst_q <= slv_acc;
                do_q     <= acc_m;
                dwr_q    <= hwrite_o;
                dslv_q   <= region(haddr_o);
            end
            if (slv_acc) begin la_v <= 1'b1; la_m <= acc_m; end
            for (int m = 0; m < 4; m++) begin
                out[m] <= acc[m] ? 1'b1 : (m_rdy[m] ? 1'b0 : out[m]);
                if (slave_done && do_q == m && !mdone[m]) begin
                    pend_v[m] <= 1'b1; pend_wr[m] <= dwr_q; pend_resp[m] <= sl_resp; pend_data[m] <= sl_data;
                end else if (mdone[m]) begin
                    pend_v[m] <= 1'b0;
                end
            end
        end
    end

    // =========================================================================
    // R-1 / R-2: acceptance is consistent on both sides (no phantom, no loss)
    // =========================================================================
    // AHB.TA.sb_conservation (pin level): at most one master believes its
    // address phase was taken, and it is taken exactly when the slave side takes one.
    a_one_accept: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) $onehot0(acc));
    a_no_phantom: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) slv_acc == (|acc));
    // what reaches the slaves is the accepting master's transfer (HTRANS may only
    // be rewritten SEQ -> NONSEQ, AHB-3)
    a_ctrl_of_acceptor: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(|acc) || (haddr_o == m_addr[acc_m] && hwrite_o == m_wr[acc_m] && hsize_o == m_size[acc_m] &&
                    (htrans_o == m_trans[acc_m] || (m_trans[acc_m] == T_SEQ && htrans_o == T_NONSEQ))));
    // F07 a_ungranted_held (white-box grant): a presenting master that is not granted is held
    generate for (g = 0; g < 4; g++) begin : g_held
        a_ungranted_held: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !(m_req[g] && grant != g) || !m_rdy[g]);
        // AHB-4: a master with nothing presented and nothing owed sees HREADY high
        a_idle_not_gated: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !(!m_req[g] && !out[g]) || m_rdy[g]);
        c_held:     cover property (@(posedge hclk_i) disable iff (!hreset_n_i) m_req[g] && grant != g);
        c_idle:     cover property (@(posedge hclk_i) disable iff (!hreset_n_i) !m_req[g] && !out[g]);
    end endgenerate

    // =========================================================================
    // R-5: fixed priority at every beat boundary, frozen inside a held address phase
    // =========================================================================
    // a_priority (white-box grant): where no address phase is being held (HREADY
    // was high last cycle) the grant is the highest requester.
    a_priority: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(past_ok && $past(hready_o) && (|m_req)) || grant == winner(m_req));
    // a_grant_stable_in_data_phase (white-box grant): while an address phase waits
    // (HREADY low) the grant does not move, whatever the requests do ([N-7.2]).
    a_grant_stable_in_data_phase: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(past_ok && !$past(hready_o)) || grant == $past(grant));
    // slave-side AHB-Lite: a waited address phase is held unchanged ([N-7.20]);
    // the one exception AHB-Lite allows: after the first cycle of an ERROR the
    // waiting transfer may be cancelled to IDLE (and to nothing else)
    wire err_first = dv_q && sl_resp && !hready_o;     // first cycle of an ERROR on the shared bus
    a_slave_addr_stable: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(past_ok && $past(!hready_o && htrans_o[1])) ||
        ($past(err_first) && htrans_o == T_IDLE) ||
        (haddr_o == $past(haddr_o) && htrans_o == $past(htrans_o) && hwrite_o == $past(hwrite_o) &&
         hsize_o == $past(hsize_o) && hburst_o == $past(hburst_o)));
    c_cancel_after_error: cover property (@(posedge hclk_i) disable iff (!hreset_n_i)
        past_ok && $past(!hready_o && htrans_o[1] && err_first) && htrans_o == T_IDLE);
    c_wait_preempt: cover property (@(posedge hclk_i) disable iff (!hreset_n_i)
        dv_q && !hready_o && m_req[3] && do_q != 2'd3);

    // =========================================================================
    // AHB-1: HWDATA belongs to the data-phase owner, not the address-phase grant
    // =========================================================================
    a_hwdata_data_phase: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(dv_q && dwr_q) || hwdata_o == m_wdata[do_q]);
    c_write_handoff: cover property (@(posedge hclk_i) disable iff (!hreset_n_i)
        dv_q && dwr_q && slv_acc && acc_m != do_q);

    // =========================================================================
    // R-8: the interconnect inserts no wait of its own
    // =========================================================================
    a_no_inserted_wait: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        hready_o == (dv_q ? sl_rdy : 1'b1));

    // =========================================================================
    // Responses: to the owner only, exactly the addressed slave's, in two cycles
    // =========================================================================
    generate for (g = 0; g < 4; g++) begin : g_resp
        // a_resp_from_addressed_slave + AHB-2: a master completes a data phase only
        // when the slave has answered ITS transfer (now, or held from earlier)...
        a_complete_has_response: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !mdone[g] || exp_ok[g]);
        // ... with that slave's response ...
        a_resp_value: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !(mdone[g] && exp_ok[g]) || m_err[g] == exp_resp[g]);
        // ... and, for a read that completed OKAY, that slave's data
        a_rdata_value: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !(mdone[g] && exp_ok[g] && !exp_wr[g] && !exp_resp[g]) || m_rdata[g] == exp_data[g]);
        // a_resp_hold (AHB-2): one held response at most; a second one would be lost
        a_resp_hold_one_deep: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !(slave_done && do_q == g && pend_v[g]));
        // a_error_not_broadcast: a master with nothing outstanding never sees ERROR
        a_error_not_broadcast: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            out[g] || !m_err[g]);
        // a_error_two_cycle at the master: an ERROR completion was preceded by the
        // ERROR first cycle (HREADY low) -- the replayed-response argument of AHB-2
        a_error_two_cycle_master: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !(past_ok && mdone[g] && m_err[g]) || $past(out[g] && !m_rdy[g] && m_err[g]));
        // AHB-7 detectors (open defect; always on, declared per suite):
        // a_held_resp_okay: a response the master cannot take now (it was preempted
        // while presenting) is never an ERROR -- ahb_master_port.v's own claim
        a_held_resp_okay: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !(slave_done && do_q == g && !mdone[g] && sl_resp));
        // a_master_err_shape: what the master sees is a legal AHB-Lite ERROR: the
        // first cycle (HREADY low, ERROR) lasts exactly one cycle and is followed
        // by the second (HREADY high, ERROR)
        a_master_err_shape: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !(past_ok && $past(out[g] && !m_rdy[g] && m_err[g])) || (m_rdy[g] && m_err[g]));
        // a_hold_not_owner (white-box): "why one entry is enough" (ahb_master_port.v):
        // a master with a held response never owns the data phase in flight, so the
        // held response and a live one can never compete for the same master
        a_hold_not_owner: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !(hold_valid[g] && dph_valid && dph_master == g));
        c_complete:     cover property (@(posedge hclk_i) disable iff (!hreset_n_i) mdone[g]);
        c_held_resp:    cover property (@(posedge hclk_i) disable iff (!hreset_n_i) mdone[g] && pend_v[g]);
        c_error:        cover property (@(posedge hclk_i) disable iff (!hreset_n_i) mdone[g] && m_err[g]);
        c_capture:      cover property (@(posedge hclk_i) disable iff (!hreset_n_i) hold_valid[g]);
    end endgenerate

    // default slave: the two-cycle ERROR in the specified order ([N-7.6], R-6)
    a_error_first_cycle: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(dv_q && dslv_q == S_DEF && dfirst_q) || (!hready_o && sl_resp));
    a_error_two_cycle: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(past_ok && $past(dv_q && dslv_q == S_DEF && dfirst_q)) || (hready_o && sl_resp));
    // every slave (not only the default one): the ERROR first cycle on the shared bus
    // lasts exactly one cycle and is followed by the completing ERROR cycle; a slave
    // in wait states answers OKAY (AHB-Lite slave rule; found TB-47)
    a_slave_err_shape: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(past_ok && $past(err_first)) || (hready_o && sl_resp));
    // the default slave's state register only takes IDLE / ERR1 / ERR2 (2'd3 unused):
    // evidence for the coverage waiver of its `default:` arm (tb/ahb/cov/ahb_waivers.toml)
    a_def_state_legal: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) def_state != 2'd3);
    c_undecoded: cover property (@(posedge hclk_i) disable iff (!hreset_n_i) dv_q && dslv_q == S_DEF && dfirst_q);
    c_error_then_accept: cover property (@(posedge hclk_i) disable iff (!hreset_n_i)
        past_ok && $past(dv_q && dslv_q == S_DEF && dfirst_q) && slv_acc);

    // =========================================================================
    // R-3 / [N-7.11]: decode (white-box hsel)
    // =========================================================================
    a_hsel_onehot: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) $onehot(hsel));
    a_decode: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        hsel == (5'd1 << region(haddr_o)) &&
        {hsel_bridge_o, hsel_dsram_o, hsel_rom_o, hsel_isram_o} == hsel[3:0]);

    // =========================================================================
    // R-9 / AHB-3: a SEQ on the slave side continues the last accepted transfer's master
    // =========================================================================
    a_burst_restart_nonseq: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(slv_acc && htrans_o == T_SEQ) || (la_v && la_m == acc_m));
    c_seq_rewrite: cover property (@(posedge hclk_i) disable iff (!hreset_n_i)
        |acc && m_trans[acc_m] == T_SEQ && htrans_o == T_NONSEQ);
    c_seq_kept: cover property (@(posedge hclk_i) disable iff (!hreset_n_i) slv_acc && htrans_o == T_SEQ);

    // =========================================================================
    // R-7 / AHB-6: the SBA indication marks an address phase accepted from M2
    // =========================================================================
    a_sba_ind: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(|acc) || hmaster_is_sba_o == acc[2]);
    c_sba_isram_write: cover property (@(posedge hclk_i) disable iff (!hreset_n_i)
        acc[2] && hsel_isram_o && hwrite_o);

    // =========================================================================
    // [N-5.2] HPROT: passed through for the core ports, the constant for SBA / DMA
    // =========================================================================
    a_hprot_const: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(|acc) || hprot_o == (acc[0] ? i_hprot_i : acc[1] ? d_hprot_i : HPROT_CONST));

    // =========================================================================
    // F22: the first cycle out of reset: no data phase (shared HREADY high), no
    // ERROR anywhere, and every master that is not presenting is free to start
    // (a master presenting in this very cycle may be held: it is not granted yet)
    // =========================================================================
    a_reset_state: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        live_q || (hready_o && m_err == 4'h0 && (m_rdy | m_req) == 4'hF));

    // request sets at a beat boundary (cg_arb.cp_request_set lives in tb/ahb/env;
    // these covers make the 15 sets visible in formal too)
    generate for (g = 1; g < 16; g++) begin : g_set
        c_request_set: cover property (@(posedge hclk_i) disable iff (!hreset_n_i)
            past_ok && $past(hready_o) && m_req == g);
    end endgenerate
endmodule

bind ahb_interconnect ahb_interconnect_sva u_ahb_sva (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i),
    .i_haddr_i(i_haddr_i), .i_htrans_i(i_htrans_i), .i_hwrite_i(i_hwrite_i), .i_hsize_i(i_hsize_i),
    .i_hburst_i(i_hburst_i), .i_hprot_i(i_hprot_i), .i_hwdata_i(i_hwdata_i),
    .i_hrdata_o(i_hrdata_o), .i_hready_o(i_hready_o), .i_hresp_o(i_hresp_o),
    .d_haddr_i(d_haddr_i), .d_htrans_i(d_htrans_i), .d_hwrite_i(d_hwrite_i), .d_hsize_i(d_hsize_i),
    .d_hburst_i(d_hburst_i), .d_hprot_i(d_hprot_i), .d_hwdata_i(d_hwdata_i),
    .d_hrdata_o(d_hrdata_o), .d_hready_o(d_hready_o), .d_hresp_o(d_hresp_o),
    .s_haddr_i(s_haddr_i), .s_htrans_i(s_htrans_i), .s_hwrite_i(s_hwrite_i), .s_hsize_i(s_hsize_i),
    .s_hburst_i(s_hburst_i), .s_hwdata_i(s_hwdata_i),
    .s_hrdata_o(s_hrdata_o), .s_hready_o(s_hready_o), .s_hresp_o(s_hresp_o),
    .m_haddr_i(m_haddr_i), .m_htrans_i(m_htrans_i), .m_hwrite_i(m_hwrite_i), .m_hsize_i(m_hsize_i),
    .m_hburst_i(m_hburst_i), .m_hwdata_i(m_hwdata_i),
    .m_hrdata_o(m_hrdata_o), .m_hready_o(m_hready_o), .m_hresp_o(m_hresp_o),
    .hsel_isram_o(hsel_isram_o), .hsel_rom_o(hsel_rom_o), .hsel_dsram_o(hsel_dsram_o), .hsel_bridge_o(hsel_bridge_o),
    .haddr_o(haddr_o), .htrans_o(htrans_o), .hwrite_o(hwrite_o), .hsize_o(hsize_o), .hburst_o(hburst_o),
    .hprot_o(hprot_o), .hwdata_o(hwdata_o), .hready_o(hready_o), .hmaster_is_sba_o(hmaster_is_sba_o),
    .hrdata_isram_i(hrdata_isram_i),   .hreadyout_isram_i(hreadyout_isram_i),   .hresp_isram_i(hresp_isram_i),
    .hrdata_rom_i(hrdata_rom_i),       .hreadyout_rom_i(hreadyout_rom_i),       .hresp_rom_i(hresp_rom_i),
    .hrdata_dsram_i(hrdata_dsram_i),   .hreadyout_dsram_i(hreadyout_dsram_i),   .hresp_dsram_i(hresp_dsram_i),
    .hrdata_bridge_i(hrdata_bridge_i), .hreadyout_bridge_i(hreadyout_bridge_i), .hresp_bridge_i(hresp_bridge_i),
    .grant(grant), .hsel(hsel), .hreadyout_df(hreadyout_df), .hresp_df(hresp_df),
    .hold_valid({u_mp_m.hold_valid, u_mp_s.hold_valid, u_mp_d.hold_valid, u_mp_i.hold_valid}),
    .dph_valid(dph_valid), .dph_master(dph_master), .def_state(u_def.state));
`endif
