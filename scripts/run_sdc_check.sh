#!/usr/bin/env bash
# =============================================================================
# run_sdc_check.sh [divide] - does flow/constraints/garuda_rtl.sdc load in Genus, and
# does every flop of the chip get a clock from it? (plan task 3.2)
#
#   source scripts/setup_env.sh
#   ./scripts/run_sdc_check.sh          hclk = refclk / 2 (the default mode)
#   ./scripts/run_sdc_check.sh 8        hclk = refclk / 8
#
# Elaborates garuda_chip_top, reads the file, and fails on an error or warning of the
# SDC reader, a command that failed, and any finding of check_timing_intent (a flop
# without a clock, a port without a delay, a generated clock without its master, ...)
# other than the two that are answered in flow/constraints/exceptions.md.
# Reports: sim/sdc_check/div<N>/.
# =============================================================================
set -u
DIV=${1:-2}
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source scripts/setup_env.sh > /dev/null
export LM_LICENSE_FILE CDS_LIC_FILE
GENUS=${GENUS:-/home/install/GENUS211/bin/genus}
LIB=${LIB:-/home/install/FOUNDRY/digital/45nm/dig/lib/slow.lib}
FL=rtl/soc/filelist_chip.f
OUT=sim/sdc_check/div$DIV
rm -rf "$OUT"; mkdir -p "$OUT"
SRCS=$(python3 scripts/expand_filelist.py "$FL")
INCS=$(python3 scripts/expand_filelist.py "$FL" --incdirs | sed 's/-I//g')
DEFS=$(python3 scripts/expand_filelist.py "$FL" --defines | sed 's/-D/-define /g')
cat > "$OUT/run.tcl" <<TCL
set_db information_level 1
set_db hdl_error_on_latch false
set_db init_hdl_search_path {$INCS rtl/include}
read_libs $LIB
read_hdl -define SYNTHESIS -define GARUDA_SRAM_BLACKBOX $DEFS -sv {$SRCS}
elaborate garuda_chip_top
set GARUDA_DIV $DIV
redirect -tee $OUT/read_sdc.log { read_sdc flow/constraints/garuda_rtl.sdc }
check_timing_intent -verbose > $OUT/check_timing_intent.rpt
foreach e [get_db exceptions] { puts "EXC [get_db \$e .name] [get_db \$e .exception_type]" }
report_clocks            > $OUT/clocks.rpt
report_clocks -generated > $OUT/clocks_generated.rpt
puts "SDC_FLOPS [llength [get_db insts -if {.is_flop == true}]]"
quit
TCL
"$GENUS" -no_gui -batch -files "$OUT/run.tcl" -log "$OUT/genus" > "$OUT/stdout.log" 2>&1
rc=$?
bad=0
note() { echo "  ** $*"; bad=1; }
{ [ $rc -eq 0 ] && grep -q "^Normal exit" "$OUT/stdout.log"; } || note "Genus did not end normally (exit $rc): $OUT/stdout.log"
[ -s "$OUT/read_sdc.log" ] || note "the SDC file was not read"
grep -E "^(Error|Warning)" "$OUT/read_sdc.log" 2> /dev/null | sort | uniq -c | head -20 > "$OUT/sdc_messages.txt"
[ -s "$OUT/sdc_messages.txt" ] && { note "messages of the SDC reader:"; cat "$OUT/sdc_messages.txt"; }
grep -E "failed +[1-9]" "$OUT/read_sdc.log" | head -5 > "$OUT/sdc_failed.txt"
[ -s "$OUT/sdc_failed.txt" ] && { note "SDC commands that failed:"; cat "$OUT/sdc_failed.txt"; }
# Two findings are the design and are answered in flow/constraints/exceptions.md
# (answers A1 and A2); they are accepted by name, anything else under them fails.
#   A1  the ripple divider: the data pin of each toggle flop, and the enable of the
#       select flops, is driven by the output of a flop that is itself a clock
#   A2  a divider stage that clocks nothing in this mode has a path group with no path
if [ -s "$OUT/check_timing_intent.rpt" ]; then
    python3 - "$OUT/check_timing_intent.rpt" > "$OUT/intent_findings.txt" <<'PY'
import re, sys
ok = {"Sequential data pins driven by a clock signal":
          r"^pin:garuda_chip_top/u_clk_div/((t[234]_q|pclk_q)_reg/d|sel_act_q_reg\[[01]\]/sena)$",
      "Timing exceptions with no effect": r"^exception:garuda_chip_top/clk_t[234]$"}
sec, prev = None, ""
for l in open(sys.argv[1]):
    l = l.rstrip()
    if l.startswith("Lint summary"):
        break
    if prev.startswith("-----") and l and not l.startswith("-"):
        sec = l                                   # a section's title follows a rule
    elif re.match(r"^(pin|port|exception|inst|clock|hpin|net):\S+", l):
        if not (sec in ok and re.match(ok[sec], l)):
            print("%s: %s" % (sec, l))
    prev = l
PY
    [ -s "$OUT/intent_findings.txt" ] && { note "check_timing_intent:"; head -20 "$OUT/intent_findings.txt"; }
    grep -q "Lint summary" "$OUT/check_timing_intent.rpt" || note "check_timing_intent report is incomplete"
else
    note "no check_timing_intent report"
fi
grep -E "^SDC_FLOPS" "$OUT/stdout.log"
[ $bad -eq 0 ] && echo "run_sdc_check: garuda_rtl.sdc loads clean at DIV$DIV" || echo "run_sdc_check: NOT clean at DIV$DIV (reports in $OUT)"
exit $bad
