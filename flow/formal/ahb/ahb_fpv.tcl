# =============================================================================
# ahb_fpv.tcl - formal proof of the AHB-Lite interconnect's properties
#   rtl/ahb/ahb_interconnect_sva.sv
#
#   /home/install/JASPER/bin/jg -allow_unsupported_OS -fpv -batch -no_jges \
#       -proj sim/formal_ahb/jgproject flow/formal/ahb/ahb_fpv.tcl
#
# One clock. The four masters and four slaves are free inputs constrained only by
# the assume_* of the sva file: a master holds its address phase until accepted,
# a slave's ERROR is two cycles. FL names a different file list (a mutant).
# =============================================================================
set FL rtl/ahb/filelist.f
if {[info exists ::env(FL)]} { set FL $::env(FL) }
set FILES [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $FL]] "\n"]
analyze -sv09 +incdir+rtl/ahb {*}$FILES
elaborate -top ahb_interconnect
clock hclk_i
reset -expression {!hreset_n_i}
prove -all -time_limit 600s
report -summary
source flow/formal/common.tcl
file mkdir [file dirname sim/formal_ahb/props.txt]
list_props sim/formal_ahb/props.txt
exit
