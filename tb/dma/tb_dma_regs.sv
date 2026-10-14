`timescale 1ns/1ps
// =============================================================================
// tb_dma_regs.sv -- DMA register tests (Track A, DMA plan D3; Karthik's plan R7
// register part; DMA sign-off checklist item 8: all 6 x 6 registers + GSTAT).
//
// Expected values come from tb/dma/env/dma_regs_pkg.sv, generated from
// Design_Docs/regs/dma.rdl (the specification's register map), not from the RTL.
// The rules a register description cannot express are applied here from the
// specification: MODE = 3 and SIZE = 3 writes are refused ([N-6.1], F03), EN set
// with CNT = 0 completes at once, ICLR is write-1-to-clear, a write to a
// read-only register is ignored without PSLVERR and PSLVERR answers only an
// offset that is not a register ([N-6.6], AUD-13).
//
// No AHB transfer may happen (only zero-length arms); dma_sva is bound and
// checks every cycle. pclk is made in the same time step as hclk (TB-44).
// =============================================================================
module tb_dma_regs;
    import dma_regs_pkg::*;

    logic hclk = 0, pclk = 0, rst_n = 0;
    always #2 hclk = ~hclk;
    initial begin #2; forever begin pclk = ~pclk; #4; end end

    logic        psel = 0, penable = 0, pwrite = 0;
    logic [11:0] paddr = 0;
    logic [31:0] pwdata = 0;
    wire  [31:0] prdata;
    wire         pready, pslverr;
    wire  [31:0] haddr, hwdata;
    wire  [1:0]  htrans;
    wire         hwrite;
    wire  [2:0]  hsize, hburst;
    wire  [5:0]  ack, comp, err;

    dma_top dut (
        .hclk_i(hclk), .hreset_n_i(rst_n), .pclk_i(pclk), .preset_n_i(rst_n),
        .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite), .paddr_i(paddr),
        .pwdata_i(pwdata), .prdata_o(prdata), .pready_o(pready), .pslverr_o(pslverr),
        .haddr_o(haddr), .htrans_o(htrans), .hwrite_o(hwrite), .hsize_o(hsize),
        .hburst_o(hburst), .hwdata_o(hwdata), .hrdata_i(32'h0), .hready_i(1'b1),
        .hresp_i(1'b0), .dma_req_i(6'd0), .dma_ack_o(ack), .dma_complete_o(comp),
        .dma_error_o(err));

    int n_ahb = 0;
    always @(posedge hclk) if (rst_n && htrans[1]) n_ahb++;

    // ---- checks and APB tasks ------------------------------------------------------
    int checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask
    task automatic wr(input [11:0] a, input [31:0] d, output bit e);
        @(posedge pclk); #0.1 psel = 1; pwrite = 1; paddr = a; pwdata = d; penable = 0;
        @(posedge pclk); #0.1 penable = 1; #0.5 e = pslverr;
        @(posedge pclk); #0.1 psel = 0; penable = 0; pwrite = 0;
    endtask
    task automatic rd(input [11:0] a, output [31:0] d, output bit e);
        @(posedge pclk); #0.1 psel = 1; pwrite = 0; paddr = a; penable = 0;
        @(posedge pclk); #0.1 penable = 1; #0.5 d = prdata; e = pslverr;
        @(posedge pclk); #0.1 psel = 0; penable = 0;
    endtask
    // back-to-back: the next setup phase starts on the edge that ends this access
    task automatic wr_bb(input [11:0] a, input [31:0] d);
        #0.1 psel = 1; pwrite = 1; paddr = a; pwdata = d; penable = 0;
        @(posedge pclk); #0.1 penable = 1;
        @(posedge pclk);
    endtask
    task automatic rd_bb(input [11:0] a, output [31:0] d);
        #0.1 psel = 1; pwrite = 0; paddr = a; penable = 0;
        @(posedge pclk); #0.1 penable = 1;
        @(posedge pclk); d = prdata;
    endtask
    task automatic apb_idle();
        #0.1 psel = 0; penable = 0; pwrite = 0;
    endtask
    function automatic [11:0] A(input int ch, input int r);
        return 12'(ch * DMA_CH_STRIDE) + DMA_REG_OFS[r];
    endfunction
    // the CR value the specification predicts after writing wd over old (EN not set here)
    function automatic [31:0] cr_after(input [31:0] old, input [31:0] wd);
        logic [31:0] v;
        v = old;
        if (wd[2:1] != 2'b11) v[2:1] = wd[2:1];
        if (wd[6:5] != 2'b11) v[6:5] = wd[6:5];
        v[3] = wd[3]; v[4] = wd[4]; v[7] = wd[7]; v[8] = wd[8];
        v[0] = 1'b0;
        return v & DMA_REG_RMASK[DMA_CR_IDX];
    endfunction
    function automatic bit is_reg(input [11:0] a);
        if (a == DMA_GSTAT_ADDR) return 1;
        if (a[1:0] != 2'b00 || a >= 12'(DMA_NCH * DMA_CH_STRIDE)) return 0;
        for (int r = 0; r < DMA_NREGS; r++) if ((a % DMA_CH_STRIDE) == DMA_REG_OFS[r]) return 1;
        return 0;
    endfunction
    // snapshot of every readable register
    task automatic snapshot(output logic [31:0] s [DMA_NCH][DMA_NREGS], output logic [31:0] g);
        bit e;
        for (int ch = 0; ch < DMA_NCH; ch++)
            for (int r = 0; r < DMA_NREGS; r++) rd(A(ch, r), s[ch][r], e);
        rd(DMA_GSTAT_ADDR, g, e);
    endtask

    initial begin
        logic [31:0] d, d2, exp, g0, g1, pat;
        logic [31:0] s0 [DMA_NCH][DMA_NREGS], s1 [DMA_NCH][DMA_NREGS];
        bit e;
        int bad, n;

        $display("=== tb_dma_regs: DMA registers against Design_Docs/regs/dma.rdl ===");
        repeat (4) @(posedge hclk); rst_n = 1; repeat (2) @(posedge hclk);

        // ---- 1. reset values: all 6 x 6 registers and GSTAT -----------------------------
        for (int ch = 0; ch < DMA_NCH; ch++)
            for (int r = 0; r < DMA_NREGS; r++) begin
                rd(A(ch, r), d, e);
                check(!e && d == (DMA_REG_RESET[r] & DMA_REG_RMASK[r]),
                      $sformatf("[F01] [F11] reset: ch%0d %s = %08h (want %08h)", ch, DMA_REG_NAME[r], d, DMA_REG_RESET[r] & DMA_REG_RMASK[r]));
            end
        rd(DMA_GSTAT_ADDR, d, e);
        check(!e && d == DMA_GSTAT_RESET, $sformatf("[F08] reset: GSTAT = %08h", d));

        // ---- 2. walking 1 and walking 0 on every writable bit ------------------------------
        for (int ch = 0; ch < DMA_NCH; ch++) begin
            for (int r = 0; r < DMA_NREGS; r++) begin
                if (r == DMA_CR_IDX || DMA_REG_KIND[r] != REG_RW) continue;
                bad = 0;
                for (int b = 0; b < 32; b++) begin
                    if (!DMA_REG_WMASK[r][b]) continue;
                    for (int w0 = 0; w0 < 2; w0++) begin
                        pat = w0 ? (DMA_REG_WMASK[r] & ~(32'd1 << b)) : (32'd1 << b);
                        wr(A(ch, r), pat, e); rd(A(ch, r), d, e);
                        if (d != (pat & DMA_REG_RMASK[r])) bad++;
                    end
                end
                check(bad == 0, $sformatf("[F04] [F05] ch%0d %s: walking 1/0 on every writable bit reads back (%0d errors)", ch, DMA_REG_NAME[r], bad));
                wr(A(ch, r), 32'h0, e);
            end
            // CR without EN, the MODE/SIZE = 3 rule applied to the expected value
            bad = 0; exp = DMA_REG_RESET[DMA_CR_IDX];
            for (int b = 1; b < 9; b++)
                for (int w0 = 0; w0 < 2; w0++) begin
                    pat = w0 ? (DMA_REG_WMASK[DMA_CR_IDX] & ~32'd1 & ~(32'd1 << b)) : (32'd1 << b);
                    wr(A(ch, DMA_CR_IDX), pat, e); rd(A(ch, DMA_CR_IDX), d, e);
                    exp = cr_after(exp, pat);
                    if (d != exp) bad++;
                end
            check(bad == 0, $sformatf("[F01] [F02] [F03] ch%0d CR: walking 1/0 on bits 8:1 reads back as the specification predicts (%0d errors)", ch, bad));
            wr(A(ch, DMA_CR_IDX), DMA_REG_RESET[DMA_CR_IDX], e);
        end

        // ---- 3. MODE = 3 and SIZE = 3 are refused ([N-6.1], F03) -----------------------------
        for (int ch = 0; ch < DMA_NCH; ch++) begin
            wr(A(ch, DMA_CR_IDX), 32'h0000_0022, e);                          // MODE = M2P (01), SIZE = halfword (01)
            wr(A(ch, DMA_CR_IDX), 32'h0000_0066, e);                          // MODE = 3, SIZE = 3
            rd(A(ch, DMA_CR_IDX), d, e);
            check(d[2:1] == 2'd1 && d[6:5] == 2'd1,
                  $sformatf("[F02] [F03] ch%0d: a write of MODE = 3 and SIZE = 3 leaves MODE %0d, SIZE %0d", ch, d[2:1], d[6:5]));
            wr(A(ch, DMA_CR_IDX), DMA_REG_RESET[DMA_CR_IDX], e);
        end

        // ---- 4. EN with CNT = 0, then ICLR (W1C, a write of 0 does nothing) ---------------
        for (int ch = 0; ch < DMA_NCH; ch++) begin
            bad = 0;
            wr(A(ch, DMA_CNT_IDX), 32'h0, e);
            wr(A(ch, DMA_CR_IDX), 32'h0000_0045, e);                          // EN, M2M, word
            repeat (4) @(posedge hclk);
            rd(A(ch, DMA_CR_IDX), d, e);   if (d[0]) bad++;                    // EN dropped
            rd(A(ch, DMA_STAT_IDX), d, e); if (!d[17] || d[15:0] != 0 || d[16]) bad++;
            rd(DMA_GSTAT_ADDR, d, e);      if (!d[8 + ch]) bad++;
            wr(A(ch, DMA_ICLR_IDX), 32'h0, e);                                // W1C: 0 changes nothing
            rd(A(ch, DMA_STAT_IDX), d, e); if (!d[17]) bad++;
            rd(A(ch, DMA_ICLR_IDX), d, e); if (d != 32'h0) bad++;              // ICLR reads 0
            wr(A(ch, DMA_ICLR_IDX), 32'h1, e);                                // clears COMPLETE
            rd(A(ch, DMA_STAT_IDX), d, e); if (d[17]) bad++;
            rd(DMA_GSTAT_ADDR, d, e);      if (d[8 + ch]) bad++;
            check(bad == 0, $sformatf("[F07] [F08] ch%0d: EN with CNT = 0 completes at once; ICLR is W1C and reads 0 (%0d errors)", ch, bad));
            wr(A(ch, DMA_CR_IDX), DMA_REG_RESET[DMA_CR_IDX], e);
        end

        // ---- 5. writes to read-only registers are ignored, no PSLVERR (AUD-13) ---------
        for (int ch = 0; ch < DMA_NCH; ch++) begin
            rd(A(ch, DMA_STAT_IDX), d, e);
            wr(A(ch, DMA_STAT_IDX), 32'hFFFF_FFFF, e);
            rd(A(ch, DMA_STAT_IDX), d2, e);
            check(!e && d2 == d, $sformatf("[F06] [AUD-13] ch%0d STAT: a write is ignored without PSLVERR", ch));
        end
        rd(DMA_GSTAT_ADDR, d, e);
        wr(DMA_GSTAT_ADDR, 32'hFFFF_FFFF, e);
        rd(DMA_GSTAT_ADDR, d2, e);
        check(!e && d2 == d, "[F08] [AUD-13] GSTAT: a write is ignored without PSLVERR");

        // ---- 6. every unmapped word offset answers PSLVERR and changes nothing ----------
        snapshot(s0, g0);
        bad = 0; n = 0;
        for (int a = 0; a < 4096; a += 4) begin
            if (is_reg(12'(a))) continue;
            n++;
            wr(12'(a), 32'hFFFF_FFFF, e); if (!e) bad++;
        end
        check(bad == 0, $sformatf("[F09] [N-6.6] a write to each of the %0d unmapped word offsets answers PSLVERR (%0d without)", n, bad));
        bad = 0;
        for (int a = 0; a < 4096; a += 4) begin
            if (is_reg(12'(a))) continue;
            rd(12'(a), d, e); if (!e || d != 32'h0) bad++;
        end
        check(bad == 0, $sformatf("[F09] a read of each unmapped word offset answers PSLVERR and reads 0 (%0d errors)", bad));
        // misaligned offsets of every register
        bad = 0;
        for (int ch = 0; ch < DMA_NCH; ch++)
            for (int r = 0; r < DMA_NREGS; r++)
                for (int o = 1; o < 4; o++) begin
                    wr(A(ch, r) + 12'(o), 32'hFFFF_FFFF, e); if (!e) bad++;
                end
        check(bad == 0, $sformatf("[F09] a write to each misaligned register offset answers PSLVERR (%0d without)", bad));
        snapshot(s1, g1);
        bad = 0;
        for (int ch = 0; ch < DMA_NCH; ch++) for (int r = 0; r < DMA_NREGS; r++) if (s1[ch][r] != s0[ch][r]) bad++;
        check(bad == 0 && g1 == g0, $sformatf("[F09] no register changed after the unmapped and misaligned writes (%0d differ)", bad));

        // ---- 7. channels do not alias ------------------------------------------------------
        for (int ch = 0; ch < DMA_NCH; ch++) begin
            wr(A(ch, DMA_SAR_IDX), 32'h1000_0000 * (ch + 1) + 32'h11, e);
            wr(A(ch, DMA_DAR_IDX), 32'h0100_0000 * (ch + 1) + 32'h22, e);
            wr(A(ch, DMA_CNT_IDX), 32'h0000_0100 * (ch + 1) + 32'h33, e);
        end
        bad = 0;
        for (int ch = 0; ch < DMA_NCH; ch++) begin
            rd(A(ch, DMA_SAR_IDX), d, e); if (d != 32'h1000_0000 * (ch + 1) + 32'h11) bad++;
            rd(A(ch, DMA_DAR_IDX), d, e); if (d != 32'h0100_0000 * (ch + 1) + 32'h22) bad++;
            rd(A(ch, DMA_CNT_IDX), d, e); if (d != 32'h0000_0100 * (ch + 1) + 32'h33) bad++;
        end
        check(bad == 0, $sformatf("[F11] the six channels' SAR, DAR and CNT do not alias (%0d errors)", bad));

        // ---- 8. back-to-back APB (no idle cycle between transfers) -----------------------
        @(posedge pclk);
        for (int ch = 0; ch < DMA_NCH; ch++) wr_bb(A(ch, DMA_SAR_IDX), 32'hA5A5_0000 + ch);
        bad = 0;
        for (int ch = 0; ch < DMA_NCH; ch++) begin rd_bb(A(ch, DMA_SAR_IDX), d); if (d != 32'hA5A5_0000 + ch) bad++; end
        apb_idle();
        check(bad == 0, $sformatf("[F10] back-to-back writes and reads land and read back (%0d errors)", bad));

        check(n_ahb == 0, $sformatf("no AHB transfer during the register tests (%0d)", n_ahb));
        $display("tb_dma_regs: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end
    initial begin #20_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
