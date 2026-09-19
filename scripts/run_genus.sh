#!/usr/bin/env bash
# =============================================================================
# run_genus.sh <top> <filelist.f> - structural synthesis check with Cadence Genus
#
# Generic synthesis (syn_generic) against a STAND-IN library: the only liberty
# installed on this machine is SCL 180 nm (scl_pdk_v2). Genus refuses to
# elaborate without one; no mapping or timing result is used - this proves the RTL
# elaborates as hardware, and reports unresolved references, multiply-driven
# nets, combinational loops and inferred latches. It says nothing about timing
# (no library, no SDC) - that is the PD flow's job.
#
# SRAM/ROM arrays are black-boxed (GARUDA_SRAM_BLACKBOX): they become macros.
# Output: sim/genus_<top>/genus.log, check_design.rpt, latches.rpt
# The only latch that may appear is the ICG latch inside core_clk_gate
# (behavioural model of the library ICG cell - see that file's header).
# =============================================================================
set -u
TOP=${1:?top}
FL=${2:?filelist}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source scripts/setup_env.sh > /dev/null
export LM_LICENSE_FILE CDS_LIC_FILE
GENUS=${GENUS:-/home/install/GENUS211/bin/genus}
LIB=${LIB:-/home/install/scl_pdk_v2/stdlib/fs120/liberty/lib_flow_ss/tsl18fs120_scl_ss.lib}
OUT=sim/genus_$TOP
mkdir -p "$OUT"

SRCS=$(python3 scripts/expand_filelist.py "$FL")
INCS=$(python3 scripts/expand_filelist.py "$FL" --incdirs | sed 's/-I//g')

cat > "$OUT/run.tcl" <<TCL
set_db information_level 1
set_db hdl_error_on_latch false
set_db init_hdl_search_path {$INCS rtl/include}
read_libs $LIB
read_hdl -define SYNTHESIS -define GARUDA_SRAM_BLACKBOX -sv {$SRCS}
elaborate $TOP
check_design -all > $OUT/check_design.rpt
syn_generic
report_sequential -hier > /dev/null
set latches [get_db insts -if {.is_latch == true}]
set fh [open $OUT/latches.rpt w]
foreach l \$latches { puts \$fh [get_db \$l .name] }
close \$fh
puts "GENUS_LATCHES [llength \$latches]"
puts "GENUS_CELLS [llength [get_db insts]]"
puts "GENUS_FLOPS [llength [get_db insts -if {.is_flop == true}]]"
quit
TCL

"$GENUS" -no_gui -batch -files "$OUT/run.tcl" -log "$OUT/genus" > "$OUT/stdout.log" 2>&1
grep -E "GENUS_(LATCHES|CELLS|FLOPS)" "$OUT/stdout.log"
grep -E "^Error|Unresolved|multiple driver|Combinational loop" "$OUT/stdout.log" "$OUT/check_design.rpt" 2>/dev/null | head -20
