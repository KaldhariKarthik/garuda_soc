# spis_report.tcl - coverage reports for the SPI slave from the merged UVM runs.
#     imc -exec flow/cov/spis_report.tcl
# Loads sim/uvm_spis/cov_work/scope/all, applies the waivers, writes four reports.
load -run sim/uvm_spis/cov_work/scope/all
source flow/cov/spis_exclusions.tcl
report -summary -inst garuda_spis_top... -metrics block:expression:toggle:fsm:assertion -out sim/uvm_spis/code_cov.txt
report -summary -inst garuda_spis_top... -metrics toggle -exclComments -out sim/uvm_spis/waivers_applied.txt
report -detail -metrics covergroup -out sim/uvm_spis/func_cov.txt
report -detail -inst garuda_spis_top... -metrics block:expression:toggle:assertion -uncovered -out sim/uvm_spis/holes.txt
exit
