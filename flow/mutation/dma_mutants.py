NAME = "dma"
BENCH = "tb/dma/filelist_dma_top.f"; FL_LINE = "-f rtl/dma/filelist.f"; TOP = "tb_dma_top"
MUTANTS_ALL = [
 ("M1 priority inverted", "rtl/dma/dma_arbiter.sv", "PRIO[BEST_W*c +: BEST_W] > best", "PRIO[BEST_W*c +: BEST_W] < best"),
 ("M2 ISRAM source not refused", "rtl/dma/dma_engine.sv", "    wire sar_bad = (sar[31:28] == 4'h0) || (sar[31:28] == 4'h1)", "    wire sar_bad = (sar[31:28] == 4'h1)"),
 ("M3 SAR advances on a failed beat", "rtl/dma/dma_chan.sv", "        end else if (done && sinc_q) begin", "        end else if ((done || err) && sinc_q) begin"),
 ("M4 one request, two beats", "rtl/dma/dma_chan.sv", "            if (beat_done_i) begin\n                taken_q <= 1'b1;", "            if (1'b0) begin\n                taken_q <= 1'b1;"),
 ("M5 ack one cycle", "rtl/dma/dma_top.sv", "parameter integer ACK_CYCLES = 32'd2", "parameter integer ACK_CYCLES = 32'd1"),
 ("M6 EN not cleared on error", "rtl/dma/dma_chan.sv", "    wire hw_clr_en = (done && last) || err;", "    wire hw_clr_en = (done && last);"),
 ("M7 MODE 3 stored", "rtl/dma/dma_chan.sv", "            if (wdata_i[2:1] != 2'b11) begin\n                mode_q <= wdata_i[2:1];", "            if (1'b1) begin\n                mode_q <= wdata_i[2:1];"),
 # AUD-13 (2026-10-13): a write to read-only STAT answers OKAY and changes nothing; the old
 # M8 (STAT write without PSLVERR) tested the rule before it. Now: the write lands in CR.
 ("M8 a write to read-only STAT lands in CR", "rtl/dma/dma_apb_slave.sv", "    assign wr_cr_o   = {6{wstb && reg_ == 3'd0}} & chsel;", "    assign wr_cr_o   = {6{wstb && (reg_ == 3'd0 || reg_ == 3'd4)}} & chsel;"),
]
MUTANTS = MUTANTS_ALL
