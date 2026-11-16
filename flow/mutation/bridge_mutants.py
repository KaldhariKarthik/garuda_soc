# Planted defects of the AHB-to-APB bridge (tools/mutate.py flow/mutation/bridge_mutants.py)
NAME = "bridge"
FILES = ["rtl/ahb2apb/ahb2apb_fabric.sv", "rtl/ahb2apb/ahb2apb_apb_fsm.sv", "rtl/ahb2apb/ahb2apb_bridge.sv", "rtl/ahb2apb/ahb2apb_bridge_sva.sv"]
BENCH = "tb/ahb2apb/filelist_ahb2apb.f"; FL_LINE = "-f rtl/ahb2apb/filelist.f"; TOP = "tb_ahb2apb"
MUTANTS = [
 ("M1 error lasts one cycle", "rtl/ahb2apb/ahb2apb_bridge.sv", "H_ERR1:  hstate <= H_ERR2;", "H_ERR1:  hstate <= H_IDLE;"),
 ("M2 absent window starts an APB transfer", "rtl/ahb2apb/ahb2apb_bridge.sv", "if (!win_ok || !word_ok) begin", "if (!word_ok) begin"),
 ("M3 timeout one cycle late", "rtl/ahb2apb/ahb2apb_apb_fsm.sv", "to_cnt == TIMEOUT - 1", "to_cnt == TIMEOUT"),
 ("M4 write data present on a read", "rtl/ahb2apb/ahb2apb_apb_fsm.sv", "write_i ? wdata_i : 32'd0", "wdata_i"),
 ("M5 PENABLE together with PSEL", "rtl/ahb2apb/ahb2apb_apb_fsm.sv", "psel_o   <= 12'd1 << win_i;", "psel_o   <= 12'd1 << win_i; penable_o <= 1'b1;"),
 ("M6 capture moves during the transfer", "rtl/ahb2apb/ahb2apb_bridge.sv", "                H_WAIT: begin\n", "                H_WAIT: begin\n                    addr_cap <= haddr_i[11:0];\n"),
 ("M7 slave error answered OKAY", "rtl/ahb2apb/ahb2apb_bridge.sv", "hstate   <= apb_err ? H_ERR1 : H_OK;", "hstate   <= H_OK;"),
 ("M8 two windows selected", "rtl/ahb2apb/ahb2apb_apb_fsm.sv", "psel_o   <= 12'd1 << win_i;", "psel_o   <= (12'd1 << win_i) | 12'd2;"),
]
