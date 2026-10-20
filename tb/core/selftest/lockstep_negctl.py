#!/usr/bin/env python3
"""lockstep_negctl.py -- negative controls for the Spike lockstep oracle.

Every control plants one defect that the oracle MUST report (non-zero exit).
Needs one completed core ISA run (make -f flow/mk/track_a_run.mk core_isa) for
the reference evidence of test `add`.

  N1  RTL image with one `add` turned into `sub` (Spike runs the real ELF)
      -> prepared here, judged by the prog suite tb/core/selftest/negctl_prog.toml
  N2  one value flipped in the RTL commit log         -> must DIVERGE
  N3  RTL commit log cut to half                      -> must MISMATCH
  N4  Spike log cut to half                           -> must MISMATCH
  N5  Spike writes its full log but exits non-zero    -> must fail (TOOL-12)
  N0  control: the untouched evidence                 -> must MATCH

usage: python3.12 tb/core/selftest/lockstep_negctl.py      (from the repo root)
Writes logs/flow/raw/negctl/ and logs/flow/summary/lockstep_negctl.txt;
exits 1 if any control is not caught (or N0 does not match).
"""
import datetime as dt
import os
import shutil
import stat
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
REF = os.path.join(ROOT, "logs", "core", "raw", "isa")
OUT = os.path.join(ROOT, "logs", "flow", "raw", "negctl")
SUM = os.path.join(ROOT, "logs", "flow", "summary", "lockstep_negctl.txt")
PY = os.environ.get("PYTHON", sys.executable)
SPIKE = os.environ.get("SPIKE", "spike")
ELF = os.path.join(ROOT, "sw", "riscv-tests", "build", "add.elf")
HEX = os.path.join(ROOT, "sw", "riscv-tests", "build", "add.hex")


def lockstep(rtl, spike_log=None, elf=None, spike=SPIKE):
    cmd = [PY, os.path.join(ROOT, "tools", "lockstep.py"), "--rtl", rtl, "--max", "1",
           "--spike", spike]
    if elf:
        cmd += ["--elf", elf]
    if spike_log:
        cmd += ["--spike-log", spike_log]
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    return p.returncode, (p.stdout + p.stderr).strip().splitlines()


def half(src, dst, keep_header=True):
    lines = open(src).read().splitlines(keepends=True)
    open(dst, "w").writelines(lines[: len(lines) // 2])


def make_n1():
    """Copy add.hex with the 2nd `add a4,ra,sp` (0x00208733, a TEST_RR_OP case
    with non-zero operands) turned into `sub`. The first add in the image is in
    the prologue and runs with zero operands, where add == sub: a control that
    changes nothing would "pass" and prove nothing (seen, 2026-10-11)."""
    words = open(HEX).read().split()
    hits = [i for i, w in enumerate(words) if int(w, 16) == 0x00208733]
    if len(hits) < 2:
        sys.exit("N1: fewer than two `add a4,ra,sp` in add.hex")
    i = hits[1]
    words[i] = f"{0x00208733 | (1 << 30):08x}"
    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, "n1_add_to_sub.hex"), "w").write("\n".join(words) + "\n")
    shutil.copy(ELF, os.path.join(OUT, "n1_add_to_sub.elf"))   # Spike runs the real program
    return i


def main():
    clog = os.path.join(REF, "add.commit.log")
    slog = os.path.join(REF, "add.spike.log")
    if not (os.path.isfile(clog) and os.path.isfile(slog)):
        sys.exit("run `make -f flow/mk/track_a_run.mk core_isa` first (needs add.commit.log/add.spike.log)")
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    rows = []

    rc, out = lockstep(clog, spike_log=slog)
    rows.append(("N0", "untouched evidence", "MATCH", rc == 0, rc, out[-1] if out else ""))

    # N2: flip one bit in the write data of the 20th retirement line
    lines = open(clog).read().splitlines(keepends=True)
    n, k = 0, None
    for i, ln in enumerate(lines):
        w = ln.split()
        if len(w) == 3 and w[0] not in ("MEM", "TRAP", "CSR") and not ln.startswith("#") and w[1] != "00":
            n += 1
            if n == 20:
                w[2] = f"{int(w[2], 16) ^ 0x10:08x}"
                lines[i] = " ".join(w) + "\n"
                k = i
                break
    n2 = os.path.join(OUT, "n2_flipped.commit.log")
    open(n2, "w").writelines(lines)
    rc, out = lockstep(n2, spike_log=slog)
    rows.append(("N2", f"flipped wdata bit (line {k})", "fail", rc != 0, rc, next((x for x in out if "DIVERGE" in x or "MISMATCH" in x), out[-1] if out else "")))

    n3 = os.path.join(OUT, "n3_short.commit.log")
    half(clog, n3)
    rc, out = lockstep(n3, spike_log=slog)
    rows.append(("N3", "RTL log cut to half", "fail", rc != 0, rc, out[-1] if out else ""))

    # Spike has no HTIF here, so its log runs on into the post-test spin loop
    # (thousands of commits past the RTL's last one): cutting the FILE in half
    # leaves the compared region intact and proves nothing. Cut the Spike
    # stream inside the compared region instead: after half the RTL's commits.
    n_rtl = sum(1 for ln in open(clog) if len(ln.split()) == 3 and ln.split()[0] not in ("MEM", "TRAP", "CSR")
                and not ln.startswith("#"))
    n4 = os.path.join(OUT, "n4_short.spike.log")
    kept, commits = [], 0
    for ln in open(slog):
        if ln.startswith("core") and ": 3 0x" in ln:
            commits += 1
            if commits > n_rtl // 2:
                break
        kept.append(ln)
    open(n4, "w").writelines(kept)
    rc, out = lockstep(clog, spike_log=n4)
    rows.append(("N4", f"Spike log cut after {n_rtl // 2} of {n_rtl} RTL commits", "fail", rc != 0, rc, out[-1] if out else ""))

    # N5: a "spike" that writes the complete, correct log and then reports an error
    fake = os.path.join(OUT, "fake_spike_exit1.sh")
    open(fake, "w").write(f"#!/bin/sh\ncat '{slog}' >&2\nexit 1\n")
    os.chmod(fake, os.stat(fake).st_mode | stat.S_IEXEC)
    rc, out = lockstep(clog, spike_log=os.path.join(OUT, "n5.spike.log"), elf=ELF, spike=fake)
    rows.append(("N5", "Spike exits 1 after a full log (TOOL-12)", "fail", rc != 0, rc, out[-1] if out else ""))

    w = make_n1()
    rows.append(("N1", f"add->sub at word {w}: judged by negctl_prog suite", "fail", None, "-", "prepared"))

    ok = all(r[3] for r in rows if r[3] is not None)
    os.makedirs(os.path.dirname(SUM), exist_ok=True)
    with open(SUM, "w") as f:
        f.write(f"lockstep negative controls  {dt.datetime.now().astimezone().isoformat(timespec='seconds')}\n")
        f.write(f"reference: {os.path.relpath(clog, ROOT)}\n\n")
        for cid, what, want, caught, rc, msg in rows:
            st = "-" if caught is None else ("CAUGHT" if caught and want == "fail" else
                                             "OK" if caught else "NOT CAUGHT")
            f.write(f"{cid}  {st:<11} rc={rc!s:<3} want={want:<6} {what}\n      {msg[:150]}\n")
        f.write(f"\nverdict: {'PASS' if ok else 'FAIL'}\n")
    print(open(SUM).read())
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
