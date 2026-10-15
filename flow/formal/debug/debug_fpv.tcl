# =============================================================================
# debug_fpv.tcl - formal proof of the debug block's properties (rtl/debug/debug_sva.sv)
#
#   /home/install/JASPER/bin/jg -allow_unsupported_OS -fpv -batch -no_jges \
#       -proj sim/formal_debug/jgproject flow/formal/debug/debug_fpv.tcl
#
# Two unrelated clocks: tck (both edges: TDO changes on the falling edge) and hclk.
# Free: TMS, TDI, the DSU taps, the AHB slave (two-cycle ERROR).
# FL = another file list (a mutant), PROPS = where the status list goes.
# =============================================================================
set FL rtl/debug/filelist.f
if {[info exists ::env(FL)]} { set FL $::env(FL) }
set FILES [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $FL]] "\n"]
analyze -sv09 +incdir+rtl/include {*}$FILES
elaborate -top debug_top
clock tck_i -both_edges
clock hclk_i
reset -expression {!por_n_i} {!dm_rst_n_i}
prove -all -time_limit 900s
report -summary
source flow/formal/common.tcl
set PROPS sim/formal_debug/props.txt
if {[info exists ::env(PROPS)]} { set PROPS $::env(PROPS) }
file mkdir [file dirname $PROPS]
list_props $PROPS
exit
