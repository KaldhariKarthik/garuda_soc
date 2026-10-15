#!/usr/bin/env python3
"""throughput.py -- plan P0.11: measure tb_boot simulation speed and memory.

Runs tb/core/run/perf.toml (normal build) and perf_cov.toml (every Verilator
coverage kind) with --jobs 1, so no two simulations share the machine, then
reads each test's wall time and peak RSS from the runner summary and the
retired-instruction and cycle counts from its log (RUN-STATS line).

    python3 tools/run/throughput.py            run both suites, then report
    python3 tools/run/throughput.py --report   report from the last runs only

Writes logs/core/evidence/P0.11_throughput.txt. The numbers set the regression
budgets (merge-blocking / nightly / soak, H9); they are re-measured when the
machine, the tool versions or tb_boot change.
"""
import argparse
import datetime as dt
import os
import platform
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SUITES = ["tb/core/run/perf.toml", "tb/core/run/perf_cov.toml"]
OUT = os.path.join(ROOT, "logs", "core", "evidence", "P0.11_throughput.txt")


def rows(suite):
    tsv = os.path.join(ROOT, "logs", "core", "summary", f"{suite}.tsv")
    lines = [l.rstrip("\n").split("\t") for l in open(tsv)]
    head = lines[1]
    return lines[0][0], [dict(zip(head, l)) for l in lines[2:]]


def stats(log):
    text = open(os.path.join(ROOT, log), errors="replace").read()
    m = re.search(r"RUN-STATS: retired=(\d+) cycles=(\d+)", text)
    return (int(m.group(1)), int(m.group(2))) if m else (None, None)


def cpu_model():
    try:
        for ln in open("/proc/cpuinfo"):
            if ln.startswith("model name"):
                return ln.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or "?"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true", help="report only, do not run")
    a = ap.parse_args()
    if not a.report:
        for s in SUITES:
            rc = subprocess.run([sys.executable, "tools/run/garuda_run.py", "suite", s,
                                 "--jobs", "1"], cwd=ROOT).returncode
            if rc:
                sys.exit(f"{s} did not pass (rc {rc}); no throughput figures from a failing run")
    out = [f"P0.11 throughput: tb_boot on t_perf_mix (Verilator, --jobs 1)",
           f"date      : {dt.datetime.now().astimezone().isoformat(timespec='seconds')}",
           f"machine   : {cpu_model()}, {os.cpu_count()} logical CPUs",
           ""]
    hdr = f"{'run':<18} {'build':<9} {'verdict':<7} {'retired':>9} {'cycles':>10} {'CPI':>5} " \
          f"{'wall s':>7} {'kinstr/s':>9} {'kcyc/s':>8} {'RSS MB':>7} {'lockstep s':>10}"
    out += [hdr, "-" * len(hdr)]
    speed = {}
    for s in SUITES:
        name = os.path.splitext(os.path.basename(s))[0]
        meta, rs = rows(name)
        out.append(f"# {meta}")
        for r in rs:
            ret, cyc = stats(r["log"])
            wall = float(r["wall_s"]) if r.get("wall_s") else None
            ok = ret and cyc and wall
            kips = ret / wall / 1e3 if ok else 0
            speed[r["test"]] = kips
            out.append(f"{r['test']:<18} {('coverage' if 'cov' in name else 'normal'):<9} "
                       f"{r['verdict']:<7} {ret or '-':>9} {cyc or '-':>10} "
                       f"{(cyc / ret if ok else 0):>5.2f} {wall or 0:>7.2f} {kips:>9.1f} "
                       f"{(cyc / wall / 1e3 if ok else 0):>8.1f} {r.get('rss_mb') or '-':>7} "
                       f"{r.get('lockstep_s') or '-':>10}")
    out.append("")
    for kind in ("nowait", "w2", "rand"):
        n, c = speed.get(f"perf_{kind}"), speed.get(f"perf_cov_{kind}")
        if n and c:
            out.append(f"coverage cost, {kind:<6}: {n / c:.2f}x slower ({n:.1f} -> {c:.1f} kinstr/s)")
    out.append("")
    out.append("Budget arithmetic (H9) uses the 'normal' and 'coverage' kinstr/s above:")
    out.append("  seconds per test ~= retired instructions / (kinstr/s * 1000) + build time;")
    out.append("  one Verilator tb_boot build is measured in logs/core/raw/build_tb_boot.log.")
    text = "\n".join(out) + "\n"
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    open(OUT, "w").write(text)
    print(text, end="")


if __name__ == "__main__":
    main()
