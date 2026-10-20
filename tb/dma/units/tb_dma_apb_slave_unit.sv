`timescale 1ns/1ps
// =============================================================================
// tb_dma_apb_slave_unit.sv -- dma_apb_slave on its own (Track A wrap-up
// 2026-10-12), against GARUDA-DMA-SPEC-001 section 6 and the rulings:
//   - map: channel n at 0x20*n (n < 6): CR 0x0, SAR 0x4, DAR 0x8, CNT 0xC,
//     STAT 0x10 (read-only), ICLR 0x14 (write-only, reads 0); GSTAT at 0x100
//     (read-only) = {ERROR[21:16], COMPLETE[13:8], ACTIVE[5:0]} of the channels
//   - a write to a writable channel register gives exactly ONE hclk strobe on that
//     register of that channel, carrying PWDATA, and nothing else (R-3, D-16)
//   - [N-6.6] / AUD-13: a write to STAT or GSTAT is ignored with no error;
//     PSLVERR only for an access that hits nothing (unmapped, misaligned,
//     offsets 0x18 / 0x1C, channel 6 / 7, above 0x100)
//   - PREADY is always 1; a read returns the register as it was in the setup phase
// Every offset 0x000..0x13C and some far ones, read and write, aligned and not,
// with random register contents; back-to-back accesses. pclk = hclk / 2, made in
// the same time step as hclk (TB-44).
// =============================================================================
module tb_dma_apb_slave_unit;
    logic hclk = 0, pclk = 0, rst_n = 0;
    always #2 hclk = ~hclk;
    initial begin #2; forever begin pclk = ~pclk; #4; end end
    logic psel = 0, penable = 0, pwrite = 0;
    logic [11:0] paddr = 0;
    logic [31:0] pwdata = 0;
    wire  [31:0] prdata, wdata;
    wire  pready, pslverr;
    wire  [5:0] wcr, wsar, wdar, wcnt, wiclr;
    logic [191:0] cr = 0, sar = 0, dar = 0, cnt = 0, stat = 0;
    dma_apb_slave dut (.hclk_i(hclk), .hreset_n_i(rst_n), .pclk_i(pclk), .preset_n_i(rst_n),
        .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite), .paddr_i(paddr), .pwdata_i(pwdata),
        .prdata_o(prdata), .pready_o(pready), .pslverr_o(pslverr), .wr_cr_o(wcr), .wr_sar_o(wsar),
        .wr_dar_o(wdar), .wr_cnt_o(wcnt), .wr_iclr_o(wiclr), .wdata_o(wdata),
        .cr_i(cr), .sar_i(sar), .dar_i(dar), .cnt_i(cnt), .stat_i(stat));
    int checks = 0, fails = 0;
    task automatic check(input bit c, input string s);
        checks++;
        if (!c) begin fails++; if (fails <= 12) $display("[FAIL] %s", s); end
    endtask
    // strobe monitor (hclk)
    int n_stb; logic [4:0] stb_reg [$]; logic [2:0] stb_ch [$]; logic [31:0] stb_data [$];
    always @(posedge hclk) if (rst_n) begin
        automatic logic [29:0] all = {wiclr, wcnt, wdar, wsar, wcr};
        for (int k = 0; k < 30; k++) if (all[k]) begin
            n_stb++; stb_reg.push_back(5'(k / 6)); stb_ch.push_back(3'(k % 6)); stb_data.push_back(wdata);
        end
    end
    function automatic bit hits(input [11:0] a, output int ch, output int r);
        ch = a[7:5]; r = a[4:2];
        if (a == 12'h100) begin r = 6; return 1; end
        return a[11:8] == 4'h0 && a[1:0] == 2'b00 && ch < 6 && r <= 5;
    endfunction
    function automatic [31:0] gstat();
        logic [31:0] g = 0;
        for (int n = 0; n < 6; n++) begin g[n] = stat[32*n + 16]; g[8 + n] = stat[32*n + 17]; g[16 + n] = stat[32*n + 18]; end
        return g;
    endfunction
    function automatic [31:0] reg_val(input int ch, input int r);
        case (r)
            0: return cr[32*ch +: 32];  1: return sar[32*ch +: 32]; 2: return dar[32*ch +: 32];
            3: return cnt[32*ch +: 32]; 4: return stat[32*ch +: 32]; 6: return gstat(); default: return 0;
        endcase
    endfunction
    task automatic access(input bit wr, input [11:0] a, input [31:0] d, input bit b2b);
        int ch, r, n0;
        bit h = hits(a, ch, r);
        logic [31:0] want_rd;
        if (!b2b) @(posedge pclk);
        #0.1 psel = 1; pwrite = wr; paddr = a; pwdata = d; penable = 0;
        want_rd = reg_val(ch, r);
        n0 = n_stb; stb_reg.delete(); stb_ch.delete(); stb_data.delete();
        @(posedge pclk); #0.1 penable = 1;
        #0.5 check(pslverr === !h && pready === 1'b1,
                   $sformatf("%s %03h: PSLVERR %0d (expected %0d), PREADY %0d", wr ? "write" : "read", a, pslverr, !h, pready));
        @(posedge pclk); #0.1 psel = 0; penable = 0; pwrite = 0;
        repeat (2) @(posedge hclk); #0.1;
        if (wr) begin
            bit want_stb = h && r != 4 && r != 6;
            check(n_stb - n0 == (want_stb ? 1 : 0),
                  $sformatf("write %03h: %0d strobe(s), expected %0d", a, n_stb - n0, want_stb ? 1 : 0));
            if (want_stb && stb_reg.size() == 1)
                check(stb_reg[0] == (r == 5 ? 4 : r) && stb_ch[0] == ch && stb_data[0] == d,
                      $sformatf("write %03h: strobe reg %0d ch %0d data %08h, expected reg %0d ch %0d data %08h",
                                a, stb_reg[0], stb_ch[0], stb_data[0], r == 5 ? 4 : r, ch, d));
        end else begin
            check(n_stb == n0, $sformatf("read %03h: a strobe", a));
            if (h) check(prdata === want_rd, $sformatf("read %03h: %08h, expected %08h", a, prdata, want_rd));
        end
    endtask
    initial begin
        repeat (4) @(posedge hclk); rst_n = 1;
        for (int pass = 0; pass < 4; pass++) begin
            foreach (cr[i]) begin cr[i] = $urandom(); sar[i] = $urandom(); dar[i] = $urandom(); cnt[i] = $urandom(); stat[i] = $urandom(); end
            for (int a = 0; a < 12'h140; a++) begin
                access(1'b0, 12'(a), 0, 0);
                access(1'b1, 12'(a), $urandom(), 0);
            end
            for (int k = 0; k < 64; k++) begin
                automatic logic [11:0] a = 12'($urandom_range(4095, 0));
                access($urandom_range(1, 0), a, $urandom(), 0);
            end
            for (int k = 0; k < 64; k++)                                  // back to back
                access($urandom_range(1, 0), 12'(32 * $urandom_range(5, 0) + 4 * $urandom_range(5, 0)), $urandom(), 1);
        end
        $display("tb_dma_apb_slave_unit: checks=%0d FAIL=%0d", checks, fails);
        $display("RESULT: %s", (fails == 0 && checks > 0) ? "PASSED" : "FAILED");
        $finish;
    end
endmodule
