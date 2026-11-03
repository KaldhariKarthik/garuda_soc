NAME = "dma"
FILES = ["rtl/dma/dma_chan.v", "rtl/dma/dma_arbiter.v", "rtl/dma/dma_engine.v", "rtl/dma/dma_apb_slave.v", "rtl/dma/dma_top.v", "rtl/dma/dma_sva.sv"]
BENCH = "tb/dma/filelist_dma_top.f"; FL_LINE = "-f rtl/dma/filelist.f"; TOP = "tb_dma_top"
MUTANTS_ALL = [
 ("M1 priority inverted", "rtl/dma/dma_arbiter.v", "PRIO[3*n +: 3] > best", "PRIO[3*n +: 3] < best"),
 ("M2 ISRAM source not refused", "rtl/dma/dma_engine.v", "wire sar_bad = (sar[31:28] == 4'h0) || (sar[31:28] == 4'h1);", "wire sar_bad = (sar[31:28] == 4'h1);"),
 ("M3 SAR advances on a failed beat", "rtl/dma/dma_chan.v", "else if (beat_done_i && sinc_q) sar_q <= sar_q + step;", "else if ((beat_done_i || beat_err_i) && sinc_q) sar_q <= sar_q + step;"),
 ("M4 one request, two beats", "rtl/dma/dma_chan.v", "else if (beat_done_i) taken_q <= 1'b1;", "else if (1'b0) taken_q <= 1'b1;"),
 ("M5 ack one cycle", "rtl/dma/dma_top.v", "parameter integer ACK_CYCLES = 2", "parameter integer ACK_CYCLES = 1"),
 ("M6 EN not cleared on error", "rtl/dma/dma_chan.v", "wire hw_clr_en = (beat_done_i && last) || beat_err_i;", "wire hw_clr_en = (beat_done_i && last);"),
 ("M7 MODE 3 stored", "rtl/dma/dma_chan.v", "if (wdata_i[2:1] != 2'b11) mode_q <= wdata_i[2:1];", "mode_q <= wdata_i[2:1];"),
 ("M8 STAT writable (no PSLVERR)", "rtl/dma/dma_apb_slave.v", "(pwrite_i & (gstat | (chan_rgn & reg_ == 3'd4)))", "(pwrite_i & gstat)"),
]
MUTANTS = MUTANTS_ALL
