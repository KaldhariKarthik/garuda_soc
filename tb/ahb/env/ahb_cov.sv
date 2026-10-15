`timescale 1ns/1ps
// =============================================================================
// ahb_cov.sv -- functional coverage of the AHB-Lite interconnect (Track A bus
// plan B1 phase A4). Bound into ahb_interconnect by tb/ahb/env/filelist_ahb_env.f
// (and by any bench that lists this file), so it samples the real ports in the
// env, the unit benches and chip runs alike. Group and point names follow
// tb/ahb/GARUDA_AHB_vplan.csv (cg_arb.*, AHB.TA.*).
//
// Module covergroups with an explicit sample(), as in tb/dma/env/dma_env_cov.sv:
// the Verilator 5.052 tool reads covergroup bins only from coverage.dat with
// --coverage-user (TOOL-22), and crashes on class covergroups sampled through a
// virtual interface (TOOL-23).
// =============================================================================
module ahb_cov (
    input wire        hclk_i,
    input wire        hreset_n_i,
    input wire [3:0]  m_req,        // HTRANS[1] of M3..M0
    input wire [3:0]  m_rdy,        // HREADY seen by M3..M0
    input wire [3:0]  m_err,        // HRESP seen by M3..M0
    input wire [3:0][31:0] m_addr,
    input wire [3:0]  m_wr,
    input wire [3:0][1:0] m_trans,
    input wire        hready_o,     // shared HREADY
    input wire [1:0]  htrans_o,
    input wire        hwrite_o,
    input wire [31:0] haddr_o,
    input wire [1:0]  grant,        // white-box
    input wire [3:0]  hold_valid    // white-box: per-master response hold (AHB-2)
);
    // ---- derived, as in ahb_ic_props_a.sv ---------------------------------
    wire [3:0] acc = m_req & m_rdy;
    wire [1:0] acc_m = acc[3] ? 2'd3 : acc[2] ? 2'd2 : acc[1] ? 2'd1 : 2'd0;
    reg        hready_q = 1'b1, dv = 1'b0, live = 1'b0;
    reg  [1:0] do_m = 2'd0;
    reg  [3:0] out = 4'd0;
    int unsigned waits = 0;                 // wait cycles of the data phase in flight
    reg        preempt_seen = 1'b0;         // a higher master requested during it
    int unsigned m0_beat = 0;               // beats of M0's current INCR burst accepted
    reg  [3:0] err_done_q = 4'd0;           // master m completed an ERROR last cycle
    reg  [3:0] hold_q = 4'd0;

    covergroup cg_arb with function sample(bit [3:0] set, bit [1:0] win);
        cp_request_set: coverpoint set { bins s[] = {[1:15]}; }
        cp_winner:      coverpoint win { bins w[] = {[0:3]}; }
    endgroup
    covergroup cg_wait with function sample(int unsigned w, bit [1:0] owner);
        cp_waits:   coverpoint w { bins w0 = {0}; bins w1 = {1}; bins w2 = {2}; bins w3 = {3};
                                   bins w4_7 = {[4:7]}; bins w8 = {8}; bins w9_63 = {[9:63]};
                                   bins long = {[64:$]}; }
        cp_owner:   coverpoint owner { bins o[] = {[0:3]}; }
    endgroup
    // a higher master requesting during a WAITED data phase (cg_arb.x_wait_preempt of
    // the vPlan); a zero-wait data phase has no cycle in which to be preempted
    covergroup cg_wait_preempt with function sample(int unsigned w, bit pre);
        cp_waits:   coverpoint w { bins w1 = {1}; bins w2 = {2}; bins w3 = {3}; bins w4_15 = {[4:15]}; bins w16_up = {[16:$]}; }
        cp_preempt: coverpoint pre;
        x_wait_preempt: cross cp_waits, cp_preempt;
    endgroup
    covergroup cg_preempt_beat with function sample(int unsigned beat, bit [1:0] by);
        cp_preempt_beat: coverpoint beat { bins b1 = {1}; bins b2 = {2}; bins b3 = {3}; bins b4_15 = {[4:15]}; }
        cp_by:           coverpoint by { bins m[] = {[1:3]}; }
        x_beat_by:       cross cp_preempt_beat, cp_by;
    endgroup
    covergroup cg_dec with function sample(bit [1:0] m, bit [3:0] nib, bit w);
        cp_master: coverpoint m   { bins m[] = {[0:3]}; }
        cp_nibble: coverpoint nib { bins n[] = {[0:15]}; }
        cp_write:  coverpoint w;
        x_master_nibble: cross cp_master, cp_nibble;
    endgroup
    covergroup cg_err with function sample(bit [1:0] m, bit [1:0] next);  // next: 0 idle, 1 same, 2 other
        cp_master: coverpoint m    { bins m[] = {[0:3]}; }
        cp_next:   coverpoint next { bins idle = {0}; bins same = {1}; bins other = {2}; }
        x_err_next: cross cp_master, cp_next {
            // the I-port is the lowest priority and pipelines: after its ERROR the next
            // acceptance can be its own or another's; every pair is reachable
        }
    endgroup
    covergroup cg_sba with function sample(bit [3:0] nib, bit w);
        cp_region: coverpoint nib { bins isram = {0}; bins rom = {1}; bins dsram = {2}; bins apb = {4};
                                    bins none = default; }
        cp_write:  coverpoint w;
        x_sba: cross cp_region, cp_write;     // an SBA write to ROM is legal on the bus (the ROM answers it)
    endgroup
    covergroup cg_hold with function sample(bit [1:0] m);
        cp_captured: coverpoint m { bins m[] = {[0:2]}; }     // M3 is never preempted
    endgroup
    covergroup cg_rst with function sample(bit [1:0] where);     // 0 idle, 1 address phase, 2 waited data phase
        cp_reset_point: coverpoint where { bins idle = {0}; bins addr = {1}; bins data_wait = {2}; }
    endgroup

    cg_arb          u_cg_arb          = new();
    cg_wait         u_cg_wait         = new();
    cg_wait_preempt u_cg_wait_pre     = new();
    cg_preempt_beat u_cg_preempt_beat = new();
    cg_dec          u_cg_dec          = new();
    cg_err          u_cg_err          = new();
    cg_sba          u_cg_sba          = new();
    cg_hold         u_cg_hold         = new();
    cg_rst          u_cg_rst          = new();

    always @(negedge hreset_n_i)
        if (live) u_cg_rst.sample((dv && !hready_q) ? 2'd2 : (htrans_o[1] ? 2'd1 : 2'd0));

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            hready_q <= 1'b1; dv <= 1'b0; out <= 4'd0; waits <= 0; preempt_seen <= 1'b0;
            m0_beat <= 0; err_done_q <= 4'd0; hold_q <= 4'd0; live <= 1'b0;
        end else begin
            live <= 1'b1;
            if (hready_q && |m_req) u_cg_arb.sample(m_req, grant);
            if (dv && hready_o) begin
                u_cg_wait.sample(waits, do_m);
                if (waits > 0) u_cg_wait_pre.sample(waits, preempt_seen);
            end
            if (dv && !hready_o) begin
                waits <= waits + 1;
                for (int h = 0; h < 4; h++) if (m_req[h] && h > do_m) preempt_seen <= 1'b1;
            end
            if (hready_o) begin
                dv <= |acc; do_m <= acc_m; waits <= 0; preempt_seen <= 1'b0;
            end
            if (|acc) begin
                u_cg_dec.sample(acc_m, haddr_o[31:28], hwrite_o);
                if (acc[2]) u_cg_sba.sample(haddr_o[31:28], hwrite_o);
            end
            // M0 burst beats and where it is preempted
            if (acc[0]) m0_beat <= (m_trans[0] == 2'b11) ? m0_beat + 1 : 1;
            if (m_trans[0] == 2'b11 && !m_rdy[0] && grant != 2'd0 && hready_q)
                u_cg_preempt_beat.sample(m0_beat, grant);
            // what follows an ERROR completion at a master
            for (int m = 0; m < 4; m++) begin
                if (err_done_q[m])
                    u_cg_err.sample(m[1:0], !(|acc) ? 2'd0 : (acc_m == m) ? 2'd1 : 2'd2);
                out[m] <= acc[m] ? 1'b1 : (m_rdy[m] ? 1'b0 : out[m]);
                if (hold_valid[m] && !hold_q[m] && m < 3) u_cg_hold.sample(m[1:0]);
            end
            for (int m = 0; m < 4; m++) err_done_q[m] <= out[m] && m_rdy[m] && m_err[m];
            hold_q   <= hold_valid;
            hready_q <= hready_o;
        end
    end
endmodule

bind ahb_interconnect ahb_cov u_ahb_cov (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i),
    .m_req({m_htrans_i[1], s_htrans_i[1], d_htrans_i[1], i_htrans_i[1]}),
    .m_rdy({m_hready_o, s_hready_o, d_hready_o, i_hready_o}),
    .m_err({m_hresp_o, s_hresp_o, d_hresp_o, i_hresp_o}),
    .m_addr({m_haddr_i, s_haddr_i, d_haddr_i, i_haddr_i}),
    .m_wr({m_hwrite_i, s_hwrite_i, d_hwrite_i, i_hwrite_i}),
    .m_trans({m_htrans_i, s_htrans_i, d_htrans_i, i_htrans_i}),
    .hready_o(hready_o), .htrans_o(htrans_o), .hwrite_o(hwrite_o), .haddr_o(haddr_o),
    .grant(grant),
    .hold_valid({u_mp_m.hold_valid, u_mp_s.hold_valid, u_mp_d.hold_valid, u_mp_i.hold_valid}));
