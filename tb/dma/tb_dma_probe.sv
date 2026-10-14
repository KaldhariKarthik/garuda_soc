`timescale 1ns/1ps
// =============================================================================
// tb_dma_probe.sv -- reproducers of the open DMA defects (Track A, DMA plan D1)
//
// Ported 2026-10-12 from the 2026-10-05 probe (~/garuda_soc/local/dma/probe),
// which only printed what it saw. Here every case CHECKS the behaviour the
// specification and the vPlan rows ask for, so a case fails on today's RTL
// exactly when its defect is present, and passes once the defect is fixed (its
// xfail entry then becomes XPASS and must be removed). dma_sva is bound through
// rtl/dma/filelist.f, so the open-bug detectors fire in these cases too; the
// suite's fail_reason names the detector that must fire. That makes the cases
// the negative control of the detectors.
//
//   +CASE=dma9     F20 as written / F42: EN cleared mid-transfer, then set again
//                  with CNT untouched: the transfer must total CNT beats and stay
//                  inside its buffer. Today it restarts from CNT (DMA-9).
//   +CASE=dma10    F43: P2M with DAR in ISRAM is refused before any AHB transfer.
//                  Today the source is read first (DMA-10).
//   +CASE=r9_sar   F32 control: a bad SAR is refused before any transfer.
//   +CASE=dma11a   F44: re-arm with CNT = 0 while the previous beat is in flight:
//                  REMAINING must stay 0. Today it wraps to 0xFFFF (DMA-11).
//   +CASE=dma11b   F44: re-arm with a new buffer while the previous beat is in
//                  flight: the new transfer must copy its own 2 words. Today the
//                  old beat lands in it (DMA-11).
//   +CASE=unaligned F17: a word channel with SAR = ...2 and a halfword channel with an
//                  odd DAR put no misaligned transfer on the bus (AHB-Lite). Today
//                  they do (DMA-13).
//   +CASE=stop_size F20/F45: stopping a word channel with CR = 0 (which also
//                  writes SIZE = byte) at every point of a beat: each beat the
//                  channel counts as done must be a whole word, read and written
//                  with the same HSIZE. Replays the formal a_write_data trace.
//   +CASE=m2m_ack  F21/F22, D-21: an M2M transfer, which no peripheral requested,
//                  pulses no dma_ack. Today every M2M beat acks the channel's
//                  peripheral (DMA-15).
//   +CASE=ack      F22: every dma_ack is 2 hclk wide and seen by exactly one pclk
//                  edge (P2M with 0-3 read waits, and M2M).
//
// Expected values come from GARUDA-DMA-SPEC-001 Rev 3.0a and the vPlan, not from
// the RTL. Real RTL only (no pasted DUT).
// =============================================================================
module tb_dma_probe;
    logic hclk = 0, pclk = 0, rst_n = 0;
    always #2 hclk = ~hclk;
    // pclk = hclk/2 on shared edges (D-5), made in the same time step as hclk, not by a
    // toggle flop on hclk (that would be the SIM-1 race, TB-44)
    initial begin #2; forever begin pclk = ~pclk; #4; end end

    localparam int CR = 0, SAR = 1, DAR = 2, CNT = 3, STAT = 4, ICLR = 5;
    localparam logic [1:0] P2M = 2'd0, M2P = 2'd1, M2M = 2'd2, W = 2'd2;

    // ---- APB -------------------------------------------------------------------
    logic        psel = 0, penable = 0, pwrite = 0;
    logic [11:0] paddr = 0;
    logic [31:0] pwdata = 0;
    wire  [31:0] prdata;
    wire         pready, pslverr;
    // ---- AHB -------------------------------------------------------------------
    wire  [31:0] haddr, hwdata;
    wire  [1:0]  htrans;
    wire         hwrite;
    wire  [2:0]  hsize, hburst;
    logic [31:0] hrdata;
    logic        hready, hresp;
    // ---- sideband ----------------------------------------------------------------
    logic [5:0]  req = 0;
    wire  [5:0]  ack, comp, err;

    dma_top dut (
        .hclk_i(hclk), .hreset_n_i(rst_n), .pclk_i(pclk), .preset_n_i(rst_n),
        .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite), .paddr_i(paddr),
        .pwdata_i(pwdata), .prdata_o(prdata), .pready_o(pready), .pslverr_o(pslverr),
        .haddr_o(haddr), .htrans_o(htrans), .hwrite_o(hwrite), .hsize_o(hsize),
        .hburst_o(hburst), .hwdata_o(hwdata), .hrdata_i(hrdata), .hready_i(hready),
        .hresp_i(hresp),
        .dma_req_i(req), .dma_ack_o(ack), .dma_complete_o(comp), .dma_error_o(err));

    // ---- AHB slave: memory with optional wait states on each read data phase -------
    logic [31:0] mem [logic [31:0]];
    logic        dp_valid = 0, dp_write = 0;
    logic [31:0] dp_addr = 0, rd_word = 0;
    logic [2:0]  dp_size = 0;
    int          rd_stall = 0, stall_left = 0;
    int          n_rd = 0, n_wr = 0, n_misaligned = 0, n_size_split = 0;
    logic [2:0]  last_rd_hsize = 3'd2;
    logic [31:0] rd_log [$], wr_log [$];

    assign hready = !(dp_valid && stall_left > 0);
    assign hresp  = 1'b0;
    assign hrdata = (dp_valid && !dp_write) ? rd_word : 32'hDEAD_BEEF;

    function automatic logic [31:0] mrd(input logic [31:0] a);
        return mem.exists({a[31:2], 2'b00}) ? mem[{a[31:2], 2'b00}] : 32'h0;
    endfunction

    always @(posedge hclk) begin
        if (!rst_n) begin
            dp_valid <= 1'b0; stall_left <= 0;
        end else begin
            if (dp_valid) begin                                   // data phase
                if (stall_left > 0) stall_left <= stall_left - 1;
                else begin
                    if (dp_write) begin
                        logic [31:0] w;
                        w = mrd(dp_addr);
                        case (dp_size)
                            3'd0:    w[8*dp_addr[1:0] +: 8] = hwdata[8*dp_addr[1:0] +: 8];
                            3'd1:    w[16*dp_addr[1]  +: 16] = hwdata[16*dp_addr[1] +: 16];
                            default: w = hwdata;
                        endcase
                        mem[{dp_addr[31:2], 2'b00}] = w;
                    end
                    dp_valid <= 1'b0;
                end
            end
            if (htrans[1] && hready) begin                        // address phase accepted
                dp_valid <= 1'b1; dp_write <= hwrite; dp_addr <= haddr; dp_size <= hsize;
                if ((hsize == 3'd1 && haddr[0]) || (hsize == 3'd2 && haddr[1:0] != 2'b00)) n_misaligned++;
                if (hwrite && hsize != last_rd_hsize) n_size_split++;   // one beat, two HSIZEs
                if (!hwrite) last_rd_hsize = hsize;
                if (hwrite) begin n_wr++; wr_log.push_back(haddr); end
                else        begin n_rd++; rd_log.push_back(haddr); rd_word <= mrd(haddr); end
                stall_left <= hwrite ? 0 : rd_stall;
            end
        end
    end

    // ---- ack monitor (F22): width in hclk, pclk edges that see it high ------------------
    int ack_w [6], ack_pe [6];
    int n_pulses = 0, bad_width = 0, bad_edges = 0;
    always @(posedge hclk) for (int n = 0; n < 6; n++) begin
        if (ack[n]) ack_w[n]++;
        else if (ack_w[n] != 0) begin
            n_pulses++;
            if (ack_w[n] != 2) bad_width++;
            ack_w[n] = 0;
        end
    end
    always @(posedge pclk) for (int n = 0; n < 6; n++) begin
        if (ack[n]) ack_pe[n]++;
        else if (ack_pe[n] != 0) begin
            if (ack_pe[n] != 1) bad_edges++;
            ack_pe[n] = 0;
        end
    end

    // ---- helpers -------------------------------------------------------------------------
    int checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask
    function automatic logic [11:0] R(int ch, int r);
        return 12'(ch * 32 + r * 4);
    endfunction
    function automatic logic [31:0] CRV(bit en, logic [1:0] mode, bit sinc, bit dinc, logic [1:0] size);
        return {23'd0, 1'b1 /*IE_ERR*/, 1'b1 /*IE_COMP*/, size, dinc, sinc, mode, en};
    endfunction
    task automatic apb_wr(input logic [11:0] a, input logic [31:0] d);
        @(posedge pclk); psel <= 1; penable <= 0; pwrite <= 1; paddr <= a; pwdata <= d;
        @(posedge pclk); penable <= 1;
        @(posedge pclk); psel <= 0; penable <= 0; pwrite <= 0;
    endtask
    task automatic apb_rd(input logic [11:0] a, output logic [31:0] d);
        @(posedge pclk); psel <= 1; penable <= 0; pwrite <= 0; paddr <= a;
        @(posedge pclk); penable <= 1;
        @(posedge pclk); d = prdata; psel <= 0; penable <= 0;
    endtask
    task automatic do_reset();
        rst_n = 0; req = 0; rd_stall = 0;
        repeat (4) @(posedge hclk);
        @(negedge hclk) rst_n = 1;                 // released away from the active edge
        repeat (4) @(posedge hclk);
    endtask
    // what: "COMPLETE" (dma_complete), "dma_error" or "dma_ack"
    task automatic wait_bit(input string what, input int ch, input int max_cyc, output bit ok);
        logic [5:0] v;
        ok = 0;
        for (int i = 0; i < max_cyc; i++) begin
            @(posedge hclk);
            v = (what == "dma_error") ? err : (what == "dma_ack") ? ack : comp;
            if (v[ch]) begin ok = 1; break; end
        end
        if (!ok) $display("  (%s on channel %0d did not rise within %0d hclk)", what, ch, max_cyc);
    endtask
    task automatic get(input int ch, output logic [31:0] st, output logic [31:0] cr);
        apb_rd(R(ch, STAT), st); apb_rd(R(ch, CR), cr);
    endtask

    // ---- the cases -----------------------------------------------------------------------
    string tcase;
    initial begin
        int nr0, nw0, nw1, k1, k2;
        bit ok;
        logic [31:0] st, cr;

        if (!$value$plusargs("CASE=%s", tcase)) tcase = "";
        $display("=== tb_dma_probe +CASE=%s ===", tcase);
        for (int i = 0; i < 128; i++) mem[32'h2000_0000 + 4 * i] = 32'hA000_0000 + i;
        mem[32'h4000_2000] = 32'h5555_0001;                       // a peripheral data register

        case (tcase)
        // ===== DMA-9 (F20 as written, F42) =============================================
        "dma9": begin
            do_reset();
            rd_stall = 12;                                       // slow beats so the stop lands mid-transfer
            apb_wr(R(0, SAR), 32'h2000_0000); apb_wr(R(0, DAR), 32'h2000_1000); apb_wr(R(0, CNT), 8);
            nw0 = n_wr;
            apb_wr(R(0, CR), CRV(1, M2M, 1, 1, W));
            while (n_wr - nw0 < 3) @(posedge hclk);
            apb_wr(R(0, CR), CRV(0, M2M, 1, 1, W));              // software clears EN
            repeat (200) @(posedge hclk);
            k1 = n_wr - nw0;
            get(0, st, cr);
            check(!cr[0] && !st[16] && !st[17] && !st[18] && st[15:0] == 16'(8 - k1),
                  $sformatf("[F20] EN cleared mid-transfer: stopped at a beat boundary after %0d beats, REMAINING %0d, no COMPLETE, no ERROR", k1, st[15:0]));
            nw1 = n_wr;
            apb_wr(R(0, CR), CRV(1, M2M, 1, 1, W));              // EN again, CNT untouched
            wait_bit("COMPLETE", 0, 20000, ok);
            repeat (20) @(posedge hclk);
            k2 = n_wr - nw1;
            check(k1 + k2 == 8 && wr_log[$] == 32'h2000_101C,
                  $sformatf("[DMA-9] [F20] EN set again continues: %0d + %0d beats = %0d (CNT 8), last write %08h (buffer ends at 2000101C)",
                            k1, k2, k1 + k2, wr_log[$]));
        end
        // ===== DMA-10 (F43) ==============================================================
        "dma10": begin
            do_reset();
            apb_wr(R(1, SAR), 32'h4000_2000); apb_wr(R(1, DAR), 32'h0000_1000); apb_wr(R(1, CNT), 1);
            apb_wr(R(1, CR), CRV(1, P2M, 0, 1, W));
            nr0 = n_rd; nw0 = n_wr;
            req[1] = 1;
            wait_bit("dma_error", 1, 2000, ok);
            repeat (10) @(posedge hclk);
            get(1, st, cr);
            check(ok && st[18] && st[21:19] == 3'd2 && !st[17] && !cr[0],
                  "[R-9] [N-7.20] DAR in ISRAM: ERROR, ERRPHASE = write, not COMPLETE, EN clear");
            check(n_wr == nw0 && ack[1] == 1'b0 && req[1],
                  "[R-9] no write, no ack, the peripheral is still requesting");
            check(n_rd == nr0,
                  $sformatf("[DMA-10] [F43] a refused beat touches nothing: %0d AHB read(s) issued before the refusal%s",
                            n_rd - nr0, (n_rd > nr0) ? $sformatf(" (%08h)", rd_log[$]) : ""));
            req[1] = 0;
        end
        // ===== R-9 control: a bad SAR (F32) ==================================================
        "r9_sar": begin
            do_reset();
            apb_wr(R(1, SAR), 32'h1000_0000); apb_wr(R(1, DAR), 32'h2000_0000); apb_wr(R(1, CNT), 1);
            apb_wr(R(1, CR), CRV(1, P2M, 0, 1, W));
            nr0 = n_rd; nw0 = n_wr;
            req[1] = 1;
            wait_bit("dma_error", 1, 2000, ok);
            repeat (10) @(posedge hclk);
            get(1, st, cr);
            check(ok && st[18] && st[21:19] == 3'd1 && n_rd == nr0 && n_wr == nw0,
                  $sformatf("[R-9] [F32] SAR in Boot ROM: ERROR, ERRPHASE = read, no AHB transfer (%0d reads, %0d writes)",
                            n_rd - nr0, n_wr - nw0));
            req[1] = 0;
        end
        // ===== DMA-11 a: re-arm with CNT = 0 while a beat is in flight (F44) ==================
        "dma11a": begin
            do_reset();
            rd_stall = 60;                                       // the first read waits 60 hclk
            apb_wr(R(2, SAR), 32'h2000_0000); apb_wr(R(2, DAR), 32'h2000_2000); apb_wr(R(2, CNT), 4);
            nr0 = n_rd; nw0 = n_wr;
            apb_wr(R(2, CR), CRV(1, M2M, 1, 1, W));
            while (n_rd - nr0 < 1) @(posedge hclk);
            rd_stall = 0;
            apb_wr(R(2, CR), CRV(0, M2M, 1, 1, W));
            apb_wr(R(2, CNT), 0);
            apb_wr(R(2, CR), CRV(1, M2M, 1, 1, W));              // zero-length arm: completes at once
            get(2, st, cr);
            check(n_wr == nw0 && st[17] && st[15:0] == 16'd0,
                  "[F44] zero-length re-arm while the old beat is still in its read: COMPLETE, REMAINING 0");
            while (n_wr - nw0 < 1) @(posedge hclk);              // the old beat lands
            repeat (20) @(posedge hclk);
            get(2, st, cr);
            check(st[17] && st[15:0] == 16'd0,
                  $sformatf("[DMA-11] [F44] [R-6] after the old beat landed: COMPLETE with REMAINING %0d (0x%04h), must stay 0",
                            st[15:0], st[15:0]));
        end
        // ===== DMA-11 b: re-arm with a new buffer while a beat is in flight (F44) =============
        "dma11b": begin
            do_reset();
            for (int i = 0; i < 4; i++) mem[32'h2000_3000 + 4 * i] = 32'h0;
            rd_stall = 60;
            apb_wr(R(2, SAR), 32'h2000_0000); apb_wr(R(2, DAR), 32'h2000_2000); apb_wr(R(2, CNT), 4);
            nr0 = n_rd; nw0 = n_wr;
            apb_wr(R(2, CR), CRV(1, M2M, 1, 1, W));
            while (n_rd - nr0 < 1) @(posedge hclk);
            rd_stall = 0;
            apb_wr(R(2, CR), CRV(0, M2M, 1, 1, W));
            apb_wr(R(2, SAR), 32'h2000_0100); apb_wr(R(2, DAR), 32'h2000_3000); apb_wr(R(2, CNT), 2);
            apb_wr(R(2, CR), CRV(1, M2M, 1, 1, W));
            wait_bit("COMPLETE", 2, 5000, ok);
            repeat (20) @(posedge hclk);
            get(2, st, cr);
            check(ok && st[17] && st[15:0] == 16'd0, "[F44] the new transfer completes with REMAINING 0");
            check(mem[32'h2000_3000] == mrd(32'h2000_0100) && mem[32'h2000_3004] == mrd(32'h2000_0104),
                  $sformatf("[DMA-11] [F44] the new transfer copies its own words: dst[0] = %08h dst[1] = %08h, want %08h %08h (old src[0] = %08h)",
                            mem[32'h2000_3000], mem[32'h2000_3004], mrd(32'h2000_0100), mrd(32'h2000_0104), mrd(32'h2000_0000)));
        end
        // ===== unaligned halfword / word (F17, DMA-13) ==========================================
        "unaligned": begin
            do_reset();
            apb_wr(R(4, SAR), 32'h2000_0002); apb_wr(R(4, DAR), 32'h2000_6000); apb_wr(R(4, CNT), 2);
            apb_wr(R(4, CR), CRV(1, M2M, 1, 1, W));                // word beats from SAR ...2
            wait_bit("COMPLETE", 4, 2000, ok);
            if (!ok) wait_bit("dma_error", 4, 10, ok);
            apb_wr(R(5, SAR), 32'h2000_0010); apb_wr(R(5, DAR), 32'h2000_7001); apb_wr(R(5, CNT), 2);
            apb_wr(R(5, CR), CRV(1, M2M, 1, 1, 2'd1));             // halfword beats to DAR ...1
            wait_bit("COMPLETE", 5, 2000, ok);
            if (!ok) wait_bit("dma_error", 5, 10, ok);
            repeat (10) @(posedge hclk);
            check(n_misaligned == 0,
                  $sformatf("[DMA-13] [F17] no misaligned transfer on the bus: %0d address phase(s) not aligned to HSIZE", n_misaligned));
        end
        // ===== stop with CR = 0 inside a word beat (F20, F45; formal a_write_data) ============
        "stop_size": begin
            int bad_words, attempts, split0, rem;
            bad_words = 0; attempts = 0;
            for (int st_w = 0; st_w < 6; st_w++) for (int k = 0; k < 12; k++) begin
                do_reset();
                for (int i = 0; i < 8; i++) mem[32'h2000_8000 + 4 * i] = 32'h0;
                rd_stall = st_w;
                apb_wr(R(0, SAR), 32'h2000_0000); apb_wr(R(0, DAR), 32'h2000_8000); apb_wr(R(0, CNT), 8);
                nr0 = n_rd; split0 = n_size_split;
                apb_wr(R(0, CR), CRV(1, M2M, 1, 1, W));
                while (n_rd == nr0) @(posedge hclk);             // the first read address was accepted
                repeat (k) @(posedge hclk);
                apb_wr(R(0, CR), 32'h0);                         // the usual stop: also SIZE = byte
                repeat (60) @(posedge hclk);
                get(0, st, cr);
                rem = st[15:0];
                for (int i = 0; i < 8 - rem; i++)
                    if (mem[32'h2000_8000 + 4 * i] != mrd(32'h2000_0000 + 4 * i)) bad_words++;
                attempts++;
            end
            check(n_size_split == 0 && bad_words == 0,
                  $sformatf("[DMA-14] [F20] [F45] stop with CR = 0 at %0d points of a word beat: %0d beat(s) written with a different HSIZE than read, %0d word(s) counted as moved but wrong",
                            attempts, n_size_split, bad_words));
        end
        // ===== M2M gives no ack (DMA-15) =========================================================
        "m2m_ack": begin
            int a0;
            do_reset();
            a0 = n_pulses;
            apb_wr(R(3, SAR), 32'h2000_0000); apb_wr(R(3, DAR), 32'h2000_5000); apb_wr(R(3, CNT), 6);
            apb_wr(R(3, CR), CRV(1, M2M, 1, 1, W));
            wait_bit("COMPLETE", 3, 2000, ok);
            repeat (10) @(posedge hclk);
            check(ok && n_pulses == a0,
                  $sformatf("[DMA-15] [F21] [D-21] an M2M transfer (no request) pulses no dma_ack: %0d ack pulse(s) for 6 beats", n_pulses - a0));
        end
        // ===== ack shape (F22, D-16) =============================================================
        "ack": begin
            do_reset();
            apb_wr(R(0, SAR), 32'h4000_2000); apb_wr(R(0, DAR), 32'h2000_4000); apb_wr(R(0, CNT), 12);
            apb_wr(R(0, CR), CRV(1, P2M, 0, 1, W));
            for (int b = 0; b < 12; b++) begin
                rd_stall = b % 4;
                req[0] = 1;
                wait_bit("dma_ack", 0, 2000, ok);
                @(posedge pclk); req[0] = 0;                     // drop on ack, hold off one pclk (D-21)
                @(posedge pclk);
            end
            rd_stall = 1;
            apb_wr(R(3, SAR), 32'h2000_0000); apb_wr(R(3, DAR), 32'h2000_5000); apb_wr(R(3, CNT), 12);
            apb_wr(R(3, CR), CRV(1, M2M, 1, 1, W));
            wait_bit("COMPLETE", 3, 5000, ok);
            repeat (10) @(posedge hclk);
            check(n_pulses == 24 && bad_width == 0 && bad_edges == 0,
                  $sformatf("[F22] [D-16] %0d ack pulses (want 24): %0d not 2 hclk wide, %0d not seen by exactly one pclk edge",
                            n_pulses, bad_width, bad_edges));
        end
        default: begin
            $display("[FAIL] unknown +CASE=%s (dma9 dma10 r9_sar dma11a dma11b unaligned stop_size m2m_ack ack)", tcase);
            fails++;
        end
        endcase

        $display("tb_dma_probe: case=%s checks=%0d  FAIL=%0d", tcase, checks, fails);
        $display("RESULT: %s", (fails || checks == 0) ? "FAILED" : "PASSED");
        $finish;
    end
    initial begin #2_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
