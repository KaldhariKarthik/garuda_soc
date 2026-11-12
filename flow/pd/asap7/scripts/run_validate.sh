#!/usr/bin/env bash
# run_validate.sh <variant> [corners]  -- validate.tcl per corner (default WC BC),
# DIV2 constraints, plus the router's DRC and antenna results and the global-route
# congestion table from the run's logs. Output: $PD_ANALYSIS/<variant>_validate/
set -euo pipefail
V=${1:?usage: run_validate.sh <variant> [corners]}
CS=${2:-"WC BC"}
export PD_CORNERS="$CS"
source "$(dirname "$0")/pd_env.sh" "$V"
out=$PD_ANALYSIS/${V}_validate; mkdir -p "$out"
export ODB=$PD_RESULTS/6_final.odb SPEF=$PD_RESULTS/6_final.spef SDC=$PD_SDC_DIR/garuda_div2.sdc
for c in $CS; do
    lv=PD_LIBS_$c; export VAL_LIBS="${!lv}" CORNER=$c
    PD_CORNERS="" pd_openroad "$out/validate_$c.log" "$PD_SCRIPTS/validate.tcl" || echo "run_validate: $c FAILED"
    grep -E "^max_|^clock_buffer|^icg" "$out/validate_$c.log" | sed "s/^/$c /"
done
rep=$PD_WORK/reports/asap7/garuda/$V
{
  echo "=== router DRC report: $(wc -l < "$rep/5_route_drc.rpt" 2>/dev/null || echo missing) lines ($rep/5_route_drc.rpt)"
  echo "=== detailed-route iterations"; grep -E "Number of violations" "$PD_LOGS/5_2_route.log" || true
  echo "=== antenna"; grep -hE "ANT-000[12]" "$PD_LOGS/5_2_route.log" "$PD_LOGS/5_3_fillcell.log" 2>/dev/null | sort | uniq -c || true
  echo "=== global-route congestion"; sed -n '/Final congestion report/,/Total wirelength/p' "$PD_LOGS/5_1_grt.log"
} > "$out/routing.txt"
cat "$out/routing.txt"
