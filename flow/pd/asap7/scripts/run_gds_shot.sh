#!/usr/bin/env bash
# =============================================================================
# run_gds_shot.sh <variant> [all|routing|<layer list>] -- PNG of the final GDS.
#
#   all       every layer (default)
#   routing   M3..M7 (GDS 30,40,50,60,70): the signal routing above the cells
#   30,40     any comma-separated list of GDS layer numbers
#
# Writes $PD_ANALYSIS/shots/<variant>_gds_<view>.png. Needs klayout on PATH
# (Docs: flow/pd/TOOLS.md); runs headless (-zz), no display needed.
# =============================================================================
set -euo pipefail
V=${1:?usage: run_gds_shot.sh <variant> [all|routing|<layers>]}
VIEW=${2:-all}
# shellcheck disable=SC1091
source "$(dirname "$0")/pd_env.sh" "$V"

gds=$PD_RESULTS/6_final.gds
[ -s "$gds" ] || { echo "run_gds_shot: no $gds"; exit 1; }
command -v klayout > /dev/null || { echo "run_gds_shot: klayout not on PATH"; exit 1; }
case $VIEW in
    all)     keep=""; tag=all ;;
    routing) keep="30,40,50,60,70"; tag=M3-M7 ;;
    *)       keep=$VIEW; tag=L$(echo "$VIEW" | tr ',' '-') ;;
esac
mkdir -p "$PD_ANALYSIS/shots"
png=$PD_ANALYSIS/shots/${V}_gds_$tag.png
klayout -zz -rd gds="$gds" -rd lyp="$PLATFORM_DIR/KLayout/asap7.lyp" -rd out="$png" \
        -rd keep="$keep" -r "$PD_SCRIPTS/gds_shot.py"
[ -s "$png" ] || { echo "run_gds_shot: no image written"; exit 1; }
