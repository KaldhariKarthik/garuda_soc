#!/usr/bin/env bash
# =============================================================================
# nightly.sh <a|b> - the nightly run of one track (plan task 1.4).
#
#   make nightly_b        track B: tree check, static checks, block benches, chip
#                         programs, the five UVM environments on tonight's seeds,
#                         the licence-free flow
#   make nightly_a        track A: its part is added by its owner in the list below
#
# Seeds come from the date: night N since 2026-01-01 runs the random seeds
# N*100+1 to N*100+20 of every UVM environment, so no two nights repeat a seed
# and a failing seed can be run again by its number.
#
# It writes, and never commits:
#   flow/nightly/<date>_<track>.md     the page: every stage, its result, its log
#   flow/nightly/seeds_<track>.csv     one line per environment per night (appended)
#   flow/nightly/bug_curve.csv         one line per night per track: open entries by priority
# A person reads the page in the morning and commits the three files.
#
# Exit status 0 only if every stage passed. To schedule it (crontab -e):
#   30 1 * * *  cd $HOME/garuda_soc && ./scripts/nightly.sh b > sim/nightly_b.out 2>&1
# =============================================================================
set -u
TRACK=${1:?usage: nightly.sh <a|b>}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
source scripts/setup_env.sh > /dev/null

DATE=$(date +%Y-%m-%d)
NIGHT=$(( ( $(date -d "$DATE" +%s) - $(date -d 2026-01-01 +%s) ) / 86400 ))
SEED0=$(( NIGHT * 100 ))
OUT=sim/nightly/${DATE}_$TRACK
PAGE=flow/nightly/${DATE}_$TRACK.md
mkdir -p "$OUT" flow/nightly

# stage name | make arguments
if [ "$TRACK" = b ]; then
STAGES="
tree check|check_tree
lint (HAL)|static_lint
clock domains (HAL)|static_cdc
block benches, track B|-k test_blocks_b
chip programs|-k test_chip
chip programs, X-propagation|static_xprop
UVM, five environments, 20 seeds from $((SEED0+1))|-k uvm_b SEED0=$SEED0 UVM_TAG=_nightly
runner self-check|selfcheck_runners
"
else
STAGES="
tree check|check_tree
core units and elements|-k test_core test_elements
block benches, track A|-k test_blocks_a
sanity programs|test_sanity
DSU against its model|test_dsu
ISA tests with Spike|regress
ISA tests, random bus waits, seed $((SEED0+1))|regress_rand SEED=$((SEED0+1))
CSR map|csr_map
random programs, 5 seeds|riscv_dv
"
fi

fail=0
{
echo "# Nightly run, track $(echo $TRACK | tr a-z A-Z), $DATE"
echo
echo "Tree \`$(git rev-parse --short HEAD)\`$([ -n "$(git status --porcelain -- rtl tb sw flow scripts tools)" ] && echo ' plus uncommitted changes'), started $(date +%H:%M). Night $NIGHT since 2026-01-01; random seeds from $((SEED0+1))."
echo
echo "| Stage | Result | Time | Log |"
echo "|---|---|---|---|"
} > "$PAGE"

echo "$STAGES" | while IFS='|' read -r name args; do
    [ -z "${name:-}" ] && continue
    log="$OUT/$(echo "$name" | tr -c 'a-zA-Z0-9\n' '_').log"
    s=$(date +%s)
    make $args > "$log" 2>&1; rc=$?
    t=$(( $(date +%s) - s ))
    if [ $rc -eq 0 ]; then r=pass; else r="**FAIL** (exit $rc)"; echo F >> "$OUT/.fail"; fi
    echo "| $name | $r | ${t} s | \`$log\` |" >> "$PAGE"
done

# the licence-free flow, when its tools are installed
if [ "$TRACK" = b ] && [ -d "$HOME/external/oss-cad-suite" ]; then
    for sim in icarus verilator; do
        log="$OUT/local_$sim.log"; s=$(date +%s)
        ( source scripts/setup_open_tools.sh > /dev/null; SIM=$sim ./scripts/run_sim.sh all ) > "$log" 2>&1; rc=$?
        [ $rc -eq 0 ] && r=pass || { r="**FAIL** (exit $rc)"; echo F >> "$OUT/.fail"; }
        echo "| block benches under $sim: $(grep -oE '[0-9]+ testbenches ran: [0-9]+ checks, [0-9]+ failures' "$log") | $r | $(( $(date +%s) - s )) s | \`$log\` |" >> "$PAGE"
    done
fi

# what failed, by line, so the page can be read without opening a log
if [ -s "$OUT/.fail" ]; then
    fail=1
    { echo; echo "## Failures"; echo; echo '```'
      grep -hE " FAIL$|NOT PASSED|VERDICT: FAIL|\[FAIL\]|SVA-FAIL|NOT WAIVED|WRONG|FAILED" "$OUT"/*.log | sort | uniq -c | sort -rn | head -40
      echo '```'; } >> "$PAGE"
fi

# seeds run tonight per UVM environment, and the running total
if [ "$TRACK" = b ]; then
    SC=flow/nightly/seeds_b.csv
    [ -f "$SC" ] || echo "date,environment,first_seed,seeds_run,seeds_failed,tree" > "$SC"
    for e in clic timers pwm gpio crg; do
        d=sim/uvm_${e}_nightly
        n=$(ls $d/random_s*.log 2> /dev/null | wc -l)
        p=$(grep -l 'RESULT: PASSED' $d/random_s*.log 2> /dev/null | wc -l)
        grep -q "^$DATE,$e," "$SC" || echo "$DATE,$e,$((SEED0+1)),$n,$((n-p)),$(git rev-parse --short HEAD)" >> "$SC"
    done
    { echo; echo "## Random seeds accumulated (block bar: 500 per environment, none failing in the last two weeks)"; echo
      echo "| Environment | Seeds run in all nights | Failed in all nights | Failed in the last 14 nights |"; echo "|---|---|---|---|"
      since=$(date -d "$DATE -14 days" +%Y-%m-%d)
      for e in clic timers pwm gpio crg; do
          awk -F, -v e=$e -v since="$since" '$2==e {n+=$4; f+=$5; if ($1 > since) r+=$5} END {printf "| %s | %d | %d | %d |\n", e, n, f, r}' "$SC"
      done; } >> "$PAGE"
fi

# the bug curve: open entries of this track tonight, by priority
BC=flow/nightly/bug_curve.csv
[ -f "$BC" ] || echo "date,track,open_p1,open_p2,open_p3,open_no_priority,fixed_or_done" > "$BC"
python3 - "$TRACK" "$DATE" >> "$BC" <<'PY'
import re, sys
track, date = sys.argv[1], sys.argv[2]
c = {"P1": 0, "P2": 0, "P3": 0, "none": 0}; closed = 0
for line in open("Docs/bugs/track_%s.md" % track):
    cells = [x.strip() for x in line.split("|")]
    if len(cells) < 6 or not re.match(r"^\*{0,2}[A-Z][A-Z0-9]{0,5}-[A-Z]?\d", cells[1]):
        continue
    state = next((x for x in cells if re.match(r"^\**(OPEN|FIXED|DONE|WAIVED|PARTLY)", x)), "")
    if state.lstrip("*").startswith("OPEN"):
        p = next((x for x in cells if x in ("P1", "P2", "P3", "**P1**", "**P2**")), "none").strip("*")
        c[p] += 1
    elif state:
        closed += 1
print("%s,%s,%d,%d,%d,%d,%d" % (date, track, c["P1"], c["P2"], c["P3"], c["none"], closed))
PY

echo >> "$PAGE"
echo "Finished $(date +%H:%M). $([ $fail -eq 0 ] && echo 'Every stage passed.' || echo 'At least one stage FAILED: see above.')" >> "$PAGE"
cat "$PAGE"
exit $fail
