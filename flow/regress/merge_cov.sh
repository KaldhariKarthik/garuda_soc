#!/usr/bin/env bash
# =============================================================================
# merge_cov.sh [session dir] - merge the coverage of every run in a vManager
# session (default: the most recent one under sim/vm_sessions) with IMC and
# write the reports to sim/cov_merged/.
#
#   -initial_model union_all is required: the runs have different top modules
#   (block benches, tb_boot, tb_chip), and IMC's default keeps only the first
#   run's model and silently drops the rest (Docs/COVERAGE.md).
# =============================================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
source scripts/setup_env.sh > /dev/null
export PATH=/home/install/INCISIVE152/tools/bin:/home/install/INCISIVE152/bin:$PATH

S=${1:-$(ls -dt sim/vm_sessions/*/ 2>/dev/null | head -1)}
[ -d "$S" ] || { echo "no session directory - run the regression first"; exit 1; }
OUT=sim/cov_merged
rm -rf "$OUT"; mkdir -p "$OUT"

runs=$(find "$S" -type d -path '*/cov_work/garuda/*' | sort | tr '\n' ' ')
n=$(echo $runs | wc -w)
[ "$n" -gt 0 ] || { echo "no coverage data under $S"; exit 1; }
echo "merging $n runs from $S"

{
  echo "merge $runs -out $OUT/merged -overwrite -initial_model union_all"
  echo "load -run $OUT/merged"
  echo "report -summary -inst -out $OUT/summary.txt"
  echo "report -summary -type -out $OUT/module_summary.txt"
  echo "report -detail -metrics covergroup -out $OUT/functional.txt"
  echo "exit"
} > "$OUT/merge.tcl"

imc -exec "$OUT/merge.tcl" 2>&1 | grep -E '\*E,|\*F,' | head -5
echo "reports: $OUT/summary.txt  $OUT/module_summary.txt  $OUT/functional.txt"
echo "GUI:     imc -load $OUT/merged &"
