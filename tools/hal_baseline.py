#!/usr/bin/env python3
"""
hal_baseline.py - HAL findings may not rise.

    python3 tools/hal_baseline.py --check  sim/static/hal.log     (make static_lint)
    python3 tools/hal_baseline.py --update sim/static/hal.log     (after a reviewed change)

flow/2_static/hal_baseline.txt holds one line per rule, "<severity> <rule> <count>", counted
over the whole chip run. The check fails when
  - a rule has more findings than its baseline (something new, or something got worse), or
  - a rule that is not in the baseline appears at all.
A count that went DOWN passes and is reported, so the baseline can be lowered in the same
commit. Updating is a decision: git diff on the baseline shows exactly what changed, and the
class table of hal_waivers.txt is where a new rule is explained.
"""
import re, sys, collections, os

BASE = os.environ.get("HAL_BASELINE") or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "flow/2_static/hal_baseline.txt")

def count(log):
    c = collections.Counter()
    for l in open(log, errors="replace"):
        m = re.match(r"^hal\w+: \*([EWN]),([A-Z0-9]+) \(", l)
        if m: c[(m.group(1), m.group(2))] += 1
    return c

def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("--check", "--update"):
        sys.exit(__doc__)
    mode, log = sys.argv[1:]
    cur = count(log)
    if not cur:
        print("hal_baseline: no HAL findings parsed from %s: the run did not happen" % log); return 1
    if mode == "--update":
        with open(BASE, "w") as fh:
            fh.write("# HAL findings per rule on the chip (make static_lint). May not rise: tools/hal_baseline.py.\n")
            fh.write("# severity rule count\n")
            for (s, r), n in sorted(cur.items(), key=lambda kv: (kv[0][0] != "E", kv[0][1])):
                fh.write("%s %s %d\n" % (s, r, n))
        print("hal_baseline: wrote %d rules, %d findings to %s" % (len(cur), sum(cur.values()), BASE)); return 0
    base = {}
    for l in open(BASE):
        if l.startswith("#") or not l.strip(): continue
        s, r, n = l.split(); base[(s, r)] = int(n)
    worse = [(k, base.get(k), n) for k, n in sorted(cur.items()) if n > base.get(k, 0)]
    better = [(k, base[k], cur.get(k, 0)) for k in sorted(base) if cur.get(k, 0) < base[k]]
    for (s, r), b, n in worse:
        print("  RISEN  %s %-7s baseline %s now %d%s" % (s, r, b if b is not None else "-", n, "   (rule not in the baseline)" if b is None else ""))
    if better:
        print("  lower  %s" % ", ".join("%s %d>%d" % (r, b, n) for (s, r), b, n in better[:8]) + (" ..." if len(better) > 8 else ""))
    print("hal_baseline: %d rules, %d findings; baseline %d; %d rule(s) risen, %d lower" % (
        len(cur), sum(cur.values()), sum(base.values()), len(worse), len(better)))
    return 1 if worse else 0

sys.exit(main())
