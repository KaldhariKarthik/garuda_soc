`timescale 1ns/1ps
// =============================================================================
// dma_cov.sv -- functional coverage of the DMA (Track A, DMA plan D4/D7; vPlan
// covergroup names, 2026-10-05 plan section 7). Bound into dma_top by every DMA
// bench (block, probe, regs, env filelists), not by rtl/dma/filelist.f or the chip.
//
// Module covergroups with an explicit sample(): Verilator 5.052 crashes on a class
// covergroup that samples through a virtual interface (TOOL-23), and its
// get_coverage() always returns 0 (TOOL-22), so the numbers come from coverage.dat
// (--coverage-user) through tools/cov/cov_report.py. Crosses use no binsof/intersect
// (Verilator drops them). Bins are what the specification asks to see; D7 adds what
// the hole list shows is missing.
// =============================================================================
module dma_cov (
    input wire        hclk_i, hreset_n_i, pclk_i,
    input wire        psel_i, penable_i, pwrite_i, pslverr_o,
    input wire [11:0] paddr_i,
    input wire [31:0] haddr_o,
    input wire [1:0]  htrans_o,
    input wire        hwrite_o, hready_i, hresp_i,
    input wire [5:0]  dma_req_i, dma_ack_o, dma_complete_o, dma_error_o,
    input wire [5:0]  wr_cr, wr_sar, wr_dar, wr_cnt, wr_iclr,
    input wire [31:0] wdata,
    input wire [191:0] cr, cnt, stat,
    input wire [5:0]  eligible, beat_done, beat_err,
    input wire [2:0]  err_phase,
    input wire        grant_valid,
    input wire [2:0]  grant_ch,
    input wire [2:0]  eng_st, eng_ch
);
    // ---- per-channel views
    function automatic [1:0] f_mode(int n); return cr[32*n + 1 +: 2]; endfunction
    function automatic [1:0] f_size(int n); return cr[32*n + 5 +: 2]; endfunction
    function automatic bit   f_en(int n);   return cr[32*n]; endfunction
    function automatic [15:0] f_rem(int n); return stat[32*n +: 16]; endfunction
    function automatic bit   f_act(int n);  return stat[32*n + 16]; endfunction

    // ---- groups -------------------------------------------------------------------------
    // F01-F03: the control fields a channel is armed with (EN 0 -> 1)
    covergroup cg_dma_cr with function sample(int ch, bit [1:0] mode, bit [1:0] size, bit sinc, bit dinc);
        cp_ch:   coverpoint ch   { bins c[] = {[0:5]}; }
        cp_mode: coverpoint mode { bins p2m = {0}; bins m2p = {1}; bins m2m = {2}; }
        cp_size: coverpoint size { bins b = {0}; bins h = {1}; bins w = {2}; }
        cp_sinc: coverpoint sinc;
        cp_dinc: coverpoint dinc;
        x_mode_size: cross cp_mode, cp_size;
        x_mode_ch:   cross cp_mode, cp_ch;
        x_size_ch:   cross cp_size, cp_ch;
        x_inc:       cross cp_mode, cp_sinc, cp_dinc;
    endgroup
    // F02/F03: illegal MODE / SIZE written, with EN 0 and 1
    covergroup cg_dma_cr3 with function sample(bit mode3, bit size3, bit en);
        cp_mode3: coverpoint mode3 { bins written = {1}; }
        cp_size3: coverpoint size3 { bins written = {1}; }
        cp_en:    coverpoint en;
        x_m: cross cp_mode3, cp_en;
        x_s: cross cp_size3, cp_en;
    endgroup
    // F05: CNT at arm time
    covergroup cg_dma_cnt with function sample(bit [15:0] c);
        cp_cnt: coverpoint c { bins zero = {0}; bins one = {1}; bins two = {2}; bins c3_15 = {[3:15]};
                               bins c16_255 = {[16:255]}; bins c256_65534 = {[256:65534]}; bins max = {65535}; }
    endgroup
    // F13-F17: every completed beat
    covergroup cg_dma_xfer with function sample(int ch, bit [1:0] mode, bit [1:0] size, bit last);
        cp_ch:   coverpoint ch   { bins c[] = {[0:5]}; }
        cp_mode: coverpoint mode { bins p2m = {0}; bins m2p = {1}; bins m2m = {2}; }
        cp_size: coverpoint size { bins b = {0}; bins h = {1}; bins w = {2}; }
        cp_last: coverpoint last;
        x_mode_size_ch: cross cp_mode, cp_size, cp_ch;
        x_last_mode:    cross cp_last, cp_mode;
    endgroup
    // F17: byte and halfword lane offsets (source on the read, destination on the write)
    covergroup cg_dma_lanes with function sample(bit wr, bit [1:0] size, bit [1:0] off);
        cp_dir:  coverpoint wr;
        cp_byte: coverpoint off iff (size == 0) { bins o[] = {[0:3]}; }
        cp_half: coverpoint off iff (size == 1) { bins o0 = {0}; bins o2 = {2}; }
        x_byte_dir: cross cp_dir, cp_byte;
        x_half_dir: cross cp_dir, cp_half;
    endgroup
    // F29-F31: errors by phase, mode, channel and beat position
    covergroup cg_dma_err with function sample(int ch, bit [2:0] ph, bit [1:0] mode, int pos);
        cp_ch:   coverpoint ch   { bins c[] = {[0:5]}; }
        cp_ph:   coverpoint ph   { bins rd = {1}; bins wr = {2}; }
        cp_mode: coverpoint mode { bins p2m = {0}; bins m2p = {1}; bins m2m = {2}; }
        cp_pos:  coverpoint pos  { bins first = {0}; bins middle = {1}; bins last = {2}; }
        x_ph_mode: cross cp_ph, cp_mode;
        x_ph_pos:  cross cp_ph, cp_pos;
        x_ph_ch:   cross cp_ph, cp_ch;
    endgroup
    // F33: interrupt lines, and flags set with the enable off
    covergroup cg_dma_irq with function sample(int ch, bit kind_err, bit enabled);
        cp_ch:   coverpoint ch { bins c[] = {[0:5]}; }
        cp_kind: coverpoint kind_err { bins complete = {0}; bins error = {1}; }
        cp_ie:   coverpoint enabled;
        x_all:   cross cp_ch, cp_kind, cp_ie;
    endgroup
    // F07: ICLR of each bit, with the flag set / clear / setting in the same cycle
    covergroup cg_dma_iclr with function sample(int bitn, int when);
        cp_bit:  coverpoint bitn { bins complete = {0}; bins error = {1}; }
        cp_when: coverpoint when { bins flag_clear = {0}; bins flag_set = {1}; bins same_cycle = {2}; }
        x_bw:    cross cp_bit, cp_when;
    endgroup
    // F26-F28: contests at the arbiter
    covergroup cg_dma_arb with function sample(int neligible, int winner);
        cp_n: coverpoint neligible { bins one = {1}; bins two = {2}; bins three_plus = {[3:6]}; }
        cp_w: coverpoint winner    { bins c[] = {[0:5]}; }
        x_nw: cross cp_n, cp_w;
    endgroup
    // F34/F35/F45/F46: a software write to the engine's own channel in each engine phase
    covergroup cg_dma_coll with function sample(int kind, bit [2:0] st);
        cp_kind: coverpoint kind { bins cr_en1 = {0}; bins cr_en0 = {1}; bins sar = {2}; bins dar = {3};
                                   bins cnt = {4}; bins iclr = {5}; }
        cp_st:   coverpoint st   { bins ra = {1}; bins rd = {2}; bins wa = {3}; bins wd = {4}; }
        x_ks:    cross cp_kind, cp_st;
    endgroup
    // F12/F20/F45: writes while the channel is active
    covergroup cg_dma_live with function sample(int kind);
        cp_kind: coverpoint kind { bins sar = {0}; bins dar = {1}; bins cnt = {2}; bins cr_keep_en = {3};
                                   bins cr_stop = {4}; bins cr_size_change = {5}; bins cr_mode_change = {6}; }
    endgroup
    // F48: wait states on each data phase, and stalls of the address phase
    covergroup cg_dma_wait with function sample(bit wr, int waits, bit stall);
        cp_dir:   coverpoint wr;
        cp_waits: coverpoint waits iff (!stall) { bins w0 = {0}; bins w1_3 = {[1:3]}; bins w4p = {[4:$]}; }
        cp_stall: coverpoint stall { bins addr_stall = {1}; }
        x_dw:     cross cp_dir, cp_waits;
    endgroup
    // F09/F10: register accesses (index 0-5 per channel, 6 = GSTAT, 7 = unmapped)
    covergroup cg_dma_apb with function sample(int regi, bit wr);
        cp_reg: coverpoint regi { bins r[] = {[0:7]}; }
        cp_wr:  coverpoint wr;
        x_rw:   cross cp_reg, cp_wr;
    endgroup

    // F21/F23/F25 (D-21): each request, seen on pclk: how long it was high before its ack,
    // withdrawn before an ack, or raised while the channel is disabled
    covergroup cg_dma_req with function sample(int ch, int width, bit withdrawn, bit en);
        cp_ch:        coverpoint ch { bins c[] = {[0:5]}; }
        // a request cannot be acked sooner than synchroniser + grant + one whole beat
        // (about 3 pclk): the first bin is that minimum latency, then waits of growing length
        cp_req_width: coverpoint width iff (!withdrawn && en) { bins min_latency = {[1:3]}; bins w4_15 = {[4:15]}; bins w16p = {[16:$]}; }
        cp_withdrawn: coverpoint withdrawn iff (en) { bins withdrawn = {1}; }
        cp_req_vs_en: coverpoint en { bins disabled = {0}; bins enabled = {1}; }
    endgroup
    // F28: hclk cycles a channel stayed eligible before the engine took its beat
    covergroup cg_dma_starve with function sample(int ch, int waited);
        cp_ch:             coverpoint ch { bins c[] = {[0:5]}; }
        cp_starved_cycles: coverpoint waited { bins now = {[0:1]}; bins short = {[2:9]}; bins long = {[10:99]}; bins very_long = {[100:$]}; }
        x_ch_starved:      cross cp_ch, cp_starved_cycles;
    endgroup
    // F47: hreset_n asserted in each engine phase, with and without another channel enabled
    covergroup cg_dma_reset with function sample(bit [2:0] st, bit other_en);
        cp_phase: coverpoint st { bins idle = {0}; bins ra = {1}; bins rd = {2}; bins wa = {3}; bins wd = {4}; }
        cp_other: coverpoint other_en;
        x_phase_other: cross cp_phase, cp_other;
    endgroup
    // F43 / R-9: a refused beat (no bus transfer: the engine leaves E_RA / E_WA with an
    // error), by side and mode
    covergroup cg_dma_r9 with function sample(bit dar_side, bit [1:0] mode);
        cp_side: coverpoint dar_side { bins sar = {0}; bins dar = {1}; }
        cp_mode: coverpoint mode { bins p2m = {0}; bins m2p = {1}; bins m2m = {2}; }
        x_r9_side_mode: cross cp_side, cp_mode;
    endgroup

    cg_dma_req    c_req    = new();
    cg_dma_starve c_starve = new();
    cg_dma_reset  c_reset  = new();
    cg_dma_r9     c_r9     = new();
    cg_dma_cr   c_cr   = new();
    cg_dma_cr3  c_cr3  = new();
    cg_dma_cnt  c_cnt  = new();
    cg_dma_xfer c_xfer = new();
    cg_dma_lanes c_lanes = new();
    cg_dma_err  c_err  = new();
    cg_dma_irq  c_irq  = new();
    cg_dma_iclr c_iclr = new();
    cg_dma_arb  c_arb  = new();
    cg_dma_coll c_coll = new();
    cg_dma_live c_live = new();
    cg_dma_wait c_wait = new();
    cg_dma_apb  c_apb  = new();

    // ---- sampling ---------------------------------------------------------------------------
    logic [5:0]  scomp_q, serr_q;     // STAT.COMPLETE / STAT.ERROR, one cycle ago
    logic        dp, dp_wr, stalled;
    int          waits;
    logic [15:0] cnt_at_arm [6];
    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            scomp_q <= 0; serr_q <= 0; dp <= 0; waits <= 0; stalled <= 0;
        end else begin
            for (int n = 0; n < 6; n++) begin
                automatic bit en1 = wr_cr[n] && wdata[0];
                if (wr_cr[n]) c_cr3.sample(wdata[2:1] == 2'b11, wdata[6:5] == 2'b11, f_en(n));
                if (en1 && !f_en(n)) begin
                    c_cr.sample(n, wdata[2:1], wdata[6:5], wdata[3], wdata[4]);
                    c_cnt.sample(cnt[32*n +: 16]); cnt_at_arm[n] = cnt[32*n +: 16];
                end
                if (beat_done[n]) c_xfer.sample(n, f_mode(n), f_size(n), f_rem(n) == 16'd1);
                if (beat_err[n])
                    c_err.sample(n, err_phase, f_mode(n),
                                 (f_rem(n) == cnt_at_arm[n]) ? 0 : (f_rem(n) == 16'd1) ? 2 : 1);
                // a flag sets: with its interrupt enabled (the line rises) or not
                scomp_q[n] <= stat[32*n + 17]; serr_q[n] <= stat[32*n + 18];
                if (stat[32*n + 17] && !scomp_q[n]) c_irq.sample(n, 0, cr[32*n + 7]);
                if (stat[32*n + 18] && !serr_q[n])  c_irq.sample(n, 1, cr[32*n + 8]);
                if (wr_iclr[n]) begin
                    if (wdata[0]) c_iclr.sample(0, (beat_done[n] && f_rem(n) == 16'd1) ? 2 : stat[32*n + 17] ? 1 : 0);
                    if (wdata[1]) c_iclr.sample(1, beat_err[n] ? 2 : stat[32*n + 18] ? 1 : 0);
                end
                if (f_act(n)) begin
                    if (wr_sar[n]) c_live.sample(0);
                    if (wr_dar[n]) c_live.sample(1);
                    if (wr_cnt[n]) c_live.sample(2);
                    if (wr_cr[n]) begin
                        c_live.sample(wdata[0] ? 3 : 4);
                        if (wdata[6:5] != f_size(n) && wdata[6:5] != 2'b11) c_live.sample(5);
                        if (wdata[2:1] != f_mode(n) && wdata[2:1] != 2'b11) c_live.sample(6);
                    end
                end
            end
            if (eng_st != 3'd0) begin
                if (wr_cr[eng_ch])   c_coll.sample(wdata[0] ? 0 : 1, eng_st);
                if (wr_sar[eng_ch])  c_coll.sample(2, eng_st);
                if (wr_dar[eng_ch])  c_coll.sample(3, eng_st);
                if (wr_cnt[eng_ch])  c_coll.sample(4, eng_st);
                if (wr_iclr[eng_ch]) c_coll.sample(5, eng_st);
            end
            if (eng_st == 3'd0 && grant_valid && beat_done == 0 && beat_err == 0)
                c_arb.sample($countones(eligible), grant_ch);
            // bus: lanes, wait states, address stalls
            if (htrans_o[1] && hready_i) begin
                c_lanes.sample(hwrite_o, cr[32*eng_ch + 5 +: 2], haddr_o[1:0]);
                dp <= 1; dp_wr <= hwrite_o; waits <= 0;
            end else if (dp && hready_i) begin
                if (!hresp_i) c_wait.sample(dp_wr, waits, 0);
                dp <= 0;
            end else if (dp) waits <= waits + 1;
            if (htrans_o[1] && !hready_i && !dp && !stalled) begin c_wait.sample(0, 0, 1); stalled <= 1; end
            if (!(htrans_o[1] && !hready_i)) stalled <= 0;
        end
    end
    // requests (pclk, like the peripherals that drive them)
    int  req_w [6];
    logic [5:0] req_q = 0;
    always @(posedge pclk_i) if (hreset_n_i) begin
        for (int n = 0; n < 6; n++) begin
            if (dma_req_i[n]) req_w[n] = req_q[n] ? req_w[n] + 1 : 1;
            if (dma_req_i[n] && !req_q[n] && !f_en(n)) c_req.sample(n, 0, 0, 0);
            if (req_q[n] && dma_ack_o[n]) c_req.sample(n, req_w[n], 0, 1);
            else if (req_q[n] && !dma_req_i[n] && f_en(n)) c_req.sample(n, req_w[n], 1, 1);
        end
        req_q <= dma_req_i & ~dma_ack_o;          // a request answered by its ack is done
    end
    // starvation, reset phase, refusals (hclk)
    int  elig_w [6];
    logic [2:0] st_q = 0;
    always @(posedge hclk_i) if (hreset_n_i) begin
        for (int n = 0; n < 6; n++) begin
            if (eng_st == 3'd0 && grant_valid && grant_ch == 3'(n) && beat_done == 0 && beat_err == 0) begin
                c_starve.sample(n, elig_w[n]); elig_w[n] = 0;
            end else if (eligible[n]) elig_w[n]++;
            else elig_w[n] = 0;
            if (beat_err[n] && (st_q == 3'd1 || st_q == 3'd3)) c_r9.sample(st_q == 3'd3, f_mode(n));
        end
        st_q <= eng_st;
    end
    always @(negedge hreset_n_i)
        c_reset.sample(st_q, (cr[0] + cr[32] + cr[64] + cr[96] + cr[128] + cr[160]) > 1);
    always @(posedge pclk_i) if (hreset_n_i && psel_i && penable_i)
        c_apb.sample(pslverr_o ? 7 : (paddr_i == 12'h100) ? 6 : int'(paddr_i[4:2]), pwrite_i);
endmodule

bind dma_top dma_cov u_dma_cov (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .pclk_i(pclk_i),
    .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i), .pslverr_o(pslverr_o), .paddr_i(paddr_i),
    .haddr_o(haddr_o), .htrans_o(htrans_o), .hwrite_o(hwrite_o), .hready_i(hready_i), .hresp_i(hresp_i),
    .dma_req_i(dma_req_i), .dma_ack_o(dma_ack_o), .dma_complete_o(dma_complete_o), .dma_error_o(dma_error_o),
    .wr_cr(wr_cr), .wr_sar(wr_sar), .wr_dar(wr_dar), .wr_cnt(wr_cnt), .wr_iclr(wr_iclr), .wdata(wdata),
    .cr(cr), .cnt(cnt), .stat(stat), .eligible(eligible), .beat_done(beat_done), .beat_err(beat_err),
    .err_phase(err_phase), .grant_valid(grant_valid), .grant_ch(grant_ch),
    .eng_st(u_eng.st), .eng_ch(u_eng.ch));
