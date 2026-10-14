#!/usr/bin/env bash
# Qualify `bugs.py check` (Gate A): every planted defect in a COPY of the
# register must make the check fail; the untouched copy must pass.
# Each plant edits table cells by column (whatever their current value) and is
# verified to have changed the copy: a plant that silently does not apply would
# otherwise "pass" and prove nothing (seen 2026-10-11, when T-12's status moved
# on and a value-matching sed stopped matching).
set -u
cd "$(git rev-parse --show-toplevel)"
PY=${PYTHON:-python3.12}
W=logs/flow/raw/bugs_selftest; mkdir -p logs/flow/summary logs/flow/raw
S=logs/flow/summary/bugs_selftest.txt; : > "$S"; ok=1

# plant <name> <op> [args...]  -- op: set <ID> <column> <value> | dup <ID> | del <ID>
plant() {
    local name=$1; shift
    rm -rf "$W"; cp -r Docs/bugs "$W"
    if ! "$PY" - "$W" "$@" <<'EOF'
import sys
d, op, rid = sys.argv[1], sys.argv[2], sys.argv[3]
p = f"{d}/core.md"
lines = open(p).read().splitlines(keepends=True)
hdr = next(l for l in lines if l.startswith("| ID |"))
cols = [c.strip() for c in hdr.strip().strip("|").split("|")]
idx = next(i for i, l in enumerate(lines) if l.startswith(f"| {rid} |"))
cells = [c.strip() for c in lines[idx].strip().strip("|").split("|")]
if op == "set":
    cells[cols.index(sys.argv[4])] = sys.argv[5]
    new = "| " + " | ".join(cells) + " |\n"
    if new == lines[idx]:
        sys.exit("plant changed nothing")
    lines[idx] = new
elif op == "dup":
    lines.insert(idx + 1, lines[idx])
elif op == "del":
    del lines[idx]
open(p, "w").writelines(lines)
EOF
    then echo "PLANT FAILED $name (the copy could not be changed as intended)" | tee -a "$S"; ok=0; return; fi
    if diff -q Docs/bugs/core.md "$W/core.md" > /dev/null; then
        echo "PLANT FAILED $name (copy identical to the register)" | tee -a "$S"; ok=0; return; fi
    if GARUDA_BUGS_DIR=$W $PY tools/bugs/bugs.py check > "$W.out" 2>&1; then
        echo "NOT CAUGHT  $name" | tee -a "$S"; ok=0
    else echo "CAUGHT      $name  ($(grep -m1 ERROR "$W.out" | cut -c1-110))" | tee -a "$S"; fi
}

rm -rf "$W"; cp -r Docs/bugs "$W"
if GARUDA_BUGS_DIR=$W $PY tools/bugs/bugs.py check > "$W.out" 2>&1; then echo "OK          untouched copy passes" | tee -a "$S"
else echo "WRONG       untouched copy fails" | tee -a "$S"; ok=0; fi
plant "duplicate ID"           dup T-12
plant "unknown status"         set T-12 Status MAYBE
plant "open without priority"  set T-12 Prio -
plant "bad Found date"         set T-12 Found 11/10/26
plant "FIXED without SHA"      set T-15 Fixed-in soon
plant "FIXED without test"     set T-13 "Regression test" -
plant "cited erratum missing"  del T-1
echo "verdict: $([ $ok = 1 ] && echo PASS || echo FAIL)" | tee -a "$S"
[ $ok = 1 ]
