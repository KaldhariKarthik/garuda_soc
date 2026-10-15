#!/usr/bin/env bash
# =============================================================================
# run_mm_hold.sh <variant> -- multi-mode hold repair between ORFS CTS and
# global route (BUGS PD-9, mm_hold.tcl).
#
# ORFS's 4_cts.odb (DIV2 hold only) is kept as 4_cts_div2only.odb, and the
# repaired database is written back as 4_cts.odb, which `make finish` then
# routes. Running it again starts again from 4_cts_div2only.odb, so the step
# can be repeated without stacking repairs.
#
# Log: $PD_LOGS/4_2_mmhold.log. The scene table also goes to the terminal.
# =============================================================================
set -euo pipefail
V=${1:?usage: run_mm_hold.sh <variant>}
# shellcheck disable=SC1091
source "$(dirname "$0")/pd_env.sh" "$V"

cts=$PD_RESULTS/4_cts.odb
orig=$PD_RESULTS/4_cts_div2only.odb
[ -s "$cts" ] || [ -s "$orig" ] || { echo "run_mm_hold: no $cts (run ORFS through cts first)"; exit 1; }
if [ ! -s "$orig" ]; then
    mv "$cts" "$orig"
    echo "run_mm_hold: kept ORFS's DIV2-only CTS database as $(basename "$orig")"
fi

export ODB_IN=$orig ODB_OUT=$cts
log=$PD_LOGS/4_2_mmhold.log
echo "run_mm_hold: $V, scenes: $PD_MODES"
rm -f "$cts"
if ! pd_openroad "$log" "$PD_SCRIPTS/mm_hold.tcl" || [ ! -s "$cts" ]; then
    echo "run_mm_hold: FAILED, see $log"
    exit 1
fi
sed -n '/^=== before/,/^worst slack max/p;/^=== after/,/^tns min/p' "$log"
grep -hE 'RSZ-0046|RSZ-0032' "$log" || true
echo "run_mm_hold: wrote $cts (log $log)"
