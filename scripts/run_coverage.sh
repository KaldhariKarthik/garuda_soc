#!/usr/bin/env bash
# =============================================================================
# GARUDA coverage run.
#
# TOOLING STATUS -- READ THIS BEFORE TRUSTING ANY NUMBER BELOW
# ------------------------------------------------------------
# CODE coverage (statement / branch / toggle) is INSTRUMENTED AND COLLECTED
# here, but it CANNOT BE REPORTED on this machine. `xrun -coverage all` writes
# a valid Xcelium 22.09 database, and the only IMC installed is Incisive 15.20,
# which rejects it:
#     *E,DBERR: Error loading database file ... serialization exception
# Xcelium 22.09 ships no IMC of its own - only launch_rmi_imc.sh, a launcher
# for a separate install. Nothing in this script can work around that; it needs
# an IMC or vManager matching the simulator. The databases under
# $COVDIR/cov_work are correct and will report the moment one is available.
#
# FUNCTIONAL coverage does not depend on IMC: the bound covergroups in
# tb/cov/garuda_cov.sv report their own numbers at end of simulation, so those
# figures are real today.
#
# ON MERGING: each test is a separate simulation, so its covergroups start
# empty. Without IMC there is no bin-level merge, and percentages from
# different runs cannot legitimately be averaged. The aggregate printed here is
# therefore the MAXIMUM per group across the suite, which is a true LOWER BOUND
# on merged coverage - never an overstatement. A real merged number needs IMC.
#
# Usage: scripts/run_coverage.sh [test ...]
# =============================================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/setup_env.sh" > /dev/null

COVDIR=${COVDIR:-sim/cov}
HEXDIR=${HEXDIR:-sw/riscv-tests/build}
SWDIR=${SWDIR:-sw/build}
MAXCYC=${MAXCYC:-200000}
mkdir -p "$COVDIR/reports"

echo "elaborating with coverage instrumentation..."
xrun -f tb/soc/filelist_boot_cov.f -top tb_boot \
     -coverage all -covoverwrite -covworkdir "$COVDIR/cov_work" \
     -covdut garuda_core_top \
     -xmlibdirname "$COVDIR/xcelium.d" -snapshot gcov \
     -l "$COVDIR/elab.log" -elaborate > /dev/null 2>&1
if grep -qE "^xrun: \*[EF]|^xmelab: \*[EF]" "$COVDIR/elab.log"; then
    echo "ELABORATION FAILED - see $COVDIR/elab.log"
    grep -E "^xrun: \*[EF]|^xmelab: \*[EF]" "$COVDIR/elab.log" | head; exit 1
fi

if [ $# -gt 0 ]; then TESTS="$*"
else
    TESTS=$(ls "$HEXDIR"/*.hex 2>/dev/null | xargs -n1 basename | sed 's/\.hex$//')
    TESTS="$TESTS ctest1 t_dsu t_irq t_wfi t_buserr t_flush t_loadbranch dsu_flag2"
fi

printf "\n%-16s %7s %7s %7s %7s %7s %7s %7s\n" TEST DECODE ALU LDST HAZARD TRAP AHB DSU
printf -- "--------------------------------------------------------------------------\n"

declare -A MAXV
for g in decode alu ldst hazard trap ahb dsu; do MAXV[$g]=0; done

for t in $TESTS; do
    hex="$HEXDIR/$t.hex"; [ -f "$hex" ] || hex="$SWDIR/$t.hex"
    [ -f "$hex" ] || continue

    # conditions some directed tests need in order to reach their coverage
    extra=""
    case "$t" in
      t_buserr) extra="+ERR_EN=1 +ERR_BASE=10020000 +ERR_SIZE=1000" ;;
      t_irq)    extra="+IRQ_AT=300" ;;
      t_wfi)    extra="+IRQ_AT=400" ;;
      t_flush)  extra="+IWAIT=3 +IRAND=1 +SEED=7" ;;
    esac

    rm -f "$COVDIR/reports/$t.txt"
    xrun -R -xmlibdirname "$COVDIR/xcelium.d" -snapshot gcov \
         -covworkdir "$COVDIR/cov_work" -covtest "$t" -covoverwrite \
         -l "$COVDIR/$t.log" +HEX="$hex" +COMMIT="$COVDIR/$t.commit.log" \
         +MAXCYC="$MAXCYC" +QUIET +COVTAG="$COVDIR/reports/$t" $extra > /dev/null 2>&1

    f="$COVDIR/reports/$t.txt"
    [ -f "$f" ] || { printf "%-16s %s\n" "$t" "(no coverage output)"; continue; }

    line=$(printf "%-16s" "$t")
    for g in decode alu ldst hazard trap ahb dsu; do
        v=$(awk -v k="$g" '$1==k{printf "%.2f", $2}' "$f")
        [ -z "$v" ] && v=0
        line="$line $(printf '%7s' "$v")"
        awk -v a="$v" -v b="${MAXV[$g]}" 'BEGIN{exit !(a>b)}' && MAXV[$g]=$v
    done
    echo "$line"
done

printf -- "--------------------------------------------------------------------------\n"
printf "%-16s" "MAX (lower bound)"
for g in decode alu ldst hazard trap ahb dsu; do printf " %7s" "${MAXV[$g]}"; done
echo
echo
echo "NOTE: code coverage collected into $COVDIR/cov_work but NOT reportable --"
echo "      Incisive 15.20 imc cannot read an Xcelium 22.09 database."
echo "      Functional numbers above are real; the aggregate is a lower bound."
