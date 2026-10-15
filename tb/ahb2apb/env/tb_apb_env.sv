`timescale 1ns/1ps
// =============================================================================
// tb_apb_env.sv -- AHB-to-APB bridge + APB fabric environment (Track A bus plan B2)
//
// The real clk_div (production hclk/pclk relation) and ahb2apb_bridge with its bound
// properties (rtl/ahb2apb/ahb2apb_sva.sv) and coverage (ahb2apb_cov.sv); the B1 AHB
// master agent; twelve apb_target models, each watched by tb/common/apb_checker.v
// (every window, not four); with `define APB_ENV_REAL_DMA` window 5 is the real
// dma_top register bank. Expectations come from garuda_map_pkg and the spec, not the RTL.
//
// SCOREBOARD:
//   - every AHB transfer completes once, in order (agent tags);
//   - a LEGAL one (window present, word, inside the 48 KiB aperture) appears exactly
//     once at its window's target, with the low address, direction and write data;
//     a read returns the target's PRDATA; the response is ERROR exactly when the
//     target answered PSLVERR or never answered (timeout);
//   - an ILLEGAL one is ERROR and reaches no target;
//   - no target saw a transfer no master sent (phantom), none saw one twice.
// APB-1 (open ruling): the bridge's timeout drops PSEL with PREADY low, which strict
// APB forbids. The checkers stay strict; the bench requires their violation count to
// equal the number of accesses the targets saw abandoned -- a narrow, counted
// exception, never a blanket waiver.
//
// +TEST=<name>   smoke windows waits b2b reject aperture timeout slverr div phase reset
//                skew toggle random  (+INJECT=drop|rdata|dup scoreboard negative controls)
// Parameters by define: APB_ENV_DIV (default 0), APB_ENV_MASK (default 0FFF).
// =============================================================================
`ifndef APB_ENV_DIV
  `define APB_ENV_DIV 24'h0
`endif
`ifndef APB_ENV_MASK
  `define APB_ENV_MASK 16'h0FFF
`endif

module tb_apb_env;
    import garuda_map_pkg::*;
    localparam [23:0] DIV  = `APB_ENV_DIV;
    localparam [15:0] MASK = `APB_ENV_MASK;

    // ---- clocks and resets (reset starts X: TB-22 / TB-46) ---------------------------
    reg refclk = 1'b0, ext_rst_n;
    initial #0 ext_rst_n = 1'b0;
    always #1 refclk = ~refclk;
    wire aon, hclk, pclk, pclk_phase, div_busy; wire [1:0] div_act;
    clk_div u_clk (.refclk_i(refclk), .raw_rst_n_i(ext_rst_n), .div_sel_i(2'b00), .aon_clk_o(aon),
                   .hclk_o(hclk), .pclk_o(pclk), .pclk_phase_o(pclk_phase), .div_act_o(div_act), .div_busy_o(div_busy));
    reg hreset_n, preset_n;
    initial #0 begin hreset_n <= 1'b0; preset_n <= 1'b0; end

    // ---- AHB master (the B1 agent) ----------------------------------------------------
    wire [31:0] haddr, hwdata, hrdata; wire [1:0] htrans; wire hwrite, hready, hresp;
    wire [2:0] hsize, hburst; wire [3:0] hprot;
    // Global HREADY as on the chip: while the bridge owns the data phase it is the bridge's
    // HREADYOUT; otherwise it comes from the other slaves (other_rdy, normally 1). So the
    // bridge sees address phases even while its own HREADYOUT is low (the [N-9.2] gap).
    wire hreadyout, hresp_b; wire [31:0] hrdata_b;
    logic other_rdy = 1'b1;
    logic bdp = 1'b0;                                   // the bridge owns the data phase
    wire  hsel = (haddr[31:28] == 4'h4);
    assign hready = bdp ? hreadyout : other_rdy;
    assign hresp  = bdp ? hresp_b : 1'b0;
    assign hrdata = bdp ? hrdata_b : 32'd0;
    always @(posedge hclk or negedge hreset_n)
        if (!hreset_n) bdp <= 1'b0;
        else if (hready) bdp <= hsel && htrans[1];
    ahb_master_agent #(.ID(1)) u_m (.hclk(hclk), .hreset_n(hreset_n), .haddr(haddr), .htrans(htrans),
        .hwrite(hwrite), .hsize(hsize), .hburst(hburst), .hprot(hprot), .hwdata(hwdata),
        .hrdata(hrdata), .hready(hready), .hresp(hresp));

    // ---- DUT ----------------------------------------------------------------------------
    wire [11:0] psel, paddr, pready, pslverr; wire penable, pwrite; wire [31:0] pwdata;
    wire [12*32-1:0] prdata;
    ahb2apb_bridge #(.WINDOW_MASK(MASK), .APB_DIV(DIV)) u_dut (
        .hclk_i(hclk), .hreset_n_i(hreset_n), .pclk_i(pclk), .preset_n_i(preset_n), .pclk_phase_i(pclk_phase),
        .hsel_i(hsel), .haddr_i(haddr), .htrans_i(htrans), .hwrite_i(hwrite), .hsize_i(hsize),
        .hwdata_i(hwdata), .hready_i(hready), .hrdata_o(hrdata_b), .hreadyout_o(hreadyout), .hresp_o(hresp_b),
        .psel_o(psel), .penable_o(penable), .pwrite_o(pwrite), .paddr_o(paddr), .pwdata_o(pwdata),
        .prdata_i(prdata), .pready_i(pready), .pslverr_i(pslverr));

    // ---- twelve targets, each with its own protocol checker ------------------------------
    wire [31:0] viol [12];
    genvar g;
    generate for (g = 0; g < 12; g++) begin : g_w
        localparam [1:0] D = DIV[2*g +: 2];
`ifdef APB_ENV_REAL_DMA
        if (g == 5) begin : g_dma
            dma_top u_dma (.hclk_i(hclk), .hreset_n_i(hreset_n), .pclk_i(pclk), .preset_n_i(preset_n),
                .psel_i(psel[g]), .penable_i(penable), .pwrite_i(pwrite), .paddr_i(paddr), .pwdata_i(pwdata),
                .prdata_o(prdata[32*g +: 32]), .pready_o(pready[g]), .pslverr_o(pslverr[g]),
                .haddr_o(), .htrans_o(), .hwrite_o(), .hsize_o(), .hburst_o(), .hwdata_o(),
                .hrdata_i(32'd0), .hready_i(1'b1), .hresp_i(1'b0), .dma_req_i(6'd0),
                .dma_ack_o(), .dma_complete_o(), .dma_error_o());
        end else
`endif
        begin : g_t
            apb_target #(.W(g)) u_t (.pclk(pclk), .preset_n(preset_n), .psel(psel[g]), .penable(penable),
                .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata), .prdata(prdata[32*g +: 32]),
                .pready(pready[g]), .pslverr(pslverr[g]));
        end
        apb_checker #(.EXTEND_MAX((1 << D) - 1)) u_chk (.clk_i(pclk), .rst_n_i(preset_n), .psel_i(psel[g]),
            .penable_i(penable), .pwrite_i(pwrite), .paddr_i({20'h0, paddr}), .pwdata_i(pwdata), .pstrb_i(4'hF),
            .pready_i(pready[g]), .pslverr_i(pslverr[g]), .viol_count_o(viol[g]));
    end endgenerate

    // =====================================================================================
    // helpers
    // =====================================================================================
    int checks = 0, fails = 0, n_xfers = 0;
    string tcase, inject;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; if (fails <= 30) $display("[FAIL] %s (t=%0t)", what, $time); end
    endtask
    function automatic logic [31:0] A(input int w, input int off);       // window w, byte offset off
        return APB_BASE + w * APB_WINDOW_BYTES + off;
    endfunction
    task automatic go(input logic [31:0] a, input bit w, input logic [2:0] sz = 3'd2, input int unsigned gap = 0);
        u_m.push(a, w, {a[15:0], 4'hC, u_m.n_issued[11:0]}, sz, gap);
    endtask
    task automatic drain(input int max = 40000);
        int n = 0;
        while (u_m.busy() && n < max) begin @(posedge hclk); n++; end
        check(!u_m.busy(), "all AHB transfers completed (no hang)");
        repeat (6) @(posedge pclk);
    endtask
`define T(w) g_w[w].g_t.u_t
    // configure a target by index (generate scopes need a constant index)
    task automatic tcfg(input int w, input int wfix, input int unsigned wmax, input bit never,
                        input logic [11:0] elo, input logic [11:0] ehi);
        case (w)
            0: begin `T(0).wait_fix = wfix; `T(0).wait_max = wmax; `T(0).never_ready = never; `T(0).err_lo = elo; `T(0).err_hi = ehi; end
            1: begin `T(1).wait_fix = wfix; `T(1).wait_max = wmax; `T(1).never_ready = never; `T(1).err_lo = elo; `T(1).err_hi = ehi; end
            2: begin `T(2).wait_fix = wfix; `T(2).wait_max = wmax; `T(2).never_ready = never; `T(2).err_lo = elo; `T(2).err_hi = ehi; end
            3: begin `T(3).wait_fix = wfix; `T(3).wait_max = wmax; `T(3).never_ready = never; `T(3).err_lo = elo; `T(3).err_hi = ehi; end
            4: begin `T(4).wait_fix = wfix; `T(4).wait_max = wmax; `T(4).never_ready = never; `T(4).err_lo = elo; `T(4).err_hi = ehi; end
`ifndef APB_ENV_REAL_DMA
            5: begin `T(5).wait_fix = wfix; `T(5).wait_max = wmax; `T(5).never_ready = never; `T(5).err_lo = elo; `T(5).err_hi = ehi; end
`endif
            6: begin `T(6).wait_fix = wfix; `T(6).wait_max = wmax; `T(6).never_ready = never; `T(6).err_lo = elo; `T(6).err_hi = ehi; end
            7: begin `T(7).wait_fix = wfix; `T(7).wait_max = wmax; `T(7).never_ready = never; `T(7).err_lo = elo; `T(7).err_hi = ehi; end
            8: begin `T(8).wait_fix = wfix; `T(8).wait_max = wmax; `T(8).never_ready = never; `T(8).err_lo = elo; `T(8).err_hi = ehi; end
            9: begin `T(9).wait_fix = wfix; `T(9).wait_max = wmax; `T(9).never_ready = never; `T(9).err_lo = elo; `T(9).err_hi = ehi; end
            10: begin `T(10).wait_fix = wfix; `T(10).wait_max = wmax; `T(10).never_ready = never; `T(10).err_lo = elo; `T(10).err_hi = ehi; end
            11: begin `T(11).wait_fix = wfix; `T(11).wait_max = wmax; `T(11).never_ready = never; `T(11).err_lo = elo; `T(11).err_hi = ehi; end
            default: ;
        endcase
    endtask
    task automatic tcfg_all(input int wfix, input int unsigned wmax);
        for (int w = 0; w < 12; w++) tcfg(w, wfix, wmax, 1'b0, 12'd0, 12'd0);
    endtask

    // ---- scoreboard -------------------------------------------------------------------
    typedef struct { int w; logic [11:0] addr; logic write; logic [31:0] wdata, rdata; logic err, ab; longint cyc; } tev_t;
    int n_abandoned_total = 0;
    // the APB checkers clear their counters when PRESET resets; bank them first so the
    // APB-1 comparison at the end covers the whole run
    int viol_bank = 0;
    task automatic bank_viol();
        foreach (viol[w]) viol_bank += viol[w];
    endtask
    task automatic collect(output tev_t ev[$]);
        ev.delete();
`define PULL(w) foreach (`T(w).log_q[k]) ev.push_back('{w, `T(w).log_q[k].addr, `T(w).log_q[k].write, `T(w).log_q[k].wdata, `T(w).log_q[k].rdata, `T(w).log_q[k].err, `T(w).log_q[k].abandoned, `T(w).log_q[k].cyc}); `T(w).log_q.delete();
        `PULL(0) `PULL(1) `PULL(2) `PULL(3) `PULL(4)
`ifndef APB_ENV_REAL_DMA
        `PULL(5)
`endif
        `PULL(6) `PULL(7) `PULL(8) `PULL(9) `PULL(10) `PULL(11)
        ev.sort(x) with (x.cyc);
    endtask
    function automatic bit legal(input logic [31:0] a, input logic [2:0] sz);
        return apb_window_of(a, MASK) >= 0 && sz == 3'd2;
    endfunction
    task automatic scoreboard(input string phase);
        tev_t ev[$];
        ahb_agent_pkg::ahb_done_t dq[$];
        int f0 = fails, j = 0;
        collect(ev);
        dq = u_m.done_q;
        if (inject == "drop" && dq.size() > 2) dq.delete(1);
        if (inject == "rdata") foreach (dq[k]) if (!dq[k].write && !dq[k].err) begin dq[k].rdata ^= 32'h10; break; end
        if (inject == "dup" && ev.size() > 0) ev.insert(0, ev[0]);
        check(dq.size() == u_m.n_issued, $sformatf("[SB] %s: %0d of %0d AHB transfers completed", phase, dq.size(), u_m.n_issued));
        foreach (dq[k]) begin
            automatic ahb_agent_pkg::ahb_done_t d = dq[k];
            check(d.tag == k, $sformatf("[SB] %s: completion %0d is tag %0d (order / loss)", phase, k, d.tag));
            if (d.addr[31:28] != 4'h4) continue;     // not the bridge's region: HSEL low, no APB activity (checked by the count)
            if (!legal(d.addr, d.size)) begin
                check(d.err, $sformatf("[SB] %s: illegal 0x%08h size %0d -> ERROR", phase, d.addr, d.size));
                continue;
            end
`ifdef APB_ENV_REAL_DMA
            if (apb_window_of(d.addr, MASK) == 5) continue;   // the real DMA: scored by t_real_dma's read-back
`endif
            n_xfers++;
            check(j < ev.size(), $sformatf("[SB] %s: legal 0x%08h reached a target", phase, d.addr));
            if (j >= ev.size()) continue;
            check(ev[j].w == apb_window_of(d.addr, MASK) && ev[j].addr == d.addr[11:0] && ev[j].write == d.write &&
                  (!d.write || ev[j].wdata == d.wdata),
                  $sformatf("[SB] %s: AHB %s 0x%08h data %08h -> APB window %0d %s 0x%03h data %08h",
                            phase, d.write ? "write" : "read", d.addr, d.wdata, ev[j].w, ev[j].write ? "write" : "read",
                            ev[j].addr, ev[j].wdata));
            check(d.err == ev[j].err, $sformatf("[SB] %s: 0x%08h response %0d, target %0d (abandoned %0d)",
                                                 phase, d.addr, d.err, ev[j].err, ev[j].ab));
            if (!d.write && !d.err)
                check(d.rdata == ev[j].rdata, $sformatf("[SB] %s: read 0x%08h got %08h, target sent %08h", phase, d.addr, d.rdata, ev[j].rdata));
            if (ev[j].ab) n_abandoned_total++;
            j++;
        end
        check(j == ev.size(), $sformatf("[SB] %s: targets saw %0d transfers, %0d expected (phantom / duplicate)", phase, ev.size(), j));
        $display("[SB] %s: %0d AHB, %0d APB transfers, %0d new failure(s)", phase, dq.size(), ev.size(), fails - f0);
        u_m.done_q.delete(); u_m.n_issued = 0;
    endtask

    // =====================================================================================
    // tests
    // =====================================================================================
    task automatic t_smoke();
        for (int w = 0; w < 12; w++) if (MASK[w]) begin go(A(w, 'h10), 1); go(A(w, 'h10), 0); end
        drain(); scoreboard("smoke");
    endtask
    // R-1 / APB-3: every present window, read and write, every word offset class
    task automatic t_windows();
        for (int w = 0; w < 12; w++) if (MASK[w])
            for (int i = 0; i < 4; i++) begin
                automatic logic [11:0] offs[4] = '{12'h000, 12'h004, 12'h7FC, 12'hFFC};
                go(A(w, offs[i]), 1); go(A(w, offs[i]), 0);
            end
        drain(); scoreboard("windows");
    endtask
    task automatic t_waits();
        int wp[4] = '{0, 1, 3, 15};
        foreach (wp[i]) begin
            tcfg_all(wp[i], 0);
            for (int w = 0; w < 12; w += 3) if (MASK[w]) begin go(A(w, 'h20), 1); go(A(w, 'h20), 0); end
            drain(); scoreboard($sformatf("waits%0d", wp[i]));
        end
        tcfg_all(-1, 6);
        for (int k = 0; k < 40; k++) begin automatic int w = $urandom_range(11); if (MASK[w]) go(A(w, 4 * k), k[0], 3'd2, k % 3); end
        drain(); scoreboard("waits_random");
        tcfg_all(0, 0);
    endtask
    // back to back: the four orders, same and different window, no idle between
    task automatic t_b2b();
        u_m.idle_in_dp = 1'b0;                        // pipelined: the next address phase in the data phase
        for (int pw = 0; pw < 2; pw++) for (int cw = 0; cw < 2; cw++) for (int same = 0; same < 2; same++) begin
            automatic int w0 = 1, w1 = same ? 1 : 7;
            go(A(w0, 'h40), pw[0]); go(A(w1, 'h44), cw[0]); go(A(w0, 'h48), pw[0]); go(A(w1, 'h4C), cw[0]);
        end
        drain(); scoreboard("b2b");
        u_m.idle_in_dp = 1'b1;
    endtask
    // no request / rejected: HSEL low (another region), sub-word (4 offsets x 2 sizes),
    // windows 12-15, a masked window
    task automatic t_reject();
        for (int o = 0; o < 4; o++) begin go(A(2, 'h80 + o), 1, 3'd0); go(A(2, 'h80 + o), 0, 3'd0); end
        for (int o = 0; o < 4; o += 2) begin go(A(2, 'h90 + o), 1, 3'd1); go(A(2, 'h90 + o), 0, 3'd1); end
        for (int w = 12; w < 16; w++) begin go(A(w, 0), 1); go(A(w, 'h10), 0); end
        go(32'h2000_0040, 1);                        // not the bridge's region: the agent's HSEL is low
        drain(); scoreboard("reject");
    endtask
    // APB-2 / Fresh plan CON-04: the aperture list, with side-effect sentinels in every window
    task automatic t_aperture();
        logic [31:0] ap[6] = '{32'h4000_0000, 32'h4000_BFFC, 32'h4000_C000, 32'h4001_0000, 32'h4001_5000, 32'h4FFF_F000};
        foreach (ap[i]) begin go(ap[i], 1); go(ap[i], 0); end
        drain(); scoreboard("aperture");
    endtask
    // R-7 / [N-7.15] edges: PREADY on the 1st, 2nd, 15th and 16th sample, and never
    task automatic t_timeout();
        int tw[4] = '{0, 1, 14, 15};                  // PREADY on sample 1, 2, 15, 16
        foreach (tw[i]) begin
            tcfg(2, tw[i], 0, 1'b0, 0, 0);
            go(A(2, 'h100), 1); go(A(2, 'h104), 0);
            drain(); scoreboard($sformatf("timeout_wait%0d", tw[i]));
        end
        tcfg(2, 0, 0, 1'b1, 0, 0);                    // never ready: two abandoned accesses
        go(A(2, 'h108), 1); go(A(2, 'h10C), 0); go(A(3, 'h10), 0);   // and the next access works
        drain(); scoreboard("timeout_never");
        tcfg(2, 0, 0, 1'b0, 0, 0);
    endtask
    task automatic t_slverr();
        for (int w = 0; w < 12; w++) if (MASK[w]) tcfg(w, 1, 0, 1'b0, 12'h200, 12'h210);
        for (int w = 0; w < 12; w++) if (MASK[w]) begin
            go(A(w, 'h200), 1); go(A(w, 'h204), 0); go(A(w, 'h210), 0);   // error, error, then OKAY
        end
        drain(); scoreboard("slverr");
        for (int w = 0; w < 12; w++) tcfg(w, 0, 0, 1'b0, 0, 0);
    endtask
    // APB_DIV: with dividers in this build, PREADY early (during the extension) and late
    task automatic t_div();
        int dw[5] = '{0, 1, 2, 4, 9};
        foreach (dw[i]) begin
            tcfg_all(dw[i], 0);
            for (int w = 0; w < 12; w++) if (MASK[w]) begin go(A(w, 'h300), 1); go(A(w, 'h300), 0); end
            drain(); scoreboard($sformatf("div_wait%0d", dw[i]));
        end
        tcfg_all(0, 0);
    endtask
    // request on both pclk phases: transfers issued with gaps of 0..3 hclk cycles
    task automatic t_phase();
        for (int gp = 0; gp < 4; gp++) for (int k = 0; k < 4; k++) go(A(9, 'h20 + 4 * k), k[0], 3'd2, gp);
        drain(); scoreboard("phase");
    endtask
    // resets: HRESET only, PRESET only (the [N-9.2] gap), and in SETUP / ACCESS / AHB wait
    task automatic t_reset();
        for (int where = 0; where < 4; where++) begin
            tcfg(4, 12, 0, 1'b0, 0, 0);               // a long ACCESS, so a reset can land inside it
            go(A(4, 'h40), 1); go(A(4, 'h44), 0);
            repeat (where == 0 ? 1 : where == 1 ? 3 : 12) @(posedge hclk);
            bank_viol();
            if (where == 3) begin
                preset_n <= 1'b0;                      // APB side alone: the bridge must hold HREADYOUT low
                repeat (4) @(posedge pclk);
                check(!hreadyout, "[N-9.2] HREADYOUT low while PRESET is asserted");
                preset_n <= 1'b1;
                drain(); u_m.done_q.delete(); u_m.n_issued = 0;
            end else begin
                hreset_n <= 1'b0; preset_n <= 1'b0;
                u_m.flush();
                repeat (3) @(posedge pclk);
                hreset_n <= 1'b1;                      // HRESET first, PRESET a few pclk later (production order)
                repeat (2) @(posedge hclk);
                check(!hreadyout, "[N-9.3] HREADYOUT low until both resets release");
                go(A(4, 'h48), 0);                    // accepted in the gap, held, then served
                repeat (3) @(posedge pclk);
                preset_n <= 1'b1;
                drain(); u_m.done_q.delete(); u_m.n_issued = 0;
            end
            begin tev_t ev[$]; collect(ev); end      // the interrupted accesses: not scored
            t_smoke();
        end
        // a reset at every delay 2..9 hclk after the request, so one lands in each phase
        // (SETUP lasts one pclk = two hclk); the interrupted accesses are not scored
        for (int d = 2; d < 10; d++) begin
            go(A(4, 'h60), d[0]);
            repeat (d) @(posedge hclk);
            bank_viol();
            hreset_n <= 1'b0; preset_n <= 1'b0; u_m.flush();
            repeat (2) @(posedge pclk);
            hreset_n <= 1'b1; repeat (2) @(posedge pclk); preset_n <= 1'b1;
            repeat (4) @(posedge hclk);
            begin tev_t ev[$]; collect(ev); end
        end
        t_smoke();
        tcfg(4, 0, 0, 1'b0, 0, 0);
    endtask

    // t_apb_reset_skew ([N-9.2]): HRESET released, PRESET still low. The other slaves keep
    // the bus going; an illegal and a legal access to the bridge are accepted in the gap,
    // held (HREADYOUT low, no false acknowledge), and served once PRESET releases
    task automatic t_skew();
        for (int legal_first = 0; legal_first < 2; legal_first++) begin
            bank_viol();
            hreset_n <= 1'b0; preset_n <= 1'b0; u_m.flush();
            repeat (3) @(posedge pclk);
            hreset_n <= 1'b1;
            repeat (2) @(posedge hclk);
            if (legal_first) begin go(A(6, 'h20), 1); go(A(6, 'h20), 0); go(A(6, 'h22), 1, 3'd1); end
            else             begin go(A(6, 'h22), 1, 3'd1); go(A(6, 'h24), 1); go(A(6, 'h24), 0); end
            repeat (24) @(posedge hclk);
            check(u_m.done_q.size() == 0 && !hreadyout, "[N-9.2] nothing acknowledged while PRESET is asserted");
            preset_n <= 1'b1;
            drain(); scoreboard($sformatf("skew%0d", legal_first));
        end
    endtask
    // toggle every captured bit: walking 1 / 0 on the write data and on the in-window
    // offset; HADDR[27:16] walking (out of the aperture: ERROR) and back
    task automatic t_toggle();
        for (int b = 0; b < 32; b++) begin
            u_m.push(A(3, 'h100), 1, 32'h1 << b); u_m.push(A(3, 'h100), 1, ~(32'h1 << b)); u_m.push(A(3, 'h100), 0, 0);
        end
        for (int b = 2; b < 12; b++) begin go(A(8, 1 << b), 1); go(A(8, 'hFFC & ~(1 << b)), 0); end
        for (int b = 16; b < 28; b++) begin go(32'h4000_0000 | (32'h1 << b), 1); go(A(1, 'h10), 0); end
        go(32'h4FFF_FFFC, 0); go(A(1, 'h14), 0);
        // the shared bus carries other regions' traffic past the bridge (HSEL low): address
        // bits 31..28 and an I-port-style INCR burst (SEQ, HTRANS[0] = 1) the bridge ignores
        go(32'h1000_0100, 0); go(32'h8000_0100, 0); go(32'hF000_0100, 0); go(32'h0000_0100, 0);
        u_m.idle_in_dp = 1'b0;                        // pipelined, so the burst keeps its SEQ beats
        for (int b = 0; b < 4; b++) u_m.push(32'h0000_0200 + 4 * b, 1'b0, 0, 3'd2, 0, 1'b1, b != 0);
        drain(); u_m.idle_in_dp = 1'b1;
        go(A(1, 'h18), 0);
        drain(); scoreboard("toggle");
    endtask
    task automatic t_random();
        for (int round = 0; round < 8; round++) begin
            tcfg_all(-1, 5);
            tcfg($urandom_range(11), -1, 3, 1'b0, 12'h400, 12'h440);
            for (int k = 0; k < 50; k++) begin
                automatic int w = $urandom_range(15);
                automatic logic [2:0] sz = ($urandom_range(7) == 0) ? 3'($urandom_range(1)) : 3'd2;
                automatic logic [11:0] o = {$urandom_range(12'hFFF) >> 2, 2'b00};
                if ($urandom_range(15) == 0) o = 12'h400 + 4 * $urandom_range(15);
                go(A(w, o) | (($urandom_range(31) == 0) ? 32'h0001_0000 : 0), $urandom_range(1), sz, $urandom_range(3));
            end
            drain(); scoreboard($sformatf("random/%0d", round));
        end
        tcfg_all(0, 0); for (int w = 0; w < 12; w++) tcfg(w, 0, 0, 1'b0, 0, 0);
    endtask
    // the real DMA register bank on window 5 (needs APB_ENV_REAL_DMA): write then read back
    // every channel's SAR / DAR / CNT through the real bridge, back to back
    task automatic t_real_dma();
`ifdef APB_ENV_REAL_DMA
        logic [31:0] v;
        for (int ch = 0; ch < 6; ch++) begin
            u_m.push(A(5, 32 * ch + 4), 1, 32'h2000_0000 + ch * 16);       // SAR
            u_m.push(A(5, 32 * ch + 8), 1, 32'h2000_8000 + ch * 16);       // DAR
            u_m.push(A(5, 32 * ch + 12), 1, 32'd100 + ch);                 // CNT
            u_m.push(A(5, 32 * ch + 4), 0, 0); u_m.push(A(5, 32 * ch + 8), 0, 0); u_m.push(A(5, 32 * ch + 12), 0, 0);
        end
        u_m.push(A(5, 'hFF0), 1, 32'h1234);                                 // an illegal offset: PSLVERR
        drain();
        foreach (u_m.done_q[k]) begin
            automatic ahb_agent_pkg::ahb_done_t d = u_m.done_q[k];
            if (d.addr == A(5, 'hFF0)) check(d.err, "[real DMA] illegal offset -> ERROR (PSLVERR through the bridge)");
            else if (!d.write) begin
                automatic int ch = d.addr[7:5]; automatic int r = d.addr[4:2];
                automatic logic [31:0] e = (r == 1) ? 32'h2000_0000 + ch * 16 : (r == 2) ? 32'h2000_8000 + ch * 16 : 32'd100 + ch;
                check(!d.err && d.rdata == e, $sformatf("[real DMA] ch%0d reg %0d read back %08h (want %08h)", ch, r, d.rdata, e));
            end else check(!d.err, $sformatf("[real DMA] write 0x%08h OKAY", d.addr));
        end
        u_m.done_q.delete(); u_m.n_issued = 0;
`else
        $display("[INFO] t_real_dma needs +define+APB_ENV_REAL_DMA");
`endif
    endtask

    // =====================================================================================
    initial begin
        int vtot;
        if (!$value$plusargs("TEST=%s", tcase)) tcase = "smoke";
        if (!$value$plusargs("INJECT=%s", inject)) inject = "";
        $display("=== tb_apb_env +TEST=%s DIV=%06h MASK=%04h%s ===", tcase, DIV, MASK, inject != "" ? {" +INJECT=", inject} : "");
        u_m.idle_in_dp = 1'b1;                       // as the D-port / SBA / DMA: IDLE in the data phase
        tcfg_all(0, 0);
        #50 ext_rst_n = 1'b1;
        repeat (4) @(posedge hclk); hreset_n <= 1'b1;
        repeat (4) @(posedge pclk); preset_n <= 1'b1;
        repeat (4) @(posedge hclk);
        case (tcase)
            "smoke": t_smoke(); "windows": t_windows(); "waits": t_waits(); "b2b": t_b2b();
            "reject": t_reject(); "aperture": t_aperture(); "timeout": t_timeout(); "slverr": t_slverr();
            "div": t_div(); "phase": t_phase(); "reset": t_reset(); "random": t_random(); "real_dma": t_real_dma();
            "skew": t_skew(); "toggle": t_toggle();
            "mut": begin t_smoke(); t_windows(); t_waits(); t_b2b(); t_reject(); t_aperture(); t_timeout();
                         t_slverr(); t_div(); t_phase(); t_toggle(); t_skew(); end
            default: begin fails++; $display("[FAIL] unknown +TEST=%s", tcase); end
        endcase
        // APB protocol: strict checkers; the only violations allowed are the counted APB-1 aborts
        vtot = viol_bank; foreach (viol[w]) vtot += viol[w];
        if (n_abandoned_total) $display("[KNOWN APB-1] %0d access(es) abandoned by the bridge timeout (open ruling)", n_abandoned_total);
        check(vtot == n_abandoned_total,
              $sformatf("[R-1] APB protocol violations %0d, of which %0d are the counted APB-1 timeout aborts", vtot, n_abandoned_total));
        $display("CHECKS: %0d  FAILS: %0d  LEGAL-TRANSFERS: %0d", checks, fails, n_xfers);
        if (fails == 0 && checks > 0) $display("RESULT: PASSED"); else $display("RESULT: FAILED");
        $finish;
    end
    initial begin #50_000_000; $display("[FAIL] global timeout"); $display("RESULT: FAILED"); $finish; end
endmodule
