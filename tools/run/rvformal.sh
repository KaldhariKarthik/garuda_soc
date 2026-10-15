#!/usr/bin/env bash
# =============================================================================
# rvformal.sh -- riscv-formal on the GARUDA core (Karthik's plan 5.6).
#   bash tools/run/rvformal.sh [jobs] [check-regex]
# Copies tb/core/riscv_formal/{wrapper.sv, mul32_altops.v, checks.cfg.in} into
# <riscv-formal>/cores/garuda (genchecks.py needs that location), fills in the
# design files (rtl/core/filelist_core.f minus the bound SVA, with the formal
# clock-gate pass-through and the ALTOPS multiplier), generates the checks,
# runs them, and writes logs/core/summary/rvformal.txt: one line per check,
# PASS / FAIL / ERROR. Exit 1 if any check does not pass.
# =============================================================================
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
JOBS=${1:-8}
ONLY=${2:-.}
T=${GARUDA_TOOLS:-$HOME/tools}
RVF=$T/src/riscv-formal
OSS=${OSS_CAD:-$T/oss-cad-suite}
D=$RVF/cores/garuda
rm -rf "$D"; mkdir -p "$D"
cp "$ROOT/tb/core/riscv_formal/wrapper.sv" "$ROOT/tb/core/riscv_formal/mul32_altops.v" "$D/"
FILES=$(cd "$ROOT" && python3.12 - <<'PY'
import sys
sys.path.insert(0, "tools/run")
import garuda_run as gr
srcs, _, _ = gr.expand_flist("rtl/core/filelist_core.f")
out = []
for s in srcs:
    if s.endswith("_sva.sv"):
        continue                                    # bound checkers: proven by fv_*
    if s == "rtl/core/core_clk_gate.v":
        s = "tb/core/formal/core_clk_gate_passthru.sv"
    if s == "rtl/core/mul32.v":
        continue                                    # replaced by the ALTOPS model
    out.append(f"{gr.ROOT}/{s}")
out.append("@basedir@/cores/@core@/mul32_altops.v")
print("\n".join(out))
PY
)
python3.12 - "$ROOT" "$D" <<PY
import sys
root, d = sys.argv[1], sys.argv[2]
s = open(f"{root}/tb/core/riscv_formal/checks.cfg.in").read()
s = s.replace("@ROOT@", root).replace("@FILES@", """$FILES""")
open(f"{d}/checks.cfg", "w").write(s)
PY
cd "$D" && PATH="$OSS/bin:$PATH" python3.12 ../../checks/genchecks.py > genchecks.log 2>&1 || { cat genchecks.log; exit 2; }
cd "$D/checks"
TARGETS=$(ls *.sby | sed 's/\.sby$//' | grep -E "$ONLY")
PATH="$OSS/bin:$PATH" make -k -j"$JOBS" $(for t in $TARGETS; do echo "$t/status"; done) > make.log 2>&1
OUT=$ROOT/logs/core/summary/rvformal.txt
mkdir -p "$(dirname "$OUT")"
{
echo "# riscv-formal (plan 5.6) $(date -Iseconds)  design=$(git -C "$ROOT" rev-parse --short=12 HEAD)  riscv-formal=$(git -C "$RVF" rev-parse --short=12 HEAD)"
pass=0; fail=0
for t in $TARGETS; do
    st=$(cat "$t/status" 2>/dev/null | awk '{print $1}')
    [ -n "$st" ] || st=ERROR
    printf '%-26s %s\n' "$t" "$st"
    [ "$st" = PASS ] && pass=$((pass+1)) || fail=$((fail+1))
done
echo "checks: $((pass+fail))  PASS: $pass  not PASS: $fail"
} > "$OUT"
cat "$OUT"
[ "$fail" = 0 ]
