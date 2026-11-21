#!/usr/bin/env bash
route]  -- hclk/aon_clk arrival spread (PD-15)|route]  -- hclk/aon_clk arrival spread (PD-15)
set -euo pipefail
V=${1:?usage: run_hclk_spread.sh <variant> [cts|route]}; ST=${2:-cts}
source "$(dirname "$0")/pd_env.sh" "$V"
case $ST in
    cts)   export ODB=$PD_RESULTS/4_cts.odb SPEF=none ;;
    route) export ODB=$PD_RESULTS/6_final.odb SPEF=$PD_RESULTS/6_final.spef ;;
    *)     echo "run_hclk_spread: stage must be cts or route"; exit 2 ;;
esac
"$PD_OPENROAD" -no_init -no_splash -threads 4 -exit "$PD_SCRIPTS/hclk_spread.tcl" 2>&1 | grep '^SPREAD'
