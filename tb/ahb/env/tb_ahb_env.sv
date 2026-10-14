`timescale 1ns/1ps
// =============================================================================
// tb_ahb_env.sv -- AHB-Lite interconnect environment (Track A bus plan B1, A4/A5)
//
// Plain SystemVerilog shaped like UVM (H4): the real ahb_interconnect with its
// bound properties (rtl/ahb/ahb_interconnect_sva.sv) and coverage
// (tb/ahb/env/ahb_cov.sv); four ahb_master_agent instances shaped like the four
// GARUDA masters; four ahb_slave_mem responders in interconnect mode (ISRAM,
// Boot ROM, DSRAM, bridge region; the real default slave is inside the DUT);
// ahb_lite_checker on the four master ports and on the shared slave bus; and a
// scoreboard written from the spec and garuda_map_pkg, not from the RTL.
//
// SCOREBOARD (transfer conservation, AHB.TA.sb_conservation):
//   - each master's transfers complete in issue order, each exactly once;
//   - a transfer to a decoded region appears exactly once in that region's slave
//     log with the same address, direction, size and (write) data; a read
//     returns exactly the word the slave sent; the response is the slave's;
//   - a transfer to an undecoded region is answered ERROR and reaches no slave;
//   - no slave saw a transfer that no master issued.
// The fixed priority, the grant freeze, HWDATA ownership and the two-cycle ERROR
// are checked cycle by cycle by the bound properties.
//
// +TEST=<name>  smoke sets preempt decode errnext waits reset starve dma sba
//               random toggle capture ahb7; mut = every directed test in one run (planted defects)
// +INJECT=<f>   scoreboard negative controls: drop wdata rdata dup (each must FAIL)
// Seed: +verilator+seed+N (runner) drives $urandom.
// =============================================================================
module tb_ahb_env;
    import garuda_map_pkg::*;

    logic hclk = 1'b0;
    logic hreset_n;
    initial #0 hreset_n = 1'b0;                 // reset as an edge (TB-22 pattern)
    always #2 hclk = ~hclk;                     // 250 MHz

    // ---- masters -------------------------------------------------------------------
    wire [31:0] i_haddr, d_haddr, s_haddr, m_haddr, i_hwdata, d_hwdata, s_hwdata, m_hwdata;
    wire [31:0] i_hrdata, d_hrdata, s_hrdata, m_hrdata;
    wire [1:0]  i_htrans, d_htrans, s_htrans, m_htrans;
    wire        i_hwrite, d_hwrite, s_hwrite, m_hwrite;
    wire [2:0]  i_hsize, d_hsize, s_hsize, m_hsize, i_hburst, d_hburst, s_hburst, m_hburst;
    wire [3:0]  i_hprot, d_hprot, s_hprot, m_hprot;
    wire        i_hready, d_hready, s_hready, m_hready, i_hresp, d_hresp, s_hresp, m_hresp;

    ahb_master_agent #(.ID(0), .HPROT(4'b0010)) u_i (.hclk(hclk), .hreset_n(hreset_n),
        .haddr(i_haddr), .htrans(i_htrans), .hwrite(i_hwrite), .hsize(i_hsize), .hburst(i_hburst),
        .hprot(i_hprot), .hwdata(i_hwdata), .hrdata(i_hrdata), .hready(i_hready), .hresp(i_hresp));
    ahb_master_agent #(.ID(1), .HPROT(4'b0011)) u_d (.hclk(hclk), .hreset_n(hreset_n),
        .haddr(d_haddr), .htrans(d_htrans), .hwrite(d_hwrite), .hsize(d_hsize), .hburst(d_hburst),
        .hprot(d_hprot), .hwdata(d_hwdata), .hrdata(d_hrdata), .hready(d_hready), .hresp(d_hresp));
    ahb_master_agent #(.ID(2)) u_s (.hclk(hclk), .hreset_n(hreset_n),
        .haddr(s_haddr), .htrans(s_htrans), .hwrite(s_hwrite), .hsize(s_hsize), .hburst(s_hburst),
        .hprot(s_hprot), .hwdata(s_hwdata), .hrdata(s_hrdata), .hready(s_hready), .hresp(s_hresp));
    ahb_master_agent #(.ID(3)) u_m (.hclk(hclk), .hreset_n(hreset_n),
        .haddr(m_haddr), .htrans(m_htrans), .hwrite(m_hwrite), .hsize(m_hsize), .hburst(m_hburst),
        .hprot(m_hprot), .hwdata(m_hwdata), .hrdata(m_hrdata), .hready(m_hready), .hresp(m_hresp));

    // ---- DUT -----------------------------------------------------------------------
    wire        sel_isram, sel_rom, sel_dsram, sel_brg, sba_ind;
    wire [31:0] haddr, hwdata;
    wire [1:0]  htrans;
    wire        hwrite, hready;
    wire [2:0]  hsize, hburst;
    wire [3:0]  hprot;
    wire [31:0] rd_isram, rd_rom, rd_dsram, rd_brg;
    wire        ry_isram, ry_rom, ry_dsram, ry_brg, rs_isram, rs_rom, rs_dsram, rs_brg;

    ahb_interconnect u_dut (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .i_haddr_i(i_haddr), .i_htrans_i(i_htrans), .i_hwrite_i(i_hwrite), .i_hsize_i(i_hsize),
        .i_hburst_i(i_hburst), .i_hprot_i(i_hprot), .i_hwdata_i(i_hwdata),
        .i_hrdata_o(i_hrdata), .i_hready_o(i_hready), .i_hresp_o(i_hresp),
        .d_haddr_i(d_haddr), .d_htrans_i(d_htrans), .d_hwrite_i(d_hwrite), .d_hsize_i(d_hsize),
        .d_hburst_i(d_hburst), .d_hprot_i(d_hprot), .d_hwdata_i(d_hwdata),
        .d_hrdata_o(d_hrdata), .d_hready_o(d_hready), .d_hresp_o(d_hresp),
        .s_haddr_i(s_haddr), .s_htrans_i(s_htrans), .s_hwrite_i(s_hwrite), .s_hsize_i(s_hsize),
        .s_hburst_i(s_hburst), .s_hwdata_i(s_hwdata),
        .s_hrdata_o(s_hrdata), .s_hready_o(s_hready), .s_hresp_o(s_hresp),
        .m_haddr_i(m_haddr), .m_htrans_i(m_htrans), .m_hwrite_i(m_hwrite), .m_hsize_i(m_hsize),
        .m_hburst_i(m_hburst), .m_hwdata_i(m_hwdata),
        .m_hrdata_o(m_hrdata), .m_hready_o(m_hready), .m_hresp_o(m_hresp),
        .hsel_isram_o(sel_isram), .hsel_rom_o(sel_rom), .hsel_dsram_o(sel_dsram), .hsel_bridge_o(sel_brg),
        .haddr_o(haddr), .htrans_o(htrans), .hwrite_o(hwrite), .hsize_o(hsize), .hburst_o(hburst),
        .hprot_o(hprot), .hwdata_o(hwdata), .hready_o(hready), .hmaster_is_sba_o(sba_ind),
        .hrdata_isram_i(rd_isram), .hreadyout_isram_i(ry_isram), .hresp_isram_i(rs_isram),
        .hrdata_rom_i(rd_rom),     .hreadyout_rom_i(ry_rom),     .hresp_rom_i(rs_rom),
        .hrdata_dsram_i(rd_dsram), .hreadyout_dsram_i(ry_dsram), .hresp_dsram_i(rs_dsram),
        .hrdata_bridge_i(rd_brg),  .hreadyout_bridge_i(ry_brg),  .hresp_bridge_i(rs_brg));

    // ---- slaves (index = region: 0 ISRAM, 1 ROM, 2 DSRAM, 3 bridge) ----------------------
    ahb_slave_mem #(.IC_MODE(1)) u_s0 (.hclk(hclk), .hreset_n(hreset_n), .hsel(sel_isram), .hready_in(hready),
        .haddr(haddr), .htrans(htrans), .hwrite(hwrite), .hsize(hsize), .hwdata(hwdata),
        .hrdata(rd_isram), .hready(ry_isram), .hresp(rs_isram));
    ahb_slave_mem #(.IC_MODE(1)) u_s1 (.hclk(hclk), .hreset_n(hreset_n), .hsel(sel_rom), .hready_in(hready),
        .haddr(haddr), .htrans(htrans), .hwrite(hwrite), .hsize(hsize), .hwdata(hwdata),
        .hrdata(rd_rom), .hready(ry_rom), .hresp(rs_rom));
    ahb_slave_mem #(.IC_MODE(1)) u_s2 (.hclk(hclk), .hreset_n(hreset_n), .hsel(sel_dsram), .hready_in(hready),
        .haddr(haddr), .htrans(htrans), .hwrite(hwrite), .hsize(hsize), .hwdata(hwdata),
        .hrdata(rd_dsram), .hready(ry_dsram), .hresp(rs_dsram));
    ahb_slave_mem #(.IC_MODE(1)) u_s3 (.hclk(hclk), .hreset_n(hreset_n), .hsel(sel_brg), .hready_in(hready),
        .haddr(haddr), .htrans(htrans), .hwrite(hwrite), .hsize(hsize), .hwdata(hwdata),
        .hrdata(rd_brg), .hready(ry_brg), .hresp(rs_brg));

    // ---- protocol checkers on every master port and on the shared slave bus ----------
    wire [31:0] v_i, v_d, v_s, v_m, v_bus;
    ahb_lite_checker u_chk_i (.clk_i(hclk), .rst_n_i(hreset_n), .haddr_i(i_haddr), .htrans_i(i_htrans),
        .hsize_i(i_hsize), .hburst_i(i_hburst), .hwrite_i(i_hwrite), .hwdata_i(i_hwdata),
        .hready_i(i_hready), .hresp_i(i_hresp), .viol_count_o(v_i));
    ahb_lite_checker u_chk_d (.clk_i(hclk), .rst_n_i(hreset_n), .haddr_i(d_haddr), .htrans_i(d_htrans),
        .hsize_i(d_hsize), .hburst_i(d_hburst), .hwrite_i(d_hwrite), .hwdata_i(d_hwdata),
        .hready_i(d_hready), .hresp_i(d_hresp), .viol_count_o(v_d));
    ahb_lite_checker u_chk_s (.clk_i(hclk), .rst_n_i(hreset_n), .haddr_i(s_haddr), .htrans_i(s_htrans),
        .hsize_i(s_hsize), .hburst_i(s_hburst), .hwrite_i(s_hwrite), .hwdata_i(s_hwdata),
        .hready_i(s_hready), .hresp_i(s_hresp), .viol_count_o(v_s));
    ahb_lite_checker u_chk_m (.clk_i(hclk), .rst_n_i(hreset_n), .haddr_i(m_haddr), .htrans_i(m_htrans),
        .hsize_i(m_hsize), .hburst_i(m_hburst), .hwrite_i(m_hwrite), .hwdata_i(m_hwdata),
        .hready_i(m_hready), .hresp_i(m_hresp), .viol_count_o(v_m));
    ahb_lite_checker u_chk_bus (.clk_i(hclk), .rst_n_i(hreset_n), .haddr_i(haddr), .htrans_i(htrans),
        .hsize_i(hsize), .hburst_i(hburst), .hwrite_i(hwrite), .hwdata_i(hwdata),
        .hready_i(hready), .hresp_i(u_dut.hresp_shared), .viol_count_o(v_bus));

    // =====================================================================================
    // helpers
    // =====================================================================================
    int checks = 0, fails = 0;
    string tcase, inject;
    longint cyc = 0;
    always @(posedge hclk) cyc++;

    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
    endtask

    // issue one transfer from master m; write data is unique per (master, tag) so the
    // scoreboard can match it unambiguously
    function automatic logic [31:0] uniq(input int m, input int unsigned tag);
        return {4'hA, m[3:0], tag[23:0]};
    endfunction
    task automatic issue(input int m, input logic [31:0] a, input bit w, input logic [2:0] sz = 3'd2,
                         input int unsigned gap = 0, input bit incr = 1'b0, input bit seq = 1'b0);
        case (m)
            0: u_i.push(a, w, uniq(0, u_i.n_issued), sz, gap, incr, seq);
            1: u_d.push(a, w, uniq(1, u_d.n_issued), sz, gap, incr, seq);
            2: u_s.push(a, w, uniq(2, u_s.n_issued), sz, gap, incr, seq);
            default: u_m.push(a, w, uniq(3, u_m.n_issued), sz, gap, incr, seq);
        endcase
    endtask
    // an M0 INCR word-read burst of n beats from a
    task automatic burst0(input logic [31:0] a, input int n, input int unsigned gap = 0);
        for (int b = 0; b < n; b++) u_i.push(a + 4*b, 1'b0, 32'd0, 3'd2, (b == 0) ? gap : 0, 1'b1, b != 0);
    endtask

    function automatic bit all_idle();
        return !u_i.busy() && !u_d.busy() && !u_s.busy() && !u_m.busy();
    endfunction
    task automatic drain(input int max_cyc = 20000);
        int n = 0;
        while (!all_idle() && n < max_cyc) begin @(posedge hclk); n++; end
        check(all_idle(), "all masters drained (no hung transfer)");
        repeat (4) @(posedge hclk);
    endtask
    task automatic set_waits(input int s, input int unsigned rmax, input int unsigned wmax);
        case (s)
            0: begin u_s0.rwait_max = rmax; u_s0.wwait_max = wmax; end
            1: begin u_s1.rwait_max = rmax; u_s1.wwait_max = wmax; end
            2: begin u_s2.rwait_max = rmax; u_s2.wwait_max = wmax; end
            default: begin u_s3.rwait_max = rmax; u_s3.wwait_max = wmax; end
        endcase
    endtask
    task automatic set_all_waits(input int unsigned rmax, input int unsigned wmax);
        for (int s = 0; s < 4; s++) set_waits(s, rmax, wmax);
    endtask
    task automatic set_err(input int s, input logic [31:0] lo, input logic [31:0] hi);
        case (s)
            0: begin u_s0.err_lo = lo; u_s0.err_hi = hi; end
            1: begin u_s1.err_lo = lo; u_s1.err_hi = hi; end
            2: begin u_s2.err_lo = lo; u_s2.err_hi = hi; end
            default: begin u_s3.err_lo = lo; u_s3.err_hi = hi; end
        endcase
    endtask

    // =====================================================================================
    // scoreboard
    // =====================================================================================
    typedef ahb_agent_pkg::ahb_txn_t txn_t;
    int n_sb_xfers = 0;

    // Attribution monitor: which master each slave acceptance belongs to, taken from
    // the MASTER ports (the master presents NONSEQ/SEQ and sees HREADY high), not from
    // the arbiter. Per slave, data phases complete in acceptance order, so the j-th
    // entry of a slave's log belongs to own_q[s][j].
    int own_q [4][$];
    wire [3:0][31:0] mon_addr = {m_haddr, s_haddr, d_haddr, i_haddr};
    wire [3:0]       mon_acc  = {m_htrans[1] & m_hready, s_htrans[1] & s_hready,
                                 d_htrans[1] & d_hready, i_htrans[1] & i_hready};
    always @(posedge hclk)
        if (hreset_n) for (int m = 0; m < 4; m++)
            if (mon_acc[m] && slave_of(mon_addr[m]) >= 0) own_q[slave_of(mon_addr[m])].push_back(m);

    function automatic int slave_of(input logic [31:0] a);   // the AHB decoder's view ([N-7.11])
        case (a[31:28])
            4'h0: return 0;  4'h1: return 1;  4'h2: return 2;  4'h4: return 3;
            default: return -1;
        endcase
    endfunction

    task automatic scoreboard(input string phase);
        txn_t        slog [4][$];
        bit          used [4][$];
        int          last [4][4];
        ahb_agent_pkg::ahb_done_t dq [4][$];
        int unsigned issued [4];
        int          f0 = fails;
        slog[0] = u_s0.log_q; slog[1] = u_s1.log_q; slog[2] = u_s2.log_q; slog[3] = u_s3.log_q;
        dq[0] = u_i.done_q; dq[1] = u_d.done_q; dq[2] = u_s.done_q; dq[3] = u_m.done_q;
        issued[0] = u_i.n_issued; issued[1] = u_d.n_issued; issued[2] = u_s.n_issued; issued[3] = u_m.n_issued;
        // negative controls: corrupt what the scoreboard sees, never the DUT
        if (inject == "drop"  && dq[1].size() > 1) dq[1].delete(dq[1].size() / 2);
        if (inject == "rdata") foreach (dq[2][k]) if (!dq[2][k].write && !dq[2][k].err) begin dq[2][k].rdata ^= 32'h1; break; end
        if (inject == "wdata") foreach (slog[2][k]) if (slog[2][k].write) begin slog[2][k].data ^= 32'h100; break; end
        if (inject == "dup"   && slog[0].size() > 0) slog[0].push_back(slog[0][0]);
        for (int s = 0; s < 4; s++) begin
            foreach (slog[s][k]) used[s].push_back(1'b0);
            for (int m = 0; m < 4; m++) last[m][s] = -1;
        end
        for (int m = 0; m < 4; m++) begin
            check(dq[m].size() == issued[m],
                  $sformatf("[SB] %s: M%0d completed %0d of %0d issued transfers", phase, m, dq[m].size(), issued[m]));
            foreach (dq[m][k]) begin
                automatic ahb_agent_pkg::ahb_done_t d = dq[m][k];
                automatic int s = slave_of(d.addr);
                check(d.tag == k, $sformatf("[SB] %s: M%0d completion %0d is tag %0d (order / loss / duplication)", phase, m, k, d.tag));
                if (s < 0) begin
                    check(d.err, $sformatf("[SB] %s: M%0d %s 0x%08h undecoded -> ERROR", phase, m, d.write ? "write" : "read", d.addr));
                    continue;
                end
                begin
                    // the next entry of slave s that belongs to master m must be this transfer
                    automatic int hit = -1;
                    for (int j = last[m][s] + 1; j < slog[s].size() && j < own_q[s].size(); j++)
                        if (own_q[s][j] == m) begin hit = j; break; end
                    check(hit >= 0, $sformatf("[SB] %s: M%0d %s 0x%08h reached slave %0d",
                                              phase, m, d.write ? "write" : "read", d.addr, s));
                    if (hit < 0) continue;
                    check(slog[s][hit].addr == d.addr && slog[s][hit].write == d.write && slog[s][hit].size == d.size &&
                          (!d.write || slog[s][hit].err || slog[s][hit].data == d.wdata),
                          $sformatf("[SB] %s: M%0d %s 0x%08h size %0d data %08h; slave %0d saw %s 0x%08h size %0d data %08h",
                                    phase, m, d.write ? "write" : "read", d.addr, d.size, d.wdata, s,
                                    slog[s][hit].write ? "write" : "read", slog[s][hit].addr, slog[s][hit].size, slog[s][hit].data));
                    used[s][hit] = 1'b1; last[m][s] = hit; n_sb_xfers++;
                    check(d.err == slog[s][hit].err, $sformatf("[SB] %s: M%0d 0x%08h response %0d, slave gave %0d",
                                                               phase, m, d.addr, d.err, slog[s][hit].err));
                    if (!d.write && !d.err)
                        check(d.rdata == slog[s][hit].data, $sformatf("[SB] %s: M%0d read 0x%08h got %08h, slave sent %08h",
                                                                      phase, m, d.addr, d.rdata, slog[s][hit].data));
                end
            end
        end
        for (int s = 0; s < 4; s++) begin
            check(own_q[s].size() == slog[s].size(),
                  $sformatf("[SB] %s: slave %0d logged %0d transfers, masters had %0d accepted", phase, s, slog[s].size(), own_q[s].size()));
            own_q[s].delete();
        end
        for (int s = 0; s < 4; s++)
            foreach (used[s][j])
                check(used[s][j], $sformatf("[SB] %s: slave %0d saw %s 0x%08h that no master completed (phantom)",
                                            phase, s, slog[s][j].write ? "write" : "read", slog[s][j].addr));
        $display("[SB] %s: %0d transfers matched, %0d new failure(s)", phase, n_sb_xfers, fails - f0);
        // next phase starts from empty logs
        u_i.done_q.delete(); u_d.done_q.delete(); u_s.done_q.delete(); u_m.done_q.delete();
        u_i.n_issued = 0; u_d.n_issued = 0; u_s.n_issued = 0; u_m.n_issued = 0;
        u_s0.log_q.delete(); u_s1.log_q.delete(); u_s2.log_q.delete(); u_s3.log_q.delete();
    endtask

    // =====================================================================================
    // tests (A5)
    // =====================================================================================
    localparam logic [31:0] A_IS = 32'h0000_1000, A_RO = 32'h1000_0100, A_DS = 32'h2000_2000, A_AP = 32'h4000_5000;

    task automatic t_smoke();
        for (int m = 0; m < 4; m++) begin
            issue(m, A_RO + 16*m, 1'b0);
            if (m != 0) begin
                issue(m, A_DS + 64*m, 1'b1); issue(m, A_DS + 64*m, 1'b0);
                issue(m, A_IS + 64*m, 1'b1); issue(m, A_AP + 64*m, 1'b1); issue(m, A_AP + 64*m, 1'b0);
            end else begin
                issue(0, A_IS, 1'b0); issue(0, A_DS, 1'b0);
            end
        end
        drain(); scoreboard("smoke");
    endtask

    // all 15 request sets at a beat boundary, under three wait profiles
    task automatic t_sets();
        for (int wp = 0; wp < 3; wp++) begin
            set_all_waits(wp == 0 ? 0 : wp == 1 ? 2 : 8, wp == 0 ? 0 : wp == 1 ? 2 : 8);
            for (int set = 1; set < 16; set++) begin
                for (int rep = 0; rep < 3; rep++) begin
                    @(posedge hclk);
                    for (int m = 0; m < 4; m++) if (set[m])
                        issue(m, (m == 0) ? A_IS + 4*rep : A_DS + 256*m + 4*rep, m != 0 && rep[0]);
                    drain();
                end
            end
            scoreboard($sformatf("sets/waits%0d", wp));
        end
        set_all_waits(0, 0);
    endtask

    // M0 INCR burst preempted at beat 1, a middle beat and the last beat by M3, M2, M1
    task automatic t_preempt();
        for (int by = 1; by < 4; by++)
            for (int at = 1; at <= 7; at += 3) begin
                for (int ws = 0; ws < 2; ws++) begin
                    set_waits(0, ws, ws);
                    @(posedge hclk);
                    burst0(A_IS + 32'h100 * at, 8);
                    issue(by, A_DS + 16*by, 1'b1, 3'd2, at);   // arrives `at` cycles into the burst
                    issue(by, A_DS + 16*by, 1'b0);
                    drain();
                end
            end
        set_waits(0, 0, 0);
        scoreboard("preempt");
    endtask

    // every HADDR[31:28] value from every master
    task automatic t_decode();
        for (int nib = 0; nib < 16; nib++)
            for (int m = 0; m < 4; m++) begin
                automatic logic [31:0] a = {nib[3:0], 28'h000_0040} + 32'h10 * m;
                issue(m, a, 1'b0);
                if (m != 0 && nib != 1) issue(m, a + 4, 1'b1);
            end
        drain(); scoreboard("decode");
    endtask

    // ERROR (default slave and a slave's own ERROR) followed by IDLE, the same master, another master
    task automatic t_errnext();
        set_err(2, 32'h2000_F000, 32'h2000_F100);
        for (int m = 0; m < 4; m++) begin
            // then idle
            issue(m, 32'h3000_0000, 1'b0); drain();
            // then the same master, back to back
            issue(m, 32'h5000_0000, m != 0); issue(m, A_DS + 8*m, 1'b0); drain();
            // then another master, timed into the ERROR's two cycles
            issue(m, 32'h2000_F000 + 4*m, 1'b0);
            issue((m + 1) % 4, A_DS + 16, (m + 1) % 4 != 0, 3'd2, 1);
            issue((m + 3) % 4, A_DS + 32, 1'b0, 3'd2, 2);
            drain();
            // ERROR after waits
            set_waits(2, 3, 3);
            issue(m, 32'h2000_F010, 1'b0); issue(m, A_DS, 1'b0); drain();
            set_waits(2, 0, 0);
        end
        set_err(2, 0, 0);
        scoreboard("errnext");
    endtask

    // wait profiles 0,1,2,3,8,long and bridge-sized, with a higher master arriving mid-stall
    task automatic t_waits();
        int unsigned prof[7] = '{0, 1, 2, 3, 8, 70, 36};
        foreach (prof[p]) begin
            for (int s = 0; s < 4; s++) begin
                if (s == 3) begin u_s3.rwait_fix = prof[p]; u_s3.wwait_fix = prof[p]; end
                else        set_waits(s, prof[p], prof[p]);
            end
            for (int m = 0; m < 3; m++) begin
                issue(m, (m == 0) ? A_IS : A_AP + 4*m, m != 0);
                issue(m + 1, A_DS + 32*m, 1'b1, 3'd2, 2);
                issue(m, (m == 0) ? A_IS + 4 : A_DS + 4*m, 1'b0);
            end
            drain(30000);
        end
        u_s3.rwait_fix = -1; u_s3.wwait_fix = -1; set_all_waits(0, 0);
        scoreboard("waits");
    endtask

    // reset when idle, in a held address phase (presented, not granted, no data phase
    // in flight) and in a waited data phase
    task automatic t_reset();
        for (int where = 0; where < 3; where++) begin
            set_waits(2, 20, 20);
            if (where == 1) begin
                // M3 holds the bus (gap 0); M0's fetch is presented and held, no data phase yet
                for (int k = 0; k < 6; k++) issue(3, A_DS + 4*k, 1'b0);
                issue(0, A_IS, 1'b0);
                repeat (1) @(posedge hclk);
            end else if (where == 2) begin
                issue(1, A_DS, 1'b1); issue(0, A_IS, 1'b0);
                issue(3, A_DS + 4, 1'b0, 3'd2, 1);
                repeat (8) @(posedge hclk);
            end else
                repeat (4) @(posedge hclk);
            hreset_n = 1'b0;
            u_i.flush(); u_d.flush(); u_s.flush(); u_m.flush();
            u_s0.log_q.delete(); u_s1.log_q.delete(); u_s2.log_q.delete(); u_s3.log_q.delete();
            for (int s = 0; s < 4; s++) own_q[s].delete();
            repeat (3) @(posedge hclk);
            hreset_n = 1'b1;
            set_waits(2, 0, 0);
            repeat (2) @(posedge hclk);
            check(hready && i_hready && d_hready && s_hready && m_hready, "[F22] after reset: bus free, every master free");
            t_smoke();
        end
    endtask

    // M0 progress once higher-priority traffic stops (fixed priority: no fairness claim)
    task automatic t_starve();
        longint t_stop, t_m0;
        for (int k = 0; k < 40; k++) issue(3, A_DS + 4*(k % 8), k[0]);
        issue(0, A_IS, 1'b0, 3'd2, 2);
        while (u_m.busy()) @(posedge hclk);
        t_stop = cyc;
        while (u_i.busy()) @(posedge hclk);
        t_m0 = cyc;
        check(t_m0 - t_stop <= 4, $sformatf("[F09] M0 granted within 4 cycles of the DMA stopping (took %0d)", t_m0 - t_stop));
        drain(); scoreboard("starve");
    endtask

    // DMA-shaped traffic: read then write, alternating DSRAM / APB / error region, with competitors
    task automatic t_dma();
        logic [31:0] src[3] = '{A_DS, A_AP, 32'h6000_0000};
        for (int k = 0; k < 24; k++) begin
            set_waits(3, k % 5, (k * 3) % 7);
            issue(3, src[k % 3] + 4*k, 1'b0);
            issue(3, src[(k + 1) % 3] + 4*k, 1'b1);
            issue(1, A_DS + 4*k, k[0], 3'd2, k % 3);
            if (k % 4 == 0) burst0(A_IS + 16*k, 4, 1);
            if (k % 6 == 0) issue(2, A_IS + 32'h800 + 4*k, 1'b1, 3'd2, 2);
            drain();
        end
        set_waits(3, 0, 0);
        scoreboard("dma");
    endtask

    // SBA writes to ISRAM (lock bypass indication, R-7) among other traffic
    task automatic t_sba();
        for (int k = 0; k < 8; k++) begin
            issue(2, A_IS + 4*k, 1'b1); issue(1, A_IS + 4*k + 64, 1'b1, 3'd2, 1); issue(2, A_IS + 4*k, 1'b0);
            issue(2, A_RO + 4*k, 1'b0); issue(2, A_DS + 4*k, 1'b1); issue(2, A_AP + 4*k, 1'b1);
            issue(2, A_RO + 32 + 4*k, 1'b1);           // a write to the ROM region: legal on the bus
            drain();
        end
        scoreboard("sba");
    endtask

    // random mix: every master, every region, sizes, gaps, waits, ERROR windows
    task automatic t_random();
        for (int round = 0; round < 12; round++) begin
            set_all_waits($urandom_range(6), $urandom_range(6));
            set_err($urandom_range(3), 32'h2000_E000, ($urandom_range(1) != 0) ? 32'h2000_E040 : 32'h2000_E000);
            for (int k = 0; k < 40; k++) begin
                automatic int m = $urandom_range(3);
                automatic int nib_sel = $urandom_range(9);
                automatic logic [3:0] nib = (nib_sel < 2) ? 4'h0 : (nib_sel < 3) ? 4'h1 : (nib_sel < 6) ? 4'h2 :
                                            (nib_sel < 8) ? 4'h4 : 4'(($urandom_range(5) * 3 + 3) % 16);
                automatic logic [2:0] sz = (m == 0) ? 3'd2 : 3'($urandom_range(2));
                automatic logic [31:0] a = {nib, 16'h2000, 12'($urandom_range(16'hFF) << 2)};
                if (sz == 3'd0) a[1:0] = 2'($urandom_range(3));
                if (sz == 3'd1) a[1]   = 1'($urandom_range(1));
                if (nib == 4'h2 && $urandom_range(7) == 0) a = 32'h2000_E000 + 4*$urandom_range(15);
                if (m == 0 && $urandom_range(3) == 0) burst0({nib, 28'h000_0800}, 1 + $urandom_range(5), $urandom_range(2));
                else issue(m, a, (m != 0) && (nib != 4'h1) && ($urandom_range(1) != 0), sz, $urandom_range(3));
            end
            drain(40000);
            scoreboard($sformatf("random/%0d", round));
        end
        set_all_waits(0, 0); for (int s = 0; s < 4; s++) set_err(s, 0, 0);
    endtask


    // toggle every address and data bit of every master port, both ways (A8): walking
    // ones and walking zeros inside each decoded region; sub-word sizes for M1..M3
    task automatic t_toggle();
        logic [3:0] rg[4] = '{4'h0, 4'h1, 4'h2, 4'h4};
        for (int m = 0; m < 4; m++)
            for (int b = 2; b < 28; b++) begin
                automatic logic [3:0] n = rg[b % 4];
                automatic logic [31:0] one  = {n, 28'h0} | (32'h1 << b);
                automatic logic [31:0] zero = {n, 28'hFFF_FFFC} & ~(32'h1 << b);
                issue(m, one, 1'b0); issue(m, zero, 1'b0);
                if (m != 0 && n != 4'h1) begin
                    issue(m, one, 1'b1); issue(m, zero, 1'b1);
                end
            end
        for (int m = 1; m < 4; m++)
            for (int a = 0; a < 4; a++) begin
                issue(m, A_DS + a, 1'b1, 3'd0); issue(m, A_DS + a, 1'b0, 3'd0);
                if (a[0] == 0) begin issue(m, A_DS + a, 1'b1, 3'd1); issue(m, A_DS + a, 1'b0, 3'd1); end
            end
        drain(40000); scoreboard("toggle");
        // data bits: write walking ones then walking zeros through every master
        for (int m = 1; m < 4; m++)
            for (int b = 0; b < 32; b++) begin
                case (m)
                    1: begin u_d.push(A_DS + 4*b, 1'b1, 32'h1 << b); u_d.push(A_DS + 4*b, 1'b1, ~(32'h1 << b)); end
                    2: begin u_s.push(A_DS + 4*b, 1'b1, 32'h1 << b); u_s.push(A_DS + 4*b, 1'b1, ~(32'h1 << b)); end
                    default: begin u_m.push(A_DS + 4*b, 1'b1, 32'h1 << b); u_m.push(A_DS + 4*b, 1'b1, ~(32'h1 << b)); end
                endcase
                issue(0, A_DS + 4*b, 1'b0);
            end
        drain(40000); scoreboard("toggle_data");
        // read-data bits from every slave: walking ones / zeros preloaded, read back by M1..M3
        for (int b = 0; b < 32; b++) begin
            u_s0.poke(A_IS + 32'h400 + 8*b, 32'h1 << b); u_s0.poke(A_IS + 32'h404 + 8*b, ~(32'h1 << b));
            u_s1.poke(A_RO + 32'h400 + 8*b, 32'h1 << b); u_s1.poke(A_RO + 32'h404 + 8*b, ~(32'h1 << b));
            u_s3.poke(A_AP + 32'h400 + 8*b, 32'h1 << b); u_s3.poke(A_AP + 32'h404 + 8*b, ~(32'h1 << b));
            for (int m = 1; m < 4; m++) begin
                issue(m, A_IS + 32'h400 + 8*b, 1'b0); issue(m, A_IS + 32'h404 + 8*b, 1'b0);
                issue(m, A_RO + 32'h400 + 8*b, 1'b0); issue(m, A_RO + 32'h404 + 8*b, 1'b0);
                issue(m, A_AP + 32'h400 + 8*b, 1'b0); issue(m, A_AP + 32'h404 + 8*b, 1'b0);
            end
            issue(0, A_RO + 32'h400 + 8*b, 1'b0); issue(0, A_RO + 32'h404 + 8*b, 1'b0);
        end
        drain(60000); scoreboard("toggle_rdata");
        // a slave's own ERROR from every region (ROM rejecting, bridge PSLVERR-like)
        for (int s = 0; s < 4; s++) set_err(s, 32'h0000_0F00 | (s == 1 ? 32'h1000_0000 : s == 2 ? 32'h2000_0000 : s == 3 ? 32'h4000_0000 : 0),
                                               32'h0000_0F10 | (s == 1 ? 32'h1000_0000 : s == 2 ? 32'h2000_0000 : s == 3 ? 32'h4000_0000 : 0));
        for (int m = 0; m < 4; m++) begin
            issue(m, 32'h0000_0F00 + 4*m, 1'b0); issue(m, 32'h1000_0F00 + 4*m, 1'b0);
            issue(m, 32'h2000_0F00 + 4*m, 1'b0); issue(m, 32'h4000_0F00 + 4*m, 1'b0);
            drain();
        end
        for (int s = 0; s < 4; s++) set_err(s, 0, 0);
        scoreboard("slave_errors");
    endtask

    // the D-port and the SBA as generic pipelined AHB-Lite masters (the interconnect
    // must serve any compliant master): each is preempted while presenting, so its
    // response is held (AHB-2) and replayed
    task automatic t_capture();
        u_d.idle_in_dp = 1'b0; u_s.idle_in_dp = 1'b0;
        set_waits(2, 2, 2);
        // one master at a time (so its first transfer is accepted at once), the higher
        // one arriving 1..3 cycles later while the first data phase waits
        for (int k = 0; k < 6; k++)
            for (int m = 1; m < 3; m++) begin
                issue(m, A_DS + 16*m + 4*k, 1'b0); issue(m, A_DS + 16*m + 4*k + 4, 1'b0);
                issue(m + 1, A_IS + 64*m + 4*k, 1'b1, 3'd2, 1 + k % 3);
                drain();
            end
        u_d.idle_in_dp = 1'b1; u_s.idle_in_dp = 1'b1;
        set_waits(2, 0, 0);
        scoreboard("capture");
    endtask

    // AHB-7 reproducer: an I-port-shaped M0 (pipelined, never cancels) gets an ERROR while
    // presenting its next fetch, and the DMA requests in the first ERROR cycle
    task automatic t_ahb7();
        u_s0.err_lo = 32'h0000_0F00; u_s0.err_hi = 32'h0000_0F04;
        for (int k = 0; k < 3; k++) begin
            u_i.push(32'h0000_0F00, 1'b0, 0, 3'd2, 0, 1'b0, 1'b0);
            u_i.push(32'h0000_0F10, 1'b0, 0, 3'd2, 0, 1'b0, 1'b0);
            issue(3, A_DS + 4*k, 1'b0, 3'd2, 1 + k);      // arrives during the ERROR
            drain();
        end
        u_s0.err_lo = 0; u_s0.err_hi = 0;
        scoreboard("ahb7");
    endtask

    // =====================================================================================
    initial begin
        if (!$value$plusargs("TEST=%s", tcase)) tcase = "smoke";
        if (!$value$plusargs("INJECT=%s", inject)) inject = "";
        $display("=== tb_ahb_env +TEST=%s%s ===", tcase, inject != "" ? {" +INJECT=", inject} : "");
        // master shapes: the I-port pipelines its fetches; the D-port, the SBA and the DMA
        // drive IDLE through each data phase (dma_engine E_RD/E_WD, the D-port, the SBA).
        // M0 cancels its next fetch after an ERROR first cycle (FA-4, the condition under
        // which AHB-7 cannot occur), except in +TEST=ahb7, which keeps the real I-port
        // shape (it never cancels, BUS-C) and must hit AHB-7's detectors.
        u_d.idle_in_dp = 1'b1; u_s.idle_in_dp = 1'b1; u_m.idle_in_dp = 1'b1;
        u_i.cancel_on_err = (tcase != "ahb7");
        for (int s = 0; s < 4; s++) set_waits(s, 0, 0);
        repeat (3) @(posedge hclk);
        hreset_n = 1'b1;
        repeat (2) @(posedge hclk);
        case (tcase)
            "smoke":   t_smoke();
            "sets":    t_sets();
            "preempt": t_preempt();
            "decode":  t_decode();
            "errnext": t_errnext();
            "waits":   t_waits();
            "reset":   t_reset();
            "starve":  t_starve();
            "dma":     t_dma();
            "sba":     t_sba();
            "random":  t_random();
            "ahb7":    t_ahb7();
            "toggle":  t_toggle();
            "capture": t_capture();
            // planted-defect run (A9): every directed test, no random phase
            "mut":     begin t_smoke(); t_sets(); t_preempt(); t_decode(); t_errnext(); t_waits();
                             t_starve(); t_dma(); t_sba(); t_capture(); t_reset(); end
            default: begin fails++; $display("[FAIL] unknown +TEST=%s", tcase); end
        endcase
        // protocol checkers: every port clean
        u_chk_i.report_result(); u_chk_d.report_result(); u_chk_s.report_result();
        u_chk_m.report_result(); u_chk_bus.report_result();
        check(v_i == 0 && v_d == 0 && v_s == 0 && v_m == 0,
              $sformatf("[F01] master-port protocol violations I=%0d D=%0d S=%0d M=%0d", v_i, v_d, v_s, v_m));
        check(v_bus == 0, $sformatf("[F01] slave-bus protocol violations %0d", v_bus));
        $display("CHECKS: %0d  FAILS: %0d  TRANSFERS: %0d", checks, fails, n_sb_xfers);
        if (fails == 0 && checks > 0) $display("RESULT: PASSED");
        else                          $display("RESULT: FAILED");
        $finish;
    end

    initial begin #20_000_000; $display("[FAIL] global timeout"); $display("RESULT: FAILED"); $finish; end
endmodule
