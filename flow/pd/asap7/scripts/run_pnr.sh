#!/usr/bin/env bash
# =============================================================================
# run_pnr.sh <variant> [--from <variant>] [--cores N] [--fallback-cores M]
#            [--no-mmhold] [--dry-run]
#
# One GARUDA ASAP7 run, synthesis to GDS, in the order the B3 runs settled on:
#
#   1. ORFS synth .. cts               (or copy them from --from <variant>)
#   2. run_mm_hold.sh                  multi-mode hold repair (PD-9)
#   3. ORFS finish                     global route, detailed route, fill, GDS
#      under a memory guard: if available memory falls below GUARD_AVAIL_MIB
#      while swap use is above GUARD_SWAP_MIB, the route is stopped and
#      restarted once with --fallback-cores threads (TOOL-21: pnr_r5 was
#      OOM-killed at 16 threads; pnr_r6/r7 peaked at 8.65 GiB with 8).
#   4. run_sta.sh <variant> route      every DIVSEL scenario on the routed
#      database, then qor.py for the run's one-page summary.
#
# Corners (PD-13, the pnr_r8 flow; on when PD_CORNERS is set, e.g. "WC TC BC"):
#   - before step 2, run_block_libs.sh writes each memory block's model per corner;
#   - step 2 repairs hold over PD_MM_SCENES (default: div2_WC div16_WC and the four
#     FF scenes), to MMHOLD_MARGIN ps of positive slack (default 10);
#   - step 4 runs STA of every mode at every corner, after CTS and after route,
#     then run_validate.sh; with PD_SAIF=<activity.saif>, run_power.sh at TT.
#
# --from copies a finished run's results up to CTS (the pnr_r7 pattern:
# "pnr_r6 up to CTS, then the new hold repair"), dropping every 5_*/6_* file.
#
# Log of the driver: $PD_LOGS/run_pnr.log; memory samples:
# $PD_LOGS/run_pnr_mem.log (time used_MiB avail_MiB swap_MiB). Before a full
# run under WSL, check .wslconfig (flow/pd/TOOLS.md §1, D-30).
# =============================================================================
set -uo pipefail
usage() { sed -n '3,4p' "$0" | sed 's/^# //'; exit 2; }

V=""; FROM=""; CORES=8; FALLBACK=6; MMHOLD=1; DRY=0
while [ $# -gt 0 ]; do
    case $1 in
        --from)            FROM=${2:?}; shift 2 ;;
        --cores)           CORES=${2:?}; shift 2 ;;
        --fallback-cores)  FALLBACK=${2:?}; shift 2 ;;
        --no-mmhold)       MMHOLD=0; shift ;;
        --dry-run)         DRY=1; shift ;;
        -h|--help)         usage ;;
        -*)                echo "run_pnr: unknown option $1"; usage ;;
        *)                 [ -z "$V" ] || usage; V=$1; shift ;;
    esac
done
[ -n "$V" ] || usage
GUARD_AVAIL_MIB=${GUARD_AVAIL_MIB:-700}
GUARD_SWAP_MIB=${GUARD_SWAP_MIB:-4000}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$here/pd_env.sh" "$V" || exit 1

mkdir -p "$PD_LOGS"
LOG=$PD_LOGS/run_pnr.log
say() { echo "$(date +%T) $*" | tee -a "$LOG"; }
step() {   # step <description> <command...>: print it; run it unless --dry-run
    local what=$1; shift
    say "STEP $what: $*"
    [ $DRY -eq 1 ] && return 0
    "$@"
}

# ---- 1. results up to CTS -----------------------------------------------------
copy_from() {   # every garuda* design (the core and its hardened memories)
    local k d n
    for k in results logs reports objects; do
        for d in "$PD_WORK/$k/asap7"/garuda*/"$FROM"; do
            [ -d "$d" ] || continue
            n=${d%/"$FROM"}/$V
            [ -e "$n" ] && { say "exists: $n (pick a new variant name)"; return 1; }
            cp -a "$d" "$n"
            rm -f "$n"/5_* "$n"/6_* "$n"/route.guide
        done
    done
}
if [ -n "$FROM" ]; then
    [ -d "$PD_WORK/results/asap7/garuda/$FROM" ] || { say "no run $FROM"; exit 1; }
    step "copy $FROM up to CTS" copy_from || exit 1
    # A copied CTS result that went through mm_hold keeps the DIV2-only
    # original next to it; start from that, so the repair is not stacked.
    if [ $DRY -eq 0 ] && [ -s "$PD_RESULTS/4_cts_div2only.odb" ]; then
        mv -f "$PD_RESULTS/4_cts_div2only.odb" "$PD_RESULTS/4_cts.odb"
    fi
else
    # the hardened memory blocks first (BLOCKS), then the core up to CTS
    to_cts() { orfs_make NUM_CORES="$CORES" build_macros > "$PD_LOGS/run_pnr_cts.log" 2>&1 \
               && orfs_make NUM_CORES="$CORES" cts >> "$PD_LOGS/run_pnr_cts.log" 2>&1; }
    step "ORFS synth..cts (log run_pnr_cts.log)" to_cts \
        || { say "ORFS failed before CTS: $PD_LOGS/run_pnr_cts.log"; exit 1; }
fi

# ---- 2. multi-mode (and multi-corner) hold repair ------------------------------
PD_CORNERS=${PD_CORNERS:-}
PD_MM_SCENES=${PD_MM_SCENES:-"div2_WC div16_WC div2_BC div4_BC div8_BC div16_BC"}
MMHOLD_MARGIN=${MMHOLD_MARGIN:-10}
export MMHOLD_MARGIN
if [ -n "$PD_CORNERS" ]; then
    step "memory block models per corner ($PD_CORNERS)" "$here/run_block_libs.sh" "$V" "$PD_CORNERS" \
        || { say "run_block_libs failed"; exit 1; }
fi
if [ $MMHOLD -eq 1 ]; then
    if [ -n "$PD_CORNERS" ]; then
        mmc=$(echo $PD_MM_SCENES | tr ' ' '\n' | sed 's/.*_//' | sort -u | tr '\n' ' ')
        step "hold repair over $PD_MM_SCENES (margin $MMHOLD_MARGIN ps)" \
            env PD_CORNERS="$mmc" PD_SCENES="$PD_MM_SCENES" "$here/run_mm_hold.sh" "$V" \
            || { say "mm_hold failed"; exit 1; }
        step "STA after CTS, every mode and corner" env PD_CORNERS="$PD_CORNERS" "$here/run_sta.sh" "$V" cts \
            || say "STA after CTS reported a failed scene"
    else
        step "multi-mode hold repair" "$here/run_mm_hold.sh" "$V" || { say "mm_hold failed"; exit 1; }
    fi
fi

# ---- 3. route .. GDS under the memory guard --------------------------------
MEMLOG=$PD_LOGS/run_pnr_mem.log
finish() {   # finish <cores>: 0 = done, 1 = failed, 3 = stopped by the guard
    local nc=$1 p u a s rc
    say "ORFS finish, NUM_CORES=$nc"
    # setsid: its own process group, so the guard can stop make and every
    # openroad under it with one signal. A shell function cannot be exec'd,
    # hence bash -c with orfs_make exported.
    export -f orfs_make
    setsid bash -c 'orfs_make "$@"' _ NUM_CORES="$nc" finish \
        > "$PD_LOGS/run_pnr_finish_nc$nc.log" 2>&1 &
    p=$!
    while kill -0 "$p" 2> /dev/null; do
        read -r u a < <(free -m | awk '/^Mem:/{print $3, $7}')
        s=$(free -m | awk '/^Swap:/{print $3}')
        echo "$(date +%T) $u $a $s" >> "$MEMLOG"
        if [ "$a" -lt "$GUARD_AVAIL_MIB" ] && [ "$s" -gt "$GUARD_SWAP_MIB" ]; then
            say "GUARD: available ${a} MiB, swap ${s} MiB: stopping NUM_CORES=$nc"
            kill -TERM -- "-$p" 2> /dev/null; sleep 5; kill -KILL -- "-$p" 2> /dev/null
            wait "$p" 2> /dev/null
            return 3
        fi
        sleep 15
    done
    wait "$p"; rc=$?
    say "NUM_CORES=$nc exit=$rc"
    awk 'BEGIN{a=1e9} $2~/^[0-9]+$/{if($2>u)u=$2; if($3<a)a=$3; if($4>s)s=$4}
         END{print "peak used " u+0 " MiB, min available " a " MiB, peak swap " s+0 " MiB"}' \
        "$MEMLOG" | tee -a "$LOG"
    return $rc
}
if [ $DRY -eq 1 ]; then
    say "STEP ORFS finish: NUM_CORES=$CORES (fallback $FALLBACK under the memory guard)"
else
    finish "$CORES"; rc=$?
    if [ $rc -ne 0 ]; then
        if [ $rc -eq 3 ] || dmesg 2> /dev/null | tail -20 | grep -q "Killed process.*openroad"; then
            rm -f "$PD_RESULTS/5_2_route.odb"
            finish "$FALLBACK" || { say "finish failed at NUM_CORES=$FALLBACK"; exit 1; }
        else
            say "finish failed: $PD_LOGS/run_pnr_finish_nc$CORES.log"; exit 1
        fi
    fi
fi

# ---- 4. sign-off style checks of the exploratory run ---------------------------
step "STA, every DIVSEL scenario${PD_CORNERS:+ and corner}" env PD_CORNERS="$PD_CORNERS" "$here/run_sta.sh" "$V" route \
    || say "STA reported a failed scenario"
if [ -n "$PD_CORNERS" ]; then
    step "validation (clock tree, limits, DRC, congestion)" "$here/run_validate.sh" "$V" "$PD_CORNERS" \
        || say "validation failed"
    if [ -n "${PD_SAIF:-}" ]; then
        step "power at TT from $PD_SAIF" "$here/run_power.sh" "$V" TC "$PD_SAIF" || say "power failed"
    fi
fi
if [ -f "$here/qor.py" ]; then
    step "QoR summary" python3 "$here/qor.py" "$V" || true
fi
say "run_pnr: $V done"
