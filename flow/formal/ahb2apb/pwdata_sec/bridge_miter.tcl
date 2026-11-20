# =============================================================================
# bridge_miter.tcl - the 8db2380 bridge (PWDATA from a flop, HAL CBPAHI) against
# the b21ef9a bridge on the same inputs, both from reset. tools/sec_rtl.py cannot
# prove this one: the new PWDATA is zero, not stale write data, in the cycles
# between a write's capture and its send, where APB gives PWDATA no meaning. So
# every output is compared in every cycle except PWDATA, compared whenever
# PSEL && PWRITE; c_differ shows the cycle where the two differ exists.
#
# Run from the repository root (Cadence environment loaded):
#   /home/install/JASPER/bin/jg -allow_unsupported_OS -fpv -batch -no_jges -proj sim/bridge_miter/jgproject flow/formal/ahb2apb/pwdata_sec/bridge_miter.tcl
# Result 2026-11-20: 9 proven, 3 covered, 0 cex (bridge_miter.result.txt).
# =============================================================================
file mkdir sim/bridge_miter
exec git show b21ef9a:rtl/ahb2apb/ahb2apb_bridge.sv | sed {s/^module ahb2apb_bridge\>/module ahb2apb_bridge_old/} > sim/bridge_miter/bridge_old.sv
analyze -sv09 +incdir+rtl/include rtl/common/garuda_pkg.sv rtl/ahb2apb/ahb2apb_fabric.sv rtl/ahb2apb/apb_phase_fsm.sv rtl/ahb2apb/ahb2apb_apb_fsm.sv rtl/ahb2apb/brg_ahb_fsm.sv rtl/ahb2apb/ahb2apb_bridge.sv sim/bridge_miter/bridge_old.sv flow/formal/ahb2apb/pwdata_sec/bridge_miter.sv
elaborate -top bridge_miter
clock hclk
clock pclk -factor 2 -phase 1
reset -expression {!rst_n}
prove -all -time_limit 1800s
report -summary
exit
