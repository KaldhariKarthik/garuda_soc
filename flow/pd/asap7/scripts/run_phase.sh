#!/usr/bin/env bash
# =============================================================================
# run_phase.sh <variant> [stage odb, default 1_synth.odb] -- clock-phase
# check (phase_check.tcl) for every DIVSEL scenario in $PD_MODES.
#
# Writes $PD_ANALYSIS/<variant>_phase/phase_<mode>.log and prints, for each
# crossing, the launch and capture clock edges STA used, which is what has
# to be compared with the divider waveforms.
# =============================================================================
set -euo pipefail
V=${1:?usage: run_phase.sh <variant> [odb]}
# shellcheck disable=SC1091
source "$(dirname "$0")/pd_env.sh" "$V"

export ODB=$PD_RESULTS/${2:-1_synth.odb}
[ -s "$ODB" ] || { echo "run_phase: no $ODB"; exit 1; }
out=$PD_ANALYSIS/${V}_phase
mkdir -p "$out"
bad=0
for m in $PD_MODES; do
    export MODE=$m SDC=$PD_SDC_DIR/garuda_$m.sdc
    log=$out/phase_$m.log
    if ! pd_openroad "$log" "$PD_SCRIPTS/phase_check.tcl" || ! grep -q "^=== DONE $m" "$log"; then
        echo "run_phase: $m FAILED, see $log"; bad=1; continue
    fi
    echo "############ $m"
    grep -E '^=== |^Startpoint|^Endpoint|clock .* edge\)|slack \(|^no |ERROR' "$log" | grep -v '^=== SDC' || true
done
echo "run_phase: logs in $out"
exit $bad
