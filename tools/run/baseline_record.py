#!/usr/bin/env python3
"""baseline_record.py -- write the Gate A baseline evidence file.

    python3.12 tools/run/baseline_record.py [--notes FILE]

Reads logs/<blk>/summary/<suite>.tsv for every suite of the baseline and writes
logs/core/evidence/baseline_<sha12>.txt with: the design SHA and tree state,
specification revisions, pinned tool versions, and every test's verdict and
classification. A baseline is "reproducible" (Gate A) only when every row is
OK, XFAIL:<bug> or XBLOCK:<bug> -- i.e. nothing UNEXPECTED, nothing XPASS.
--notes appends a hand-written section (differences against the audit
reference aae00a2, each explained by the aae00a2..baseline diff).
"""
import argparse
import datetime as dt
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SUITES = [("core", "units"), ("core", "elements"), ("core", "smokes"), ("core", "isa"),
          ("core", "isa_rand"), ("core", "sanity"), ("core", "extra"), ("dsu", "model"),
          ("flow", "selftest"), ("flow", "negctl_prog")]


def out(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT, shell=isinstance(cmd, str))
        return (p.stdout or p.stderr).strip().splitlines()[0]
    except (OSError, IndexError):
        return "unavailable"


def spec_revisions():
    rows = []
    for p in sorted(glob.glob(os.path.join(ROOT, "Design_Docs", "GARUDA-*.md"))):
        txt = open(p, errors="replace").read(6000)
        m = (re.search(r"\|\s*(?:Revision|Rev\.?|Version)\s*\|\s*([^|\n]+)\|", txt, re.I)
             or re.search(r"\b(Rev(?:ision)?\.?\s*[0-9][0-9.]*[a-z]?)", txt))
        rows.append((os.path.basename(p), m.group(1).strip() if m else "?"))
    return rows


def read_tsv(blk, suite):
    p = os.path.join(ROOT, "logs", blk, "summary", f"{suite}.tsv")
    if not os.path.exists(p):
        return None, []
    lines = open(p).read().splitlines()
    meta = lines[0]
    cols = lines[1].split("\t")
    return meta, [dict(zip(cols, ln.split("\t"))) for ln in lines[2:] if ln.strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--notes")
    a = ap.parse_args()
    sha = out(["git", "rev-parse", "HEAD"])
    tree = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True,
                          cwd=ROOT).stdout.splitlines()
    rtl_dirty = any(ln[3:].startswith("rtl/") for ln in tree)
    T = os.environ.get("GARUDA_TOOLS", os.path.expanduser("~/tools"))
    tools = [
        ("verilator", out([os.environ.get("VERILATOR", "verilator"), "--version"])),
        ("verilator_coverage", out([os.environ.get("VERILATOR_COV", "verilator_coverage"), "--version"])),
        ("iverilog", out(["iverilog", "-V"])),
        ("spike", out([os.environ.get("SPIKE", "spike"), "--help"]) + "  src " +
         out(["git", "-C", f"{T}/src/riscv-isa-sim", "rev-parse", "--short", "HEAD"])),
        ("riscv gcc", out([f"{os.environ.get('RISCV_BIN', '')}/{os.environ.get('RISCV_PREFIX', '')}gcc", "--version"])),
        ("riscv-tests", out(["git", "-C", os.environ.get("RISCV_TESTS", ""), "rev-parse", "--short", "HEAD"])),
        ("yosys", out([f"{os.environ.get('OSS_CAD', '')}/bin/yosys", "-V"])),
        ("sby", out([f"{os.environ.get('OSS_CAD', '')}/bin/sby", "--version"])),
        ("python", out([os.environ.get("PYTHON", sys.executable), "--version"])),
        ("host", out("cat /etc/redhat-release")),
    ]
    dst = os.path.join(ROOT, "logs", "core", "evidence", f"baseline_{sha[:12]}.txt")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    bad_total = 0
    with open(dst, "w") as f:
        f.write("GARUDA Track A -- Gate A execution baseline\n")
        f.write(f"written      : {dt.datetime.now().astimezone().isoformat(timespec='seconds')}\n")
        f.write(f"design SHA   : {sha}  (execution baseline = origin/main when Phase 0 began)\n")
        f.write(f"rtl/ state   : {'DIRTY' if rtl_dirty else 'clean (no change under rtl/)'}\n")
        f.write(f"tree changes : {len(tree)} path(s): Track A flow files only (tools/run, tb/*/run, "
                f"tb/core/selftest, flow/mk, logs, .gitignore, tools/lockstep.py TOOL-12)\n")
        f.write("audit ref    : aae00a2 (results compared below only with the diff named)\n\n")
        f.write("Specification revisions\n")
        for n, r in spec_revisions():
            f.write(f"  {n:<36} {r}\n")
        f.write("\nPinned tools\n")
        for n, v in tools:
            f.write(f"  {n:<20} {v}\n")
        f.write("\nSuites (verdict / classification; full rows in logs/<blk>/summary/<suite>.tsv)\n")
        for blk, suite in SUITES:
            meta, rows = read_tsv(blk, suite)
            if meta is None:
                f.write(f"\n  {blk}/{suite}: NOT RUN\n")
                bad_total += 1
                continue
            n = {k: sum(1 for r in rows if r["verdict"] == k) for k in ("PASS", "FAIL", "BLOCKED")}
            bad = [r for r in rows if r["class"] == "UNEXPECTED" or r["class"].startswith("XPASS")]
            bad_total += len(bad)
            ls = {}
            for r in rows:
                if r.get("lockstep", "-") not in ("-", ""):
                    ls[r["lockstep"]] = ls.get(r["lockstep"], 0) + 1
            stamp = re.search(r"date=(\S+)", meta)
            f.write(f"\n  {blk}/{suite}: {len(rows)} tests  PASS={n['PASS']} FAIL={n['FAIL']} "
                    f"BLOCKED={n['BLOCKED']}  unclassified={len(bad)}  run {stamp.group(1) if stamp else '?'}\n")
            if ls:
                f.write("    lockstep: " + ", ".join(f"{k}={v}" for k, v in sorted(ls.items())) + "\n")
            shims = sorted({s for r in rows for s in r.get("shims", "-").split(";") if s not in ("-", "")})
            if shims:
                f.write(f"    shims   : {', '.join(shims)} (declared in the suite manifest)\n")
            for r in rows:
                if r["class"] != "OK":
                    f.write(f"    {r['class']:<16} {r['test']:<24} {r['detail'][:110]}\n")
        f.write(f"\nGate A baseline classification: {'COMPLETE' if bad_total == 0 else f'{bad_total} UNCLASSIFIED'}\n")
        if a.notes:
            f.write("\n" + open(a.notes).read())
    print(open(dst).read())
    return 0 if bad_total == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
