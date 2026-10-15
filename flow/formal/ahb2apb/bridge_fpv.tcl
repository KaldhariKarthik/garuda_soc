# =============================================================================
# bridge_fpv.tcl - formal proof of the AHB-to-APB bridge's properties
#   rtl/ahb2apb/ahb2apb_bridge_sva.sv  (the a_* are proved, the c_* reached)
#
# Run from the repository root:
#   /home/install/JASPER/bin/jg -allow_unsupported_OS -fpv -batch -no_jges \
#       -proj sim/formal_bridge/jgproject flow/formal/ahb2apb/bridge_fpv.tcl
#
# The model: hclk is the base clock; pclk is hclk divided by two (D-5), every pclk
# edge is an hclk edge. The inputs the tool may not invent are in the sva file as
# assume_*: an AHB master that holds its address phase until accepted. Everything
# else is free: the APB slaves answer PREADY, PRDATA and PSLVERR as they like, so
# every wait, every error and the timeout are all reachable.
# =============================================================================
# settings, from the environment so this file is never edited:
#   MASK  window mask      default 0FFE   (windows 1 to 11)
#   DIV   24-bit APB_DIV   default 000000 (no divider); FFFFFF is /8 on every window
#   FILES a file list of the three RTL files and the sva, to prove a mutant instead
set MASK 0FFE; set DIV 000000; set FL rtl/ahb2apb/filelist.f
if {[info exists ::env(MASK)]} { set MASK $::env(MASK) }
if {[info exists ::env(DIV)]}  { set DIV  $::env(DIV) }
if {[info exists ::env(FL)]}   { set FL   $::env(FL) }
set FILES [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $FL]] "\n"]
analyze -sv09 +incdir+rtl/include {*}$FILES

# the parameters of the chip: windows 1 to 11 present
elaborate -top ahb2apb_bridge -parameter WINDOW_MASK 16'h$MASK -parameter APB_DIV 24'h$DIV -parameter TIMEOUT 16

clock hclk_i
clock pclk_i -factor 2 -phase 1
reset -expression {!hreset_n_i} {!preset_n_i}

# the pclk phase input is not used by the bridge (the spec keeps it on the port list)
assume {pclk_phase_i == 1'b0}

prove -all -time_limit 600s
report -summary
source flow/formal/common.tcl
file mkdir [file dirname sim/formal_bridge/props.txt]
list_props sim/formal_bridge/props.txt
exit
