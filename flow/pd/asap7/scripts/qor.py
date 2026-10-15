#!/usr/bin/env python3
"""
qor.py -- what a GARUDA ASAP7 run produced, on one page; and runs side by side.

    python3 flow/pd/asap7/scripts/qor.py pnr_r7              # one run
    python3 flow/pd/asap7/scripts/qor.py --compare pnr_r5 pnr_r6 pnr_r7
    python3 flow/pd/asap7/scripts/qor.py --all               # every run under results/

Reads only files ORFS and the pd_* steps already wrote, under PD_WORK
(default ~/tools/garuda_pd): the per-stage metrics (logs/.../<stage>.json),
the stage logs (runtime, peak memory, the first error), 4_2_mmhold.log and
analysis/<run>_sta_<stage>/. Needs no ORFS environment and starts no tool.

One run   -> analysis/<run>_qor.md (and the terminal)
--compare -> analysis/qor_compare.md: one row per run, the run-history table
             of the PD logs, with what changed left for the reader to write.

A stage followed by a later one is complete. The last stage that has a log is
complete only if ORFS wrote its .json AND its log has no [ERROR line (ORFS
writes the .json of a failed global route too: pnr_r4). Otherwise the run
stopped there, and the first [ERROR / Signal / Killed line of that log is
given as the reason; no such line means the process was stopped from
outside, which on this machine has meant the out-of-memory killer
(BUGS TOOL-21).

The numbers are EXPLORATORY ASAP7 numbers (D-27); none carries over to 28 nm.
"""
import argparse
import glob
import json
import os
import re
import sys

PD_WORK = os.environ.get("PD_WORK", os.path.expanduser("~/tools/garuda_pd"))
ANALYSIS = os.environ.get("PD_ANALYSIS", os.path.join(PD_WORK, "analysis"))
DESIGN = "garuda"

# ORFS stages in flow order: (log/json stem, short name)
STAGES = [
    ("1_synth", "synth"),
    ("2_1_floorplan", "floorplan"),
    ("2_2_floorplan_macro", "macro place"),
    ("2_3_floorplan_tapcell", "tapcell"),
    ("2_4_floorplan_pdn", "pdn"),
    ("3_1_place_gp_skip_io", "global place (no io)"),
    ("3_2_place_iop", "io place"),
    ("3_3_place_gp", "global place"),
    ("3_4_place_resized", "resize"),
    ("3_5_place_dp", "detailed place"),
    ("4_1_cts", "cts"),
    ("4_2_mmhold", "multi-mode hold"),
    ("5_1_grt", "global route"),
    ("5_2_route", "detailed route"),
    ("5_3_fillcell", "fill cells"),
    ("6_1_fill", "metal fill"),
    ("6_report", "report"),
]
ELAPSED = re.compile(r"Elapsed time: ([0-9:.]+)\[h:\]min:sec\..*?Peak memory: (\d+)KB")
# /usr/bin/time -v, used for the steps outside ORFS (4_2_mmhold.log)
GNU_TIME = re.compile(r"Elapsed \(wall clock\) time \(h:mm:ss or m:ss\): ([0-9:.]+)"
                      r".*?Maximum resident set size \(kbytes\): (\d+)", re.S)
FAILURE = re.compile(r"^\[ERROR [A-Z]+-\d+\].*|Signal \d+ received.*|.*\bKilled\b.*|.*Error \d+$", re.M)


def run_dirs(run):
    return {k: os.path.join(PD_WORK, k, "asap7", DESIGN, run) for k in ("logs", "results", "reports")}


def load_json(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def read(path):
    try:
        with open(path, errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def seconds(hms):
    """'1:02:03.4' / '30:36.59' / '0:05.99' -> seconds"""
    total = 0.0
    for part in hms.split(":"):
        total = total * 60 + float(part)
    return total


def fmt_dur(s):
    if s is None:
        return "-"
    s = int(round(s))
    return "%d:%02d:%02d" % (s // 3600, s % 3600 // 60, s % 60) if s >= 3600 else "%d:%02d" % (s // 60, s % 60)


def fmt(v, nd=2):
    if v is None:
        return "-"
    if isinstance(v, float):
        return ("%." + str(nd) + "f") % v
    return str(v)


def stages(run):
    """[(stem, name, state, seconds, peak_mib, reason)] for every stage with a log."""
    d = run_dirs(run)
    present = [(stem, name) for stem, name in STAGES
               if os.path.exists(os.path.join(d["logs"], stem + ".log"))]
    out = []
    for k, (stem, name) in enumerate(present):
        log = os.path.join(d["logs"], stem + ".log")
        text = read(log)
        m = ELAPSED.findall(text) or GNU_TIME.findall(text)
        secs = seconds(m[-1][0]) if m else None
        peak = int(m[-1][1]) // 1024 if m else None
        has_json = os.path.exists(os.path.join(d["logs"], stem + ".json"))
        if stem == "4_2_mmhold":                     # not an ORFS stage: no .json
            done = "MMHOLD DONE" in text
        elif k < len(present) - 1:                  # a later stage ran
            done = True
        else:
            done = has_json and not re.search(r"^\[ERROR ", text, re.M)
        reason = ""
        if not done:
            f = FAILURE.search(text)
            reason = f.group(0).strip() if f else "no error in the log: stopped from outside (out of memory?)"
        out.append((stem, name, "done" if done else "STOPPED", secs, peak, reason))
    return out


def mmhold(run):
    """Per-scene hold WNS before/after from 4_2_mmhold.log (pd_scene_summary table),
    or the all-scene figures of the older script."""
    text = read(os.path.join(run_dirs(run)["logs"], "4_2_mmhold.log"))
    if not text:
        return None
    res = {"buffers": None, "endpoints": None, "table": {}}
    m = re.search(r"Inserted (\d+) hold buffers", text)
    res["buffers"] = int(m.group(1)) if m else 0
    m = re.search(r"Found (\d+) endpoints with hold violations", text)
    res["endpoints"] = int(m.group(1)) if m else 0
    for tag in ("before", "after"):
        blk = re.search(r"^=== %s\n(.*?)(?=^worst slack|\Z)" % tag, text, re.M | re.S)
        if not blk:
            continue
        for line in blk.group(1).splitlines():
            f = line.split()
            if len(f) == 5 and f[0].startswith("div"):
                res["table"].setdefault(f[0], {})[tag] = (f[1], f[3])     # setup_wns, hold_wns
        ws = re.search(r"^=== %s\n.*?^worst slack min (\S+)" % tag, text, re.M | re.S)
        if ws:
            res["all_" + tag] = ws.group(1)
    return res


def sta(run, stage="route"):
    """{mode: {key: value}} from analysis/<run>_sta_<stage>/sta_div*.log summary blocks."""
    out = {}
    for log in sorted(glob.glob(os.path.join(ANALYSIS, "%s_sta_%s" % (run, stage), "sta_div*.log")),
                      key=lambda p: int(re.search(r"div(\d+)", p).group(1))):
        mode = re.search(r"(div\d+)", log).group(1)
        blk = re.search(r"^=== summary\n(.*?)^===", read(log), re.M | re.S)
        if blk:
            out[mode] = dict(l.split(None, 1) for l in blk.group(1).splitlines() if len(l.split()) == 2)
    return out


def metrics(run):
    d = run_dirs(run)
    fin = load_json(os.path.join(d["logs"], "6_report.json"))
    drt = load_json(os.path.join(d["logs"], "5_2_route.json"))
    syn = load_json(os.path.join(d["logs"], "1_synth.json"))
    g = lambda dct, k: dct.get(k)
    return {
        "setup_ws": g(fin, "finish__timing__setup__ws"),
        "setup_tns": g(fin, "finish__timing__setup__tns"),
        "hold_ws": g(fin, "finish__timing__hold__ws"),
        "hold_tns": g(fin, "finish__timing__hold__tns"),
        "fmax_hclk": g(fin, "finish__timing__fmax__clock:hclk"),
        "skew_setup": g(fin, "finish__clock__skew__setup"),
        "skew_hold": g(fin, "finish__clock__skew__hold"),
        "slew_viol": g(fin, "finish__timing__drv__max_slew"),
        "cap_viol": g(fin, "finish__timing__drv__max_cap"),
        "die_area": g(fin, "finish__design__die__area"),
        "stdcell_area": g(fin, "finish__design__instance__area__stdcell"),
        "stdcells": g(fin, "finish__design__instance__count__stdcell"),
        "macros": g(fin, "finish__design__instance__count__macros"),
        "util": g(fin, "finish__design__instance__utilization"),
        "flops": g(fin, "finish__design__instance__count__class:sequential_cell"),
        "hold_bufs": g(fin, "finish__design__instance__count__class:timing_repair_buffer"),
        "power_mw": (g(fin, "finish__power__total") or 0) * 1e3 if g(fin, "finish__power__total") is not None else None,
        "drc": g(drt, "detailedroute__route__drc_errors"),
        "wirelength": g(drt, "detailedroute__route__wirelength"),
        "vias": g(drt, "detailedroute__route__vias"),
        "antenna_nets": g(drt, "detailedroute__antenna__violating__nets"),
        "synth_area": g(syn, "synth__design__instance__area__stdcell"),
        "warnings": g(fin, "finish__flow__warnings__count"),
    }


def one_page(run):
    st = stages(run)
    if not st:
        return None
    m = metrics(run)
    stopped = [s for s in st if s[2] != "done"]
    total = sum(s[3] for s in st if s[3] is not None)
    peak = max((s[4] for s in st if s[4] is not None), default=None)
    L = ["# %s: quality of results (ASAP7, exploratory)" % run, ""]
    if stopped:
        s = stopped[0]
        L.append("**Stopped in %s** (`%s.log`): %s" % (s[1], s[0], s[5]))
    elif st[-1][0] == "6_report":
        L.append("**Complete**: synthesis to GDS.")
    else:
        L.append("**Incomplete**: last stage run was %s." % st[-1][1])
    L += ["", "Run time %s in the stages logged, peak memory %s MiB (%s)." %
          (fmt_dur(total), fmt(peak), max(st, key=lambda s: s[4] or 0)[1] if peak else "-"), ""]

    if m["setup_ws"] is not None:
        L += ["## Final (ORFS report, primary scenario DIV2)", "",
              "| Metric | Value |", "|---|---|",
              "| setup WNS / TNS (ps) | %s / %s |" % (fmt(m["setup_ws"]), fmt(m["setup_tns"])),
              "| hold WNS / TNS (ps) | %s / %s |" % (fmt(m["hold_ws"]), fmt(m["hold_tns"])),
              "| hclk fmax (MHz) | %s |" % fmt(m["fmax_hclk"] / 1e6 if m["fmax_hclk"] else None, 1),
              "| clock skew setup / hold (ps) | %s / %s |" % (fmt(m["skew_setup"], 1), fmt(m["skew_hold"], 1)),
              "| max-slew / max-cap violations | %s / %s |" % (fmt(m["slew_viol"]), fmt(m["cap_viol"])),
              "| die area (um^2) | %s |" % fmt(m["die_area"], 0),
              "| std cells / area (um^2) | %s / %s |" % (fmt(m["stdcells"]), fmt(m["stdcell_area"], 1)),
              "| flops / timing-repair buffers / macros | %s / %s / %s |" % (fmt(m["flops"]), fmt(m["hold_bufs"]), fmt(m["macros"])),
              "| utilisation | %s |" % (("%.1f %%" % (100 * m["util"])) if m["util"] is not None else "-"),
              "| power (mW) | %s |" % fmt(m["power_mw"], 3),
              "| DRC errors after detailed route | %s |" % fmt(m["drc"]),
              "| wirelength (um) / vias | %s / %s |" % (fmt(m["wirelength"]), fmt(m["vias"])),
              "| antenna-violating nets | %s |" % fmt(m["antenna_nets"]),
              ""]

    s_route = sta(run, "route") or sta(run, "cts")
    if s_route:
        which = "routed, extracted parasitics" if sta(run, "route") else "after CTS, estimated parasitics"
        L += ["## Every DIVSEL scenario (make pd_sta; %s)" % which, "",
              "| mode | setup WNS | setup TNS | hold WNS | hold TNS | setup / hold violating endpoints |",
              "|---|---|---|---|---|---|"]
        for mode, v in s_route.items():
            L.append("| %s | %s | %s | %s | %s | %s / %s |" % (
                mode, v.get("setup_wns", "-"), v.get("setup_tns", "-"), v.get("hold_wns", "-"),
                v.get("hold_tns", "-"), v.get("setup_viol_endpoints", "-"), v.get("hold_viol_endpoints", "-")))
        L.append("")
    else:
        L += ["No per-scenario STA for this run (`make pd_sta V=%s`)." % run, ""]

    mh = mmhold(run)
    if mh:
        L += ["## Multi-mode hold repair (4_2_mmhold.log)", "",
              "%s endpoints repaired with %s buffers." % (mh["endpoints"], mh["buffers"]), ""]
        if mh["table"]:
            L += ["| scene | hold WNS before | hold WNS after |", "|---|---|---|"]
            for sc, v in mh["table"].items():
                L.append("| %s | %s | %s |" % (sc, v.get("before", ("-", "-"))[1], v.get("after", ("-", "-"))[1]))
        else:
            L.append("All scenes together: worst hold %s before, %s after (the per-scene table of the "
                     "older script was empty, BUGS TOOL-24)." % (mh.get("all_before", "-"), mh.get("all_after", "-")))
        L.append("")

    L += ["## Stages", "", "| stage | state | run time | peak memory (MiB) |", "|---|---|---|---|"]
    for stem, name, state, secs, pk, reason in st:
        L.append("| %s | %s | %s | %s |" % (name, state, fmt_dur(secs), fmt(pk)))
    L += ["", "Generated by `flow/pd/asap7/scripts/qor.py` from `%s`." % run_dirs(run)["logs"]]
    return "\n".join(L) + "\n"


def compare(runs):
    rows = ["# GARUDA ASAP7 runs side by side (exploratory)", "",
            "| run | outcome | setup WNS (ps) | hold WNS (ps) | worst hold, all modes (ps) | DRC | std cells | "
            "hold buffers | run time | peak MiB |",
            "|---|---|---|---|---|---|---|---|---|---|"]
    for r in runs:
        st = stages(r)
        if not st:
            continue
        m = metrics(r)
        stopped = [s for s in st if s[2] != "done"]
        if stopped:
            outcome = "stopped: %s" % stopped[0][1]
        elif st[-1][0] == "6_report":
            outcome = "GDS"
        else:
            outcome = "to %s" % st[-1][1]
        s = sta(r, "route")
        worst = min((float(v["hold_wns"]) for v in s.values() if "hold_wns" in v), default=None)
        total = sum(x[3] for x in st if x[3] is not None)
        peak = max((x[4] for x in st if x[4] is not None), default=None)
        rows.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            r, outcome, fmt(m["setup_ws"]), fmt(m["hold_ws"]), fmt(worst), fmt(m["drc"]),
            fmt(m["stdcells"]), fmt(m["hold_bufs"]), fmt_dur(total), fmt(peak)))
    return "\n".join(rows) + "\n"


def all_runs():
    base = os.path.join(PD_WORK, "logs", "asap7", DESIGN)
    runs = [os.path.basename(p) for p in glob.glob(os.path.join(base, "*")) if os.path.isdir(p)]
    key = lambda r: (re.sub(r"\d+$", "", r), int(re.search(r"(\d+)$", r).group(1)) if re.search(r"\d+$", r) else 0)
    return sorted(runs, key=key)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("runs", nargs="*")
    ap.add_argument("--compare", action="store_true", help="one row per run instead of one page")
    ap.add_argument("--all", action="store_true", help="every run under PD_WORK")
    ap.add_argument("--no-write", action="store_true", help="print only")
    a = ap.parse_args()
    runs = all_runs() if a.all else a.runs
    if not runs:
        ap.error("name a run, or --all")
    os.makedirs(ANALYSIS, exist_ok=True)
    if a.compare or a.all:
        text = compare(runs)
        out = os.path.join(ANALYSIS, "qor_compare.md")
    else:
        pages = []
        for r in runs:
            p = one_page(r)
            if p is None:
                print("qor: no logs for run %s under %s" % (r, PD_WORK), file=sys.stderr)
                return 1
            pages.append(p)
            if not a.no_write:
                with open(os.path.join(ANALYSIS, "%s_qor.md" % r), "w") as fh:
                    fh.write(p)
        text = "\n".join(pages)
        out = os.path.join(ANALYSIS, "%s_qor.md" % runs[0]) if len(runs) == 1 else ANALYSIS
    print(text, end="")
    if not a.no_write:
        if a.compare or a.all:
            with open(out, "w") as fh:
                fh.write(text)
        print("\nqor: written to %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
