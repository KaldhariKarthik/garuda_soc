#!/usr/bin/env bash
# =============================================================================
# run_block_libs.sh <variant> [corners]   (default corners: WC TC BC)
#
# Writes <block>_<corner>.lib next to each hardened memory block's
# <block>_typ.lib, one per ASAP7 corner (WC = SS, TC = TT, BC = FF), for the
# multi-corner steps (PD-13). The block itself is not changed.
# =============================================================================
set -euo pipefail
V=${1:?usage: run_block_libs.sh <variant> [corners]}
CORNERS=${2:-"WC TC BC"}
source "$(dirname "$0")/pd_env.sh" "$V"
for c in $CORNERS; do
    std=$(orfs_make "print-${c}_NLDM_LIB_FILES" 2> /dev/null | tail -1 | sed "s/^${c}_NLDM_LIB_FILES *[:=]* *//")
    for d in "$PD_WORK/results/asap7"/garuda_garuda_*/"$V"; do
        blk=$(basename "$(dirname "$d")"); blk=${blk#garuda_}
        [ -s "$d/6_final.odb" ] || { echo "run_block_libs: no $d/6_final.odb"; exit 1; }
        export BLOCK_DIR=$d BLOCK=$blk CORNER=$c CORNER_LIBS="$std" OUT=$d/${blk}_$c.lib
        pd_openroad "$PD_LOGS/block_lib_${blk}_$c.log" "$PD_SCRIPTS/block_corner_libs.tcl" \
            && [ -s "$OUT" ] || { echo "run_block_libs: FAILED $blk $c"; exit 1; }
        echo "run_block_libs: $OUT"
    done
done
