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
# the APB master drives its signals from pclk: they change only at a pclk edge
clock -rate {psel_i penable_i pwrite_i paddr_i pwdata_i} pclk_i
reset -expression {!hreset_n_i} {!preset_n_i}
# The APB bus is idle while either reset is asserted, and an access starts with its setup
# phase (the same assumptions block_fpv.tcl gives every APB block). Without them the first
# cycle after reset could be the middle of an access begun in reset, with its address
# changing: the counterexample of a_strobe_once on 2026-11-04.
# (a clocked assumption is not applied during the reset analysis, so the rate-limited APB
# inputs could leave reset in the middle of an access: -reset constrains that phase)
assume -reset -name assume_apb_idle_at_reset {!psel_i && !penable_i}
assume -name assume_apb_setup_first  {@(posedge hclk_i) disable iff (!hreset_n_i) $rose(psel_i) |-> !penable_i}
# The APB rules again on hclk with |-> : the pclk forms in dma_sva.sv use |=> and are only
# checked at the next pclk edge, so a counterexample could end one hclk before it. An
# access phase follows its setup phase and lasts one pclk (two hclk); address, direction
# and data do not change from setup to access.
assume -name assume_apb_access_after_setup_h {@(posedge hclk_i) disable iff (!hreset_n_i) (psel_i && penable_i) |-> ($past(psel_i && !penable_i) || $past(psel_i && !penable_i, 2))}
assume -name assume_apb_access_stable_h {@(posedge hclk_i) disable iff (!hreset_n_i) (psel_i && penable_i) |-> ($stable(paddr_i) && $stable(pwrite_i) && $stable(pwdata_i))}
prove -all -time_limit 900s
report -summary
source flow/formal/common.tcl
set PROPS sim/formal_dma/props.txt
if {[info exists ::env(PROPS)]} { set PROPS $::env(PROPS) }
file mkdir [file dirname $PROPS]
list_props $PROPS
exit
