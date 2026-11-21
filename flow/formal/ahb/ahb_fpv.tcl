# =============================================================================
# ahb_fpv.tcl - formal proof of the AHB-Lite interconnect's properties
#   rtl/ahb/ahb_interconnect_sva.sv
#
#   /home/install/JASPER/bin/jg -allow_unsupported_OS -fpv -batch -no_jges \
#       -proj sim/formal_ahb/jgproject flow/formal/ahb/ahb_fpv.tcl
#
# One clock. The four masters and four slaves are free inputs constrained by the
# environment of the SymbiYosys suite, tb/ahb/formal/ahb_fv_env.sv (FA-1..FA-3, and
# FA-4: a master cancels its next transfer after the first cycle of its own ERROR,
# the condition under which AHB-7 cannot occur, D-32). AHB7_FIND=1 drops FA-4: the
# AHB-7 detectors (a_held_resp_okay, a_master_err_shape, and a_slave_addr_stable /
# a_addr_phase_stable when the master then cancels) must then fail.
# FL names a different file list (a mutant).
# 2026-11-21 (TOOL-A34): until then this script loaded no environment; its last
# result (2026-10-15, 20 assertions) predates ahb_ic_props_a.sv.
# =============================================================================
set FL rtl/ahb/filelist.f
if {[info exists ::env(FL)]} { set FL $::env(FL) }
set FILES [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $FL]] "\n"]
analyze -sv09 +incdir+rtl/ahb {*}$FILES
if {[info exists ::env(AHB7_FIND)] && $::env(AHB7_FIND)} {
    analyze -sv09 tb/ahb/formal/ahb_fv_env.sv
} else {
    analyze -sv09 +define+AHB_FV_CANCEL_ON_ERROR tb/ahb/formal/ahb_fv_env.sv
}
elaborate -top ahb_interconnect
clock hclk
reset -expression {!hreset_n}
prove -all -time_limit 600s
report -summary
source flow/formal/common.tcl
set PROPS sim/formal_ahb/props.txt
if {[info exists ::env(PROPS)]} { set PROPS $::env(PROPS) }
file mkdir [file dirname $PROPS]
list_props $PROPS
exit
