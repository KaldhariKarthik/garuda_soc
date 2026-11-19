# Planted defects of the AHB-to-APB bridge (tools/mutate.py flow/mutation/bridge_mutants.py)
NAME = "bridge"
BENCH = "tb/ahb2apb/filelist_ahb2apb.f"; FL_LINE = "-f rtl/ahb2apb/filelist.f"; TOP = "tb_ahb2apb"
MUTANTS = [
 ("M1 error lasts one cycle", "rtl/ahb2apb/brg_ahb_fsm.sv", "                hresp_o = 1'b1;\n                hstate_next = H_ERR2;", "                hresp_o = 1'b1;\n                hstate_next = H_IDLE;"),
 ("M2 absent window starts an APB transfer", "rtl/ahb2apb/ahb2apb_bridge.sv", "    wire       allowed = win_ok && word_ok;", "    wire       allowed = word_ok;"),
 ("M3 timeout one cycle late", "rtl/ahb2apb/ahb2apb_apb_fsm.sv", "(to_cnt == TO_CNT_W'(TIMEOUT - 32'd1))", "(to_cnt == TO_CNT_W'(TIMEOUT))"),
 ("M4 write data present on a read", "rtl/ahb2apb/ahb2apb_bridge.sv", "        end else if (capture && !hwrite_i) begin\n            wdata_cap <= 32'd0;", "        end else if (1'b0) begin\n            wdata_cap <= 32'd0;"),
 ("M5 PENABLE together with PSEL", "rtl/ahb2apb/ahb2apb_apb_fsm.sv", "            psel_o <= win_hot;\n", "            psel_o <= win_hot;\n            penable_o <= 1'b1;\n"),
 ("M6 capture moves during the transfer", "rtl/ahb2apb/ahb2apb_bridge.sv", "        end else if (capture) begin\n            win_cap <= win;", "        end else if (capture || xfer) begin\n            win_cap <= win;"),
 ("M7 slave error answered OKAY", "rtl/ahb2apb/brg_ahb_fsm.sv", "hstate_next = apb_err_i ? H_ERR1 : H_OK;", "hstate_next = H_OK;"),
 ("M8 two windows selected", "rtl/ahb2apb/ahb2apb_apb_fsm.sv", "            psel_o <= win_hot;\n", "            psel_o <= win_hot | 12'd2;\n"),
]
