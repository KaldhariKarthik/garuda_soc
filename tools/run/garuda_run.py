#!/usr/bin/env python3
"""garuda_run.py -- strict, logged, reproducible test runner (Track A, open tools).

    python3.12 tools/run/garuda_run.py suite <manifest.toml> [--only NAME ...]
                                             [--seed N] [--jobs N] [--keep-going]
    python3.12 tools/run/garuda_run.py report <block> <suite>

A manifest (TOML, see tb/core/run/*.toml and Docs/handbook/H2_running.md)
names the block, the suite, how to build the bench(es) and the tests.

Verdict of one test (stricter than the repo Makefile macros, which run
`xrun ...; grep ...` and never look at the exit status):
  PASS    only if ALL hold: fresh build of this run; simulator exit 0; the
          pass marker present; no timeout; zero [FAIL]/[SVA-FAIL] lines,
          zero assertion failures, zero other %Error lines; every `require`
          regex present, no `forbid` regex present; lockstep MATCH when the
          test is lockstepped.
  FAIL    anything else that ran.
  BLOCKED the bench could not be built (tool limitation or source error);
          never PASS or FAIL.
Then classified against the suite's xfail list (bug ID per entry):
  OK                      PASS and not listed
  XFAIL:<bug>             FAIL, listed as expected FAIL (and, when the test
                          gives `fail_reason`, the log shows that reason)
  XBLOCK:<bug>            BLOCKED, listed as expected BLOCKED
  XPASS:<bug>             PASS but listed: the list is stale -> error
  UNEXPECTED              FAIL or BLOCKED and not listed -> error
The suite exits 1 if any test is XPASS or UNEXPECTED, else 0.

Verilator facts this relies on (measured, see Docs/handbook/H2_running.md):
  - with +verilator+error+limit raised, Verilator EXITS 0 after assertion
    failures, so assertion failures are counted from the log;
  - Verilator is 2-state: X-propagation and $isunknown checks are
    XCELIUM-ONLY and are never claimed from a Verilator run.

Logs (Docs/handbook/H2_running.md, "Log convention"):
  logs/<blk>/raw/<suite>/...      per-run logs, builds, commit/spike logs (ignored by git)
  logs/<blk>/summary/<suite>.tsv  one row per test of the last full suite run
  logs/<blk>/summary/<suite>.txt  human summary of the same
  logs/<blk>/history.tsv          one row per test run, appended
Every log starts with a header (date, tool, design SHA + dirty flag, seed,
command, reproduce line) and ends with a footer (exit code, counts, verdict).
"""
import argparse
import concurrent.futures as cf
import datetime as dt
import difflib
import fnmatch
import glob
import os
import re
import shlex
import shutil
import time
import subprocess
import sys
import tomllib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
VERSION = "garuda-run 1"

VL_FLAGS = ["--binary", "--timing", "-sv", "--assert",
            "-Wno-fatal", "-Wno-lint", "-Wno-style"]
# Coverage mode (--coverage): every kind Verilator 5.052 has. Not per-instance:
# the report merges per module definition (tools/cov/cov_report.py).
COV_FLAGS = ["--coverage-line", "--coverage-toggle", "--coverage-expr", "--coverage-fsm",
             "--coverage-user"]
# Nothing may switch assertions off, and keep running after an assertion
# failure so every failure is counted (the count, not the exit code, decides).
VL_RT_ARGS = ["+verilator+assert+lock", "+verilator+error+limit+1000"]

RE_FAIL_LINE = re.compile(r"\[FAIL\]|\[SVA-FAIL\]")
RE_ASSERT = re.compile(r"Assertion failed|ASSERTION FAIL")
RE_ERROR = re.compile(r"%Error")
RE_WARN = re.compile(r"%Warning")


# ----------------------------------------------------------------------------- utils
def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def now():
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def rel(p):
    return os.path.relpath(p, ROOT)


def git_state():
    head = sh(["git", "-C", ROOT, "rev-parse", "HEAD"]).stdout.strip()
    branch = sh(["git", "-C", ROOT, "rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()
    design = sh(["git", "-C", ROOT, "status", "--porcelain", "--", "rtl"]).stdout.strip()
    tree = sh(["git", "-C", ROOT, "status", "--porcelain"]).stdout.strip()
    return {
        "sha": head,
        "branch": branch,
        "design_dirty": bool(design),
        "tree_changes": len(tree.splitlines()) if tree else 0,
    }


def tool_version_icarus():
    out = sh(["iverilog", "-V"]).stdout.strip().splitlines()
    return out[0] if out else "iverilog: unknown"


def tool_version(exe):
    try:
        out = sh([exe, "--version"]).stdout.strip().splitlines()
        return out[0] if out else "unknown"
    except FileNotFoundError:
        return "NOT FOUND"


# ------------------------------------------------------------------- filelists
def expand_flist(path, seen=None, srcs=None, incs=None, defs=None):
    """Expand a .f filelist the way scripts/expand_filelist.py does (same
    recursion, order, de-duplication) but KEEP -define lines (TOOL-15)."""
    if seen is None:
        seen, srcs, incs, defs = set(), [], [], []
    path = os.path.normpath(path)
    if path in seen:
        return srcs, incs, defs
    seen.add(path)
    if not os.path.exists(os.path.join(ROOT, path)):
        raise FileNotFoundError(f"filelist not found: {path}")
    base = os.path.dirname(path)
    with open(os.path.join(ROOT, path)) as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("//") or line.startswith("#"):
                continue
            if line.startswith("-f "):
                nxt = line[3:].strip()
                if not os.path.exists(os.path.join(ROOT, nxt)):
                    nxt = os.path.join(base, nxt)
                expand_flist(nxt, seen, srcs, incs, defs)
            elif line.startswith("-incdir"):
                d = line.split(None, 1)[1].strip()
                if d not in incs:
                    incs.append(d)
            elif line.startswith("-define") or line.startswith("+define+"):
                d = (line.split(None, 1)[1].strip() if line.startswith("-define")
                     else line[len("+define+"):])
                if d not in defs:
                    defs.append(d)
            elif line.startswith("-"):
                continue  # -sv and similar: language mode, not a source
            elif line not in srcs:
                srcs.append(line)
    return srcs, incs, defs


# ----------------------------------------------------------------------- shims
def apply_shims(srcs, shims, shim_dir):
    """Return (sources with shimmed copies substituted, [(id, file, nlines)]).

    A shim is a declared, minimal, Verilator-only deviation from a repo file.
    Shims that match the same file are applied one after the other, each to the
    result of the previous one. Each must change exactly `lines` lines of the
    content it was applied to, and every changed line must carry the marker
    `shim:<id>`, or the run aborts. The diff kept next to the copy is against
    the repo file.
    """
    used, out = [], []
    for s in srcs:
        cur_path = s
        orig = new = None
        for sh_ in shims:
            if not fnmatch.fnmatch(s, sh_["glob"]):
                continue
            if orig is None:
                with open(os.path.join(ROOT, s)) as fh:
                    orig = fh.read().splitlines(keepends=True)
                new = list(orig)
            pat = re.compile(sh_["match"])
            step = [pat.sub(sh_["replace"], ln) for ln in new]
            changed = [i for i, (a, b) in enumerate(zip(new, step)) if a != b]
            if not changed:
                continue
            if len(changed) != sh_["lines"]:
                raise RuntimeError(f"shim {sh_['id']}: {s} changed in {len(changed)} lines, "
                                   f"expected {sh_['lines']}")
            if any(f"shim:{sh_['id']}" not in step[i] for i in changed):
                raise RuntimeError(f"shim {sh_['id']}: a changed line lacks the marker")
            new = step
            used.append((sh_["id"], s, len(changed)))
        if new is not None and new != orig:
            dst = os.path.join(shim_dir, s)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, "w") as fh:
                fh.writelines(new)
            with open(dst + ".diff", "w") as fh:
                fh.writelines(difflib.unified_diff(orig, new, s, rel(dst)))
            cur_path = rel(dst)
        out.append(cur_path)
    return out, used


# ------------------------------------------------------------------ log helpers
def header(f, ctx, kind, name, cmd, seed, shims, repro, tool=None):
    g = ctx["git"]
    f.write(f"# {VERSION}\n")
    f.write(f"# date      : {now()}\n")
    f.write(f"# block     : {ctx['block']}   suite: {ctx['suite']}   test: {name}   kind: {kind}\n")
    f.write(f"# design    : {g['sha']} (rtl/ {'DIRTY' if g['design_dirty'] else 'clean'}; "
            f"{g['tree_changes']} uncommitted path(s) in tree)  branch {g['branch']}\n")
    f.write(f"# tool      : {tool or ctx['tool']}\n")
    f.write(f"# seed      : {seed}\n")
    f.write(f"# shims     : {', '.join(f'{i}:{p}({n})' for i, p, n in shims) or 'none'}\n")
    f.write(f"# command   : {shlex.join(cmd)}\n")
    f.write(f"# reproduce : {repro}\n")
    f.write("# ---- tool output ----\n")
    f.flush()


def footer(f, rc, counts, verdict, detail):
    f.write("\n# ---- footer ----\n")
    f.write(f"# exit code : {rc}\n")
    f.write("# counts    : " + " ".join(f"{k}={v}" for k, v in counts.items()) + "\n")
    f.write(f"# verdict   : {verdict}{('  ' + detail) if detail else ''}\n")


# ------------------------------------------------------------------------ build
def build(ctx, bname, flist, top, extra_defs=(), sim="verilator", exclude=(), replace=None,
          vl_flags=()):
    """Fresh build (Verilator by default, or Icarus for 4-state checks).
    Returns dict(ok, bin, sim, tool, log, shims, sva_src, sva_ign, why)."""
    bdir = os.path.join(ctx["raw"], "build", bname)
    shutil.rmtree(bdir, ignore_errors=True)            # evidence from this run only
    os.makedirs(bdir)
    log = os.path.join(ctx["raw"], f"build_{bname}.log")
    try:
        srcs, incs, defs = expand_flist(flist)
        # a declared exclusion is a shim too: listed in every log header
        dropped = [x for x in srcs if x in set(exclude)]
        srcs = [x for x in srcs if x not in set(exclude)]
        # a declared replacement (negative controls: a mutant in place of a
        # design file) is listed in every log header too
        replace = replace or {}
        swapped = [(x, replace[x]) for x in srcs if x in replace]
        srcs = [replace.get(x, x) for x in srcs]
        srcs, used = apply_shims(srcs, ctx["shims"], os.path.join(ctx["raw"], "shim"))
        used = ([("EXCLUDED", x, 0) for x in dropped] +
                [("REPLACED", f"{a}->{b}", 0) for a, b in swapped] + used)
    except (FileNotFoundError, RuntimeError) as e:
        with open(log, "w") as f:
            f.write(f"# setup error: {e}\n")
        return {"ok": False, "log": log, "why": str(e), "shims": [], "sva_src": 0, "sva_ign": 0,
                "sim": sim, "tool": "-"}
    defs = list(defs) + list(extra_defs)
    missing = [s for s in srcs if not os.path.exists(os.path.join(ROOT, s))]
    if sim == "icarus":
        tool = tool_version_icarus()
        binp = os.path.join(bdir, f"{top}.vvp")
        cmd = ["iverilog", "-g2012", "-o", rel(binp), "-s", top,
               *[f"-I{d}" for d in incs], *[f"-D{d}" for d in defs], *srcs]
    else:
        tool = ctx["tool"]
        binp = os.path.join(bdir, "obj", f"V{top}")
        args = ([f"+incdir+{d}" for d in incs] + [f"+define+{d}" for d in defs] + srcs)
        # vl_flags: extra build options declared in the manifest (for example a
        # coverage build); they appear in the logged command like everything else
        # $VARS in vl_flags expand from the environment (tool paths: env.sh)
        vl_flags = [os.path.expandvars(x) for x in vl_flags]
        cmd = [ctx["verilator"], *VL_FLAGS, *vl_flags, "-j", str(ctx["vl_jobs"]),
               "--top-module", top, "-Mdir", rel(os.path.join(bdir, "obj")), *args]
    repro = (f"{ctx['python']} tools/run/garuda_run.py suite {ctx['manifest']} "
             f"--only <test using bench {bname}>")
    with open(log, "w") as f:
        header(f, ctx, "build", bname, cmd, "-", used, repro, tool)
        if missing:
            rc = 2
            f.write(f"missing sources: {missing}\n")
        else:
            t0 = time.monotonic()
            p = subprocess.run(cmd, cwd=ROOT, stdout=f, stderr=subprocess.STDOUT, timeout=3600)
            rc = p.returncode
            build_s = time.monotonic() - t0
    ok = rc == 0 and os.path.isfile(binp) and os.access(binp, os.X_OK)
    text = open(log, errors="replace").read()
    sva_src = 0
    for s in srcs:
        try:
            sva_src += len(re.findall(r"\b(?:assert|assume)\s+property",
                                      open(os.path.join(ROOT, s), errors="replace").read()))
        except OSError:
            pass
    sva_ign = len(re.findall(r"ASSERTIGN|COVERIGN|Ignoring unsupported", text))
    why = ""
    if not ok:
        m = re.search(r"^%Error.*$", text, re.M)
        why = (m.group(0)[:200] if m else f"rc={rc}, binary missing")
    with open(log, "a") as f:
        footer(f, rc, {"errors": len(RE_ERROR.findall(text)),
                       "warnings": len(RE_WARN.findall(text)),
                       "sva_in_src": sva_src, "sva_ignored": sva_ign,
                       "build_s": f"{build_s:.1f}" if not missing else "-"},
               "BUILT" if ok else "BLOCKED", why)
    return {"ok": ok, "bin": binp, "sim": sim, "tool": tool, "log": log, "shims": used,
            "sva_src": sva_src, "sva_ign": sva_ign, "why": why}


# -------------------------------------------------------------------------- run
def run_measured(cmd, cwd, out, timeout):
    """subprocess.run with the child's wall time and peak RSS (os.wait4 rusage).
    Returns (rc, wall_s, rss_mb); raises subprocess.TimeoutExpired like run()."""
    t0 = time.monotonic()
    p = subprocess.Popen(cmd, cwd=cwd, stdout=out, stderr=subprocess.STDOUT)
    while True:
        pid, status, ru = os.wait4(p.pid, os.WNOHANG)
        if pid:
            p.returncode = os.waitstatus_to_exitcode(status)
            return p.returncode, time.monotonic() - t0, ru.ru_maxrss / 1024.0
        if time.monotonic() - t0 > timeout:
            p.kill()
            os.wait4(p.pid, 0)
            p.returncode = -9
            raise subprocess.TimeoutExpired(cmd, timeout)
        time.sleep(0.02)


def run_one(ctx, t, b):
    """Run one test on a built bench; return a result row (dict)."""
    name, seed = t["name"], ctx["seed"]
    row = {"test": name, "seed": seed, "shims": ";".join(f"{i}" for i, _, _ in b["shims"]) or "-",
           "sva_src": b["sva_src"], "sva_ign": b["sva_ign"], "lockstep": "-", "detail": "",
           "log": "-"}
    if not b["ok"]:
        row.update(verdict="BLOCKED", rc="-", marker="-", n_fail="-", n_assert="-", n_err="-",
                   detail=b["why"] or "build failed", log=rel(b["log"]))
        return row
    log = os.path.join(ctx["raw"], f"sim_{name}_s{seed}.log")
    run_dir = ROOT if t["cwd"] == "root" else os.path.dirname(b["bin"])
    # {raw} / {name} in plusargs: per-run output paths (e.g. +RVFI_LOG={raw}/{name}.rvfi.log)
    plus = [x.format(raw=ctx["raw"], name=name) for x in t["plusargs"]]
    if t.get("hex"):
        clog = os.path.join(ctx["raw"], f"{name}.commit.log")
        for p in (clog, os.path.join(ctx["raw"], f"{name}.spike.log"),
                  os.path.join(ctx["raw"], f"{name}.lockstep.txt")):
            if os.path.exists(p):
                os.remove(p)                    # never judge stale evidence
        # no_commit (endurance rows checked by the Spike co-simulation): no
        # commit log on disk -- 1e9 instructions would be ~27 GB
        plus = [f"+HEX={os.path.join(ROOT, t['hex'])}",
                "+COMMIT=/dev/null" if t.get("no_commit") else f"+COMMIT={clog}"] + plus
    if b["sim"] == "icarus":
        cmd = ["vvp", "-n", b["bin"], *plus]
    else:
        cmd = [b["bin"], *VL_RT_ARGS, f"+verilator+seed+{seed}", *plus]
        if ctx.get("coverage"):
            dat = os.path.join(ctx["raw"], "cov", f"{name}_s{seed}.dat")
            os.makedirs(os.path.dirname(dat), exist_ok=True)
            if os.path.exists(dat):
                os.remove(dat)
            cmd.append(f"+verilator+coverage+file+{dat}")
            row["cov_dat"] = rel(dat)
    repro = (f"source tools/run/env.sh && {ctx['python']} tools/run/garuda_run.py suite "
             f"{ctx['manifest']} --only {name} --seed {seed}")
    with open(log, "w") as f:
        header(f, ctx, "sim", name, [cmd[0] if b["sim"] == "icarus" else rel(cmd[0])] + cmd[1:],
               seed, b["shims"], repro, b["tool"])
        try:
            rc, wall, rss = run_measured(cmd, run_dir, f, t["timeout"])
            row.update(wall_s=f"{wall:.2f}", rss_mb=f"{rss:.0f}")
        except subprocess.TimeoutExpired:
            rc = "TIMEOUT"
    text = open(log, errors="replace").read().split("# ---- tool output ----", 1)[-1]
    # `known`: [[regex, n, bug], ...] -- a line-level xfail. Lines matching the
    # regex are taken out of the fail/assertion/error counts, but must occur
    # EXACTLY n times: a new failure still fails, and a known one that stops
    # happening is reported as stale (like XPASS).
    reasons = []
    for rx, want, bug in t.get("known", []):
        hits = [ln for ln in text.splitlines() if re.search(rx, ln)]
        got = sum(1 for ln in hits if RE_FAIL_LINE.search(ln) or RE_ASSERT.search(ln))
        if got != want:
            reasons.append(f"known /{rx}/ ({bug}) occurred {got} time(s), want {want}")
        text = "\n".join(ln for ln in text.splitlines() if not re.search(rx, ln))
    marker = bool(re.search(t["marker"], text, re.M))
    n_fail = len(RE_FAIL_LINE.findall(text))
    n_assert = len(RE_ASSERT.findall(text))
    n_err = sum(1 for ln in text.splitlines() if RE_ERROR.search(ln) and not RE_ASSERT.search(ln))
    if rc == "TIMEOUT":
        reasons.append(f"TIMEOUT after {t['timeout']}s")
    elif rc != 0:
        reasons.append(f"exit {rc}")
    if not marker:
        reasons.append("pass marker missing")
    if n_fail:
        reasons.append(f"{n_fail} [FAIL] line(s)")
    if n_assert and not t.get("allow_assert"):
        reasons.append(f"{n_assert} assertion failure(s)")
    if n_err:
        reasons.append(f"{n_err} %Error line(s)")
    for rq in t["require"]:
        if not re.search(rq, text, re.M):
            reasons.append(f"missing: /{rq}/")
    for fb in t["forbid"]:
        if re.search(fb, text, re.M):
            reasons.append(f"forbidden: /{fb}/")
    # exact counts: [[regex, n], ...] -- for self-tests that must fire a known
    # number of times (a check that fires too often is as wrong as one that never does)
    for rx, want in t.get("count", []):
        got = len(re.findall(rx, text, re.M))
        if got != want:
            reasons.append(f"count /{rx}/ = {got}, want {want}")
    first = re.search(r"^.*(\[FAIL\]|Assertion failed|%Error|FAILED|TIMEOUT).*$", text, re.M)
    row.update(rc=rc, marker="yes" if marker else "no", n_fail=n_fail, n_assert=n_assert,
               n_err=n_err, log=rel(log))
    # lockstep against Spike (only for a run that otherwise passed: a failing run's
    # commit log proves nothing more)
    if t.get("lockstep") and not reasons:
        t0 = time.monotonic()
        row["lockstep"] = lockstep(ctx, t)
        row["lockstep_s"] = f"{time.monotonic() - t0:.2f}"
        if row["lockstep"] != "MATCH":
            reasons.append(f"lockstep {row['lockstep']}")
    elif t.get("hex"):
        row["lockstep"] = "n/a" if not t.get("lockstep") else "not-run"
    # `post`: a check run on the outputs of a passing run (e.g. tools/rvfi_check.py);
    # placeholders {commit} {raw} {name} {root}; a non-zero exit fails the test
    if t.get("post") and not reasons:
        pcmd = [x.format(commit=os.path.join(ctx["raw"], f"{name}.commit.log"), raw=ctx["raw"],
                         name=name, root=ROOT) for x in t["post"]]
        pp = sh(pcmd, cwd=ROOT, timeout=900)
        last = (pp.stdout.strip().splitlines() or ["(no output)"])[-1]
        with open(log, "a") as f:
            f.write(f"# post-check: {shlex.join(pcmd)}\n# post exit: {pp.returncode}\n# post: {last}\n")
        if pp.returncode != 0:
            reasons.append(f"post-check failed: {last[:120]}")
    verdict = "PASS" if not reasons else "FAIL"
    # `fail_reason` (negative controls): an expected FAIL counts as XFAIL only
    # if the log shows this reason -- a control that fails for another reason
    # (crash, wrong check) proves nothing and is classified UNEXPECTED
    if t.get("fail_reason") and verdict == "FAIL":
        row["reason_ok"] = bool(re.search(t["fail_reason"], text, re.M))
        if not row["reason_ok"]:
            reasons.append(f"fail_reason /{t['fail_reason']}/ not in the log")
    detail = "; ".join(reasons)
    if verdict == "FAIL" and first:
        detail += f" | first: {first.group(0).strip()[:140]}"
    row.update(verdict=verdict, detail=detail)
    with open(log, "a") as f:
        footer(f, rc, {"marker": row["marker"], "fail_lines": n_fail, "assert_fail": n_assert,
                       "errors": n_err, "lockstep": row["lockstep"],
                       "wall_s": row.get("wall_s", "-"), "rss_mb": row.get("rss_mb", "-")},
               verdict, detail)
    return row


def lockstep(ctx, t):
    clog = os.path.join(ctx["raw"], f"{t['name']}.commit.log")
    slog = os.path.join(ctx["raw"], f"{t['name']}.spike.log")
    out = os.path.join(ctx["raw"], f"{t['name']}.lockstep.txt")
    if not os.path.isfile(clog) or os.path.getsize(clog) == 0:
        return "NO-RUN"
    elf = os.path.join(ROOT, t["elf"])
    if not os.path.isfile(elf):
        return "NO-ELF"
    cmd = [ctx["python"], os.path.join(ROOT, "tools", "lockstep.py"), "--rtl", clog,
           "--elf", elf, "--spike-log", slog, "--spike", ctx["spike"], "--max", "3"]
    cmd += ctx.get("lockstep_args", [])
    p = sh(cmd, cwd=ROOT, timeout=900)
    with open(out, "w") as f:
        f.write(f"# command: {shlex.join(cmd)}\n# exit: {p.returncode}\n")
        f.write(p.stdout + p.stderr)
    if p.returncode == 0 and re.search(r"^MATCH", p.stdout, re.M):
        return "MATCH"
    if re.search(r"^MISMATCH", p.stdout, re.M):
        return "MISMATCH"
    if re.search(r"DIVERGE", p.stdout):
        return "DIVERGE"
    return f"ERROR(rc={p.returncode})"


# -------------------------------------------------------------------- manifest
def load_manifest(path):
    with open(os.path.join(ROOT, path), "rb") as fh:
        m = tomllib.load(fh)
    s = m["suite"]
    d = {"top": "tb_top", "marker": r"ALL CHECKS PASSED|^ RESULT: PASSED", "timeout": 900,
         "require": [], "forbid": [], "plusargs": [], "cwd": "build"}
    d.update(m.get("defaults", {}))
    tests = []
    for t in m.get("test", []):
        x = dict(d)
        x.update(t)
        tests.append(x)
    ls = m.get("lockstep", {})
    for pg in m.get("programs", []):
        for hexp in sorted(glob.glob(os.path.join(ROOT, pg["glob"]))):
            name = os.path.splitext(os.path.basename(hexp))[0]
            x = dict(d)
            x.update({k: v for k, v in pg.items() if k != "glob"})
            x["name"] = name
            x["hex"] = rel(hexp)
            x["elf"] = rel(os.path.splitext(hexp)[0] + ".elf")
            x["lockstep"] = bool(ls.get("enabled")) and name not in ls.get("skip", [])
            tests.append(x)
    for x in tests:
        if x.get("hex") and "elf" not in x:
            x["elf"] = os.path.splitext(x["hex"])[0] + ".elf"
        x.setdefault("lockstep", False)
    return m, s, tests


def load_xfail(path):
    xf = {}
    if path and os.path.exists(os.path.join(ROOT, path)):
        for ln in open(os.path.join(ROOT, path)):
            if not ln.strip() or ln.startswith("#"):
                continue
            f = ln.rstrip("\n").split("\t")
            if len(f) < 4:
                continue
            suite, test, expect, bug = f[:4]
            xf[(suite, test)] = (expect.upper(), bug, f[4] if len(f) > 4 else "")
    return xf


def classify(row, suite, xf):
    key = (suite, row["test"])
    v = row["verdict"]
    if key in xf:
        expect, bug, _ = xf[key]
        if v == "PASS":
            return f"XPASS:{bug}"
        if v == expect and row.get("reason_ok", True):
            return f"{'XFAIL' if v == 'FAIL' else 'XBLOCK'}:{bug}"
        return "UNEXPECTED"
    return "OK" if v == "PASS" else "UNEXPECTED"


# ------------------------------------------------------------------------ main
COLS = ["test", "verdict", "class", "rc", "marker", "n_fail", "n_assert", "n_err",
        "lockstep", "sva_src", "sva_ign", "shims", "seed", "wall_s", "rss_mb", "lockstep_s",
        "cov_dat", "detail", "log"]


def cmd_suite(a):
    m, s, tests = load_manifest(a.manifest)
    if a.only:
        tests = [t for t in tests if t["name"] in a.only]
        if not tests:
            sys.exit(f"no test named {a.only} in {a.manifest}")
    blk, suite = s["block"], s["name"]
    # coverage mode: Verilator builds with COV_FLAGS, one coverage.dat per run,
    # outputs under <suite>.cov so the normal results are never overwritten.
    # Icarus rows are skipped (no coverage database). The xfail list still
    # applies by the suite's own name.
    out = suite + (".cov" if a.coverage else "")
    if a.coverage:
        skipped = [t["name"] for t in tests if t.get("sim") == "icarus"]
        tests = [t for t in tests if t.get("sim") != "icarus"]
        if skipped:
            print(f"[{out}] coverage mode: skipping Icarus rows {skipped}", flush=True)
    logs = os.path.join(ROOT, "logs", blk)
    raw = os.path.join(logs, "raw", out)
    if not a.only:
        shutil.rmtree(raw, ignore_errors=True)
    os.makedirs(raw, exist_ok=True)
    os.makedirs(os.path.join(logs, "summary"), exist_ok=True)
    jobs = max(1, a.jobs)
    ctx = {
        "block": blk, "suite": suite, "manifest": a.manifest, "raw": raw,
        "git": git_state(), "seed": a.seed if a.seed is not None else s.get("seed", 1),
        "verilator": os.environ.get("VERILATOR", "verilator"),
        "python": os.environ.get("PYTHON", sys.executable),
        "spike": os.environ.get("SPIKE", "spike"),
        "shims": m.get("shim", []),
        "vl_jobs": max(1, (os.cpu_count() or 4) // jobs),
        "lockstep_args": m.get("lockstep", {}).get("args", []),
        "coverage": a.coverage,
    }
    cov = COV_FLAGS if a.coverage else []
    ctx["tool"] = tool_version(ctx["verilator"])
    print(f"[{suite}] block={blk} tests={len(tests)} seed={ctx['seed']} "
          f"design={ctx['git']['sha'][:12]}{' DIRTY' if ctx['git']['design_dirty'] else ''} "
          f"tool='{ctx['tool']}'", flush=True)

    # build: one bench for a program suite, one per test otherwise
    builds = {}
    if s.get("kind") == "prog":
        bench = m["bench"]
        print(f"[{suite}] building {bench['top']} ...", flush=True)
        flist = bench.get("cov_flist", bench["flist"]) if a.coverage else bench["flist"]
        builds["bench"] = build(ctx, bench["top"], flist, bench["top"],
                                bench.get("defines", []), bench.get("sim", "verilator"),
                                bench.get("exclude", []), bench.get("replace", {}),
                                bench.get("vl_flags", []) + cov)
        bmap = {t["name"]: "bench" for t in tests}
    else:
        bmap = {t["name"]: t["name"] for t in tests}
        with cf.ThreadPoolExecutor(jobs) as ex:
            fut = {ex.submit(build, ctx, t["name"],
                             t.get("cov_flist", t["flist"]) if a.coverage else t["flist"],
                             t["top"], t.get("defines", []), t.get("sim", "verilator"),
                             t.get("exclude", []), t.get("replace", {}),
                             t.get("vl_flags", []) + cov): t["name"]
                   for t in tests}
            for f in cf.as_completed(fut):
                builds[fut[f]] = f.result()

    with cf.ThreadPoolExecutor(jobs) as ex:
        rows = list(ex.map(lambda t: run_one(ctx, t, builds[bmap[t["name"]]]), tests))

    xf = load_xfail(s.get("xfail"))
    for r in rows:
        r["class"] = classify(r, suite, xf)
        print(f"  {r['verdict']:<7} {r['class']:<22} {r['test']:<32} "
              f"{'' if r['verdict'] == 'PASS' else r['detail'][:110]}", flush=True)

    # summary (full runs only) + history (always)
    tag = "" if not a.only else ".partial"
    tsv = os.path.join(logs, "summary", f"{out}{tag}.tsv")
    with open(tsv, "w") as f:
        f.write(f"# {VERSION} suite={out} block={blk} date={now()} "
                f"design={ctx['git']['sha']} rtl_dirty={ctx['git']['design_dirty']} "
                f"tool={ctx['tool']} seed={ctx['seed']}\n")
        f.write("\t".join(COLS) + "\n")
        for r in rows:
            f.write("\t".join(str(r.get(c, "")) for c in COLS) + "\n")
    hist = os.path.join(logs, "history.tsv")
    new = not os.path.exists(hist)
    with open(hist, "a") as f:
        if new:
            f.write("date\tsha\trtl_dirty\tsuite\ttest\tseed\tverdict\tclass\tdetail\n")
        for r in rows:
            f.write("\t".join([now(), ctx["git"]["sha"][:12], str(ctx["git"]["design_dirty"]),
                               out, r["test"], str(r["seed"]), r["verdict"], r["class"],
                               r["detail"][:200].replace("\t", " ")]) + "\n")
    write_text_summary(blk, out + tag, rows, ctx)
    bad = [r for r in rows if r["class"] == "UNEXPECTED" or r["class"].startswith("XPASS")]
    n = {k: sum(1 for r in rows if r["verdict"] == k) for k in ("PASS", "FAIL", "BLOCKED")}
    print(f"[{out}] PASS={n['PASS']} FAIL={n['FAIL']} BLOCKED={n['BLOCKED']} "
          f"-> {'OK' if not bad else f'{len(bad)} unexpected'}  ({rel(tsv)})")
    return 1 if bad else 0


def write_text_summary(blk, suite, rows, ctx):
    p = os.path.join(ROOT, "logs", blk, "summary", f"{suite}.txt")
    with open(p, "w") as f:
        f.write(f"{VERSION}  suite {suite}  block {blk}  {now()}\n")
        f.write(f"design {ctx['git']['sha']}  rtl/ {'DIRTY' if ctx['git']['design_dirty'] else 'clean'}"
                f"  tool {ctx['tool']}  seed {ctx['seed']}\n\n")
        w = max([len(r["test"]) for r in rows] + [4])
        for r in rows:
            f.write(f"{r['verdict']:<8}{r['class']:<24}{r['test']:<{w + 2}}"
                    f"{'' if r['verdict'] == 'PASS' else r['detail'][:150]}\n")
        f.write("\n")
        for k in ("PASS", "FAIL", "BLOCKED"):
            f.write(f"{k:<8}{sum(1 for r in rows if r['verdict'] == k)}\n")
        f.write(f"total   {len(rows)}\n")


def cmd_report(a):
    p = os.path.join(ROOT, "logs", a.block, "summary", f"{a.suite}.txt")
    print(open(p).read())
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sp = ap.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("suite")
    s.add_argument("manifest")
    s.add_argument("--only", nargs="+")
    s.add_argument("--seed", type=int)
    s.add_argument("--jobs", type=int, default=4)
    s.add_argument("--coverage", action="store_true",
                   help="coverage build + one coverage.dat per run (outputs <suite>.cov)")
    r = sp.add_parser("report")
    r.add_argument("block")
    r.add_argument("suite")
    a = ap.parse_args()
    return {"suite": cmd_suite, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
