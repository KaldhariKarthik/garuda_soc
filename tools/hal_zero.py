#!/usr/bin/env python3
"""hal_zero.py - the HAL gate with every rule on (zero-waiver ruling, 2026-11-16).

    python3 tools/hal_zero.py <hal.log>                 check: exit 1 on any finding without an
                                                        exception, or any exception that matches nothing
    python3 tools/hal_zero.py <hal.log> --summary       the same, plus the open findings per rule and directory
    python3 tools/hal_zero.py <hal.log> --list RULE     every open finding of one rule
    python3 tools/hal_zero.py <hal.log> --off           the findings under rules off, per rule and scope
    python3 tools/hal_zero.py <hal.log> --own           judge own RTL only (vendor IP review open)

HAL runs with its whole default rule set (flow/2_static/hal_all.f switches nothing off).
D-40 (2026-11-20, zero unjustified waivers): flow/2_static/hal_rules.tsv lists the rules that
judge style or structure, or only report information; each is off for own RTL and/or vendored IP
(rtl/third_party) with its reason and the check that covers it instead. Their findings are
counted per rule and not judged; an OFF row whose rule fires nowhere fails (stale). Every other
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
RULES = os.environ.get("HAL_RULES") or os.path.join(ROOT, "flow/2_static/hal_rules.tsv")
KINDS = ("info", "style", "structure", "correctness")


def rule_list():
    """{rule: (own_off, vendor_off)} from hal_rules.tsv; every row needs a reason and a cover."""
    off = {}
    with open(RULES) as fh:
        for n, ln in enumerate(fh, 1):
            ln = ln.rstrip("\n")
            if not ln.strip() or ln.startswith("#"):
                continue
            p = ln.split("\t")
            if len(p) != 6 or p[1] not in ("on", "off") or p[2] not in ("on", "off") or p[3] not in KINDS \
                    or not p[4].strip() or not p[5].strip():
                raise SystemExit("hal_zero: %s:%d: need RULE, on|off, on|off, kind, reason, covered_by" % (RULES, n))
            if p[0] in off:
                raise SystemExit("hal_zero: %s:%d: %s listed twice" % (RULES, n, p[0]))
            off[p[0]] = (p[1] == "off", p[2] == "off")
    return off


def vendor(f):
    return f.startswith("rtl/third_party/")
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
    off = rule_list()
    ruled = [off.get(x[0], (False, False))[1 if vendor(x[2]) else 0] for x in fnd]
    for r, (o, v) in sorted(off.items()):
        if (o or v) and not any(ruled[i] and x[0] == r for i, x in enumerate(fnd)):
            print("hal_zero: STALE rule row %s: %s fires nowhere it is off" % (RULES, r))
            bad += 1
    used = list(ruled)
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
    if "--own" in sys.argv:
        # the gate while the vendor IP review is open (D-40): own RTL judged, vendor counted
        ven = [x for x in open_ if vendor(x[2])]
        open_ = [x for x in open_ if not vendor(x[2])]
        print("hal_zero: --own: %d open findings in rtl/third_party not judged (vendor review, D-40)" % len(ven))
    sev = collections.Counter(x[1] for x in open_)
    n_off = sum(ruled)
    print("hal_zero: %d findings: %d under rules off by hal_rules.tsv, %d excepted per line (%d rows), "
          "%d open (E %d, W %d, N %d), %d bad rows"
          % (len(fnd), n_off, sum(used) - n_off, len(rows), len(open_), sev["E"], sev["W"], sev["N"], bad))
    if "--off" in sys.argv:
        c = collections.Counter((x[0], "vendor" if vendor(x[2]) else "own") for i, x in enumerate(fnd) if ruled[i])
        for (r, sc), k in sorted(c.items(), key=lambda kv: -kv[1]):
            print("  off %-7s %-6s %5d" % (r, sc, k))
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
