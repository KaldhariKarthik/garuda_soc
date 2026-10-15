# =============================================================================
# uart_fpv.tcl - formal proof of the garuda_uart_top wrapper's properties, with the
# vendored engine inside it (not edited, D-22) and the shim.
#
#   /home/install/JASPER/bin/jg -allow_unsupported_OS -fpv -batch -no_jges \
#       -proj sim/formal_uart/jgproject flow/formal/uart/uart_fpv.tcl
#
# One clock, pclk. The APB master, the pins and the DMA acknowledge are free, except
# that the APB master makes legal transfers. FL = another file list, PROPS = output.
# =============================================================================
set FL rtl/uart/filelist.f
if {[info exists ::env(FL)]} { set FL $::env(FL) }
set FILES [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $FL]] "\n"]
set INCS {}
foreach d [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $FL --incdirs]] " "] {
    if {$d ne ""} { lappend INCS +incdir+[string range $d 2 end] }
}
analyze -sv09 +incdir+rtl/include +incdir+rtl/common {*}$INCS {*}$FILES
elaborate -top garuda_uart_top
clock pclk_i
reset -expression {!preset_n_i}
assume -name assume_apb_legal {@(posedge pclk_i) disable iff (!preset_n_i) (psel_i && !penable_i) |=> (psel_i && penable_i && $stable(paddr_i) && $stable(pwrite_i) && $stable(pwdata_i))}
assume -name assume_apb_ends {@(posedge pclk_i) disable iff (!preset_n_i) (psel_i && penable_i) |=> !penable_i}
assume -name assume_apb_starts {@(posedge pclk_i) disable iff (!preset_n_i) ($rose(psel_i)) |-> !penable_i}
prove -all -time_limit 900s
report -summary
source flow/formal/common.tcl
set PROPS sim/formal_uart/props.txt
if {[info exists ::env(PROPS)]} { set PROPS $::env(PROPS) }
file mkdir [file dirname $PROPS]
list_props $PROPS
exit
