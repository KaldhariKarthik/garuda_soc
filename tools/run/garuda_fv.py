#!/usr/bin/env python3
"""garuda_fv.py -- formal runs (SymbiYosys) with the H6 result classes.

    python3.12 tools/run/garuda_fv.py <manifest.toml> [--only TASK ...] [--jobs N]

A manifest (TOML, e.g. tb/core/formal/core_trap.toml) names the design (a .f
filelist, the top, files to leave out or replace, extra environment and
property files, extra SBY options) and the tasks (mode bmc | prove | cover,
engine, depth, options, defines). For
each task a fresh SBY file is generated under logs/<blk>/raw/<suite>/<task>/
and run; the result is classified (Docs/handbook/H6_formal.md):

  PROVEN          mode prove, PASS (unbounded)
  BOUNDED(d)      mode bmc, PASS: no counterexample up to depth d -- not a proof
  COVERED         mode cover, every cover statement reached
  UNREACHED(n)    mode cover, n cover statements not reached within the depth
  FAIL            an assertion fails (properties named; trace in the work dir)
  UNRESOLVED      no answer (timeout, solver limit)
  ERROR           the run did not get as far as an answer (setup/tool error)

A PDR FAIL with no trace is reported by SBY as "ERROR rc=16": the class is
taken from the engine summary line, never from the status word alone.
Tasks expected to FAIL (negative controls, fail-before evidence) are listed in
the suite's xfail file, exactly like simulation (H2).
"""
import argparse
import concurrent.futures as cf
import datetime as dt
import glob
import os
import re
import shutil
import subprocess
import sys
import time
import tomllib

sys.path.insert(0, os.path.dirname(__file__))
from garuda_run import ROOT, expand_flist, git_state, load_xfail, now, rel  # noqa: E402

VERSION = "garuda-fv 1"


def design_sources(d, t=None):
    srcs, incs, defs = expand_flist(d["flist"])
    excl = set(d.get("exclude", []))
    repl = dict(d.get("replace", {}))
    repl.update((t or {}).get("replace", {}))   # per-task swap, e.g. a reference mutant
    out = [repl.get(s, s) for s in srcs if s not in excl]
    out += d.get("extra", [])
    hdrs = []
    for inc in incs:
        hdrs += sorted(rel(p) for p in glob.glob(os.path.join(ROOT, inc, "*.vh")))
    return out, hdrs, ["FORMAL"] + defs + d.get("defines", []) + list((t or {}).get("defines", []))


def make_sby(d, t, props):
    srcs, hdrs, defs = design_sources(d, t)
    files = srcs + props
    names = [os.path.basename(f) for f in files + hdrs]
    dup = {n for n in names if names.count(n) > 1}
    if dup:
        raise RuntimeError(f"basename collision in SBY [files]: {dup}")
    mode = t["mode"]
    lines = ["[options]", f"mode {mode}"]
    if mode in ("bmc", "cover") or "depth" in t:
        lines.append(f"depth {t.get('depth', 20)}")
    # extra SBY [options] lines from the design and the task, e.g. "multiclock on"
    # for a two-clock design (the DMA: pclk = hclk/2, tb/dma/formal/dma.toml)
    lines += list(d.get("options", [])) + list(t.get("options", []))
    lines += ["", "[engines]", t.get("engine", "smtbmc yices"), "", "[script]", "plugin -i slang",
              "read_slang -I . " + " ".join(f"-D{x}" for x in defs) + " "
              + " ".join(os.path.basename(f) for f in files) + f" --top {d['top']}"]
    lines += t.get("script", [])
    lines += [f"prep -top {d['top']}", "", "[files]"]
    lines += [os.path.join(ROOT, f) for f in files + hdrs]
    return "\n".join(lines) + "\n", files


def model_props(work):
    """(asserts, covers) actually present in the elaborated model."""
    il = os.path.join(work, "model", "design.il")
    if not os.path.exists(il):
        return None, None
    t = open(il, errors="replace").read()
    return (len(re.findall(r'FLAVOR "assert"', t)) or len(re.findall(r"\$assert\b", t)),
            len(re.findall(r'FLAVOR "cover"', t)) or len(re.findall(r"\$cover\b", t)))


def classify(mode, depth, work, rc, timed_out):
    log = os.path.join(work, "logfile.txt")
    text = open(log, errors="replace").read() if os.path.exists(log) else ""
    status = open(os.path.join(work, "status")).read().strip() if os.path.exists(
        os.path.join(work, "status")) else ""
    failed = sorted(set(re.findall(r"Assert failed in [^:]+: ([^\s(]+)", text)))
    failed += sorted(set(re.findall(r"Assert(?:ion)? [^\n]*?\b(a_[A-Za-z0-9_]+)\b[^\n]*failed", text)))
    unreached = sorted(set(re.findall(r"Unreached cover statement[^:]*:\s*(\S+)", text)))
    # a k-induction step that fails is not a counterexample (SBY: UNKNOWN, rc 4); only a
    # basecase / bmc / pdr failure is (TOOL-26, 2026-10-12)
    engine_fail = re.search(r"returned FAIL(?! for induction)", text) is not None
    induction_only = re.search(r"returned FAIL for induction", text) is not None and not engine_fail
    if timed_out or "TIMEOUT" in status:
        return "UNRESOLVED", "timeout", failed
    if mode == "prove" and status.startswith("PASS"):
        return "PROVEN", "", failed
    if mode == "bmc" and status.startswith("PASS"):
        return f"BOUNDED({depth})", "", failed
    if mode == "cover":
        if status.startswith("PASS"):
            return "COVERED", "", failed
        if unreached:
            return f"UNREACHED({len(unreached)})", " ".join(unreached[:8]), failed
    if status.startswith("FAIL") or engine_fail:
        return "FAIL", ("props: " + ", ".join(failed[:8])) if failed else "assertion failed (see trace)", failed
    if status.startswith("UNKNOWN"):
        if induction_only:
            return "UNRESOLVED", f"k-induction step failed (not inductive at depth {depth}); basecase passed", []
        return "UNRESOLVED", "solver gave no answer", failed
    m = re.search(r"^.*(ERROR|Error).*$", text, re.M)
    return "ERROR", (m.group(0)[-160:] if m else f"rc={rc} status='{status}'"), failed


def run_task(ctx, d, t):
    work_root = os.path.join(ctx["raw"], t["name"])
    shutil.rmtree(work_root, ignore_errors=True)
    os.makedirs(work_root)
    props = t.get("props", ctx["props"])
    try:
        sby, _ = make_sby(d, t, props)
    except (FileNotFoundError, RuntimeError) as e:
        return {"task": t["name"], "mode": t["mode"], "result": "ERROR", "detail": str(e),
                "secs": 0, "log": "-"}
    sby_path = os.path.join(work_root, f"{t['name']}.sby")
    open(sby_path, "w").write(sby)
    env = dict(os.environ)
    env["PATH"] = os.path.join(ctx["oss"], "bin") + os.pathsep + env["PATH"]
    log = os.path.join(ctx["raw"], f"fv_{t['name']}.log")
    t0 = time.time()
    timed_out = False
    with open(log, "w") as f:
        f.write(f"# {VERSION}\n# date      : {now()}\n# block     : {ctx['block']}   suite: "
                f"{ctx['suite']}   task: {t['name']}   mode: {t['mode']}\n"
                f"# design    : {ctx['git']['sha']} (rtl/ {'DIRTY' if ctx['git']['design_dirty'] else 'clean'};"
                f" {ctx['git']['tree_changes']} uncommitted path(s))\n# tool      : {ctx['tool']}\n"
                f"# reproduce : source tools/run/env.sh && python3.12 tools/run/garuda_fv.py "
                f"{ctx['manifest']} --only {t['name']}\n# ---- tool output ----\n")
        f.flush()
        try:
            p = subprocess.run([os.path.join(ctx["oss"], "bin", "sby"), "-f", sby_path],
                               cwd=work_root, stdout=f, stderr=subprocess.STDOUT, env=env,
                               timeout=t.get("timeout", 3600))
            rc = p.returncode
        except subprocess.TimeoutExpired:
            rc, timed_out = "TIMEOUT", True
    secs = int(time.time() - t0)
    work = os.path.join(work_root, t["name"])
    res, detail, _ = classify(t["mode"], t.get("depth", 20), work, rc, timed_out)
    n_as, n_cv = model_props(work)
    want = t.get("min_asserts", ctx["min_asserts"]) if t["mode"] != "cover" else t.get("min_covers", ctx["min_covers"])
    have = n_as if t["mode"] != "cover" else n_cv
    if have is not None and have < want:
        # a run with the properties missing proves nothing (seen 2026-10-11)
        res, detail = "ERROR", f"model has {have} {'assert' if t['mode'] != 'cover' else 'cover'}(s), manifest wants >= {want}"
    detail = (f"[{n_as} asserts, {n_cv} covers in model] " if n_as is not None else "") + detail
    with open(log, "a") as f:
        f.write(f"\n# ---- footer ----\n# exit code : {rc}\n# seconds   : {secs}\n# result    : {res}  {detail}\n")
    return {"task": t["name"], "mode": t["mode"], "result": res, "detail": detail, "secs": secs,
            "log": rel(log)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("manifest")
    ap.add_argument("--only", nargs="+")
    ap.add_argument("--jobs", type=int, default=4)
    a = ap.parse_args()
    with open(os.path.join(ROOT, a.manifest), "rb") as fh:
        m = tomllib.load(fh)
    s, d = m["suite"], m["design"]
    tasks = m["task"]
    if a.only:
        tasks = [t for t in tasks if t["name"] in a.only]
    blk, suite = s["block"], s["name"]
    raw = os.path.join(ROOT, "logs", blk, "raw", suite)
    os.makedirs(raw, exist_ok=True)
    os.makedirs(os.path.join(ROOT, "logs", blk, "summary"), exist_ok=True)
    oss = os.environ.get("OSS_CAD", os.path.expanduser("~/tools/oss-cad-suite"))
    ver = subprocess.run([os.path.join(oss, "bin", "sby"), "--version"], capture_output=True, text=True).stdout.strip()
    ctx = {"block": blk, "suite": suite, "manifest": a.manifest, "raw": raw, "git": git_state(),
           "oss": oss, "tool": f"{ver}, yosys-slang, oss-cad-suite {os.path.basename(os.path.realpath(oss))}",
           "props": m.get("props", []),
           "min_asserts": d.get("min_asserts", 1), "min_covers": d.get("min_covers", 1)}
    print(f"[{suite}] block={blk} tasks={len(tasks)} design={ctx['git']['sha'][:12]}"
          f"{' DIRTY' if ctx['git']['design_dirty'] else ''}", flush=True)
    with cf.ThreadPoolExecutor(max(1, a.jobs)) as ex:
        rows = list(ex.map(lambda t: run_task(ctx, d, t), tasks))
    xf = load_xfail(s.get("xfail"))
    bad = 0
    for r in rows:
        key = (suite, r["task"])
        ok_res = r["result"] in ("PROVEN", "COVERED") or r["result"].startswith("BOUNDED")
        if key in xf:
            exp, bug, _ = xf[key]
            r["class"] = f"XFAIL:{bug}" if r["result"] == exp else (f"XPASS:{bug}" if ok_res else "UNEXPECTED")
        else:
            r["class"] = "OK" if ok_res else "UNEXPECTED"
        if r["class"] == "UNEXPECTED" or r["class"].startswith("XPASS"):
            bad += 1
        print(f"  {r['result']:<14} {r['class']:<20} {r['task']:<26} {r['secs']:>5}s  {r['detail'][:100]}", flush=True)
    tag = ".partial" if a.only else ""
    tsv = os.path.join(ROOT, "logs", blk, "summary", f"{suite}{tag}.tsv")
    cols = ["task", "mode", "result", "class", "secs", "detail", "log"]
    with open(tsv, "w") as f:
        f.write(f"# {VERSION} suite={suite} block={blk} date={now()} design={ctx['git']['sha']} "
                f"rtl_dirty={ctx['git']['design_dirty']} tool={ctx['tool']}\n" + "\t".join(cols) + "\n")
        for r in rows:
            f.write("\t".join(str(r[c]) for c in cols) + "\n")
    hist = os.path.join(ROOT, "logs", blk, "history.tsv")
    with open(hist, "a") as f:
        for r in rows:
            f.write("\t".join([now(), ctx["git"]["sha"][:12], str(ctx["git"]["design_dirty"]), suite,
                               r["task"], "-", r["result"], r["class"], r["detail"][:200]]) + "\n")
    print(f"[{suite}] {len(rows)} task(s) -> {'OK' if not bad else f'{bad} unexpected'}  ({rel(tsv)})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
