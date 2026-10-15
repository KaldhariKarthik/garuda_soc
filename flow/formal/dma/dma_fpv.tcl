# =============================================================================
# dma_fpv.tcl - formal proof of the DMA's properties (rtl/dma/dma_sva.sv)
#
#   /home/install/JASPER/bin/jg -allow_unsupported_OS -fpv -batch -no_jges \
#       -proj sim/formal_dma/jgproject flow/formal/dma/dma_fpv.tcl
#
# hclk is the base clock, pclk is hclk / 2 (D-5). Free: the APB master (legal
# transfers only), the AHB slave (two-cycle ERROR), the six request lines.
# FL = another file list (a mutant), PROPS = where the status list goes.
# =============================================================================
set FL rtl/dma/filelist.f
if {[info exists ::env(FL)]} { set FL $::env(FL) }
set FILES [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $FL]] "\n"]
analyze -sv09 +incdir+rtl/include {*}$FILES
elaborate -top dma_top
clock hclk_i
clock pclk_i -factor 2 -phase 1
reset -expression {!hreset_n_i} {!preset_n_i}
prove -all -time_limit 900s
report -summary
source flow/formal/common.tcl
set PROPS sim/formal_dma/props.txt
if {[info exists ::env(PROPS)]} { set PROPS $::env(PROPS) }
file mkdir [file dirname $PROPS]
list_props $PROPS
exit
