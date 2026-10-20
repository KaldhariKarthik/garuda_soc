#!/usr/bin/env bash
# =============================================================================
# sim_verdict.sh <log> <simulator exit status> [<pass regex>]
#
# One verdict for the Makefile's simulation macros (Docs/bugs/archive/BUGS_HISTORY.md TOOL-13).
# Each of run_test, run_tb_top, run_tb_elem and run_blk used to run xrun and
# then end in a printf or a grep, so the target exited 0 whatever xrun
# returned and whatever the log said. A run passes here only if ALL hold:
#
#   - the simulator exited 0
#   - the log has no Cadence *E / *F message (IMPDLL excepted, as in the
#     uvm_* targets) and no xsim ERROR: line
#   - no [FAIL], [SVA-FAIL], "FAIL <name>", "RESULT: FAILED" or
#     "CHECK(S) FAILED" line
#   - the pass regex, when one is given, matches
#
# Exit status alone is not enough (Verilator has exited 0 after assertion
# failures) and neither is a pass marker alone (a run can print PASSED and
# then die): the rule is the one the uvm_* and xprop targets already apply.
# =============================================================================
log="$1"; rc="$2"; pass="${3:-}"
why=""
if [ ! -f "$log" ]; then
    echo "  VERDICT: FAIL (no log: $log)"
    exit 1
fi
[ "$rc" = 0 ] || why="$why simulator exit $rc;"
n=$(grep -E '\*[EF],' "$log" | grep -vc IMPDLL)
[ "$n" = 0 ] || why="$why $n *E/*F message(s);"
n=$(grep -cE '^ERROR:' "$log")
[ "$n" = 0 ] || why="$why $n ERROR line(s);"
n=$(grep -cE '\[FAIL\]|\[SVA-FAIL\]|^FAIL |RESULT: *FAILED|CHECK\(S\) FAILED' "$log")
[ "$n" = 0 ] || why="$why $n failure line(s);"
if [ -n "$pass" ] && ! grep -qE "$pass" "$log"; then
    why="$why no pass marker /$pass/;"
fi
if [ -n "$why" ]; then
    echo "  VERDICT: FAIL ($why )"
    exit 1
fi
echo "  VERDICT: PASS"
