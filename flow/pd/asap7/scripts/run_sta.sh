#!/usr/bin/env bash
# =============================================================================
# run_sta.sh <variant> <cts|route> -- STA of every DIVSEL scenario.
#
#   cts    4_cts.odb, parasitics estimated from placement
#   route  6_final.odb with 6_final.spef (extracted parasitics)
#
# Writes $PD_ANALYSIS/<variant>_sta_<stage>/sta_<mode>.log, one per scenario,
# and summary.txt: one line per scenario with the setup and hold worst and
# total negative slack and the violating endpoint counts. Exit 1 if any
# scenario failed to run; a negative slack is reported, not an error.
# =============================================================================
set -euo pipefail
V=${1:?usage: run_sta.sh <variant> <cts|route>}
ST=${2:?usage: run_sta.sh <variant> <cts|route>}
# shellcheck disable=SC1091
source "$(dirname "$0")/pd_env.sh" "$V"

case $ST in
    cts)   export ODB=$PD_RESULTS/4_cts.odb SPEF=none ;;
    route) export ODB=$PD_RESULTS/6_final.odb SPEF=$PD_RESULTS/6_final.spef ;;
    *)     echo "run_sta: stage must be cts or route, not '$ST'"; exit 2 ;;
esac
[ -s "$ODB" ] || { echo "run_sta: no $ODB"; exit 1; }
[ "$SPEF" = none ] || [ -s "$SPEF" ] || { echo "run_sta: no $SPEF"; exit 1; }

out=$PD_ANALYSIS/${V}_sta_$ST
mkdir -p "$out"
sum=$out/summary.txt
printf "# %s %s  %s\n" "$V" "$ST" "$(date '+%Y-%m-%d %H:%M')" > "$sum"
printf "%-6s %10s %12s %10s %12s %6s %6s\n" mode setup_wns setup_tns hold_wns hold_tns s_viol h_viol >> "$sum"
bad=0
for m in $PD_MODES; do
    export MODE=$m SDC=$PD_SDC_DIR/garuda_$m.sdc
    log=$out/sta_$m.log
    if ! pd_openroad "$log" "$PD_SCRIPTS/sta_post.tcl" || ! grep -q "^=== DONE $m" "$log"; then
        echo "run_sta: $m FAILED, see $log"; bad=1; continue
    fi
    # The summary block is "key value" lines between "=== summary" and the next "===".
    awk -v m="$m" '
        /^=== summary/ { on = 1; next }
        on && /^===/   { exit }
        on             { v[$1] = $2 }
        END { printf "%-6s %10s %12s %10s %12s %6s %6s\n", m, v["setup_wns"], v["setup_tns"],
              v["hold_wns"], v["hold_tns"], v["setup_viol_endpoints"], v["hold_viol_endpoints"] }
    ' "$log" >> "$sum"
done
cat "$sum"
echo "run_sta: logs in $out"
exit $bad
