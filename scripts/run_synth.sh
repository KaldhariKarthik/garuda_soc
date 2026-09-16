#!/usr/bin/env bash
# =============================================================================
# run_synth.sh -- generic-gate synthesis of the GARUDA SoC with Yosys
#
# WHAT THIS IS FOR
# ----------------
# This is a STRUCTURAL synthesis check, not the signoff flow. Signoff is Cadence
# Genus against the 28 nm library, and nothing here replaces it. What this does
# give you, on any machine with yosys and no licence at all, is the answer to
# the questions that actually stop a tapeout schedule:
#
#   - does every block synthesise, or is there RTL that only a simulator likes?
#   - how many cells and flops, and does that number move when it should not?
#   - ARE THERE ANY LATCHES?  This is the big one. A latch inferred from an
#     incomplete case or a missing else is invisible in simulation, survives
#     every functional test, and is found at STA or, worse, at silicon.
#   - does the hierarchy actually elaborate with the real leaf cells wired up?
#
# CORE-1 in docs/BUGS.md is exactly the class of defect this catches: RTL that
# means one thing to a simulator and something else to a synthesiser, which had
# been in the tree for the life of the project.
#
# USAGE
#     ./scripts/run_synth.sh                  # whole chip (default)
#     ./scripts/run_synth.sh garuda_soc_top   # SoC without clocks/resets
#     ./scripts/run_synth.sh clic_top         # one block
#
# Output lands in sim/synth/<top>/.
# =============================================================================
set -u

TOP=${1:-garuda_chip_top}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

case "$TOP" in
    garuda_chip_top) FLIST=rtl/soc/filelist_chip.f ;;
    garuda_soc_top)  FLIST=rtl/soc/filelist_soc.f  ;;
    clic_top)        FLIST=rtl/clic/filelist.f     ;;
    ahb2apb_bridge)  FLIST=rtl/ahb2apb/filelist.f  ;;
    isram_top|dsram_top|bootrom_top) FLIST=rtl/mem/filelist.f ;;
    clk_div)         FLIST=rtl/clk_div/filelist.f  ;;
    reset_ctrl)      FLIST=rtl/reset_ctrl/filelist.f ;;
    ahb_interconnect) FLIST=rtl/ahb/filelist.f     ;;
    dma_top)         FLIST=rtl/dma/filelist.f      ;;
    *) echo "unknown top '$TOP'"; exit 1 ;;
esac

OUT=sim/synth/$TOP
mkdir -p "$OUT"

if ! command -v yosys > /dev/null 2>&1; then
    echo "ERROR: yosys is not on PATH."
    echo "  This machine has no simulator or synthesis tool installed; see"
    echo "  docs/RTL_LOG_2026-09-16.md for what has and has not been run."
    echo "  Install with:  choco install yosys   (or use the oss-cad-suite build)"
    exit 127
fi

echo "=== expanding $FLIST ==="
python3 scripts/expand_filelist.py "$FLIST" --yosys > "$OUT/read.ys" || exit 1
echo "    $(grep -c read_verilog "$OUT/read.ys") source files"

cat > "$OUT/synth.ys" <<EOF
# ---- read -------------------------------------------------------------------
$(cat "$OUT/read.ys")

# ---- elaborate --------------------------------------------------------------
hierarchy -check -top $TOP

# ---- generic synthesis ------------------------------------------------------
# proc/opt/fsm/memory/techmap is the standard generic flow. No target library is
# mapped: the point is structural validity and a stable cell/flop/latch count,
# not timing. Genus does the real mapping.
proc
opt -full
fsm
opt -full
memory -nomap
opt -full
techmap
opt -full

# ---- the checks that matter -------------------------------------------------
# -assert makes 'check' FAIL the run on a real problem rather than printing it
# and exiting 0, which is the difference between a gate and a report nobody
# reads.
check -assert

stat
select -count t:\$dlatch t:\$_DLATCH_* %u
EOF

echo "=== running yosys ==="
yosys -q -l "$OUT/yosys.log" "$OUT/synth.ys"
RC=$?

echo
echo "=== result ==="
if [ $RC -ne 0 ]; then
    echo "SYNTHESIS FAILED (rc=$RC) -- see $OUT/yosys.log"
    grep -iE "^ERROR|Warning: Wire .* is used but has no driver" "$OUT/yosys.log" | head -20
    exit $RC
fi

sed -n '/=== design hierarchy ===/,/^$/p' "$OUT/yosys.log" | head -40
grep -E "Number of cells|Number of wires|Number of memories" "$OUT/yosys.log" | tail -5

LATCH=$(grep -cE '\\\$_?DLATCH' "$OUT/yosys.log")
echo
if [ "$LATCH" -gt 0 ]; then
    echo "*** LATCHES INFERRED -- investigate before doing anything else ***"
    grep -E '\\\$_?DLATCH' "$OUT/yosys.log" | head
    exit 1
else
    echo "No latches inferred."
fi

echo "Full log: $OUT/yosys.log"
