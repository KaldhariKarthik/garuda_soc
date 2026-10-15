# =============================================================================
# pd_env.sh -- the environment every GARUDA ASAP7 PD step shares.
#
#   source flow/pd/asap7/scripts/pd_env.sh <variant>
#
# Sets, for the FLOW_VARIANT <variant> of the ORFS run:
#   GARUDA_ROOT   this repository
#   ORFS_HOME     OpenROAD-flow-scripts (default ~/tools/OpenROAD-flow-scripts)
#   PD_WORK       the ORFS WORK_HOME (default ~/tools/garuda_pd): results/,
#                 logs/, reports/, objects/ and analysis/ live there, never in
#                 the repo (config.mk)
#   PD_VARIANT    <variant>
#   PD_RESULTS    $PD_WORK/results/asap7/garuda/<variant>
#   PD_LOGS       $PD_WORK/logs/asap7/garuda/<variant>
#   PD_ANALYSIS   $PD_WORK/analysis
#   PD_SDC_DIR    flow/constraints/asap7 (the four DIVSEL scenarios)
#   PD_CONFIG     flow/pd/asap7/config.mk
#   PD_OPENROAD   the openroad binary that ORFS built (ORFS's env.sh uses
#                 OPENROAD for its source directory)
# and exports LIB_FILES, ADDITIONAL_LIBS, PLATFORM_DIR and DONT_USE_CELLS
# exactly as ORFS resolves them for this design (make print-<VAR>), so a step
# reads the same libraries as the flow did. The function orfs_make runs the
# ORFS Makefile for this design and variant.
#
# The ASAP7 results are EXPLORATORY (config.mk, D-27): nothing here says
# anything about timing at 28 nm.
# =============================================================================

if [ -z "${1:-}" ]; then
    echo "pd_env.sh: usage: source pd_env.sh <variant>" >&2
    return 2 2> /dev/null || exit 2
fi

GARUDA_ROOT=${GARUDA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}
ORFS_HOME=${ORFS_HOME:-$HOME/tools/OpenROAD-flow-scripts}
PD_WORK=${PD_WORK:-$HOME/tools/garuda_pd}
PD_VARIANT=$1
PD_RESULTS=$PD_WORK/results/asap7/garuda/$PD_VARIANT
PD_LOGS=$PD_WORK/logs/asap7/garuda/$PD_VARIANT
PD_ANALYSIS=${PD_ANALYSIS:-$PD_WORK/analysis}
PD_SDC_DIR=$GARUDA_ROOT/flow/constraints/asap7
PD_CONFIG=$GARUDA_ROOT/flow/pd/asap7/config.mk
PD_SCRIPTS=$GARUDA_ROOT/flow/pd/asap7/scripts
PD_MODES=${PD_MODES:-"div2 div4 div8 div16"}
export GARUDA_ROOT ORFS_HOME PD_WORK PD_VARIANT PD_RESULTS PD_LOGS PD_ANALYSIS \
       PD_SDC_DIR PD_CONFIG PD_SCRIPTS PD_MODES

if [ ! -d "$ORFS_HOME/flow" ]; then
    echo "pd_env.sh: no ORFS at $ORFS_HOME (set ORFS_HOME)" >&2
    return 1 2> /dev/null || exit 1
fi

# ORFS's env.sh puts its own openroad, yosys and klayout first on PATH. It
# reads unset variables, so it is sourced with -u off.
_pd_u=$-
set +u
# shellcheck disable=SC1091
source "$ORFS_HOME/env.sh" > /dev/null 2>&1
case $_pd_u in *u*) set -u ;; esac
unset _pd_u
PD_OPENROAD=${PD_OPENROAD:-$(command -v openroad || echo "$ORFS_HOME/tools/install/OpenROAD/bin/openroad")}
export PD_OPENROAD

orfs_make() {   # orfs_make <make arguments...>
    make --no-print-directory -C "$ORFS_HOME/flow" DESIGN_CONFIG="$PD_CONFIG" \
         WORK_HOME="$PD_WORK" FLOW_VARIANT="$PD_VARIANT" "$@"
}

# One make call per variable: ORFS prints "VAR = value".
for _v in LIB_FILES ADDITIONAL_LIBS PLATFORM_DIR DONT_USE_CELLS; do
    _val=$(orfs_make "print-$_v" 2> /dev/null | tail -1 | sed "s/^$_v *[:=]* *//")
    export "$_v=$_val"
done
unset _v _val

if [ -z "$LIB_FILES" ] || [ ! -d "$PLATFORM_DIR" ]; then
    echo "pd_env.sh: ORFS did not resolve LIB_FILES / PLATFORM_DIR for $PD_CONFIG" >&2
    return 1 2> /dev/null || exit 1
fi

# pd_openroad <log> <tcl> -- run one Tcl step, drop the library-parser noise
# that every ASAP7 read prints (STA-1212 timing groups from output ports,
# ODB-0227 LEF reads), keep everything else.
pd_openroad() {
    local log=$1 tcl=$2
    mkdir -p "$(dirname "$log")"
    "$PD_OPENROAD" -no_init -no_splash -threads "${PD_THREADS:-4}" -exit "$tcl" 2>&1 \
        | grep -vE 'STA-1212|ODB-0227' > "$log"
    return "${PIPESTATUS[0]}"
}
