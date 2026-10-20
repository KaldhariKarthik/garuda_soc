#!/usr/bin/env python3
"""
cov_local.py - covergroup coverage from Verilator, without IMC, compared with the record.

    python3 tools/cov_local.py report  <coverage.dat> [more.dat ...]
    python3 tools/cov_local.py compare <BLOCK> <coverage.dat> [more.dat ...]
    python3 tools/cov_local.py compare DMA sim/a.dat sim/b.dat --only cg_beat,cg_ctrl

Reads the coverage.dat files that a Verilator build with --coverage-user writes
(+verilator+coverage+file+<path> names them per run), adds the counts of every
bin over all of them (a merge), and prints, per covergroup, the bins hit out of
the bins that count, and the holes by coverpoint or cross. ignore_bins and
illegal_bins do not count, as in IMC.

compare puts that next to the block's section of Docs/coverage/FINDINGS.md, the
latest IMC record (`make cov_chart`, Cadence, on the lab machine): the bins IMC
counted, and for every hole IMC listed whether it is still a hole here. Verilator
names cross bins `a_x_b` and auto bins `auto_3`; IMC writes `a,b` and `auto[3]`;
the names are compared after turning the first form into the second.

What it does NOT do: code coverage figures (Verilator's line and toggle counting
is not IMC's block and toggle counting, so those numbers are not comparable),
FSM and assertion coverage. On the same covergroups and the same tests the
functional figures agree with IMC bin for bin (DMA, 2026-10-21: cg_beat 97/134,
cg_ctrl 25/27, the same holes by name). Verilator 5.053 reports covergroup
coverage correctly; 5.052 returned 0.0 % from get_coverage() (Docs/bugs/track_a.md
TOOL-A2), which is what made Verilator runs look like zero functional coverage.
"""
import argparse
import collections
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FINDINGS = os.path.join(ROOT, "Docs", "coverage", "FINDINGS.md")


def read_dat(paths):
    """{(covergroup, bin path): count} summed over the files; set of ignored bins."""
    bins = collections.OrderedDict()
    skip = set()
    for p in paths:
        with open(p, encoding="latin1") as fh:
            for line in fh:
                if not line.startswith("C '") or "\x01t\x02covergroup" not in line:
                    continue
                rec, cnt = line[3:].rstrip("\n").rsplit("' ", 1)
                f = dict(x.split("\x02", 1) for x in rec.split("\x01") if "\x02" in x)
                h = f.get("h", "")
                if "." not in h:
                    continue
                cg, rest = h.split(".", 1)
                key = (cg, rest)
                bins[key] = bins.get(key, 0) + int(cnt)
                if f.get("Bt") in ("ignore", "illegal"):
                    skip.add(key)
    return bins, skip


def imc_name(s):
    """Verilator bin path -> IMC spelling: auto_3 -> auto[3], a_x_b -> a,b."""
    s = re.sub(r"auto_(\d+)", r"auto[\1]", s)
    return s.replace("_x_", ",")


def summarise(bins, skip, only=None):
    out = collections.OrderedDict()
    for (cg, rest), c in bins.items():
        if only and cg not in only:
            continue
        if (cg, rest) in skip:
            continue
        d = out.setdefault(cg, {"hit": 0, "total": 0, "holes": collections.OrderedDict()})
        d["total"] += 1
        if c > 0:
            d["hit"] += 1
        else:
            item, _, b = rest.partition(".")
            d["holes"].setdefault(item, []).append(imc_name(b))
    return out


def read_findings(block):
    """{covergroup: (hit, total, {item: [holes]})} from the block's FINDINGS.md section."""
    if not os.path.exists(FINDINGS):
        return {}
    text = open(FINDINGS, encoding="utf-8").read()
    m = re.search(r"^## %s\s*$(.*?)(?=^## |\Z)" % re.escape(block), text, re.M | re.S)
    if not m:
        return {}
    res = {}
    cur = None
    for line in m.group(1).splitlines():
        g = re.match(r"\*\*`(\w+)`\*\* \((\d+) of (\d+) bins\)", line)
        if g:
            cur = g.group(1)
            res[cur] = (int(g.group(2)), int(g.group(3)), collections.OrderedDict())
            continue
        g = re.match(r"- `(\w+)`: \d+ uncovered: (.*)", line)
        if g and cur:
            res[cur][2][g.group(1)] = [x.strip().strip("`") for x in g.group(2).split("`, `")]
    return res


def pct(a, b):
    return "%.1f%%" % (100.0 * a / b) if b else "-"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("cmd", choices=("report", "compare"))
    ap.add_argument("args", nargs="+")
    ap.add_argument("--only", default="", help="comma-separated covergroups to show")
    a = ap.parse_args()
    block = None
    files = a.args
    if a.cmd == "compare":
        block, files = a.args[0], a.args[1:]
        if not files:
            ap.error("compare needs a block and at least one coverage.dat")
    for f in files:
        if not os.path.exists(f):
            ap.error("no such file: %s" % f)
    only = set(x for x in a.only.split(",") if x)
    bins, skip = read_dat(files)
    here = summarise(bins, skip, only)
    if not here:
        print("cov_local: no covergroup bins in %s (built with --coverage-user?)" % ", ".join(files))
        return 1

    if a.cmd == "report":
        for cg, d in here.items():
            print("%s: %d of %d bins (%s)" % (cg, d["hit"], d["total"], pct(d["hit"], d["total"])))
            for item, hs in d["holes"].items():
                print("   %s: %d uncovered: %s" % (item, len(hs), ", ".join(hs)))
        return 0

    rec = read_findings(block)
    if not rec:
        print("cov_local: no section '## %s' with covergroups in %s" % (block, FINDINGS))
    print("%-24s %-22s %-22s" % ("covergroup", "record (IMC)", "here (Verilator)"))
    for cg in list(rec) + [c for c in here if c not in rec]:
        r = rec.get(cg)
        h = here.get(cg)
        print("%-24s %-22s %-22s" % (cg,
              "%d/%d %s" % (r[0], r[1], pct(r[0], r[1])) if r else "not recorded",
              "%d/%d %s" % (h["hit"], h["total"], pct(h["hit"], h["total"])) if h else "not built here"))
    for cg, (rh, rt, rholes) in rec.items():
        h = here.get(cg)
        if not h:
            continue
        print("\n%s holes on record:" % cg)
        for item, hs in rholes.items():
            still = set(h["holes"].get(item, []))
            closed = [x for x in hs if x not in still]
            open_ = [x for x in hs if x in still]
            print("   %-22s %2d on record: %2d closed here, %2d still open%s" % (
                item, len(hs), len(closed), len(open_), (": " + ", ".join(open_)) if open_ else ""))
        new = {i: [x for x in hs if x not in rholes.get(i, [])] for i, hs in h["holes"].items()}
        new = {i: hs for i, hs in new.items() if hs}
        if new:
            print("   not holes on record, holes here (these runs do not hit them):")
            for i, hs in new.items():
                print("      %s: %s" % (i, ", ".join(hs)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
