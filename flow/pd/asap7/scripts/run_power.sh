#!/usr/bin/env bash
# =============================================================================
# run_power.sh <variant> <corner> <activity.saif> [scope]   (PD-14)
#   corner: WC | TC | BC; scope default tb_chip/dut/u_core
# Power of the routed run at one corner (DIV2 constraints), first with
# OpenSTA's default activity, then with the simulation's.
# Output: $PD_ANALYSIS/<variant>_power_<corner>.log
# =============================================================================
set -euo pipefail
V=${1:?usage: run_power.sh <variant> <corner> <saif> [scope]}; C=${2:?}; SAIF=${3:?}
SCOPE=${4:-tb_chip/dut/u_core}
export PD_CORNERS=$C
source "$(dirname "$0")/pd_env.sh" "$V"
lv=PD_LIBS_$C
export PWR_LIBS="${!lv}" ODB=$PD_RESULTS/6_final.odb SPEF=$PD_RESULTS/6_final.spef SDC=$PD_SDC_DIR/garuda_div2.sdc
mkdir -p "$PD_ANALYSIS"
export ACT_TCL=$PD_ANALYSIS/${V}_activity.tcl
python3 "$PD_SCRIPTS/saif_to_activity.py" "$SAIF" "$SCOPE" "$ACT_TCL"
log=$PD_ANALYSIS/${V}_power_$C.log
pd_openroad "$log" "$PD_SCRIPTS/power.tcl"
grep -E "^=== |^Total|^Sequential|^Combinational|^Clock|^Macro|^Pad" "$log"
