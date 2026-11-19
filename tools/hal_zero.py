#!/usr/bin/env python3
"""hal_zero.py - the HAL gate with every rule on (zero-waiver ruling, 2026-11-16).

    python3 tools/hal_zero.py <hal.log>                 check: exit 1 on any finding without an
                                                        exception, or any exception that matches nothing
    python3 tools/hal_zero.py <hal.log> --summary       the same, plus the open findings per rule and directory
    python3 tools/hal_zero.py <hal.log> --list RULE     every open finding of one rule

HAL runs with its whole default rule set (flow/2_static/hal.f switches nothing off). A
finding is closed only by changing the RTL, or by one row of flow/2_static/hal_exceptions.tsv:

    RULE <TAB> file:line <TAB> text <TAB> CLASS

where `text` is a piece of the finding's message (the signal or port name) and CLASS is one
of the classes defined at the top of the same file ("# class NAME: reason"). Each class names
a structure the chip must have. The exception is per RTL line: a row covers every finding of
that rule on that line whose message holds `text`, i.e. the line in every instance of its
module (the APB shim is instantiated eight times; its IRQEN register is one line and one
row). A row that matches no finding (the line moved, or the RTL changed) fails the check,
so the list cannot go stale; an empty `text` is refused.
"""
import collections, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXC = os.environ.get("HAL_EXCEPTIONS") or os.path.join(ROOT, "flow/2_static/hal_exceptions.tsv")
PAT = re.compile(r"^hal[a-z]*: \*([EWNF]),([A-Z0-9]+) \(\./([^,]*),(\d+)\|\d+\): (.*)$")


def findings(log):
    out = []
    with open(log, errors="replace") as fh:
        for ln in fh:
            m = PAT.match(ln.rstrip("\n"))
            if m:
                sev, rule, f, line, msg = m.groups()
                out.append((rule, sev, f, int(line), msg))
    return out


def exceptions():
    classes, rows = {}, []
    if not os.path.exists(EXC):
        return classes, rows
    with open(EXC) as fh:
        for n, ln in enumerate(fh, 1):
            ln = ln.rstrip("\n")
            m = re.match(r"^# class ([A-Z_]+): (.+)$", ln)
            if m:
                classes[m.group(1)] = m.group(2)
                continue
            if not ln.strip() or ln.startswith("#"):
                continue
            p = ln.split("\t")
            if len(p) != 4:
                raise SystemExit("hal_zero: %s:%d: need 4 tab-separated fields" % (EXC, n))
            rule, where, text, cls = p
            if not text.strip():
                raise SystemExit("hal_zero: %s:%d: empty text field" % (EXC, n))
            f, _, line = where.rpartition(":")
            rows.append((n, rule, f, int(line), text, cls))
    return classes, rows


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    log = sys.argv[1]
    fnd = findings(log)
    if not fnd:
        print("hal_zero: no HAL findings parsed from %s: the run did not happen" % log)
        return 1
    with open(log, errors="replace") as fh:
        if "Analysis complete" not in fh.read():
            print("hal_zero: %s has no 'Analysis complete': the run did not finish" % log)
            return 1
    classes, rows = exceptions()
    bad = 0
    used = [False] * len(fnd)
    for n, rule, f, line, text, cls in rows:
        if cls not in classes:
            print("hal_zero: %s:%d: class %s is not defined" % (EXC, n, cls))
            bad += 1
            continue
        hits = [i for i, x in enumerate(fnd)
                if x[0] == rule and x[2] == f and x[3] == line and text in x[4] and not used[i]]
        if not hits:
            print("hal_zero: STALE exception %s:%d: %s %s:%d '%s' matches no finding" % (EXC, n, rule, f, line, text))
            bad += 1
            continue
        for i in hits:
            used[i] = True
    open_ = [x for i, x in enumerate(fnd) if not used[i]]
    sev = collections.Counter(x[1] for x in open_)
    print("hal_zero: %d findings, %d excepted (%d rows), %d open (E %d, W %d, N %d), %d bad exception rows"
          % (len(fnd), sum(used), len(rows), len(open_), sev["E"], sev["W"], sev["N"], bad))
    if "--summary" in sys.argv:
        by_rule = collections.Counter((x[0], x[1]) for x in open_)
        for (r, s), c in sorted(by_rule.items(), key=lambda kv: -kv[1]):
            dirs = collections.Counter("/".join(x[2].split("/")[:3 if "third_party" in x[2] else 2]) for x in open_ if x[0] == r)
            print("  %s %-7s %5d   %s" % (s, r, c, ", ".join("%s %d" % kv for kv in dirs.most_common(6))))
    if "--list" in sys.argv:
        want = sys.argv[sys.argv.index("--list") + 1]
        for r, s, f, line, msg in open_:
            if r == want:
                print("%s\t%s:%d\t%s" % (r, f, line, msg))
    return 0 if not open_ and not bad else 1


if __name__ == "__main__":
    sys.exit(main())
