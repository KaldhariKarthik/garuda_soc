# =============================================================================
# mem_fpv.tcl - formal proof of the memory properties (rtl/mem/mem_sva.sv) on the
# shared AHB front end with a 16-word array (flow/formal/mem/mem_fv_top.sv).
#
#   /home/install/JASPER/bin/jg -allow_unsupported_OS -fpv -batch -no_jges \
#       -proj sim/formal_mem/jgproject flow/formal/mem/mem_fpv.tcl
#
# FORMAL is defined: the data check tracks one word chosen by the tool.
# WRITABLE=0 proves the ROM configuration. FL = another file list (a mutant).
# =============================================================================
set FL rtl/mem/filelist.f
if {[info exists ::env(FL)]} { set FL $::env(FL) }
set W 1
if {[info exists ::env(WRITABLE)]} { set W $::env(WRITABLE) }
set FILES [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $FL]] "\n"]
set KEEP {}
foreach f $FILES { if {[string match *sram_wrapper.v $f] || [string match *ahb_mem_slave_if.v $f] || [string match *mem_sva.sv $f]} { lappend KEEP $f } }
analyze -sv09 +define+FORMAL +incdir+rtl/mem {*}$KEEP flow/formal/mem/mem_fv_top.sv
elaborate -top mem_fv_top -parameter WRITABLE $W
clock hclk_i
reset -expression {!hreset_n_i}
prove -all -time_limit 900s
report -summary
source flow/formal/common.tcl
set PROPS sim/formal_mem/props.txt
if {[info exists ::env(PROPS)]} { set PROPS $::env(PROPS) }
file mkdir [file dirname $PROPS]
list_props $PROPS
exit
