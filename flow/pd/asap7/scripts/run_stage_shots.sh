#!/usr/bin/env bash
# =============================================================================
# run_stage_shots.sh <variant> [views]   (default: floorplan placement grt route)
# A PNG of the run at each stage, from its saved databases, drawn by OpenROAD's
# GUI off-screen. Output: $PD_ANALYSIS/shots/<variant>/stage_<n>_<view>.png
# =============================================================================
set -euo pipefail
V=${1:?usage: run_stage_shots.sh <variant> [views]}
VIEWS=${2:-"floorplan placement grt route"}
source "$(dirname "$0")/pd_env.sh" "$V"
out=$PD_ANALYSIS/shots/$V; mkdir -p "$out"
export QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-offscreen}
for view in $VIEWS; do
    case $view in
        floorplan) db=2_floorplan.odb n=1 ;;
        placement) db=3_place.odb     n=2 ;;
        grt)       db=5_1_grt.odb     n=4 ;;
        route)     db=6_final.odb     n=5 ;;
        *) echo "run_stage_shots: unknown view $view"; exit 2 ;;
    esac
    [ -s "$PD_RESULTS/$db" ] || { echo "run_stage_shots: no $PD_RESULTS/$db"; exit 1; }
    w=$out/stage_${n}_$view.png
    tcl=$(mktemp); printf 'read_db %s\ngui::show "source %s" false\nexit\n' \
        "$PD_RESULTS/$db" "$PD_SCRIPTS/stage_shots.tcl" > "$tcl"
    ODB=$PD_RESULTS/$db OUT=$w VIEW=$view "$PD_OPENROAD" -no_init -no_splash -exit "$tcl" \
        > "$out/stage_${n}_$view.log" 2>&1 || true
    rm -f "$tcl"
    [ -s "$w" ] || { echo "run_stage_shots: $view FAILED, see $out/stage_${n}_$view.log"; exit 1; }
    echo "run_stage_shots: $w"
done
