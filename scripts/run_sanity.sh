#!/usr/bin/env bash
# =============================================================================
# Core Sanity TB (verification plan Phase 2) -- the directed rows that the ISA
# suite cannot reach.
#
# The riscv-tests suite proves the ISA. It cannot prove anything about
# interrupts, bus errors, WFI, or fetch behaviour under redirect pressure,
# because no ISA test can assert an IRQ pin or make a slave return ERROR. These
# tests drive those conditions from the testbench, so each one is listed here
# with the plan row it closes and the plusargs that create the condition.
#
# Usage: scripts/run_sanity.sh [test ...]
# =============================================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/setup_env.sh" > /dev/null

RUNDIR=${RUNDIR:-sim/sanity}
MAXCYC=${MAXCYC:-50000}
SEED=${SEED:-7}
mkdir -p "$RUNDIR"

# test | plan row | plusargs creating the condition
SANITY_TESTS=(
  "t_loadbranch|11 load-use into a branch|"
  "t_flush|22 flush with outstanding fetch|+IWAIT=3 +IRAND=1 +SEED=$SEED"
  "t_buserr|17 D-port ERROR response|+ERR_EN=1 +ERR_BASE=10020000 +ERR_SIZE=1000"
  "t_irq|18/19 CLIC interrupt mid-stream, MRET resume|+IRQ_AT=300"
  "t_wfi|20 WFI sleep and wake|+IRQ_AT=400"
  "t_dsu|9/13 DSU Custom-0 and busy hold|"
  "t_mem|item 6: width x offset matrix, byte enables, misalign traps|"
)

echo "elaborating..."
xrun -f tb/soc/filelist_boot.f -top tb_boot \
     -xmlibdirname "$RUNDIR/xcelium.d" -snapshot gsan \
     -l "$RUNDIR/elab.log" -elaborate > /dev/null 2>&1
if grep -qE "^xrun: \*[EF]|^xmelab: \*[EF]" "$RUNDIR/elab.log"; then
    echo "ELABORATION FAILED - see $RUNDIR/elab.log"; exit 1
fi

pass=0; fail=0; FAILED=""
printf "\n%-14s %-10s %s\n" TEST RESULT "PLAN ROW"
printf -- "----------------------------------------------------------------------\n"

for entry in "${SANITY_TESTS[@]}"; do
    t="${entry%%|*}"; rest="${entry#*|}"; row="${rest%%|*}"; args="${rest#*|}"
    [ $# -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$t" && continue

    hex="sw/build/$t.hex"
    [ -f "$hex" ] || { printf "%-14s %-10s %s\n" "$t" "NO-HEX" "$row"; continue; }

    xrun -R -xmlibdirname "$RUNDIR/xcelium.d" -snapshot gsan \
         -l "$RUNDIR/$t.log" +HEX="$hex" +COMMIT="$RUNDIR/$t.commit.log" \
         +MAXCYC="$MAXCYC" +QUIET $args > /dev/null 2>&1

    if   grep -q "TOHOST=1 -> PASSED" "$RUNDIR/$t.log"; then r=PASS; pass=$((pass+1))
    elif grep -q "TIMEOUT"            "$RUNDIR/$t.log"; then r=TIMEOUT; fail=$((fail+1)); FAILED="$FAILED $t"
    else r="FAIL$(grep -oP 'test \K[0-9]+' "$RUNDIR/$t.log" | head -1)"; fail=$((fail+1)); FAILED="$FAILED $t"; fi
    printf "%-14s %-10s %s\n" "$t" "$r" "$row"
done

printf -- "----------------------------------------------------------------------\n"
echo "PASS=$pass FAIL=$fail"
[ -n "$FAILED" ] && echo "failing:$FAILED"
[ "$fail" -eq 0 ]
