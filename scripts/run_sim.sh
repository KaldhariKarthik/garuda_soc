#!/usr/bin/env bash
# =============================================================================
# run_sim.sh -- run a GARUDA testbench under Icarus Verilog
#
# WHAT THIS IS, AND WHAT IT IS NOT
# --------------------------------
# The signoff simulator for this project is Cadence Xcelium and nothing here
# replaces it. This is the back-end for machines that have no Cadence licence:
# it consumes the SAME .f filelists the Makefile's xrun/xsim legs consume, so a
# testbench run here is running exactly the same source list that runs there.
# That property is the whole point -- the moment the synthesis or lint flow gets
# its own hand-written source list, it starts building different RTL from the
# one that was simulated, and the divergence is silent.
#
# Icarus is a real compiler with a real parser, which is most of the value: the
# first thing it does is refuse to compile RTL that only a reader believed in.
#
# USAGE
#     ./scripts/run_sim.sh tb_crg
#     ./scripts/run_sim.sh tb_clic +VERBOSE
#
# Output lands in sim/<top>/.
# =============================================================================
set -u

TOP=${1:-}
shift || true
PLUSARGS="$*"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

case "$TOP" in
    tb_crg)              FLIST=tb/clk_div/filelist_crg.f       ;;
    tb_mem_subsystem)    FLIST=tb/mem/filelist_mem.f           ;;
    tb_ahb2apb)          FLIST=tb/ahb2apb/filelist_ahb2apb.f   ;;
    tb_clic)             FLIST=tb/clic/filelist_clic.f         ;;
    tb_ahb_interconnect) FLIST=tb/ahb/filelist_ahb_ic.f        ;;
    "")
        echo "usage: $0 <top> [+plusargs]"
        exit 1 ;;
    *) echo "unknown top '$TOP'"; exit 1 ;;
esac

if ! command -v iverilog > /dev/null 2>&1; then
    echo "ERROR: iverilog is not on PATH."
    echo "  Install with:  choco install iverilog"
    echo "  See docs/RTL_LOG_2026-09-16.md for what has and has not been run."
    exit 127
fi

OUT=sim/$TOP
mkdir -p "$OUT"

# python3 is a Microsoft Store stub on some Windows installs and exits without
# running anything, so resolve an interpreter that actually works rather than
# assuming the name.
PY=""
for c in python3 python py; do
    if command -v $c > /dev/null 2>&1 && $c -c "" > /dev/null 2>&1; then PY=$c; break; fi
done
if [ -z "$PY" ]; then echo "ERROR: no working python interpreter found"; exit 1; fi

SRCS=$($PY scripts/expand_filelist.py "$FLIST") || exit 1
INCS=$($PY scripts/expand_filelist.py "$FLIST" --incdirs) || exit 1

echo "=== compiling $TOP ($(echo "$SRCS" | wc -l) sources) ==="

# -g2012 is required: the testbenches are SystemVerilog and the RTL uses
#   $clog2, indexed part-selects and arrays of nets.
# -Wall surfaces width mismatches and implicit declarations, which is where
#   most first-compile RTL defects actually live.
iverilog -g2012 -Wall -o "$OUT/$TOP.vvp" -s "$TOP" $INCS $SRCS \
    2> "$OUT/compile.log"
RC=$?

if [ $RC -ne 0 ]; then
    echo "COMPILE FAILED (rc=$RC)"
    grep -E "error|Error|ERROR" "$OUT/compile.log" | head -30
    echo "  full log: $OUT/compile.log"
    exit $RC
fi

WARNS=$(grep -c -i "warning" "$OUT/compile.log" 2>/dev/null || echo 0)
echo "    compiled clean ($WARNS warnings -- see $OUT/compile.log)"

echo "=== running $TOP ==="
vvp "$OUT/$TOP.vvp" $PLUSARGS 2>&1 | tee "$OUT/run.log"

echo
echo "=== verdict ==="
grep -E "RESULT:|PASSED|FAILED|TIMEOUT|checks=" "$OUT/run.log" | tail -5
grep -c "\[FAIL\]" "$OUT/run.log" | sed 's/^/    [FAIL] lines: /'
