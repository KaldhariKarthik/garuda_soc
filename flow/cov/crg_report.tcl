# crg_report.tcl - coverage reports for the clock divider and the reset controller from the merged UVM runs.
#     imc -exec flow/cov/crg_report.tcl
# Loads sim/uvm_crg/cov_work/scope/all, applies the waivers, writes four reports.
load -run sim/uvm_crg/cov_work/scope/all
source flow/cov/crg_exclusions.tcl
report -summary -inst clk_div... reset_ctrl... -metrics block:expression:toggle:fsm:assertion -out sim/uvm_crg/code_cov.txt
report -summary -inst reset_ctrl... -metrics toggle -exclComments -out sim/uvm_crg/waivers_applied.txt
report -detail -metrics covergroup -out sim/uvm_crg/func_cov.txt
report -detail -inst clk_div... reset_ctrl... -metrics block:expression:toggle:assertion -uncovered -out sim/uvm_crg/holes.txt
report -detail -inst clk_div... reset_ctrl... -metrics assertion -covered -out sim/uvm_crg/assert_all.txt
exit
