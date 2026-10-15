# =============================================================================
# chip_conn.tcl - JasperGold Connectivity: every interrupt line reaches its CLIC ID and every
# DMA channel its peripheral, on garuda_chip_core (flow/formal/conn/chip_conn.csv, from the TRM
# and DMA [N-6.4]). Blocks not on any connection are black-boxed by the tool.
#   /home/install/JASPER/bin/jg -allow_unsupported_OS -conn -batch -no_jges \
#       -proj sim/formal_conn/jgproject flow/formal/conn/chip_conn.tcl
# =============================================================================
set FL rtl/soc/filelist_chip.f
if {[info exists ::env(FL)]} { set FL $::env(FL) }
set FILES [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $FL]] "\n"]
set INCS {}
foreach d [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $FL --incdirs]] " "] {
    if {$d ne ""} { lappend INCS +incdir+[string range $d 2 end] }
}
analyze -sv09 +define+SYNTHESIS {*}$INCS {*}$FILES
blackbox_assistant -config -connectivity_map flow/formal/conn/chip_conn.csv
elaborate -top garuda_chip_core
clock refclk
reset -expression {!ext_rst_n}
check_conn -load flow/formal/conn/chip_conn.csv
check_conn -validate
check_conn -prove
check_conn -report -file sim/formal_conn/report.txt -force
report -summary
exit
