NAME = "debug"
BENCH = "tb/debug/filelist_debug.f"; FL_LINE = "-f rtl/debug/filelist.f"; TOP = "tb_debug"
MUTANTS = [
 ("M1 TAP: TLR does not select IDCODE", "rtl/debug/jtag_tap.sv", "        end else if (tlr_o) begin\n            ir_q <= IR_IDCODE;", "        end else if (1'b0) begin\n            ir_q <= IR_IDCODE;"),
 ("M2 TAP: Select-IR with TMS stays", "rtl/debug/tap_fsm.sv", "SELIR: st_next = tms_i ? ST_RESET : CAPIR;", "SELIR: st_next = tms_i ? SELIR : CAPIR;"),
 ("M3 DTM: busy not sticky (DBG-1 back)", "rtl/debug/debug_dtm.sv", "            busy_err <= 1'b1;  // sticky busy", "            busy_err <= 1'b0;  // sticky busy"),
 ("M4 DTM: request while busy", "rtl/debug/debug_dtm.sv", "    wire issue     = !tlr_i && upd_dmi && !busy && !busy_err;", "    wire issue     = !tlr_i && upd_dmi;"),
 ("M5 DM: unaligned SBDATA0-write starts a bus access", "rtl/debug/debug_module.sv", "    wire start_w = try_w && word_size && sadr_ok;", "    wire start_w = try_w && word_size;"),
 ("M5b DM: unaligned read-on-address starts a bus access", "rtl/debug/debug_module.sv", "    wire start_a = try_a && word_size && wadr_ok;", "    wire start_a = try_a && word_size;"),
 ("M5c DM: unaligned read-on-data starts a bus access", "rtl/debug/debug_module.sv", "    wire start_r = try_r && word_size && sadr_ok;", "    wire start_r = try_r && word_size;"),
 ("M6 DM: no autoincrement", "rtl/debug/debug_module.sv", "            sbaddr <= sbaddr + 32'd4;", "            sbaddr <= sbaddr;"),
 ("M7 DM: inactive DM still resets the hart", "rtl/debug/debug_module.sv", "assign hartreset_o = dmactive & grant_q;", "assign hartreset_o = grant_q;"),
 ("M8 SBA: address dropped before acceptance", "rtl/debug/sba_fsm.sv", "            S_ADDR: begin\n                if (hready_i) begin", "            S_ADDR: begin\n                if (1'b1) begin"),
]
