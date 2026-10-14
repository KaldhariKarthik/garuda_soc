#!/usr/bin/env python3
"""Freeze the source identity of a baseline (Track A bus plan B0; Fresh plan section 3).

Writes logs/flow/evidence/baseline_<sha12>[_DIRTY]/ with:
  git_commit.txt    HEAD SHA and branch
  git_status.txt    `git status --porcelain=v1`
  worktree.diff     `git diff --binary` (tracked changes)
  index.diff        `git diff --cached --binary`
  untracked.txt     untracked files with their SHA-256 (the diff does not carry them)
  spec_vplan_hashes.txt  SHA-256 of the normative YAML, the bus/DMA specs and vPlans
  environment.txt   date, uname, open-tool versions (Verilator, Icarus, Yosys/SBY,
                    Python), Cadence tools if on PATH

Every later evidence file names this directory. A DIRTY tree is recorded as
DIRTY, never described as a clean commit-only baseline.

    python3 tools/run/freeze.py            # write the snapshot
    python3 tools/run/freeze.py --print    # only print the directory it would use
"""
import argparse
import datetime
import hashlib
import os
import platform
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HASHED = [
    "Design_Docs/garuda_system.yaml",
    "Design_Docs/GARUDA-AHB-SPEC-001.md",
    "Design_Docs/GARUDA-AHB2APB-SPEC-001.md",
    "Design_Docs/GARUDA-DMA-SPEC-001.md",
    "tb/ahb/GARUDA_AHB_vplan.csv",
    "tb/ahb2apb/GARUDA_AHB2APB_vplan.csv",
    "tb/dma/GARUDA_DMA_vplan.csv",
    "rtl/include/garuda_map.vh",
    "tb/common/garuda_map_pkg.sv",
]
TOOLS = [
    ["verilator", "--version"], ["iverilog", "-V"],
    # env.sh keeps the oss-cad-suite off PATH on purpose; its tools are run by path
    [os.path.join(os.environ.get("OSS_CAD", ""), "bin", "yosys"), "-V"],
    [os.path.join(os.environ.get("OSS_CAD", ""), "bin", "sby"), "--version"],
    ["xrun", "-version"], ["irun", "-version"], ["imc", "-version"], ["jg", "-version"],
]


def git(*a):
    return subprocess.run(["git", *a], cwd=ROOT, capture_output=True, text=True).stdout


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def first_line(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        out = (p.stdout or p.stderr).strip().splitlines()
        return out[0] if out else "(no output)"
    except (OSError, subprocess.TimeoutExpired):
        return "(not on PATH)"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--print", action="store_true")
    a = ap.parse_args()
    sha = git("rev-parse", "HEAD").strip()
    status = git("status", "--porcelain=v1")
    dirty = bool(status.strip())
    name = "baseline_%s%s" % (sha[:12], "_DIRTY" if dirty else "")
    out = os.path.join(ROOT, "logs", "flow", "evidence", name)
    if a.print:
        print(os.path.relpath(out, ROOT))
        return 0
    os.makedirs(out, exist_ok=True)
    branch = git("rev-parse", "--abbrev-ref", "HEAD").strip()
    with open(os.path.join(out, "git_commit.txt"), "w") as f:
        f.write("%s\nbranch %s\n%s\n" % (sha, branch, "DIRTY: uncommitted changes, see worktree.diff / untracked.txt"
                                        if dirty else "clean"))
    open(os.path.join(out, "git_status.txt"), "w").write(status)
    open(os.path.join(out, "worktree.diff"), "w").write(git("diff", "--binary"))
    open(os.path.join(out, "index.diff"), "w").write(git("diff", "--cached", "--binary"))
    with open(os.path.join(out, "untracked.txt"), "w") as f:
        for p in git("ls-files", "--others", "--exclude-standard").splitlines():
            fp = os.path.join(ROOT, p)
            if os.path.isfile(fp):
                f.write("%s  %s\n" % (sha256(fp), p))
    with open(os.path.join(out, "spec_vplan_hashes.txt"), "w") as f:
        for p in HASHED:
            fp = os.path.join(ROOT, p)
            f.write("%s  %s\n" % (sha256(fp) if os.path.isfile(fp) else "MISSING" + " " * 57, p))
    with open(os.path.join(out, "environment.txt"), "w") as f:
        f.write("date      %s\n" % datetime.datetime.now().astimezone().isoformat(timespec="seconds"))
        f.write("uname     %s\n" % " ".join(platform.uname()))
        f.write("python    %s\n" % sys.version.split()[0])
        for cmd in TOOLS:
            f.write("%-9s %s\n" % (os.path.basename(cmd[0]), first_line(cmd)))
    print("freeze: wrote %s (%s)" % (os.path.relpath(out, ROOT), "DIRTY" if dirty else "clean"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
