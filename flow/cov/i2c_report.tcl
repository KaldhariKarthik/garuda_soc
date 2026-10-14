# i2c_report.tcl - coverage reports for the I2C from the merged UVM runs.
#     imc -exec flow/cov/i2c_report.tcl
# Loads sim/uvm_i2c/cov_work/scope/all, applies the waivers, writes four reports.
load -run sim/uvm_i2c/cov_work/scope/all
source flow/cov/i2c_exclusions.tcl
report -summary -inst garuda_i2c_top... -metrics block:expression:toggle:fsm:assertion -out sim/uvm_i2c/code_cov.txt
report -summary -inst garuda_i2c_top... -metrics toggle -exclComments -out sim/uvm_i2c/waivers_applied.txt
report -detail -metrics covergroup -out sim/uvm_i2c/func_cov.txt
report -detail -inst garuda_i2c_top... -metrics block:expression:toggle:assertion -uncovered -out sim/uvm_i2c/holes.txt
exit
