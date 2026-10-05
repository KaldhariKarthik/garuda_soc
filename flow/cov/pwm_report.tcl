# pwm_report.tcl - coverage reports for the PWM from the merged UVM runs.
#     imc -exec flow/cov/pwm_report.tcl
# Loads sim/uvm_pwm/cov_work/scope/all, applies the waivers, writes four reports.
load -run sim/uvm_pwm/cov_work/scope/all
source flow/cov/pwm_exclusions.tcl
report -summary -inst garuda_pwm_top... -metrics block:expression:toggle:fsm:assertion -out sim/uvm_pwm/code_cov.txt
report -summary -inst garuda_pwm_top... -metrics toggle -exclComments -out sim/uvm_pwm/waivers_applied.txt
report -detail -metrics covergroup -out sim/uvm_pwm/func_cov.txt
report -detail -inst garuda_pwm_top... -metrics block:expression:toggle:assertion -uncovered -out sim/uvm_pwm/holes.txt
exit
