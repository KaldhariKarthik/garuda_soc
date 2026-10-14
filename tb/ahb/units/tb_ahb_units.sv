`timescale 1ns/1ps
// =============================================================================
// tb_ahb_units.sv -- one bench per rtl/ahb sub-module on its own (Track A bus plan
// B1 phase A6). Each unit is driven with exhaustive or random stimulus and checked
// cycle by cycle against a reference written from GARUDA-AHB-SPEC-001 (section
// noted per unit), not copied from the RTL. Each unit has a negative control in
// tb/ahb/run/units.toml: a planted defect from tb/ahb/mut/ that must fail it.
//
//   +UNIT=decoder        [N-7.11] HADDR[31:28] -> one-hot select, default slave otherwise
//   +UNIT=arbiter        [N-7.2]/[N-7.3] fixed priority at every boundary, grant frozen
//                        while an address phase waits; [N-7.4] data-phase tracking;
//                        AHB-3 SEQ break on an owner change
//   +UNIT=master_port    [N-7.20]/[N-8.2] + AHB-2/AHB-4: what one master sees
//   +UNIT=default_slave  [N-7.6] two-cycle ERROR for each accepted transfer
//   +UNIT=slave_mux      [N-7.5] data-phase select register and the return mux
//   +UNIT=master_mux     address from the grant, HWDATA from the data-phase owner (AHB-1),
//                        SEQ -> NONSEQ on seq_break (AHB-3), HPROT substitution [N-5.2]
// =============================================================================
module tb_ahb_units;
    logic clk = 1'b0, rst_n;
    initial #0 rst_n = 1'b0;
    always #2 clk = ~clk;

    int checks = 0, fails = 0, cycles = 2000;
    string unit;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; if (fails <= 20) $display("[FAIL] %s (t=%0t)", what, $time); end
    endtask

    // ---------------- decoder ----------------
    logic [31:0] dec_a;  wire [4:0] dec_sel;
    ahb_decoder u_dec (.haddr_i(dec_a), .hsel_o(dec_sel));

    // ---------------- arbiter ----------------
    logic [7:0] arb_htrans; logic arb_hready;
    wire  [1:0] arb_grant, arb_dphm; wire arb_seqb, arb_dphv;
    ahb_arbiter u_arb (.hclk_i(clk), .hreset_n_i(rst_n), .htrans_i(arb_htrans), .hready_i(arb_hready),
                       .grant_o(arb_grant), .seq_break_o(arb_seqb), .dph_valid_o(arb_dphv), .dph_master_o(arb_dphm));

    // ---------------- master port ----------------
    logic [1:0] mp_htrans; logic mp_gr, mp_own, mp_rdy; logic [31:0] mp_rd; logic mp_resp;
    wire  mp_hready, mp_hresp; wire [31:0] mp_hrdata;
    ahb_master_port u_mp (.hclk_i(clk), .hreset_n_i(rst_n), .htrans_i(mp_htrans), .granted_i(mp_gr),
                          .dph_own_i(mp_own), .hready_shared_i(mp_rdy), .hrdata_shared_i(mp_rd),
                          .hresp_shared_i(mp_resp), .hready_o(mp_hready), .hrdata_o(mp_hrdata), .hresp_o(mp_hresp));

    // ---------------- default slave ----------------
    logic ds_sel, ds_rdy; logic [1:0] ds_trans;
    wire [31:0] ds_rdata; wire ds_rdyo, ds_resp;
    ahb_default_slave u_ds (.hclk_i(clk), .hreset_n_i(rst_n), .hsel_i(ds_sel), .htrans_i(ds_trans),
                            .hready_i(ds_rdy), .hrdata_o(ds_rdata), .hreadyout_o(ds_rdyo), .hresp_o(ds_resp));

    // ---------------- slave mux ----------------
    logic [4:0] sm_sel; logic sm_dv; logic [4:0][31:0] sm_rd; logic [4:0] sm_ry, sm_rs;
    wire [31:0] sm_hrdata; wire sm_hresp, sm_hready; wire [4:0] sm_dphsel;
    ahb_slave_mux u_sm (.hclk_i(clk), .hreset_n_i(rst_n), .hsel_i(sm_sel), .dph_valid_i(sm_dv),
        .hrdata_s0_i(sm_rd[0]), .hreadyout_s0_i(sm_ry[0]), .hresp_s0_i(sm_rs[0]),
        .hrdata_s1_i(sm_rd[1]), .hreadyout_s1_i(sm_ry[1]), .hresp_s1_i(sm_rs[1]),
        .hrdata_s2_i(sm_rd[2]), .hreadyout_s2_i(sm_ry[2]), .hresp_s2_i(sm_rs[2]),
        .hrdata_s3_i(sm_rd[3]), .hreadyout_s3_i(sm_ry[3]), .hresp_s3_i(sm_rs[3]),
        .hrdata_df_i(sm_rd[4]), .hreadyout_df_i(sm_ry[4]), .hresp_df_i(sm_rs[4]),
        .hrdata_o(sm_hrdata), .hresp_o(sm_hresp), .hready_o(sm_hready), .dph_sel_o(sm_dphsel));

    // ---------------- master mux ----------------
    logic [1:0] mm_grant, mm_dph; logic mm_seqb;
    logic [3:0][31:0] mm_addr, mm_wdata; logic [3:0][1:0] mm_trans; logic [3:0] mm_wr;
    logic [3:0][2:0] mm_size, mm_burst; logic [3:0] mm_iprot, mm_dprot;
    wire [31:0] mm_haddr, mm_hwdata; wire [1:0] mm_htrans; wire mm_hwrite; wire [2:0] mm_hsize, mm_hburst; wire [3:0] mm_hprot;
    ahb_master_mux u_mm (.grant_i(mm_grant), .dph_master_i(mm_dph), .seq_break_i(mm_seqb),
        .i_haddr_i(mm_addr[0]), .i_htrans_i(mm_trans[0]), .i_hwrite_i(mm_wr[0]), .i_hsize_i(mm_size[0]),
        .i_hburst_i(mm_burst[0]), .i_hprot_i(mm_iprot), .i_hwdata_i(mm_wdata[0]),
        .d_haddr_i(mm_addr[1]), .d_htrans_i(mm_trans[1]), .d_hwrite_i(mm_wr[1]), .d_hsize_i(mm_size[1]),
        .d_hburst_i(mm_burst[1]), .d_hprot_i(mm_dprot), .d_hwdata_i(mm_wdata[1]),
        .s_haddr_i(mm_addr[2]), .s_htrans_i(mm_trans[2]), .s_hwrite_i(mm_wr[2]), .s_hsize_i(mm_size[2]),
        .s_hburst_i(mm_burst[2]), .s_hwdata_i(mm_wdata[2]),
        .m_haddr_i(mm_addr[3]), .m_htrans_i(mm_trans[3]), .m_hwrite_i(mm_wr[3]), .m_hsize_i(mm_size[3]),
        .m_hburst_i(mm_burst[3]), .m_hwdata_i(mm_wdata[3]),
        .haddr_o(mm_haddr), .htrans_o(mm_htrans), .hwrite_o(mm_hwrite), .hsize_o(mm_hsize),
        .hburst_o(mm_hburst), .hprot_o(mm_hprot), .hwdata_o(mm_hwdata));

    // ======================= references (from the spec) =========================
    function automatic [4:0] ref_dec(input [31:0] a);
        case (a[31:28]) 4'h0: return 5'b00001; 4'h1: return 5'b00010; 4'h2: return 5'b00100;
                        4'h4: return 5'b01000; default: return 5'b10000; endcase
    endfunction
    function automatic [1:0] ref_winner(input [3:0] r);
        return r[3] ? 2'd3 : r[2] ? 2'd2 : r[1] ? 2'd1 : 2'd0;
    endfunction

    initial begin
        if (!$value$plusargs("UNIT=%s", unit)) unit = "decoder";
        void'($value$plusargs("CYCLES=%d", cycles));
        $display("=== tb_ahb_units +UNIT=%s ===", unit);
        arb_htrans = 0; arb_hready = 1; mp_htrans = 0; mp_gr = 0; mp_own = 0; mp_rdy = 1; mp_rd = 0; mp_resp = 0;
        ds_sel = 0; ds_rdy = 1; ds_trans = 0; sm_sel = 5'b10000; sm_dv = 0; sm_rd = '0; sm_ry = '1; sm_rs = '0;
        mm_grant = 0; mm_dph = 0; mm_seqb = 0; mm_addr = '0; mm_wdata = '0; mm_trans = '0; mm_wr = '0;
        mm_size = '0; mm_burst = '0; mm_iprot = 0; mm_dprot = 0; dec_a = 0;
        // reset released on a falling edge: no flop samples in the same instant as the release
        repeat (2) @(posedge clk); @(negedge clk); rst_n = 1'b1;
        case (unit)
        // -------------------------------------------------------------------------
        "decoder": begin
            for (int n = 0; n < 16; n++) foreach (dec_a[b]) begin
                dec_a = {n[3:0], 28'h0} | (32'h1 << (b % 28)) ^ 32'h0;
                #1 check(dec_sel == ref_dec(dec_a), $sformatf("[N-7.11] decode 0x%08h -> %05b (want %05b)", dec_a, dec_sel, ref_dec(dec_a)));
            end
            for (int k = 0; k < cycles; k++) begin
                dec_a = $urandom; #1 check(dec_sel == ref_dec(dec_a) && $onehot(dec_sel), $sformatf("[N-7.11] decode 0x%08h", dec_a));
            end
        end
        // -------------------------------------------------------------------------
        "arbiter": begin
            logic [1:0] g_q = 2'd0; logic rdy_q = 1'b1, dv = 1'b0, lov = 1'b0; logic [1:0] dm = 2'd0, lo = 2'd0;
            for (int k = 0; k < cycles; k++) begin
                logic [3:0] req; logic [1:0] exp_g;
                // stimulus: random requests, but a waited address phase is held (AHB-Lite)
                if (!rdy_q && arb_htrans[2*g_q+1]) begin
                    for (int m = 0; m < 4; m++) if (m != g_q && $urandom_range(3) == 0) arb_htrans[2*m +: 2] = $urandom_range(1) ? 2'b10 : 2'b00;
                end else
                    for (int m = 0; m < 4; m++) arb_htrans[2*m +: 2] = ($urandom_range(2) == 0) ? 2'b00 : ($urandom_range(3) == 0 ? 2'b11 : 2'b10);
                arb_hready = ($urandom_range(3) != 0);
                #1;
                for (int m = 0; m < 4; m++) req[m] = arb_htrans[2*m+1];
                exp_g = rdy_q ? ref_winner(req) : g_q;              // [N-7.2] frozen while a phase waits
                check(arb_grant == exp_g, $sformatf("[N-7.3] grant %0d for requests %04b (want %0d, frozen=%0d)", arb_grant, req, exp_g, !rdy_q));
                check(arb_dphv == dv && (!dv || arb_dphm == dm), $sformatf("[N-7.4] data phase %0d/%0d (want %0d/%0d)", arb_dphv, arb_dphm, dv, dm));
                check(arb_seqb == (!lov || lo != arb_grant), "[AHB-3] seq_break = first transfer after an owner change");
                @(posedge clk);
                if (arb_hready) begin dv = req[arb_grant]; dm = arb_grant; if (req[arb_grant]) begin lov = 1; lo = arb_grant; end end
                g_q = arb_grant; rdy_q = arb_hready;
                @(negedge clk);
            end
        end
        // -------------------------------------------------------------------------
        "master_port": begin
            logic hv = 1'b0, hr = 1'b0; logic [31:0] hd = 0;
            for (int k = 0; k < cycles; k++) begin
                bit pres, pend, ent;
                mp_htrans = $urandom_range(1) ? 2'b10 : 2'b00; mp_gr = $urandom_range(1); mp_own = $urandom_range(1);
                mp_rdy = $urandom_range(3) != 0; mp_rd = $urandom; mp_resp = $urandom_range(7) == 0;
                if (hv) mp_own = 1'b0;                      // a held master owns no data phase (a_hold_not_owner)
                #1;
                pres = mp_htrans[1]; pend = pres || mp_own; ent = mp_gr || (mp_own && !pres);
                // [N-7.20] + AHB-4: idle and owed nothing -> HREADY 1; else the shared HREADY if entitled
                check(mp_hready == (pend ? (mp_rdy && ent) : 1'b1), "[N-7.20/AHB-4] HREADY seen by the master");
                // [N-8.2] + AHB-2: a held response first, then the live one only to the owner
                check(mp_hrdata == (hv ? hd : mp_own ? mp_rd : 32'd0) && mp_hresp == (hv ? hr : mp_own ? mp_resp : 1'b0),
                      "[N-8.2/AHB-2] HRDATA / HRESP returned to the master");
                @(posedge clk);
                if (mp_own && !mp_gr && pres && mp_rdy) begin hv = 1; hd = mp_rd; hr = mp_resp; end   // owner preempted while presenting
                else if (hv && mp_hready) hv = 0;                                                    // delivered
                @(negedge clk);
            end
        end
        // -------------------------------------------------------------------------
        "default_slave": begin
            int st = 0;                                           // 0 idle, 1 ERR1, 2 ERR2
            for (int k = 0; k < cycles; k++) begin
                ds_sel = $urandom_range(1); ds_trans = $urandom_range(3); ds_rdy = (st == 1) ? 1'b0 : ($urandom_range(3) != 0);
                #1;
                check(ds_rdyo == (st != 1) && ds_resp == (st != 0) && ds_rdata == 32'd0,
                      $sformatf("[N-7.6] state %0d: HREADYOUT %0d HRESP %0d", st, ds_rdyo, ds_resp));
                @(posedge clk);
                st = (st == 1) ? 2 : (ds_sel && ds_rdy && ds_trans[1]) ? 1 : 0;
                @(negedge clk);
            end
        end
        // -------------------------------------------------------------------------
        "slave_mux": begin
            logic [4:0] dsel = 5'd0;
            for (int k = 0; k < cycles; k++) begin
                int s;
                sm_sel = 5'b1 << $urandom_range(4); sm_dv = $urandom_range(1);
                foreach (sm_rd[i]) begin sm_rd[i] = $urandom; sm_ry[i] = $urandom_range(1); sm_rs[i] = $urandom_range(1); end
                #1;
                s = dsel[0] ? 0 : dsel[1] ? 1 : dsel[2] ? 2 : dsel[3] ? 3 : dsel[4] ? 4 : -1;
                check(sm_dphsel == dsel, "[N-7.5] data-phase select register");
                check(sm_hready == (!sm_dv ? 1'b1 : (s < 0) ? 1'b1 : sm_ry[s]), "[N-7.5] HREADY from the data-phase slave");
                check(!sm_dv ? (sm_hrdata == 0 && !sm_hresp) : (s < 0) ? (sm_hrdata == 0 && !sm_hresp)
                                                                       : (sm_hrdata == sm_rd[s] && sm_hresp == sm_rs[s]),
                      "[N-7.5] return from the data-phase slave only");
                @(posedge clk);
                if (sm_hready) dsel = sm_sel;
                @(negedge clk);
            end
        end
        // -------------------------------------------------------------------------
        "master_mux": begin
            for (int k = 0; k < cycles; k++) begin
                logic [1:0] g, d; logic [1:0] t;
                mm_grant = $urandom_range(3); mm_dph = $urandom_range(3); mm_seqb = $urandom_range(1);
                for (int m = 0; m < 4; m++) begin
                    mm_addr[m] = $urandom; mm_wdata[m] = $urandom; mm_trans[m] = $urandom_range(3); mm_wr[m] = $urandom_range(1);
                    mm_size[m] = $urandom_range(2); mm_burst[m] = $urandom_range(1);
                end
                mm_iprot = $urandom; mm_dprot = $urandom;
                #1;
                g = mm_grant; d = mm_dph; t = mm_trans[g];
                check(mm_haddr == mm_addr[g] && mm_hwrite == mm_wr[g] && mm_hsize == mm_size[g] && mm_hburst == mm_burst[g],
                      "[N-7.2] address and control from the address-phase grant");
                check(mm_htrans == ((mm_seqb && t == 2'b11) ? 2'b10 : t), "[AHB-3] SEQ -> NONSEQ only on seq_break");
                check(mm_hwdata == mm_wdata[d], "[AHB-1] HWDATA from the data-phase owner");
                check(mm_hprot == ((g == 0) ? mm_iprot : (g == 1) ? mm_dprot : 4'b0011), "[N-5.2] HPROT pass-through / substitution");
                @(negedge clk);
            end
        end
        default: begin fails++; $display("[FAIL] unknown +UNIT=%s", unit); end
        endcase
        $display("CHECKS: %0d  FAILS: %0d", checks, fails);
        if (fails == 0 && checks > 0) $display("RESULT: PASSED"); else $display("RESULT: FAILED");
        $finish;
    end
endmodule
