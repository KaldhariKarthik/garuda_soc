`timescale 1ns/1ps
// =============================================================================
// dma_env_top.sv -- DMA verification environment (Track A, DMA plan D4/D5).
//
//   APB driver (tasks, pclk) --> dma_top --> AHB-Lite slave (tb/ahb/agent/ahb_slave_mem)
//   request agent (dma_req_agent, D-21) <--> dma_req/dma_ack
//   checkers: dma_sva (bound via rtl/dma/filelist.f), ahb_lite_checker on M3,
//             dma_req_checker x6, dma_beat_check (pins and registers only, R4)
//   reference model + scoreboard: dma_env_pkg::dma_model, fed by the slave's log
//
// +TEST=smoke   every mode x size on one channel at a time, zero and random waits
// +TEST=qual    model qualification: six transfers whose results were worked out
//               by hand from the specification; the DUT and the model must both
//               match the hand values (DMA plan D4)
// +TEST=coll|reset|arb|req|held|matrix|edge|bits|r9  directed tests (DMA plan D5/D7)
// +TEST=mut     all directed tests + rand +ITER=n in one run (planted defects, D8)
// +TEST=rand    +ITER=n iterations: 1..6 channels at once, random modes, sizes,
//               counts, waits, address stalls, an injected ERROR (20 %), a stop (15 %)
// +INJECT=wdata|drop|stat|irq|ack  negative controls of the scoreboard: one fault is
//               put into what the scoreboard sees, and it must report it (D4)
// +SEED via +verilator+seed (the runner passes it).
// pclk is made in the same time step as hclk (TB-44).
// =============================================================================
module tb_dma_env;
    import dma_env_pkg::*;

    logic hclk = 0, pclk = 0, rst_n = 0;
    always #2 hclk = ~hclk;
    initial begin #2; forever begin pclk = ~pclk; #4; end end

    logic        psel = 0, penable = 0, pwrite = 0;
    logic [11:0] paddr = 0;
    logic [31:0] pwdata = 0;
    wire  [31:0] prdata;
    wire         pready, pslverr;
    wire  [31:0] haddr, hwdata, hrdata;
    wire  [1:0]  htrans;
    wire         hwrite, hready, hresp;
    wire  [2:0]  hsize, hburst;
    wire  [5:0]  req, ack, comp, err;

    dma_top dut (
        .hclk_i(hclk), .hreset_n_i(rst_n), .pclk_i(pclk), .preset_n_i(rst_n),
        .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite), .paddr_i(paddr),
        .pwdata_i(pwdata), .prdata_o(prdata), .pready_o(pready), .pslverr_o(pslverr),
        .haddr_o(haddr), .htrans_o(htrans), .hwrite_o(hwrite), .hsize_o(hsize),
        .hburst_o(hburst), .hwdata_o(hwdata), .hrdata_i(hrdata), .hready_i(hready),
        .hresp_i(hresp), .dma_req_i(req), .dma_ack_o(ack), .dma_complete_o(comp),
        .dma_error_o(err));

    ahb_slave_mem u_mem (.hclk(hclk), .hreset_n(rst_n), .hsel(1'b1), .hready_in(1'b1), .haddr(haddr), .htrans(htrans),
                         .hwrite(hwrite), .hsize(hsize), .hwdata(hwdata), .hrdata(hrdata),
                         .hready(hready), .hresp(hresp));
    dma_req_agent u_req (.pclk(pclk), .rst_n(rst_n), .ack(ack), .req(req));

    wire [31:0] ahb_viol;
    ahb_lite_checker u_ahbchk (.clk_i(hclk), .rst_n_i(rst_n), .haddr_i(haddr), .htrans_i(htrans),
                               .hsize_i(hsize), .hburst_i(hburst), .hwrite_i(hwrite), .hwdata_i(hwdata),
                               .hready_i(hready), .hresp_i(hresp), .viol_count_o(ahb_viol));
    // the D-21 checkers see the acks of channels in a peripheral mode (P2M/M2P): on an
    // M2M beat today's RTL also pulses the ack (DMA-15, counted by the scoreboard)
    logic [5:0] pmode = 6'd0;
    genvar g;
    generate for (g = 0; g < 6; g++) begin : g_rc
        localparam string NM [6] = '{"ch0", "ch1", "ch2", "ch3", "ch4", "ch5"};
        dma_req_checker #(.NAME(NM[g])) u_rc (.clk_i(pclk), .rst_n_i(rst_n), .req_i(req[g]), .ack_i(ack[g] & pmode[g]));
    end endgenerate

    // the check made from pins and registers alone (R4)
    dma_beat_check u_beat (.hclk(hclk), .rst_n(rst_n), .pclk(pclk), .psel(psel), .penable(penable),
                           .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata), .haddr(haddr), .hwdata(hwdata),
                           .hrdata(hrdata), .htrans(htrans), .hwrite(hwrite), .hready(hready), .hresp(hresp),
                           .hsize(hsize));

    // ---- checks and APB tasks ------------------------------------------------------
    int checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask
    task automatic wr(input [11:0] a, input [31:0] d);
        @(posedge pclk); #0.1 psel = 1; pwrite = 1; paddr = a; pwdata = d; penable = 0;
        @(posedge pclk); #0.1 penable = 1;
        @(posedge pclk); #0.1 psel = 0; penable = 0; pwrite = 0;
    endtask
    task automatic rd(input [11:0] a, output [31:0] d);
        @(posedge pclk); #0.1 psel = 1; pwrite = 0; paddr = a; penable = 0;
        @(posedge pclk); #0.1 penable = 1; #0.5 d = prdata;
        @(posedge pclk); #0.1 psel = 0; penable = 0;
    endtask
    function automatic [11:0] R(input int ch, input int r); return 12'(32 * ch + 4 * r); endfunction
    localparam int CR = 0, SAR = 1, DAR = 2, CNT = 3, STAT = 4, ICLR = 5;

    // ---- scoreboard ------------------------------------------------------------------
    dma_model m = new();
    int ack0 [6];
    string inject = "";
    bit    hold_req = 0;          // program_xfer leaves the request agent off (the test starts it)
    bit    injected = 0;          // each fault is put in once

    // program the transfer and its data; the agent makes the requests it needs
    task automatic program_xfer(dma_xfer t);
        m.arm(t);
        m.fifo_val[t.ch].delete();
        if (t.src_fifo()) begin
            for (int k = 0; k < t.cnt; k++) begin
                logic [31:0] v = $urandom();
                u_mem.fifo_push(fifo_addr(t.ch), v); m.fifo_val[t.ch].push_back(v);
            end
        end else begin
            // source words for every address the transfer may read
            for (int k = 0; k <= t.cnt; k++) begin
                logic [31:0] a = {t.sar()[31:2], 2'b00} + (t.sinc ? 32'(k * step_of(t.size)) : 32'd0);
                logic [31:0] v = $urandom();
                u_mem.poke(a, v); m.src_word[{a[31:2], 2'b00}] = v;
            end
        end
        ack0[t.ch] = u_req.n_ack[t.ch];
        wr(R(t.ch, SAR), t.sar()); wr(R(t.ch, DAR), t.dar()); wr(R(t.ch, CNT), t.cnt);
        if (t.mode != M_M2M) begin u_req.mode[t.ch] = hold_req ? REQ_OFF : REQ_D21; u_req.todo[t.ch] = t.cnt; end
        pmode[t.ch] = (t.mode != M_M2M);
        wr(R(t.ch, CR), t.cr(1'b1));
    endtask

    // feed the slave's log to the model
    task automatic drain_log();
        while (u_mem.log_q.size() > 0) begin
            ahb_agent_pkg::ahb_txn_t tx = u_mem.log_q.pop_front();
            // flip the lowest bit of the lane the beat carries (a bit outside it is not data)
            if (!injected && tx.write && inject == "wdata") begin tx.data ^= 32'd1 << (8 * tx.addr[1:0]); injected = 1; end
            if (!injected && tx.write && inject == "drop")  begin injected = 1; continue; end
            m.on_transfer(tx.addr, tx.write, tx.size, tx.data, tx.err);
        end
    endtask

    // wait until no channel is active and no beat is in flight, then check every channel
    // wait for idle and feed the model (no register check): the qualification test
    task automatic finish_qual(input int n);
        logic [31:0] g;
        int guard = 0;
        do begin rd(12'h100, g); guard++; end while (g[5:0] != 0 && guard < 20000);
        repeat (40) @(posedge hclk);
        drain_log();
    endtask
    task automatic cleanup(input bit [5:0] used);
        for (int n = 0; n < 6; n++) if (used[n]) begin
            u_req.mode[n] = REQ_OFF; u_req.todo[n] = 0;
            wr(R(n, ICLR), 32'h3); m.x[n] = null;
            u_mem.fifo_flush(fifo_addr(n));
            repeat (4) @(posedge pclk); pmode[n] = 1'b0;
        end
        repeat (8) @(posedge pclk);
    endtask
    task automatic finish_and_check(input bit [5:0] used, input string tag);
        logic [31:0] g, cr, st, sar, dar;
        int guard = 0;
        do begin rd(12'h100, g); guard++; end while (g[5:0] != 0 && guard < 20000);
        check(guard < 20000, {tag, ": every channel went idle"});
        repeat (40) @(posedge hclk);                       // a beat in flight lands
        drain_log();
        for (int n = 0; n < 6; n++) if (used[n]) begin
            bit ic, ie;
            int ak;
            rd(R(n, CR), cr); rd(R(n, STAT), st); rd(R(n, SAR), sar); rd(R(n, DAR), dar);
            ic = comp[n]; ie = err[n]; ak = u_req.n_ack[n] - ack0[n];
            if (!injected && inject == "stat") begin st[0] ^= 1'b1; injected = 1; end
            if (!injected && inject == "irq")  begin ic = !ic; injected = 1; end
            if (!injected && inject == "ack" && m.x[n].mode != M_M2M) begin ak++; injected = 1; end
            m.check_regs(n, cr, st, sar, dar, ic, ie, ak);
            // M2P: the peripheral register received exactly one write per beat
            if (m.x[n].dst_fifo() && u_mem.fifo_level(fifo_addr(n)) != m.done[n])
                m.fail($sformatf("ch%0d: the peripheral register holds %0d writes after %0d beats", n,
                                 u_mem.fifo_level(fifo_addr(n)), m.done[n]));
        end
        // clean up for the next round
        for (int n = 0; n < 6; n++) if (used[n]) begin
            u_req.mode[n] = REQ_OFF; u_req.todo[n] = 0;
            wr(R(n, ICLR), 32'h3); m.x[n] = null;
            u_mem.fifo_flush(fifo_addr(n));                // left over by a stop or an ERROR
            repeat (4) @(posedge pclk); pmode[n] = 1'b0;
        end
        repeat (8) @(posedge pclk);
    endtask


    // ---- model qualification: expected values written by hand from the spec ------------
    // qx: program a transfer with fixed fields (no randomisation)
    function automatic dma_xfer qx(int ch, logic [1:0] mode, logic [1:0] size, bit sinc, bit dinc,
                                   int cnt, logic [31:0] soff, logic [31:0] doff);
        dma_xfer t = new();
        t.ch = ch; t.mode = mode; t.size = size; t.sinc = sinc; t.dinc = dinc; t.cnt = cnt;
        t.soff = soff; t.doff = doff; t.iec = 1; t.iee = 1;
        return t;
    endfunction
    // compare the DUT's registers, and the model's prediction, with the hand values
    task automatic qual_regs(int n, string tag, int k, logic [15:0] rem, logic [31:0] hsar, logic [31:0] hdar,
                             bit hcomp, bit herr, logic [2:0] heph);
        logic [31:0] st, sar, dar;
        rd(R(n, STAT), st); rd(R(n, SAR), sar); rd(R(n, DAR), dar);
        check(m.done[n] == k && m.exp_sar(n, k) == hsar && m.exp_dar(n, k) == hdar,
              $sformatf("[qual] %s: the model predicts %0d beats, SAR %08h, DAR %08h (hand: %0d, %08h, %08h)",
                        tag, m.done[n], m.exp_sar(n, m.done[n]), m.exp_dar(n, m.done[n]), k, hsar, hdar));
        check(st[15:0] == rem && st[17] == hcomp && st[18] == herr && st[21:19] == heph && sar == hsar && dar == hdar,
              $sformatf("[qual] %s: STAT %08h SAR %08h DAR %08h match the hand values", tag, st, sar, dar));
    endtask
    task automatic t_qual();
        dma_xfer t;
        logic [31:0] w;
        u_mem.rwait_max = 1; u_mem.wwait_max = 1;
        // 1. M2M word, 4 beats: SAR 2000_0100 -> 2000_0110, DAR 2080_0200 -> 2080_0210
        t = qx(0, M_M2M, 2'd2, 1, 1, 4, 32'h100, 32'h200); program_xfer(t);
        u_mem.poke(32'h2000_0100, 32'hA0A1A2A3); m.src_word[32'h2000_0100] = 32'hA0A1A2A3;
        finish_qual(0);
        qual_regs(0, "1 M2M word x4", 4, 16'd0, 32'h2000_0110, 32'h2080_0210, 1, 0, 3'd0);
        check(u_mem.peek(32'h2080_0200) == 32'hA0A1A2A3, "[qual] 1: the first word arrived unchanged");
        cleanup(6'b000001);
        // 2. M2M byte, 5 beats from 2000_0103 to 2080_0001: SAR -> 2000_0108, DAR -> 2080_0006;
        //    destination bytes 1..5 = source bytes 3..7
        t = qx(0, M_M2M, 2'd0, 1, 1, 5, 32'h103, 32'h001);
        u_mem.poke(32'h2080_0000, 32'h0); u_mem.poke(32'h2080_0004, 32'h0);
        program_xfer(t);
        u_mem.poke(32'h2000_0100, 32'h44332211); m.src_word[32'h2000_0100] = 32'h44332211;   // bytes 0..3
        u_mem.poke(32'h2000_0104, 32'h88776655); m.src_word[32'h2000_0104] = 32'h88776655;   // bytes 4..7
        finish_qual(0);
        qual_regs(0, "2 M2M byte x5", 5, 16'd0, 32'h2000_0108, 32'h2080_0006, 1, 0, 3'd0);
        // bytes 3..7 = 44 55 66 77 88 land in destination bytes 1..5: word 0 = {66,55,44,00},
        // word 1 low half = {88,77}. (First written as 77665544, which ignored DAR = ..01; the
        // hand arithmetic was redone on 2026-10-12, DUT and model had agreed all along.)
        check(u_mem.peek(32'h2080_0000) == 32'h66554400 && u_mem.peek(32'h2080_0004)[15:0] == 16'h8877,
              $sformatf("[qual] 2: destination bytes 1..5 hold source bytes 3..7 (%08h %08h)", u_mem.peek(32'h2080_0000), u_mem.peek(32'h2080_0004)));
        cleanup(6'b000001);
        // 3. M2M halfword, SINC only, 3 beats: SAR 2001_0002 -> 2001_0008, DAR stays 2081_0000;
        //    every beat writes the same halfword, so it ends holding the last source halfword
        t = qx(1, M_M2M, 2'd1, 1, 0, 3, 32'h2, 32'h0); program_xfer(t);
        u_mem.poke(32'h2001_0000, 32'h2222_1111); m.src_word[32'h2001_0000] = 32'h2222_1111;
        u_mem.poke(32'h2001_0004, 32'h4444_3333); m.src_word[32'h2001_0004] = 32'h4444_3333;
        finish_qual(1);
        qual_regs(1, "3 M2M half x3, SINC only", 3, 16'd0, 32'h2001_0008, 32'h2081_0000, 1, 0, 3'd0);
        check(u_mem.peek(32'h2081_0000)[15:0] == 16'h4444, "[qual] 3: the destination halfword holds the last source halfword (4444)");
        cleanup(6'b000010);
        // 4. P2M word from channel 2's peripheral register, 3 beats: SAR stays 4000_1200,
        //    DAR 2082_0040 -> 2082_004C, three acks, the words in order
        t = qx(2, M_P2M, 2'd2, 0, 1, 3, 32'h0, 32'h40); program_xfer(t);
        finish_qual(2);
        qual_regs(2, "4 P2M word x3", 3, 16'd0, 32'h4000_1200, 32'h2082_004C, 1, 0, 3'd0);
        check(u_mem.peek(32'h2082_0040) == m.fifo_val[2][0] && u_mem.peek(32'h2082_0048) == m.fifo_val[2][2] &&
              u_req.n_ack[2] - ack0[2] == 3, "[qual] 4: the three peripheral words arrived in order, three acks");
        cleanup(6'b000100);
        // 5. M2P byte to channel 3's register, 2 beats from 2003_0005: SAR -> 2003_0007; the register
        //    receives two writes whose byte lane 0 holds source bytes 5 and 6
        t = qx(3, M_M2P, 2'd0, 1, 0, 2, 32'h5, 32'h0); program_xfer(t);
        u_mem.poke(32'h2003_0004, 32'hDDCCBBAA); m.src_word[32'h2003_0004] = 32'hDDCCBBAA;   // bytes 4..7
        finish_qual(3);
        qual_regs(3, "5 M2P byte x2", 2, 16'd0, 32'h2003_0007, 32'h4000_1300, 1, 0, 3'd0);
        w = u_mem.fifo_pop(fifo_addr(3));
        check(w[7:0] == 8'hBB && u_mem.fifo_pop(fifo_addr(3)) [7:0] == 8'hCC, "[qual] 5: the register received source bytes 5 (BB) and 6 (CC)");
        cleanup(6'b001000);
        // 6. M2M word, 4 beats, the third read answers ERROR: two beats done, REMAINING 2,
        //    ERROR with ERRPHASE = read, SAR and DAR frozen at the failing beat (+8)
        u_mem.clear_counts(); u_mem.err_rd_n = 2;
        t = qx(4, M_M2M, 2'd2, 1, 1, 4, 32'h0, 32'h0); program_xfer(t);
        finish_qual(4);
        qual_regs(4, "6 M2M word x4, read ERROR on beat 3", 2, 16'd2, 32'h2004_0008, 32'h2084_0008, 0, 1, 3'd1);
        u_mem.err_rd_n = -1;
        cleanup(6'b010000);
        u_mem.rwait_max = 0; u_mem.wwait_max = 0;
    endtask


    // ---- directed tests (DMA plan D5) ----------------------------------------------------
    // the hclk cycle of the last software strobe and of the last result, per channel
    longint cyc = 0, t_iclr [6], t_set [6], t_err [6];
    always @(posedge hclk) begin
        cyc++;
        for (int n = 0; n < 6; n++) begin
            if (dut.wr_iclr[n]) t_iclr[n] = cyc;
            if (dut.beat_done[n] && dut.stat[32*n +: 16] == 16'd1) t_set[n] = cyc;
            if (dut.beat_err[n]) t_err[n] = cyc;
        end
    end
    // F34/F35/F12/[N-7.19]: a software write to the running channel in every engine phase
    // (phases swept by fixed wait states x the APB start offset). SAR and DAR are rewritten
    // with the value they already hold, on an M2M transfer whose side does not increment
    // (SINC = 0 / DINC = 0): the write lands in any phase and changes nothing, whatever
    // F12/F46 rule for a new value (pending). (Not on P2M / M2P: their beats start on a
    // pclk-synchronised request, so the one-cycle E_RA always falls on the hclk phase
    // opposite the APB strobe, with pclk = hclk/2 phase-locked (D-5).)
    task automatic t_coll();
        string kinds [8] = '{"cr_en1", "cr_en0", "cnt", "iclr_c", "iclr_e", "sar_fix", "dar_fix", "cr_en1_last"};
        logic [31:0] d;
        foreach (kinds[ki]) for (int w = 0; w < 4; w++) for (int k = 0; k < 12; k++) begin
            dma_xfer t;
            int e0 = m.errors, n = 1;
            string kind = kinds[ki];
            u_mem.rwait_fix = w; u_mem.wwait_fix = w; u_mem.clear_counts();
            u_mem.err_wr_n = (kind == "iclr_e") ? 1 : -1;
            begin
                t = qx(n, M_M2M, 2'd2, kind != "sar_fix", kind != "dar_fix", (kind == "cr_en1") ? 12 : 3,
                       32'h40 * k, 32'h40 * k);
            end
            t_iclr[n] = 0; t_set[n] = 0; t_err[n] = 0;
            u_req.gap_max[n] = 0;                                  // requests back to back
            program_xfer(t);
            // cr_en1_last (D-2, [N-7.19]): a CR write with EN = 1 swept across the LAST beat of a
            // three-beat transfer; CNT is 0 first, so a write that lands after the end re-arms a
            // zero-length transfer and the end state is the same whichever cycle it hits
            if (kind == "cr_en1_last") wr(R(n, CNT), 32'd0);
            repeat (k) @(posedge pclk);
            case (kind)
                "cr_en1": begin t.iec = !t.iec; wr(R(n, CR), t.cr(1'b1)); end      // fields land, EN stays (F34)
                "cr_en1_last": wr(R(n, CR), t.cr(1'b1));                           // hardware clear wins (D-2)
                "cr_en0": wr(R(n, CR), t.cr(1'b0));                                // stop, SIZE kept (F20)
                "cnt":    wr(R(n, CNT), 32'd7);                                    // no effect on the running transfer
                "iclr_c": wr(R(n, ICLR), 32'h1);
                "iclr_e": wr(R(n, ICLR), 32'h2);
                "sar_fix": wr(R(n, SAR), t.sar());
                "dar_fix": wr(R(n, DAR), t.dar());
            endcase
            finish_qual(n);
            // [N-7.19]: a clear strobed after the flag set clears it; in the same cycle, set wins
            if (kind == "iclr_c" && t_set[n] != 0 && t_iclr[n] > t_set[n]) m.comp_cleared[n] = 1;
            if (kind == "iclr_e" && t_err[n] != 0 && t_iclr[n] > t_err[n]) m.err_cleared[n] = 1;
            begin
                logic [31:0] cr, st, sar, dar;
                rd(R(n, CR), cr); rd(R(n, STAT), st); rd(R(n, SAR), sar); rd(R(n, DAR), dar);
                m.check_regs(n, cr, st, sar, dar, comp[n], err[n], u_req.n_ack[n] - ack0[n]);
                if (kind == "cnt") begin rd(R(n, CNT), d); if (d != 32'd7) m.fail("CNT write during the transfer did not land"); end
                if (kind == "cr_en1" && cr[7] != t.iec) m.fail("CR write during the transfer: IE_COMP did not land (F34)");
            end
            u_mem.err_wr_n = -1;
            cleanup(6'd1 << n);
            check(m.errors == e0, $sformatf("[coll] %s at waits %0d, offset %0d pclk: scoreboard clean", kind, w, k));
        end
        u_mem.rwait_fix = -1; u_mem.wwait_fix = -1;
    endtask
    // F47: hreset_n in every engine phase (swept), with a second channel pending; afterwards
    // every register is at reset, the bus and the interrupt lines are quiet, and a new
    // transfer works
    task automatic t_reset();
        logic [31:0] d;
        int bad;
        for (int o = 0; o < 2; o++) for (int w = 0; w < 3; w++) for (int k = 0; k < 14; k++) begin
            dma_xfer t = qx(0, M_M2M, 2'd2, 1, 1, 6, 32'h100, 32'h100);
            dma_xfer t2 = qx(3, M_P2M, 2'd2, 0, 1, 4, 32'h0, 32'h200);
            u_mem.rwait_fix = w; u_mem.wwait_fix = w;
            if (o == 0) begin                                // with a second channel pending (no request yet)
                program_xfer(t2);
                u_req.mode[3] = REQ_OFF;
            end
            program_xfer(t);
            repeat (k) @(posedge hclk);
            #0.3 rst_n = 0;                                   // reset in the middle of whatever is happening
            repeat (3) @(posedge hclk); #0.3 rst_n = 1; repeat (3) @(posedge hclk);
            u_mem.log_q.delete(); m.x[0] = null; m.x[3] = null;
            for (int n = 0; n < 6; n++) begin u_req.todo[n] = 0; u_req.mode[n] = REQ_OFF; u_mem.fifo_flush(fifo_addr(n)); end
            bad = 0;
            for (int n = 0; n < 6; n++) for (int r = 0; r < 5; r++) begin
                rd(R(n, r), d);
                if (d != ((r == 0) ? 32'h40 : 32'h0)) bad++;
            end
            repeat (20) @(posedge hclk);
            if (htrans != 2'b00 || ack != 0 || comp != 0 || err != 0 || u_mem.log_q.size() != 0) bad++;
            check(bad == 0, $sformatf("[F47] reset at waits %0d, %0d hclk after the arm%s: registers at reset, bus and lines quiet",
                                      w, k, o ? "" : ", a second channel pending"));
            pmode = 0;
        end
        u_mem.rwait_fix = -1; u_mem.wwait_fix = -1;
        begin                                                // and a transfer works afterwards
            dma_xfer t = qx(2, M_M2M, 2'd1, 1, 1, 5, 32'h300, 32'h300);
            int e0 = m.errors;
            program_xfer(t); finish_and_check(6'd1 << 2, "after the resets");
            check(m.errors == e0, "[F47] a transfer after the resets is clean");
        end
    endtask
    // F26/F28: all six channels eligible at once; channel 5 (lowest priority) waits while
    // the others keep requesting, then resumes and loses nothing
    task automatic t_arb();
        bit [5:0] used = 6'h3F;
        int e0 = m.errors;
        for (int n = 0; n < 6; n++) begin
            dma_xfer t = qx(n, M_P2M, 2'd2, 0, 1, (n == 5) ? 4 : 24, 32'h0, 32'h0);
            hold_req = 1; program_xfer(t); hold_req = 0;   // requests held back until all are armed
        end
        repeat (4) @(posedge pclk);
        for (int n = 0; n < 6; n++) begin u_req.gap_max[n] = 0; u_req.mode[n] = REQ_D21; end   // all raise at once
        finish_and_check(used, "six channels at once");
        check(m.errors == e0, "[F26] [F28] six channels at once: every transfer complete and correct, channel 5 not lost");
        // F28: even the top-priority channel waits for the beat in flight ([N-7.11], beats
        // are atomic): channel 0 armed during a channel 1 beat whose data phases take 60 cycles
        e0 = m.errors;
        begin
            dma_xfer t1 = qx(1, M_M2M, 2'd2, 1, 1, 2, 32'h400, 32'h400);
            dma_xfer t0 = qx(0, M_M2M, 2'd2, 1, 1, 2, 32'h400, 32'h400);
            u_mem.rwait_fix = 60; u_mem.wwait_fix = 60;
            program_xfer(t1);
            program_xfer(t0);
            finish_and_check(6'b000011, "channel 0 behind a slow beat");
            u_mem.rwait_fix = -1; u_mem.wwait_fix = -1;
        end
        check(m.errors == e0, "[F28] the top-priority channel waits for the slow beat in flight, then completes");
    endtask
    // F23: requests withdrawn before the grant give no beat; F25: a request on a disabled
    // channel is ignored
    task automatic t_req();
        dma_xfer t;
        int e0 = m.errors, nb;
        // F25: request high on a disabled channel: no transfer
        u_req.mode[4] = REQ_HELD; u_req.todo[4] = 1;
        nb = u_mem.n_rd;
        repeat (40) @(posedge pclk);
        check(u_mem.n_rd == nb, "[F25] a request on a disabled channel moves nothing");
        u_req.mode[4] = REQ_OFF; repeat (4) @(posedge pclk);
        // F23: withdrawn requests
        u_req.withdraw_pct = 50;
        t = qx(4, M_P2M, 2'd2, 0, 1, 10, 32'h0, 32'h80);
        program_xfer(t);
        u_req.mode[4] = REQ_WITHDRAW;
        finish_and_check(6'd1 << 4, "withdrawn requests");
        check(m.errors == e0 && u_req.n_withdrawn[4] > 0,
              $sformatf("[F23] %0d request(s) withdrawn before the grant gave no beat; the transfer completed exactly", u_req.n_withdrawn[4]));
        u_req.withdraw_pct = 0;
    endtask
    // F50 (negative): a peripheral that holds its request high gets one beat, then the
    // channel waits; dma_req_checker must report the broken contract (D-21)
    task automatic t_held();
        dma_xfer t = qx(5, M_P2M, 2'd2, 0, 1, 4, 32'h0, 32'h0);
        logic [31:0] st;
        program_xfer(t);
        u_req.mode[5] = REQ_HELD;
        repeat (200) @(posedge pclk);
        rd(R(5, STAT), st);
        check(st[15:0] == 16'd3, $sformatf("[F50] a request held high gives one beat, then the channel waits (REMAINING %0d of 4)", st[15:0]));
    endtask

    // F13-F17: every channel x mode x size, two beats from an unaligned-in-the-word address
    // (byte offset 3, halfword offset 2), and every MODE x SINC x DINC; fixed data-phase
    // waits step through 0..5 (F48: four and more); every other transfer with address stalls
    task automatic t_matrix();
        int idx = 0, e0 = m.errors;
        for (int ch = 0; ch < 6; ch++) for (int md = 0; md < 3; md++) for (int sz = 0; sz < 3; sz++) begin
            logic [1:0] mode = 2'(md);
            logic [31:0] off = (sz == 0) ? 32'h13 : (sz == 1) ? 32'h12 : 32'h10;
            dma_xfer t = qx(ch, mode, 2'(sz), mode != M_P2M, mode != M_M2P, 2, off, off);
            u_mem.rwait_fix = idx % 6; u_mem.wwait_fix = (idx + 3) % 6;
            u_mem.stall_max = idx[0] ? 3 : 0; u_mem.stall_pct = idx[0] ? 40 : 0;     // address stalls (F48)
            idx++;
            program_xfer(t); finish_and_check(6'd1 << ch, t.str());
        end
        for (int md = 0; md < 3; md++) for (int inc = 0; inc < 4; inc++) begin
            dma_xfer t = qx((md * 4 + inc) % 6, 2'(md), 2'd2, inc[0], inc[1], 3, 32'h20, 32'h20);
            u_mem.rwait_fix = idx % 6; u_mem.wwait_fix = (idx + 3) % 6; idx++;
            program_xfer(t); finish_and_check(6'd1 << t.ch, t.str());
        end
        u_mem.rwait_fix = -1; u_mem.wwait_fix = -1; u_mem.stall_max = 0; u_mem.stall_pct = 0;
        check(m.errors == e0, $sformatf("[F13-F17] [F48] %0d transfers: every channel x mode x size and every increment pair, waits 0..5: scoreboard clean", idx));
    endtask
    // F29-F31, F02/F03, F12, F45: errors at the edges of a transfer; illegal MODE / SIZE and
    // same-value SAR / DAR written to an enabled channel; MODE changed while it runs
    task automatic t_edge();
        int e0 = m.errors;
        logic [31:0] d, st;
        dma_xfer t;
        // F29/F30: a write ERROR on a P2M transfer (first beat, then last beat)
        for (int pos = 0; pos < 2; pos++) begin
            t = qx(2, M_P2M, 2'd2, 0, 1, 3, 32'h0, 32'h100);
            u_mem.clear_counts(); u_mem.err_wr_n = pos ? 2 : 0;
            program_xfer(t); finish_and_check(6'd1 << 2, $sformatf("P2M write ERROR on beat %0d", pos ? 3 : 1));
            u_mem.err_wr_n = -1;
        end
        // F29/F31: a read ERROR on the last beat of an M2M transfer
        t = qx(0, M_M2M, 2'd1, 1, 1, 3, 32'h0, 32'h0);
        u_mem.clear_counts(); u_mem.err_rd_n = 2;
        program_xfer(t); finish_and_check(6'd1, "M2M read ERROR on the last beat");
        u_mem.err_rd_n = -1;
        check(m.errors == e0, "[F29-F31] ERROR on a P2M write (first, last beat) and on the last M2M read: scoreboard clean");
        // F33: the interrupt enables are separate: an ERROR with only IE_ERR raises dma_error,
        // with only IE_COMP it raises nothing; a completion with only IE_ERR raises nothing
        // (qx sets both enables; found by the planted-defect run, mutant M07)
        e0 = m.errors;
        for (int k = 0; k < 2; k++) begin
            t = qx(5, M_M2M, 2'd2, 1, 1, 2, 32'h40, 32'h40);
            t.iec = (k == 1); t.iee = (k == 0);
            u_mem.clear_counts(); u_mem.err_wr_n = 1;
            program_xfer(t); finish_and_check(6'd1 << 5, $sformatf("ERROR with IE_COMP=%0d IE_ERR=%0d", t.iec, t.iee));
            u_mem.err_wr_n = -1;
        end
        t = qx(5, M_M2M, 2'd2, 1, 1, 2, 32'h80, 32'h80);
        t.iec = 0; t.iee = 1;
        program_xfer(t); finish_and_check(6'd1 << 5, "completion with IE_COMP=0 IE_ERR=1");
        check(m.errors == e0, "[F33] IE_COMP and IE_ERR gate only their own line: scoreboard clean");
        // an enabled P2M channel that waits for its request (no beat in flight)
        e0 = m.errors;
        t = qx(3, M_P2M, 2'd1, 0, 1, 6, 32'h0, 32'h40);
        hold_req = 1; program_xfer(t); hold_req = 0;
        repeat (8) @(posedge pclk);
        // F02/F03: MODE 3 and SIZE 3 written with EN = 1 leave MODE and SIZE alone; the rest lands
        wr(R(3, CR), t.cr(1'b1) | 32'h6);
        wr(R(3, CR), t.cr(1'b1) | 32'h60);
        rd(R(3, CR), d);
        check(d[2:1] == M_P2M && d[6:5] == 2'd1 && d[0], $sformatf("[F02] [F03] MODE 3 / SIZE 3 written to an enabled channel: CR = %08h, MODE and SIZE kept", d));
        // F12: SAR and DAR written with their own value while the channel is enabled
        wr(R(3, SAR), t.sar());
        rd(R(3, DAR), d); wr(R(3, DAR), d);
        // two beats on requests, then F45: MODE changed to M2M while REMAINING = 4; the channel
        // runs on without requests (vPlan F45 notes; acks after the change wait for DMA-15)
        u_req.todo[3] = 2; u_req.gap_max[3] = 0; u_req.mode[3] = REQ_D21;
        begin
            int guard = 0;
            do begin rd(R(3, STAT), st); guard++; end while (st[15:0] != 16'd4 && guard < 2000);
        end
        repeat (8) @(posedge pclk);
        rd(R(3, STAT), st);
        check(st[15:0] == 16'd4 && st[16], $sformatf("[F45] two requests gave two beats; the channel waits, active (STAT %08h)", st));
        pmode[3] = 1'b0; m.ack_free[3] = 1;
        begin
            dma_xfer t2 = qx(3, M_M2M, 2'd1, 0, 1, 6, 32'h0, 32'h40);
            wr(R(3, CR), t2.cr(1'b1));
        end
        finish_and_check(6'd1 << 3, "MODE changed to M2M while running");
        check(m.errors == e0, "[F02] [F03] [F12] [F45] writes to an enabled channel, MODE changed while running: scoreboard clean");
    endtask

    // F05/F18/F19: REMAINING's upper bits on every channel (armed with CNT = FFFF, stopped
    // before any beat, re-armed with a short count) and bus addresses outside the env's
    // windows (bits 19-22, 24-28, 30, 31). Programmed by APB directly: the model's
    // address map does not cover these addresses, so these runs are checked here and by
    // the pin-level beat checker
    task automatic t_bits();
        logic [31:0] st, d;
        int e0 = m.errors;
        for (int n = 0; n < 6; n++) begin
            wr(R(n, SAR), fifo_addr(n)); wr(R(n, DAR), dst_win(n)); wr(R(n, CNT), 32'hFFFF);
            wr(R(n, CR), 32'h1B1);                           // P2M halfword, no request: armed, waits
            repeat (4) @(posedge pclk);
            rd(R(n, STAT), st);
            check(st[15:0] == 16'hFFFF && st[16], $sformatf("[F05] ch%0d armed with CNT = FFFF: REMAINING FFFF, active (STAT %08h)", n, st));
            wr(R(n, CR), 32'h1B0);                           // stop before any beat
            rd(R(n, STAT), st);
            check(st[15:0] == 16'hFFFF && !st[16] && !st[17], $sformatf("[F20] ch%0d stopped: REMAINING kept, idle, not complete (STAT %08h)", n, st));
            begin                                            // re-armed with a short count
                dma_xfer t = qx(n, M_M2M, 2'd2, 1, 1, 2, 32'h0, 32'h0);
                program_xfer(t); finish_and_check(6'd1 << n, t.str());
            end
        end
        check(m.errors == e0, "[F05] [F20] REMAINING FFFF -> stop -> re-arm short on every channel: scoreboard clean");
        // high address bits: M2M word x2 from 9F78_0000 to DF78_0100, then back
        begin
            logic [31:0] src = 32'h9F78_0000, dst = 32'hDF78_0100, v0 = 32'hC0DE_0001, v1 = 32'hC0DE_0002;
            u_mem.poke(src, v0); u_mem.poke(src + 4, v1);
            wr(R(0, SAR), src); wr(R(0, DAR), dst); wr(R(0, CNT), 32'd2);
            wr(R(0, CR), 32'h5D);                            // M2M word, SINC, DINC, EN
            begin
                int guard = 0;
                do begin rd(R(0, STAT), st); guard++; end while (st[16] && guard < 2000);
            end
            repeat (20) @(posedge hclk);
            rd(R(0, SAR), d);
            check(st[17] && st[15:0] == 0 && d == src + 8 && u_mem.peek(dst) == v0 && u_mem.peek(dst + 4) == v1,
                  $sformatf("[F13] M2M at 9F78_0000 -> DF78_0100: complete, data moved, SAR %08h", d));
            u_mem.log_q.delete();                            // outside the model's map (checked above)
            wr(R(0, ICLR), 32'h3);
        end
        begin                                                // and back to low addresses (1 -> 0)
            dma_xfer t = qx(1, M_M2M, 2'd2, 1, 1, 2, 32'h0, 32'h0);
            e0 = m.errors;
            program_xfer(t); finish_and_check(6'd1 << 1, t.str());
            check(m.errors == e0, "[F13] a transfer at low addresses after it: scoreboard clean");
        end
    endtask

    // R-9 / F32 / F43: a refused source (Boot ROM region) and a refused destination (ISRAM
    // region) in every mode: the channel ends in ERROR with ERRPHASE read / write,
    // REMAINING unchanged, and nothing is transferred to or from the refused address.
    // Today's RTL reads the source before refusing a destination (DMA-10): the detector
    // fires once per destination case (declared `known` in tb/dma/run/env.toml). Checked
    // here and by the pin-level beat checker (R-9 rule); the model's map has no refused
    // addresses, so the slave's log is not fed to it.

    // ---- bus plan B3: the Fresh plan's Phase 3 gaps ---------------------------------------
    // CNT = 65535: the largest transfer, every beat checked by the model and the scoreboard
    task automatic t_maxcnt();
        logic [31:0] g;
        int guard = 0;
        // bytes: 65535 beats stay inside the channel's 64 KiB window (the model attributes
        // transfers to channels by window; 65535 words would cross into channel 1's)
        dma_xfer t = qx(0, M_M2M, 2'd0, 1, 1, 65535, 32'h0, 32'h0);
        u_mem.rwait_max = 0; u_mem.wwait_max = 0; u_mem.stall_max = 0; u_mem.stall_pct = 0;
        program_xfer(t);
        do begin repeat (64) @(posedge hclk); rd(12'h100, g); guard++; end while (g[0] && guard < 20000);
        check(!g[0], "[F05] [CNT=65535] the transfer finished");
        finish_and_check(6'd1, "maxcnt");
    endtask
    // DMA-16 (open ruling): P2M from a pop-on-read FIFO, the SECOND destination write gets an
    // AHB ERROR. Records what happens: beat 1 lands; beat 2's item is popped and its write
    // fails (ERRPHASE write, REMAINING / DAR frozen, no ack); after ICLR and a re-arm the
    // channel continues with item 3 -- item 2 is lost. Passes while the behaviour is as
    // logged in Docs/bugs/dma.md DMA-16; the ruling decides whether it is accepted (A).
    task automatic t_dma16();
        int n = 2;
        logic [31:0] st, sar, dar, d = dst_win(2);
        logic [31:0] v[4] = '{32'hA160_0000, 32'hA160_0001, 32'hA160_0002, 32'hA160_0003};
        int a0 = u_req.n_ack[n], guard = 0;
        foreach (v[i]) u_mem.fifo_push(fifo_addr(n), v[i]);
        u_mem.err_lo = d + 4; u_mem.err_hi = d + 8;
        wr(R(n, SAR), fifo_addr(n)); wr(R(n, DAR), d); wr(R(n, CNT), 32'd4);
        u_req.mode[n] = REQ_D21; u_req.todo[n] = 4;
        wr(R(n, CR), {23'd0, 1'b1, 1'b1, 2'd2, 1'b1, 1'b0, 2'(M_P2M), 1'b1});      // word, DINC, both IEs
        do begin rd(R(n, STAT), st); guard++; end while (!st[18] && guard < 400);
        repeat (20) @(posedge hclk);
        rd(R(n, STAT), st); rd(R(n, SAR), sar); rd(R(n, DAR), dar);
        check(st[18] && st[21:19] == 3'd2 && st[15:0] == 16'd3 && !st[16],
              $sformatf("[DMA-16] write ERROR on beat 2: ERROR, ERRPHASE write, REMAINING 3 (STAT %08h)", st));
        check(dar == d + 4 && sar == fifo_addr(n), $sformatf("[DMA-16] SAR / DAR frozen at the failed beat (DAR %08h)", dar));
        check(u_mem.peek(d) == v[0], "[DMA-16] beat 1 delivered item 1");
        check(u_mem.fifo_level(fifo_addr(n)) == 2, $sformatf("[DMA-16] the FIFO gave up item 2 to the failed beat (level %0d)",
                                                            u_mem.fifo_level(fifo_addr(n))));
        check(u_req.n_ack[n] - a0 == 1, $sformatf("[DMA-16] one ack (beat 1), none for the failed beat (%0d)", u_req.n_ack[n] - a0));
        // clear, fix the destination, re-arm for the two remaining items
        u_req.mode[n] = REQ_OFF; u_mem.err_lo = 0; u_mem.err_hi = 0;
        wr(R(n, ICLR), 32'h3); repeat (8) @(posedge pclk);
        wr(R(n, DAR), d + 4); wr(R(n, CNT), 32'd2);
        u_req.mode[n] = REQ_D21; u_req.todo[n] = 2;
        wr(R(n, CR), {23'd0, 1'b1, 1'b1, 2'd2, 1'b1, 1'b0, 2'(M_P2M), 1'b1});
        guard = 0;
        do begin rd(R(n, STAT), st); guard++; end while (!st[17] && guard < 400);
        check(st[17] && !st[18], "[DMA-16] the re-armed transfer completes");
        check(u_mem.peek(d + 4) == v[2] && u_mem.peek(d + 8) == v[3],
              $sformatf("[DMA-16] after the re-arm the stream continues with item 3: %08h %08h (item 2 = %08h is lost)",
                        u_mem.peek(d + 4), u_mem.peek(d + 8), v[1]));
        $display("[KNOWN DMA-16] a P2M item popped by a beat whose write fails is lost (ruling pending; proposed: document)");
        u_req.mode[n] = REQ_OFF; u_req.todo[n] = 0;
        wr(R(n, CR), 32'h0); wr(R(n, ICLR), 32'h3);
        u_mem.fifo_flush(fifo_addr(n)); u_mem.log_q.delete();
        repeat (8) @(posedge pclk);
    endtask
    // a request held high through a failed beat: the failure does not consume it (DMA-8 fix),
    // so after ICLR and a re-arm the still-held request gives exactly one beat, then the
    // channel waits for the request to drop and rise again (one beat per request, [N-7.10])
    task automatic t_held_err();
        int n = 3;
        logic [31:0] st, d = dst_win(3);
        int a0 = u_req.n_ack[n], guard = 0;
        for (int k = 0; k < 4; k++) u_mem.fifo_push(fifo_addr(n), 32'hB0B0_0000 + k);
        u_mem.err_lo = d; u_mem.err_hi = d + 4;                       // the first write fails
        wr(R(n, SAR), fifo_addr(n)); wr(R(n, DAR), d); wr(R(n, CNT), 32'd3);
        u_req.mode[n] = REQ_HELD; u_req.todo[n] = 3;              // raised once, never dropped
        wr(R(n, CR), {23'd0, 1'b1, 1'b1, 2'd2, 1'b1, 1'b0, 2'(M_P2M), 1'b1});
        do begin rd(R(n, STAT), st); guard++; end while (!st[18] && guard < 400);
        check(st[18] && st[21:19] == 3'd2 && st[15:0] == 16'd3, $sformatf("[F21] held request: beat 1 write ERROR (STAT %08h)", st));
        u_mem.err_lo = 0; u_mem.err_hi = 0;
        wr(R(n, ICLR), 32'h3); repeat (8) @(posedge pclk);
        wr(R(n, DAR), d + 16);
        wr(R(n, CR), {23'd0, 1'b1, 1'b1, 2'd2, 1'b1, 1'b0, 2'(M_P2M), 1'b1});   // re-arm; the request never dropped
        repeat (300) @(posedge pclk);
        rd(R(n, STAT), st);
        check(st[15:0] == 16'd2 && !st[18], $sformatf("[F21] [DMA-8] the held request survived the failure: exactly one beat after the re-arm (REMAINING %0d)", st[15:0]));
        check(u_req.n_ack[n] - a0 == 1, $sformatf("[F22] one ack for that beat (%0d)", u_req.n_ack[n] - a0));
        u_req.mode[n] = REQ_OFF; u_req.todo[n] = 0;
        wr(R(n, CR), 32'h0); wr(R(n, ICLR), 32'h3);
        u_mem.fifo_flush(fifo_addr(n)); u_mem.log_q.delete();
        repeat (8) @(posedge pclk);
    endtask

    task automatic t_r9();
        logic [31:0] st;
        for (int side = 0; side < 2; side++) for (int md = 0; md < 3; md++) begin
            int n = 1 + md;
            logic [31:0] sa = side ? ((md == M_P2M) ? fifo_addr(n) : src_win(n)) : 32'h1000_0040;
            logic [31:0] da = side ? 32'h0000_0100 : ((md == M_M2P) ? fifo_addr(n) : dst_win(n));
            int guard = 0, bad = 0;
            if (md == M_P2M) u_mem.fifo_push(fifo_addr(n), 32'h5555_0000 + n);
            wr(R(n, SAR), sa); wr(R(n, DAR), da); wr(R(n, CNT), 32'd2);
            if (md != M_M2M) begin u_req.mode[n] = REQ_D21; u_req.todo[n] = 1; end
            wr(R(n, CR), {23'd0, 1'b1, 1'b1, 2'd2, 1'b0, 1'b0, 2'(md), 1'b1});   // word, no increments, both IEs
            do begin rd(R(n, STAT), st); guard++; end while (!st[18] && guard < 400);
            repeat (20) @(posedge hclk);
            rd(R(n, STAT), st);
            foreach (u_mem.log_q[i]) if (u_mem.log_q[i].addr[31:29] == 3'b000) bad++;
            check(st[18] && st[21:19] == (side ? 3'd2 : 3'd1) && st[15:0] == 16'd2 && !st[16] && err[n] && bad == 0,
                  $sformatf("[F32] [F43] R-9 %s refused, mode %0d: ERROR, ERRPHASE %0d, REMAINING %0d, %0d transfer(s) at the refused address (STAT %08h)",
                            side ? "destination" : "source", md, st[21:19], st[15:0], bad, st));
            u_req.mode[n] = REQ_OFF; u_req.todo[n] = 0;
            wr(R(n, CR), 32'h0); wr(R(n, ICLR), 32'h3);
            u_mem.fifo_flush(fifo_addr(n)); u_mem.log_q.delete();
            repeat (8) @(posedge pclk);
        end
    endtask

    // ---- tests ---------------------------------------------------------------------------
    task automatic t_smoke();
        int e0;
        for (int waits = 0; waits < 2; waits++)
            for (int lm = 0; lm < 3; lm++)
                for (int ls = 0; ls < 3; ls++) begin
                    dma_xfer t = new();
                    logic [1:0] want_m = 2'(lm), want_s = 2'(ls);
                    int want_c = (lm * 3 + ls) % 6;
                    e0 = m.errors;
                    u_mem.rwait_max = waits ? 3 : 0; u_mem.wwait_max = waits ? 3 : 0;
                    u_mem.stall_max = waits ? 2 : 0; u_mem.stall_pct = waits ? 10 : 0;
                    t.cnt_lo = 3; t.cnt_hi = 12;
                    if (!t.randomize() with { ch == want_c; mode == want_m; size == want_s;
                                              (mode == M_M2M) -> (sinc && dinc); iec; iee; })
                        $fatal(1, "randomize failed");
                    program_xfer(t);
                    finish_and_check(6'd1 << t.ch, t.str());
                    check(m.errors == e0, $sformatf("[smoke] %s waits=%0d: scoreboard clean", t.str(), waits));
                end
    endtask

    task automatic t_rand(input int iters);
        for (int it = 0; it < iters; it++) begin
            dma_xfer t;
            bit [5:0] used = 0;
            int nch = $urandom_range(6, 1), e0 = m.errors, total = 0;
            u_mem.rwait_max = $urandom_range(5, 0); u_mem.wwait_max = $urandom_range(5, 0);
            u_mem.stall_max = $urandom_range(3, 0); u_mem.stall_pct = $urandom_range(20, 0);
            u_mem.err_rd_n = -1; u_mem.err_wr_n = -1; u_mem.clear_counts();
            for (int n = 0; n < 6; n++) u_req.gap_max[n] = $urandom_range(4, 0);
            for (int i = 0; i < nch; i++) begin
                int want_c;
                do want_c = $urandom_range(5, 0); while (used[want_c]);   // (Verilator: no rand index in a constraint)
                t = new();
                if (!t.randomize() with { ch == want_c; }) $fatal(1, "randomize failed");
                used[t.ch] = 1; total += t.cnt;
                program_xfer(t);
            end
            if ($urandom_range(99, 0) < 20) begin                       // one ERROR somewhere
                if ($urandom_range(1, 0)) u_mem.err_rd_n = $urandom_range(total - 1, 0);
                else                      u_mem.err_wr_n = $urandom_range(total - 1, 0);
            end
            if ($urandom_range(99, 0) < 15) begin                       // stop one channel (keeps SIZE: DMA-14)
                int n;
                do n = $urandom_range(5, 0); while (!used[n]);
                repeat ($urandom_range(200, 1)) @(posedge hclk);
                wr(R(n, CR), m.x[n].cr(1'b0));
            end
            finish_and_check(used, $sformatf("rand iteration %0d", it));
            check(m.errors == e0, $sformatf("[rand] iteration %0d: %0d channel(s), scoreboard clean", it, nch));
        end
    endtask

    // ---- main -----------------------------------------------------------------------------
    string tname;
    int iters;
    initial begin
        if (!$value$plusargs("TEST=%s", tname)) tname = "smoke";
        if (!$value$plusargs("ITER=%d", iters)) iters = 40;
        void'($value$plusargs("INJECT=%s", inject));
        $display("=== tb_dma_env +TEST=%s ===", tname);
        for (int n = 0; n < 6; n++) u_mem.fifo_add(fifo_addr(n));
        repeat (4) @(posedge hclk); rst_n = 1; repeat (4) @(posedge hclk);
        case (tname)
            "smoke": t_smoke();
            "rand":  t_rand(iters);
            "qual":  t_qual();
            "coll":  t_coll();
            "reset": t_reset();
            "arb":   t_arb();
            "req":   t_req();
            "held":  t_held();
            "matrix": t_matrix();
            "edge":  t_edge();
            "bits":  t_bits();
            "r9":    t_r9();
            "maxcnt":   t_maxcnt();
            "dma16":    t_dma16();
            "held_err": t_held_err();
            // the planted-defect run (DMA plan D8): every directed test, then random
            // iterations with stalls, waits and errors, in one simulation
            "mut":   begin t_qual(); t_matrix(); t_edge(); t_bits(); t_coll(); t_reset();
                           t_arb(); t_req(); t_rand(iters); end
            default: begin $display("[FAIL] unknown +TEST=%s", tname); fails++; end
        endcase
        check(ahb_viol == 0, $sformatf("AHB-Lite checker on M3: %0d violation(s)", ahb_viol));
        begin
            automatic int v = 0;
            v += g_rc[0].u_rc.violations(); v += g_rc[1].u_rc.violations(); v += g_rc[2].u_rc.violations();
            v += g_rc[3].u_rc.violations(); v += g_rc[4].u_rc.violations(); v += g_rc[5].u_rc.violations();
            check(v == 0, $sformatf("dma_req_checker: %0d D-21 violation(s) by the request agent", v));
        end
        check(m.errors == 0, $sformatf("scoreboard: %0d mismatch(es) in total", m.errors));
        check(u_beat.violations == 0 && (u_beat.beats > 0 || tname == "r9"),     // r9 completes no beat by design
              $sformatf("pin-level beat checker (R4): %0d beats checked, %0d violation(s)", u_beat.beats, u_beat.violations));
        $display("[KNOWN DMA-15] %0d dma_ack pulse(s) on M2M beats (the RTL acks every beat; ruling pending)", m.m2m_acks);
        $display("tb_dma_env: test=%s checks=%0d  FAIL=%0d", tname, checks, fails);
        $display("RESULT: %s", (fails || checks == 0) ? "FAILED" : "PASSED");
        $finish;
    end
    initial begin #200_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
