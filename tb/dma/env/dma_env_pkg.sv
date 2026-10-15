`timescale 1ns/1ps
// =============================================================================
// dma_env_pkg.sv -- DMA environment classes (Track A, DMA plan D4; plain SV shaped
// like UVM: item, reference model, scoreboard; no UVM library).
//
// dma_xfer   one channel's transfer as software programs it (rand, constrained).
// dma_model  the reference model, written from GARUDA-DMA-SPEC-001 Rev 3.0a and the
//            vPlan, never from the RTL. Transaction level: it predicts, per channel,
//            the sequence of beats (read address, size, data; write address, lanes)
//            and, for any number k of beats done, the registers software must read
//            (F20: REMAINING, SAR and DAR agree with the beats done). The scoreboard
//            feeds it the AHB transfers the slave saw and the registers read back.
//
// Address plan (so a transfer on the bus names its channel): channel n reads
// from SRC_BASE + n*WIN, writes to DST_BASE + n*WIN, and its peripheral data
// register is FIFO_BASE + n*0x100.
//
// Until the D6 fixes, random transfers stay clear of the open defects (each is
// reproduced by a directed case instead): aligned addresses (DMA-13), legal
// regions (DMA-10), a stop keeps SIZE (DMA-14), no re-arm with a beat in flight
// (DMA-11), no restart with CNT untouched (DMA-9).
// =============================================================================
package dma_env_pkg;
    localparam logic [31:0] SRC_BASE  = 32'h2000_0000;
    localparam logic [31:0] DST_BASE  = 32'h2080_0000;
    localparam logic [31:0] FIFO_BASE = 32'h4000_1000;
    localparam logic [31:0] WIN       = 32'h0001_0000;
    localparam logic [1:0]  M_P2M = 2'd0, M_M2P = 2'd1, M_M2M = 2'd2;
    // request-agent modes (tb/dma/env/dma_req_agent.sv)
    localparam int REQ_OFF = 0, REQ_D21 = 1, REQ_HELD = 2, REQ_WITHDRAW = 3;

    function automatic logic [31:0] fifo_addr(input int ch);  return FIFO_BASE + 32'h100 * ch;  endfunction
    function automatic logic [31:0] src_win(input int ch);    return SRC_BASE + WIN * ch;       endfunction
    function automatic logic [31:0] dst_win(input int ch);    return DST_BASE + WIN * ch;       endfunction
    function automatic int step_of(input logic [1:0] size);   return 1 << size;                endfunction
    // the channel a transfer belongs to, by address (-1: none)
    function automatic int chan_of(input logic [31:0] a);
        for (int n = 0; n < 6; n++) begin
            if (a >= src_win(n) && a < src_win(n) + WIN) return n;
            if (a >= dst_win(n) && a < dst_win(n) + WIN) return n;
            if ({a[31:2], 2'b00} == fifo_addr(n)) return n;
        end
        return -1;
    endfunction
    // the bytes a beat of SIZE at address A carries, from a 32-bit bus word
    function automatic logic [31:0] lanes(input logic [31:0] w, input logic [31:0] a, input logic [1:0] size);
        case (size)
            2'd0:    return {24'd0, w[8*a[1:0] +: 8]};
            2'd1:    return {16'd0, w[16*a[1] +: 16]};
            default: return w;
        endcase
    endfunction

    // ---------------------------------------------------------------- item
    class dma_xfer;
        rand int unsigned ch;
        rand logic [1:0]  mode, size;
        rand bit          sinc, dinc, iec, iee;
        rand int unsigned cnt;
        rand int unsigned soff, doff;            // offsets inside the channel windows
        constraint c_ch    { ch < 6; }
        // mode weights M2M 4 : P2M 3 : M2P 3, written with a weight variable and
        // implications rather than `dist` (Verilator 5.052 fails dist + inline with)
        rand int unsigned mode_w;
        constraint c_mode  { mode_w < 10;
                             (mode_w < 4)                -> (mode == M_M2M);
                             (mode_w >= 4 && mode_w < 7) -> (mode == M_P2M);
                             (mode_w >= 7)               -> (mode == M_M2P); }
        constraint c_size  { size inside {[0:2]}; }
        // CNT is drawn in post_randomize: Verilator 5.052 fails `dist` together with an
        // inline `with` (tool limit seen 2026-10-05). Weights 1:10, 2-8:40, 9-40:40,
        // 41-100:10; a test may force a range with cnt_lo/cnt_hi.
        int unsigned cnt_lo = 0, cnt_hi = 0;
        constraint c_cnt   { cnt inside {[1:100]}; }
        function void post_randomize();
            int unsigned r = $urandom_range(99, 0);
            if (cnt_hi != 0)  cnt = $urandom_range(cnt_hi, cnt_lo);
            else if (r < 10)  cnt = 1;
            else if (r < 50)  cnt = $urandom_range(8, 2);
            else if (r < 90)  cnt = $urandom_range(40, 9);
            else              cnt = $urandom_range(100, 41);
        endfunction
        // the peripheral side does not increment, except in 20 % of draws: SINC and DINC are
        // independent of MODE in the specification ([N-6.1]); an incrementing side is memory
        rand int unsigned inc_w;
        constraint c_inc   { inc_w < 10;
                             (inc_w < 8 && mode == M_P2M) -> sinc == 0;
                             (inc_w < 8 && mode == M_M2P) -> dinc == 0; }
        // aligned to the beat size (DMA-13 open), well inside the window
        constraint c_off   { soff < 32'h8000; doff < 32'h8000;
                             (size == 1) -> (soff[0] == 0 && doff[0] == 0);
                             (size == 2) -> (soff[1:0] == 0 && doff[1:0] == 0); }
        // the peripheral data register is the source of a P2M and the destination of an M2P
        // transfer when that side does not increment; otherwise the side is memory
        function bit src_fifo(); return mode == M_P2M && !sinc; endfunction
        function bit dst_fifo(); return mode == M_M2P && !dinc; endfunction
        function logic [31:0] sar();  return src_fifo() ? fifo_addr(ch) : src_win(ch) + soff; endfunction
        function logic [31:0] dar();  return dst_fifo() ? fifo_addr(ch) : dst_win(ch) + doff; endfunction
        function logic [31:0] cr(input bit en);
            return {23'd0, iee, iec, size, dinc, sinc, mode, en};
        endfunction
        function string str();
            return $sformatf("ch%0d %s size=%0d sinc=%0d dinc=%0d cnt=%0d sar=%08h dar=%08h ie=%0d%0d",
                             ch, mode == M_M2M ? "M2M" : mode == M_P2M ? "P2M" : "M2P",
                             size, sinc, dinc, cnt, sar(), dar(), iec, iee);
        endfunction
    endclass

    // ---------------------------------------------------------------- reference model
    class dma_model;
        dma_xfer     x [6];                // the armed transfer per channel (null: none)
        int          done [6];             // beats done
        bit          err [6];
        logic [2:0]  errph [6];
        int          fifo_rd [6];          // P2M: FIFO values consumed
        logic [31:0] fifo_val [6][$];      // P2M: what the test pushed, in order
        logic [31:0] src_word [logic [31:0]];   // the source memory as the test wrote it
        // the beat being assembled
        bit          rd_ok [6];
        logic [31:0] rd_addr [6], rd_data [6];
        int          errors = 0;
        int          m2m_acks = 0;      // DMA-15 (ruling): acks on M2M beats, counted, not failed
        bit          comp_cleared [6];  // an ICLR landed after COMPLETE set ([N-7.19]: then it clears)
        bit          err_cleared [6];   // likewise for ERROR and ERRPHASE
        bit          ack_free [6];      // F45: MODE changed while running, acks not predicted (DMA-15 ruling)
        string       last_error = "";

        function void fail(string s);
            errors++;
            if (errors <= 20) $display("[FAIL] [SB] %s", s);
            last_error = s;
        endfunction
        function void arm(dma_xfer t);
            x[t.ch] = t; done[t.ch] = 0; err[t.ch] = 0; errph[t.ch] = 0; fifo_rd[t.ch] = 0;
            rd_ok[t.ch] = 0; comp_cleared[t.ch] = 0; err_cleared[t.ch] = 0;
            ack_free[t.ch] = 0;
        endfunction
        function logic [31:0] exp_sar(int n, int k);
            return x[n].sar() + (x[n].sinc ? k * step_of(x[n].size) : 0);
        endfunction
        function logic [31:0] exp_dar(int n, int k);
            return x[n].dar() + (x[n].dinc ? k * step_of(x[n].size) : 0);
        endfunction
        // one AHB transfer, in bus order
        function void on_transfer(logic [31:0] a, bit wr, logic [2:0] hs, logic [31:0] d, bit e);
            int n = chan_of(a);
            if (n < 0 || x[n] == null) begin fail($sformatf("transfer to %08h belongs to no armed channel", a)); return; end
            if (err[n] || done[n] >= x[n].cnt) begin fail($sformatf("ch%0d: transfer to %08h after its transfer ended", n, a)); return; end
            if (hs != {1'b0, x[n].size}) fail($sformatf("ch%0d: HSIZE %0d, SIZE %0d", n, hs, x[n].size));
            if (!wr) begin
                logic [31:0] want_a = exp_sar(n, done[n]);
                if (rd_ok[n]) fail($sformatf("ch%0d: a second read before the write of beat %0d", n, done[n]));
                if (a != want_a) fail($sformatf("ch%0d beat %0d: read at %08h, expected %08h", n, done[n], a, want_a));
                if (e) begin err[n] = 1; errph[n] = 3'd1; return; end           // read ERROR: no write follows
                if (x[n].src_fifo()) begin
                    logic [31:0] want = (fifo_rd[n] < fifo_val[n].size()) ? fifo_val[n][fifo_rd[n]] : 32'd0;
                    if (d != want) fail($sformatf("ch%0d beat %0d: read %08h from the FIFO, pushed %08h", n, done[n], d, want));
                    fifo_rd[n]++;
                end else begin
                    logic [31:0] want = src_word.exists({a[31:2], 2'b00}) ? src_word[{a[31:2], 2'b00}] : 32'd0;
                    if (d != want) fail($sformatf("ch%0d beat %0d: read %08h at %08h, memory holds %08h", n, done[n], d, a, want));
                end
                rd_ok[n] = 1; rd_addr[n] = a; rd_data[n] = d;
            end else begin
                logic [31:0] want_a = exp_dar(n, done[n]);
                if (!rd_ok[n]) fail($sformatf("ch%0d beat %0d: write with no read before it", n, done[n]));
                if (a != want_a) fail($sformatf("ch%0d beat %0d: write at %08h, expected %08h", n, done[n], a, want_a));
                if (!e && lanes(d, a, x[n].size) != lanes(rd_data[n], rd_addr[n], x[n].size))
                    fail($sformatf("ch%0d beat %0d: wrote %08h, the read carried %08h (size %0d)", n, done[n],
                                   lanes(d, a, x[n].size), lanes(rd_data[n], rd_addr[n], x[n].size), x[n].size));
                rd_ok[n] = 0;
                if (e) begin err[n] = 1; errph[n] = 3'd2; return; end           // write ERROR
                done[n]++;
            end
        endfunction
        // the registers software must read once channel n is idle (F18-F20, F29, F33)
        function void check_regs(int n, logic [31:0] cr, logic [31:0] st, logic [31:0] sar,
                                 logic [31:0] dar, bit irq_c, bit irq_e, int acks);
            bit comp;
            int k;
            if (x[n] == null) return;
            k = done[n];
            comp = !err[n] && k == x[n].cnt && !comp_cleared[n];
            if (rd_ok[n]) fail($sformatf("ch%0d: beat %0d read but never written", n, k));
            if (cr[0])                              fail($sformatf("ch%0d: EN still set when idle", n));
            if (st[15:0] != 16'(x[n].cnt - k))      fail($sformatf("ch%0d: REMAINING %0d, %0d of %0d beats done", n, st[15:0], k, x[n].cnt));
            if (st[16])                             fail($sformatf("ch%0d: ACTIVE when idle", n));
            if (st[17] != comp)                     fail($sformatf("ch%0d: COMPLETE %0d, expected %0d", n, st[17], comp));
            if (st[18] != (err[n] && !err_cleared[n]))  fail($sformatf("ch%0d: ERROR %0d, expected %0d", n, st[18], err[n] && !err_cleared[n]));
            if (st[21:19] != (err_cleared[n] ? 3'd0 : errph[n])) fail($sformatf("ch%0d: ERRPHASE %0d, expected %0d", n, st[21:19], err_cleared[n] ? 3'd0 : errph[n]));
            if (sar != exp_sar(n, k))               fail($sformatf("ch%0d: SAR %08h, expected %08h after %0d beats", n, sar, exp_sar(n, k), k));
            if (dar != exp_dar(n, k))               fail($sformatf("ch%0d: DAR %08h, expected %08h after %0d beats", n, dar, exp_dar(n, k), k));
            if (irq_c != (comp && x[n].iec))        fail($sformatf("ch%0d: dma_complete %0d", n, irq_c));
            if (irq_e != (err[n] && !err_cleared[n] && x[n].iee)) fail($sformatf("ch%0d: dma_error %0d", n, irq_e));
            if (x[n].mode != M_M2M && !ack_free[n] && acks != k) fail($sformatf("ch%0d: %0d acks for %0d beats", n, acks, k));
            if (x[n].mode == M_M2M) m2m_acks += acks;     // DMA-15: the RTL acks every beat; ruling pending
        endfunction
    endclass
endpackage
