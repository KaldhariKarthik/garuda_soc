#!/usr/bin/env bash
# =============================================================================
# GARUDA coverage: collect with Incisive, merge and report with IMC.
#
# WHY IRUN AND NOT XRUN
# ---------------------
# The regression runs on Xcelium 22.09, but IMC on this machine is Incisive
# 15.20 and cannot read an Xcelium 22.09 coverage database:
#     *E,DBERR: Error loading database file ... serialization exception
# There is no format-downgrade option in xrun, and no newer IMC installed. The
# fix is to move the WRITER back rather than the reader forward: irun 15.20 is
# installed, matches IMC's vintage, and the design builds and runs under it
# unchanged.
#
# So there are deliberately two flows, and that is a feature rather than a
# workaround:
#   xrun (Xcelium 22.09) - the regression. Fast, and where every bug so far was
#                          found. Correctness signoff.
#   irun (Incisive 15.20) - coverage collection only. Metrics signoff.
# Both consume the SAME filelists, so a test covered here is the same test that
# passes there. Functional coverage numbers have been cross-checked between the
# two simulators and agree exactly, which is a useful independent check on the
# covergroups themselves.
#
# WHAT GETS MEASURED
#   code       - statement / branch / toggle, per module, from -coverage all
#   functional - the seven bound covergroups in tb/cov/garuda_cov.sv
# IMC's `report -summary` does NOT roll covergroups into its Functional column;
# use `report -detail -metrics covergroup`, which this script does.
#
# Usage: scripts/run_coverage.sh [test ...]
# =============================================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Incisive for collection; the shared env still supplies the licence and RISC-V
# paths. Deliberately NOT scripts/setup_env.sh's Xcelium PATH order.
source "$ROOT/scripts/setup_env.sh" > /dev/null
export PATH=/home/install/INCISIVE152/tools/bin:$PATH
IMC=${IMC:-/home/install/INCISIVE152/bin/imc}

COVDIR=${COVDIR:-sim/cov}
HEXDIR=${HEXDIR:-sw/riscv-tests/build}
SWDIR=${SWDIR:-sw/build}
MAXCYC=${MAXCYC:-400000}
rm -rf "$COVDIR"; mkdir -p "$COVDIR/reports"

# ---------------------------------------------------------------------------
# 1. elaborate once
# ---------------------------------------------------------------------------
echo "elaborating (irun, coverage instrumented)..."
irun -f tb/soc/filelist_boot_cov.f -top tb_boot \
     -coverage all -cov_cgsample -covoverwrite \
     -covworkdir "$COVDIR/cov_work" -nclibdirname "$COVDIR/INCA_libs" \
     -snapshot gcov -elaborate -l "$COVDIR/elab.log" > /dev/null 2>&1
if grep -qE "^irun: \*[EF]|^ncelab: \*[EF]" "$COVDIR/elab.log"; then
    echo "ELABORATION FAILED - see $COVDIR/elab.log"
    grep -E "\*[EF]," "$COVDIR/elab.log" | head; exit 1
fi

# ---------------------------------------------------------------------------
# 2. run every test into its own coverage scope
# ---------------------------------------------------------------------------
if [ $# -gt 0 ]; then TESTS="$*"
else
    TESTS=$(ls "$HEXDIR"/*.hex 2>/dev/null | xargs -n1 basename | sed 's/\.hex$//')
    TESTS="$TESTS ctest1 boot6 dsu_flag2 t_dsu t_irq t_wfi t_buserr t_flush t_loadbranch t_mem t_clic t_cov"
fi

ran=""
printf "\n%-18s %s\n" TEST RESULT
printf -- "----------------------------------------\n"
for t in $TESTS; do
    hex="$HEXDIR/$t.hex"; [ -f "$hex" ] || hex="$SWDIR/$t.hex"
    [ -f "$hex" ] || continue

    # conditions some directed tests need to reach their coverage at all
    extra=""
    case "$t" in
      t_buserr) extra="+ERR_EN=1 +ERR_BASE=10020000 +ERR_SIZE=1000" ;;
      t_irq)    extra="+IRQ_AT=300" ;;
      t_wfi)    extra="+IRQ_AT=400" ;;
      t_flush)  extra="+IWAIT=3 +IRAND=1 +SEED=7" ;;
      t_clic)   extra="+IRQ_EVERY=40 +IRQ_SWEEP=1" ;;
    esac

    irun -R -snapshot gcov -nclibdirname "$COVDIR/INCA_libs" \
         -covworkdir "$COVDIR/cov_work" -covtest "$t" -covoverwrite \
         -l "$COVDIR/$t.log" +HEX="$hex" +COMMIT="$COVDIR/$t.commit.log" \
         +MAXCYC="$MAXCYC" +QUIET +COVTAG="$COVDIR/reports/$t" $extra > /dev/null 2>&1

    if grep -q "TOHOST=1 -> PASSED" "$COVDIR/$t.log"; then r=PASS
    elif grep -q "TIMEOUT" "$COVDIR/$t.log"; then r=TIMEOUT
    else r=FAIL; fi
    printf "%-18s %s\n" "$t" "$r"
    [ -d "$COVDIR/cov_work/scope/$t" ] && ran="$ran $COVDIR/cov_work/scope/$t"
done

# ---------------------------------------------------------------------------
# 2b. unit-level databases
# ---------------------------------------------------------------------------
# tb_boot exercises the DSU with only a handful of instructions, so the DSU's
# internals (CSA tree, Kogge-Stone adder, multipliers, shifter) read near zero
# from the system level alone. Their real coverage comes from tb_dsu_top's
# randomised sweep and from the per-block unit TBs. Those are different TOP
# modules but the same design modules, so IMC merges them into one view - which
# is the whole reason the verification plan asks for a merged number rather
# than a system-level one.
if [ $# -eq 0 ]; then
    mkdir -p "$COVDIR/unit_libs"

    echo; echo "collecting unit-level coverage..."
    python3 tools/gen/DSU_gen.py --count "${DSU_TESTS:-600}" --seed "${DSU_SEED:-1}" \
            --outdir "$COVDIR/dsu" > /dev/null 2>&1
    irun -64bit -f tb/dsu/filelist_dsu_top.f -top tb_dsu_top \
         -coverage all -cov_cgsample -covoverwrite \
         -covworkdir "$COVDIR/cov_work" -covtest dsu_unit \
         -nclibdirname "$COVDIR/unit_libs" -l "$COVDIR/dsu_unit.log" \
         +STIM="$COVDIR/dsu/dsu_stim.mem" +EXP="$COVDIR/dsu/dsu_expected.mem" > /dev/null 2>&1
    if grep -q "RESULT         : PASSED" "$COVDIR/dsu_unit.log"; then
        printf "%-18s %s\n" "dsu_unit" "PASS"
        ran="$ran $COVDIR/cov_work/scope/dsu_unit"
    else
        printf "%-18s %s\n" "dsu_unit" "FAIL"
    fi

    # the six constrained-random block TBs (top module is tb_top)
    for u in decode_control imm_gen reg_file branch_predict hazard_forward_unit id_stage; do
        irun -64bit -f "tb/core/filelist_$u.f" -top tb_top \
             -coverage all -cov_cgsample -covoverwrite \
             -covworkdir "$COVDIR/cov_work" -covtest "unit_$u" \
             -nclibdirname "$COVDIR/unit_libs" -l "$COVDIR/unit_$u.log" > /dev/null 2>&1
        f=$(grep -c "\[FAIL\]" "$COVDIR/unit_$u.log" 2>/dev/null)
        printf "%-18s %s\n" "unit_$u" "$([ "$f" = 0 ] && echo PASS || echo "FAIL($f)")"
        [ -d "$COVDIR/cov_work/scope/unit_$u" ] && ran="$ran $COVDIR/cov_work/scope/unit_$u"
    done
fi

[ -z "$ran" ] && { echo "no coverage scopes produced"; exit 1; }

# ---------------------------------------------------------------------------
# 3. merge every run and report
# ---------------------------------------------------------------------------
# Merging is the whole point of having IMC: each test is a separate simulation
# starting with empty covergroups, so without a bin-level merge the only honest
# aggregate is a per-group maximum. Merged, these are real totals.
echo; echo "merging $(echo $ran | wc -w) runs..."
{
  echo "merge $ran -out $COVDIR/cov_work/merged -overwrite -initial_model union_all"
  echo "load -run $COVDIR/cov_work/merged"
  echo "report -summary -out $COVDIR/summary.txt"
  echo "report -summary -type -out $COVDIR/module_summary.txt"
  echo "report -detail -metrics covergroup -out $COVDIR/functional.txt"
  echo "report -detail -out $COVDIR/detail.txt"
  echo "exit"
} > "$COVDIR/merge.tcl"

"$IMC" -exec "$COVDIR/merge.tcl" 2>&1 | grep -E "\*E,|\*F,|MERGE" | head -5

echo
echo "================= MERGED COVERAGE ================="
awk 'NR<=4' "$COVDIR/summary.txt" 2>/dev/null | cut -c1-118
echo
echo "----------------- functional (covergroups) -----------------"
grep -E "^u_cg_" "$COVDIR/functional.txt" 2>/dev/null | awk '{printf "  %-16s %s %s\n",$1,$2,$3}'
echo
echo "reports: $COVDIR/summary.txt  $COVDIR/functional.txt  $COVDIR/detail.txt"
