#!/usr/bin/env bash
# =============================================================================
# GARUDA ISA regression: run every built test through tb_boot, then lockstep
# each one against Spike.
#
# Two independent verdicts per test, and both must agree:
#   TOHOST  - the test's own self-check (it knows which case failed)
#   LOCKSTEP- every retired instruction matches Spike's (pc, rd, value)
# A test can pass its self-check and still diverge from Spike (e.g. a wrong
# value written to a register the test never reads back), which is exactly the
# class of bug the self-checks miss. Hence both.
#
# The design elaborates ONCE into a snapshot; each test is then a -R rerun with
# a different +HEX. Re-elaborating per test would dominate the runtime.
#
# Usage: scripts/run_regression.sh [test ...]      (default: all built tests)
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# One source of truth for tool locations; safe to source repeatedly.
source "$ROOT/scripts/setup_env.sh" > /dev/null

HEXDIR=${HEXDIR:-sw/riscv-tests/build}
RUNDIR=${RUNDIR:-sim/regress}
MAXCYC=${MAXCYC:-100000}

# ---------------------------------------------------------------------------
# Tests where instruction-level lockstep against Spike is NOT APPLICABLE.
# These are not waivers for failures -- each still has to pass its own TOHOST
# self-check. They are cases where comparing instruction streams is meaningless
# by construction:
#
#   p-div/divu/rem/remu : GARUDA has no hardware divider (Sec. 7.2). It takes an
#     illegal-instruction trap and emulates in software, retiring ~100
#     instructions where Spike's hardware divider retires one. The streams
#     cannot match and it would be wrong if they did.
#   p-csr / p-mcsr / p-ma_fetch : misa bit 23 ("X", non-standard extension
#     present) is set by csr_file.v:85 because of the Custom-0 DSU. Spike knows
#     nothing about the DSU and reports 0x40001100 where GARUDA correctly
#     reports 0x40801100. Each of these tests reads misa into a register.
# ---------------------------------------------------------------------------
NO_LOCKSTEP=" p-div p-divu p-rem p-remu p-csr p-mcsr p-ma_fetch "

mkdir -p "$RUNDIR"

if [ $# -gt 0 ]; then
    TESTS="$*"
else
    TESTS=$(ls "$HEXDIR"/*.hex 2>/dev/null | xargs -n1 basename | sed 's/\.hex$//')
fi

[ -z "$TESTS" ] && { echo "no tests in $HEXDIR - run 'make -C sw/riscv-tests'"; exit 1; }

# ---- elaborate once ----
echo "elaborating snapshot..."
xrun -f tb/soc/filelist_boot.f -top tb_boot \
     -xmlibdirname "$RUNDIR/xcelium.d" -snapshot garuda_boot \
     -l "$RUNDIR/elab.log" -elaborate > /dev/null 2>&1
# An incremental run that recompiles nothing prints no "snapshot" line, so the
# verdict is the presence of errors, not the presence of a success message.
if grep -qE "^xrun: \*[EF]|^xmelab: \*[EF]" "$RUNDIR/elab.log"; then
    echo "ELABORATION FAILED - see $RUNDIR/elab.log"
    grep -E "^xrun: \*[EF]|^xmelab: \*[EF]" "$RUNDIR/elab.log" | head; exit 1
fi

pass=0; fail=0; FAILED=""
printf "\n%-12s %-10s %-10s %s\n" TEST TOHOST LOCKSTEP NOTE
printf -- "------------------------------------------------------------\n"

for t in $TESTS; do
    hex="$HEXDIR/$t.hex"
    elf="$HEXDIR/$t.elf"
    [ -f "$hex" ] || { printf "%-12s %-10s %-10s %s\n" "$t" "-" "-" "no hex"; continue; }

    clog="$RUNDIR/$t.commit.log"
    rlog="$RUNDIR/$t.run.log"
    slog="$RUNDIR/$t.spike.log"

    xrun -R -xmlibdirname "$RUNDIR/xcelium.d" -snapshot garuda_boot \
         -l "$rlog" +HEX="$hex" +COMMIT="$clog" +MAXCYC="$MAXCYC" +QUIET ${EXTRA_ARGS:-} \
         > /dev/null 2>&1

    if   grep -q "PASSED" "$rlog"; then th=PASS
    elif grep -q "FAILED" "$rlog"; then th="FAIL$(grep -oP 'test \K[0-9]+' "$rlog" | head -1)"
    else th="NORESULT"; fi

    if [ -z "${NO_LOCKSTEP##* $t *}" ]; then
        ls_v="n/a"
    elif [ -f "$elf" ]; then
        ls_out=$(python3 tools/lockstep.py --rtl "$clog" --elf "$elf" \
                    --spike-log "$slog" --spike "$SPIKE" --max 3 2>&1)
        if echo "$ls_out" | grep -q "^MATCH"; then ls_v=MATCH
        else ls_v=DIVERGE; echo "$ls_out" > "$RUNDIR/$t.lockstep.txt"; fi
    else
        ls_v="NO-ELF"
    fi

    note=""
    if [ "$th" = "PASS" ] && { [ "$ls_v" = "MATCH" ] || [ "$ls_v" = "n/a" ]; }; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); FAILED="$FAILED $t"
        [ "$ls_v" = "DIVERGE" ] && note="see $RUNDIR/$t.lockstep.txt"
    fi
    printf "%-12s %-10s %-10s %s\n" "$t" "$th" "$ls_v" "$note"
done

printf -- "------------------------------------------------------------\n"
echo "PASS=$pass FAIL=$fail"
[ -n "$FAILED" ] && echo "failing:$FAILED"
[ "$fail" -eq 0 ]
