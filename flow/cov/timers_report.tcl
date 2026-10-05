# timers_report.tcl - coverage reports for the timers and watchdog from the merged UVM runs.
#     imc -exec flow/cov/timers_report.tcl
# Loads sim/uvm_timers/cov_work/scope/all, applies the waivers, writes four reports.
load -run sim/uvm_timers/cov_work/scope/all
source flow/cov/timers_exclusions.tcl
report -summary -inst timers_top... -metrics block:expression:toggle:fsm:assertion -out sim/uvm_timers/code_cov.txt
report -summary -inst timers_top... -metrics toggle -exclComments -out sim/uvm_timers/waivers_applied.txt
report -detail -metrics covergroup -out sim/uvm_timers/func_cov.txt
report -detail -inst timers_top... -metrics assertion -out sim/uvm_timers/assert.txt
exit
