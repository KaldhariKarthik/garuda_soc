#!/usr/bin/env python3
"""waiver_audit.py - every waiver of the chip, justified or not under D-40 (2026-11-20).

    python3 tools/waiver_audit.py              one line per kind, then the unjustified entries
    python3 tools/waiver_audit.py --all        every entry with its verdict
    python3 tools/waiver_audit.py --hal LOG    add HAL, judged by tools/hal_zero.py on LOG

D-40 (Docs/DECISIONS.md): a waiver stands only if it is specific (one entry, one point),
reasoned, backed by evidence, and checked for staleness by a tool. This tool reads each waiver
file and gives each entry a verdict:

  justified    reason present, specific, nothing marks it as a fix still owed
  unjustified  no reason, auto-generated, marked OPEN / "to be fixed", or wider than one point
               (a whole file or a glob) where D-40 asks for one point

Report only (2026-11-20); it becomes a make check_tree gate once the unjustified count is 0.
Stale checks are done by the tools that apply each file (make local_lint, run_synth.sh,
tools/cov/cov_report.py, tools/hal_zero.py); this tool does not repeat them.
"""
import csv, fnmatch, glob, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PENDING = [0]   # coverage waivers that are justified but whose reviewer field is still "pending"
# OPEN in capitals is a bug-register state; "open item" or "ties the gate open" is not a fix owed
OPEN_WORDS = re.compile(r"\bOPEN\b|[Tt]o be fixed|TODO|FIXME")


def rel(p):
    return os.path.relpath(p, ROOT)


def verilator():
    """lint_off lines; the reason is the comment block above (blank lines end it)."""
    p = os.path.join(ROOT, "flow/2_static/verilator_waivers.vlt")
    out, comment = [], []
    for n, ln in enumerate(open(p), 1):
        s = ln.strip()
        if s.startswith("//"):
            comment.append(s[2:].strip())
            continue
        if not s:
            comment = []
            continue
        if s.startswith("lint_off"):
            why = " ".join(comment)
            m = re.search(r'-file\s+"([^"]+)"', s)
            f = m.group(1) if m else ""
            vendored = "third_party" in f
            specific = "-lines" in s or (vendored and "*" not in f.replace("*rtl", "rtl"))
            if not why:
                v = "unjustified: no reason"
            elif OPEN_WORDS.search(why):
                v = "unjustified: marked as a fix owed"
            elif not specific:
                v = "unjustified: whole file or glob, not one point"
            else:
                v = "justified"
            out.append(("verilator", "%s:%d" % (rel(p), n), s, v))
    return out


def yosys():
    p = os.path.join(ROOT, "flow/2_static/yosys_waivers.txt")
    out = []
    for n, ln in enumerate(open(p), 1):
        if not ln.strip() or ln.startswith("#"):
            continue
        pat, _, why = ln.rstrip("\n").partition("\t")
        v = "justified" if why.strip() else "unjustified: no reason"
        if v == "justified" and re.search(r"\.\*\s*$|^\.\*", pat):
            v = "unjustified: pattern matches any instance, not one point"
        out.append(("yosys", "%s:%d" % (rel(p), n), pat, v))
    return out


def cdc():
    p = os.path.join(ROOT, "flow/2_static/cdc/reports/waivers.csv")
    # the reviewed waivers of the script: tag and pattern, each with its reason
    tcl = open(os.path.join(ROOT, "flow/2_static/cdc/cdc_chip.tcl")).read()
    user = re.findall(r'^waive (\w+) -\w+ \{([^}]+)\} "([^"]+)"', tcl, re.M)
    out = []
    for r in csv.DictReader(open(p)):
        c = (r.get("Comment") or "").strip()
        auto = r.get("Waiver Type") == "Auto" or c.lower().startswith("auto waived")
        occ = (r.get("Occurrence") or "").split("-")[0]
        cover = [u for u in user if u[0] == r.get("Tag") and fnmatch.fnmatch(occ, u[1])]
        if auto and cover:
            v = "justified"
            c = "auto-waived by the tool; reviewed in cdc_chip.tcl: " + cover[0][2]
        elif auto:
            v = "unjustified: auto-waived by the tool, no reviewed reason"
        elif not c:
            v = "unjustified: no reason"
        else:
            v = "justified"
        out.append(("cdc", "%s id %s" % (rel(p), r.get("Id")), "%s %s" % (r.get("Tag"), c[:60]), v))
    return out


def coverage():
    """tb/*/cov/*_waivers.toml: [[waiver]] tables with reason and evidence."""
    out = []
    for p in sorted(glob.glob(os.path.join(ROOT, "tb/*/cov/*_waivers.toml"))):
        cur, start = None, 0
        rows = []
        for n, ln in enumerate(open(p), 1):
            if ln.strip() == "[[waiver]]":
                if cur is not None:
                    rows.append((start, cur))
                cur, start = {}, n
                continue
            m = re.match(r'^(\w+)\s*=\s*"(.*)"\s*$', ln.rstrip("\n"))
            if cur is not None and m:
                cur[m.group(1)] = m.group(2)
        if cur is not None:
            rows.append((start, cur))
        for n, w in rows:
            if not w.get("reason", "").strip():
                v = "unjustified: no reason"
            elif not w.get("evidence", "").strip():
                v = "unjustified: no evidence"
            elif OPEN_WORDS.search(w.get("reason", "") + " " + w.get("evidence", "")):
                v = "unjustified: marked as a fix owed"
            else:
                v = "justified"
                if w.get("reviewer", "").startswith("pending"):
                    PENDING[0] += 1
            out.append(("coverage", "%s:%d" % (rel(p), n), "%s %s" % (w.get("id", "?"), w.get("category", "")), v))
    return out


def bins():
    """ignore_bins / illegal_bins: a reason comment on the line or the line above."""
    out = []
    files = []
    for d in ("tb", "rtl"):
        for dp, _, fs in os.walk(os.path.join(ROOT, d)):
            files += [os.path.join(dp, f) for f in fs if f.endswith((".sv", ".svh"))]
    for p in sorted(files):
        lines = open(p, errors="replace").read().split("\n")
        for i, ln in enumerate(lines):
            if not re.search(r"\b(ignore_bins|illegal_bins)\b", ln) or ln.strip().startswith("//"):
                continue
            here = "//" in ln
            # the comment above the group: walk up over the other bins of the same cross or
            # coverpoint (and their continuation lines) and its header line
            j, above = i - 1, False
            while j >= 0 and i - j <= 20:
                s = lines[j].strip()
                if s.startswith("//") or s.endswith("*/"):
                    above = True
                    break
                if re.search(r"\b(ignore_bins|illegal_bins|bins)\b", s) or not s.endswith(";") \
                        and not re.search(r"\b(endgroup|endmodule|end)\b", s):
                    if re.search(r"\b(cross|coverpoint)\b|\{\s*$", s):
                        j -= 1   # the header: one more line up may hold the comment
                        if j >= 0 and lines[j].strip().startswith("//"):
                            above = True
                        break
                    j -= 1
                    continue
                break
            v = "justified" if (here or above) else "unjustified: no reason in the source"
            out.append(("bins", "%s:%d" % (rel(p), i + 1), ln.strip()[:70], v))
    return out


def imc():
    """flow/cov/*_exclusions*.tcl written by hand (not generated from a tb/*/cov/*_waivers.toml):
    every exclude needs a -comment reason. Staleness is IMC's: an exclude that matches nothing
    is reported in the cov_chart log (2026-11-20: these files were not read before)."""
    out = []
    for p in sorted(glob.glob(os.path.join(ROOT, "flow/cov/*_exclusions*.tcl"))):
        head = open(p).read(600)
        # generated from a tb/*/cov/*_waivers.toml: counted there. top_exclusions.tcl is generated
        # from the register descriptions (tools/cov/gen_top_exclusions.py) and is counted here.
        if "GENERATED" in head and "gen_top_exclusions" not in head:
            continue
        for n, ln in enumerate(open(p), 1):
            s = ln.strip()
            if not s.startswith("exclude "):
                continue
            m = re.search(r'-comment\s+"([^"]*)"', s)
            v = "justified" if m and m.group(1).strip() else "unjustified: no -comment reason"
            out.append(("imc", "%s:%d" % (rel(p), n), s[:80], v))
    return out


def superlint():
    """flow/2_static/superlint/chip/findings.tsv (tools/superlint_findings.py): one row per
    finding with its class; OPEN is a finding no reading covers."""
    p = os.path.join(ROOT, "flow/2_static/superlint/chip/findings.tsv")
    if not os.path.exists(p):
        return [("superlint", rel(p), "no findings.tsv: findings explained in prose only",
                 "unjustified: not yet one entry per finding")]
    out = []
    for n, ln in enumerate(open(p), 1):
        if ln.startswith("#") or not ln.strip():
            continue
        tag, where, inst, cls, why = ln.rstrip("\n").split("\t")
        v = "unjustified: no class (OPEN)" if cls == "OPEN" or not why.strip() else "justified"
        out.append(("superlint", "%s:%d" % (rel(p), n), "%s %s %s" % (tag, where, cls), v))
    return out


def hal(log):
    r = subprocess.run([sys.executable, os.path.join(ROOT, "tools/hal_zero.py"), log],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    first = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else "no output"
    m = re.search(r"(\d+) open", first)
    n = int(m.group(1)) if m else -1
    return [("hal", rel(log) if log.startswith(ROOT) else log, first,
             "justified" if n == 0 and r.returncode == 0 else "unjustified: %d open findings" % n)]


def main():
    rows = verilator() + yosys() + cdc() + coverage() + imc() + bins() + superlint()
    if "--hal" in sys.argv:
        rows += hal(sys.argv[sys.argv.index("--hal") + 1])
    kinds = []
    for k, *_ in rows:
        if k not in kinds:
            kinds.append(k)
    print("%-10s %6s %10s %12s" % ("kind", "total", "justified", "unjustified"))
    bad = 0
    for k in kinds:
        e = [r for r in rows if r[0] == k]
        j = sum(1 for r in e if r[3] == "justified")
        print("%-10s %6d %10d %12d" % (k, len(e), j, len(e) - j))
        bad += len(e) - j
    print()
    for k, where, what, v in rows:
        if "--all" in sys.argv or v != "justified":
            print("%-9s %-10s %s  %s" % (k, "OK" if v == "justified" else "NO", where, v if v != "justified" else what[:60]))
            if v != "justified":
                print("%-20s %s" % ("", what[:110]))
    if PENDING[0]:
        print("\ncoverage: %d justified entries still have reviewer = pending" % PENDING[0])
    print("\nwaiver_audit: %d unjustified" % bad)
    return 0


if __name__ == "__main__":
    sys.exit(main())
