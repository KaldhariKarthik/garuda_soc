# gpio_report.tcl - coverage reports for the GPIO from the merged UVM runs.
#     imc -exec flow/cov/gpio_report.tcl
# Loads sim/uvm_gpio/cov_work/scope/all, applies the waivers, writes four reports.
load -run sim/uvm_gpio/cov_work/scope/all
source flow/cov/gpio_exclusions.tcl
report -summary -inst garuda_gpio_top... -metrics block:expression:toggle:fsm:assertion -out sim/uvm_gpio/code_cov.txt
report -summary -inst garuda_gpio_top... -metrics toggle -exclComments -out sim/uvm_gpio/waivers_applied.txt
report -detail -metrics covergroup -out sim/uvm_gpio/func_cov.txt
report -detail -inst garuda_gpio_top... -metrics block:expression:toggle:assertion -uncovered -out sim/uvm_gpio/holes.txt
report -detail -inst garuda_gpio_top... -metrics assertion -covered -out sim/uvm_gpio/assert_all.txt
exit
