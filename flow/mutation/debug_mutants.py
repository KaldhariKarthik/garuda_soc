NAME = "debug"
FILES = ["rtl/debug/jtag_tap.v", "rtl/debug/dtm.v", "rtl/debug/dmi_cdc.v", "rtl/debug/sba_master.v", "rtl/debug/debug_module.v", "rtl/debug/debug_top.v", "rtl/debug/debug_sva.sv"]
BENCH = "tb/debug/filelist_debug.f"; FL_LINE = "-f rtl/debug/filelist.f"; TOP = "tb_debug"
MUTANTS = [
 ("M1 TAP: TLR does not select IDCODE", "rtl/debug/jtag_tap.v", "if (st == TLR)   ir_q  <= IR_IDCODE;", "if (1'b0)   ir_q  <= IR_IDCODE;"),
 ("M2 TAP: Select-IR with TMS stays", "rtl/debug/jtag_tap.v", "SELIR: st <= tms_i ? TLR   : CAPIR;", "SELIR: st <= tms_i ? SELIR : CAPIR;"),
 ("M3 DTM: busy not sticky (DBG-1 back)", "rtl/debug/dtm.v", "if (busy) dmistat <= 2'd3;\n", "if (1'b0) dmistat <= 2'd3;\n"),
 ("M4 DTM: request while busy", "rtl/debug/dtm.v", "if (busy)                  dmistat <= 2'd3; // sticky busy\n                    else if (dmistat == 2'd0) begin", "if (1'b0)                  dmistat <= 2'd3; // sticky busy\n                    else if (1'b1) begin"),
 ("M5 DM: unaligned address not refused", "rtl/debug/debug_module.v", "else if (sbaddr[1:0] != 0)  sberror <= 3'd2;", "else if (1'b0)  sberror <= 3'd2;"),
 ("M6 DM: no autoincrement", "rtl/debug/debug_module.v", "if (sbautoinc)      sbaddr <= sbaddr + 32'd4;", "if (sbautoinc)      sbaddr <= sbaddr;"),
 ("M7 DM: inactive DM still resets the hart", "rtl/debug/debug_module.v", "assign hartreset_o = dmactive & hartreset;", "assign hartreset_o = hartreset;"),
 ("M8 SBA: address dropped before acceptance", "rtl/debug/sba_master.v", "S_ADDR: if (hready_i) begin", "S_ADDR: if (1'b1) begin"),
]
