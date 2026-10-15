#!/usr/bin/env bash
# =============================================================================
# run_skew.sh <variant> [sdc] -- clock-tree report of a CTS database
# (cts_skew.tcl). Reads 4_1_cts.odb, the tree as TritonCTS built it, before
# any timing repair; the SDC defaults to the run's own 4_cts.sdc (DIV2).
#
# Writes $PD_ANALYSIS/<variant>_cts_skew.log.
# =============================================================================
set -euo pipefail
V=${1:?usage: run_skew.sh <variant> [sdc]}
# shellcheck disable=SC1091
source "$(dirname "$0")/pd_env.sh" "$V"

export ODB=$PD_RESULTS/4_1_cts.odb
export SDC=${2:-$PD_RESULTS/4_cts.sdc}
[ -s "$ODB" ] || { echo "run_skew: no $ODB"; exit 1; }
[ -s "$SDC" ] || { echo "run_skew: no $SDC"; exit 1; }

log=$PD_ANALYSIS/${V}_cts_skew.log
if ! pd_openroad "$log" "$PD_SCRIPTS/cts_skew.tcl" || ! grep -q '^=== DONE' "$log"; then
    echo "run_skew: FAILED, see $log"; exit 1
fi
grep -E '^-- |^ *Latency|^[a-z_]+ +[0-9.-]+ *$|^worst slack|^tns' "$log" | head -30 || true
echo "run_skew: $log"
