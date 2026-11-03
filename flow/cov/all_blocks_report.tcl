# all_blocks_report.tcl - code and functional coverage of every block, from the
# merged database sim/cov_hand/all (see ~/Desktop/garuda_cov_every_block.md).
#     imc -exec flow/cov/all_blocks_report.tcl
# Writes code_raw.txt (as measured), code_waived.txt (after the written waivers
# of the seven blocks that have them), func.txt (UVM covergroups), func_types.txt (the bound
# covergroups, by type) and func_detail.txt (every bin, hit or not) in sim/cov_hand.
load -run sim/cov_hand/all
report -summary -inst *... -metrics block:expression:toggle:fsm:assertion -out sim/cov_hand/code_raw.txt
source flow/cov/clic_exclusions.tcl
source flow/cov/timers_exclusions.tcl
source flow/cov/crg_exclusions.tcl
source flow/cov/pwm_exclusions.tcl
source flow/cov/gpio_exclusions.tcl
source flow/cov/i2c_exclusions.tcl
source flow/cov/spis_exclusions.tcl
report -summary -inst *... -metrics block:expression:toggle:fsm:assertion -out sim/cov_hand/code_waived.txt
report -summary -inst uvm_pkg... -metrics covergroup -out sim/cov_hand/func.txt
# the covergroups bound into the RTL (bridge, AHB, DMA, debug, memories, SPI master, DSU, shim, chip, core)
report -summary -type -metrics covergroup -out sim/cov_hand/func_types.txt
report -detail -metrics covergroup -all -out sim/cov_hand/func_detail.txt
exit
