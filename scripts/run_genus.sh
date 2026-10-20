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
DEFS=$(python3 scripts/expand_filelist.py "$FL" --defines | sed 's/-D/-define /g')   # TOOL-15
[ -n "$SRCS" ] || { echo "run_genus: no sources from $FL"; exit 1; }

cat > "$OUT/run.tcl" <<TCL
set_db information_level 1
set_db hdl_error_on_latch false
set_db init_hdl_search_path {$INCS rtl/include}
read_libs $LIB
read_hdl -define SYNTHESIS -define GARUDA_SRAM_BLACKBOX $DEFS -sv {$SRCS}
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

rm -f "$OUT/stdout.log" "$OUT/check_design.rpt" "$OUT/latches.rpt"
"$GENUS" -no_gui -batch -files "$OUT/run.tcl" -log "$OUT/genus" > "$OUT/stdout.log" 2>&1
rc=$?
grep -E "^GENUS_(LATCHES|CELLS|FLOPS)" "$OUT/stdout.log"

# -----------------------------------------------------------------------------
# Verdict (Docs/bugs/archive/BUGS_HISTORY.md TOOL-13). The last command here used to be a grep whose
# pattern also matches the heading "Unresolved References" of the report, so
# the script returned 0 whatever Genus had found. Now each thing is counted:
#   Genus ended normally and printed no Error
#   no unresolved reference, empty module or undriven pin
#   multiply driven pins: only the four bidirectional pads (I2C SCL and SDA,
#     the two GPIO), which a pad cell will replace
#   latches: only the enable latch of the core's clock gate
# -----------------------------------------------------------------------------
bad=0
note() { echo "  ** $*"; bad=1; }
{ [ $rc -eq 0 ] && grep -q "^Normal exit" "$OUT/stdout.log"; } || note "Genus did not end normally (exit status $rc), see $OUT/stdout.log"
n=$(grep -cE "^Error" "$OUT/stdout.log")
[ "$n" = 0 ] || { note "$n Error message(s):"; grep -E "^Error" "$OUT/stdout.log" | sort | uniq -c | head; }
if [ -s "$OUT/check_design.rpt" ]; then
    val() { awk -v k="$1" 'index($0, k) == 1 { print $NF }' "$OUT/check_design.rpt" | tail -1; }
    for k in "Unresolved References" "Empty Modules" "Undriven Port(s)" "Undriven Leaf Pin(s)" \
             "Undriven hierarchical pin(s)" "Multidriven Port(s)" "Multidriven unloaded net(s)"; do
        v=$(val "$k"); [ "$v" = 0 ] || note "$k: ${v:-not reported}"
    done
    md=$(sed -n '/Multidriven Port(s)\/Pin(s)/,/Constant Pin(s)/p' "$OUT/check_design.rpt" | grep -E "^h?pin:" \
         | grep -vE "/u_i2c/(i2c_s(cl|da)_i|u_shim/sync0_q_reg\[[01]\]/d)$|/u_gpio/(gpio_i\[[01]\]|u_shim/sync0_q_reg\[[01]\]/d)$|/u_core/(i2c_s(cl|da)_i|gpio_i\[[01]\])$")
    [ -z "$md" ] || { note "multiply driven pins other than the bidirectional pads:"; echo "$md" | head; }
else
    note "no check_design report"
fi
if [ -f "$OUT/latches.rpt" ]; then
    ul=$(grep -v "u_core_u_cg_en_l_reg" "$OUT/latches.rpt")
    [ -z "$ul" ] || { note "latches other than the clock gate's enable latch:"; echo "$ul" | head; }
else
    note "no latch report"
fi
if [ $bad -eq 0 ]; then echo "run_genus: $TOP structurally clean"; else echo "run_genus: $TOP NOT clean"; fi
exit $bad
