# =============================================================================
# crg_exclusions.tcl - coverage waivers for blocks 22 and 23, the clock divider
# and the reset controller.
#
# Applied in IMC after loading the merged run:
#     imc -exec flow/cov/crg_report.tcl
# or typed at the IMC prompt. Every line has its reason. Sign-off criterion 3
# (flow/0_signoff_criteria.md): code coverage 100% after the waivers below.
#
# Two reasons cover everything here:
#   1. The four registers of this window use bits 9:8 and 4:0 only (CLKRST
#      section 6): the read-data bits listed are 0 in every register. Checked
#      on every read by the scoreboard.
#   2. PREADY is tied high (AHB2APB 7.5); checked by a_pready.
# The clock divider itself has no waiver; two lines waive a guard inside its checker.
# =============================================================================
exclude -inst reset_ctrl -toggle prdata_o\[10\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[10\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[11\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[11\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[12\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[12\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[13\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[13\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[14\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[14\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[15\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[15\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[16\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[16\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[17\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[17\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[18\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[18\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[19\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[19\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[20\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[20\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[21\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[21\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[22\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[22\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[23\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[23\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[24\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[24\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[25\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[25\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[26\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[26\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[27\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[27\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[28\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[28\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[29\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[29\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[30\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[30\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[31\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[31\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[7\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[7\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[6\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[6\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle prdata_o\[5\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl.u_apb -toggle prdata_o\[5\] -comment "read-data bit that is 0 in every register of this window: constant by specification, checked by the scoreboard on every read"
exclude -inst reset_ctrl -toggle pready_o -comment "PREADY is tied high, no wait states: checked by a_pready and sb_pready"
exclude -inst reset_ctrl.u_apb -toggle pready_o -comment "PREADY is tied high, no wait states: checked by a_pready and sb_pready"
exclude -inst reset_ctrl.u_reset_ctrl_sva -toggle pready_o -comment "PREADY is tied high, no wait states: checked by a_pready and sb_pready"
exclude -inst clk_div.u_clk_div_sva -expression 1.1 -comment "a guard in the checker, not design logic: the reference period is measured before hclk first moves, so the case reference-period-unknown with an hclk edge already seen does not occur"
exclude -inst clk_div.u_clk_div_sva -expression 4.1 -comment "the same guard for pclk in the checker, not design logic"
