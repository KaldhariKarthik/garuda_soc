# clic_report.tcl - coverage reports for the CLIC from the merged UVM runs.
#     imc -exec flow/cov/clic_report.tcl
# Loads sim/uvm_clic/cov_work/scope/all, applies the waivers, writes three reports.
load -run sim/uvm_clic/cov_work/scope/all
source flow/cov/clic_exclusions.tcl
report -summary -inst clic_top... -metrics block:expression:toggle:fsm:assertion -out sim/uvm_clic/code_cov.txt
report -summary -inst clic_top... -metrics toggle -exclComments -out sim/uvm_clic/waivers_applied.txt
report -detail -metrics covergroup -out sim/uvm_clic/func_cov.txt
exit
