#!/usr/bin/env python3
"""cov_report.py -- merge Verilator coverage of one block and judge it (H5).

    python3 tools/cov/cov_report.py tb/core/cov/cov.toml [--holes N]

The block's cov.toml names the coverage summaries to merge (written by
`garuda_run.py suite <m> --coverage`), the design and testbench file scopes,
the waiver file and the targets. Only runs classified OK (passed, not an
expected failure) contribute: coverage from a failing run proves nothing.

Points are merged per MODULE DEFINITION (hierarchy dropped): a line, branch,
expression, toggle bit/direction, FSM arc or covergroup bin counts as covered
if any instance in any passing run hit it -- the same view as IMC's module
summary with -initial_model union_all.

Reported separately, never merged into one number (H5):
  design code coverage     line / branch / expr / toggle / fsm per RTL module
  design functional        covergroup bins (covergroups sampling DUT ports)
  testbench code coverage  line / branch / expr / toggle of tb/** and bound SVA

Waivers (cov.toml `waivers`, TOML [[waiver]] tables) remove points from the
total only with: id, metric, file (glob), match (regex), category, reason,
evidence, reviewer. A waiver that matches no point is STALE, and a waiver that
matches a COVERED point contradicts its own claim (except category `ignore`,
which mirrors a source ignore_bins); both fail the report.
Exit status: 0 when every design module meets the targets after waivers and
the waiver file is clean, 1 otherwise.
"""
import argparse
import collections
import fnmatch
import os
import re
import sys
import tomllib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CODE = ["line", "branch", "expr", "toggle", "fsm"]
# waiver categories (H5):
#   constant      a literal constant in the RTL (cite the line) or a register
#                 proven constant (cite the PROVEN property)
#   unreachable   proven impossible: formal PROVEN negation, a full case
#                 statement's default, or contradictory conditions (interval proof)
#   not-connected an input tied off until a planned change (name the plan item)
#   ignore        a covergroup bin the SOURCE declares as ignore_bins, dropped by
#                 the simulator (Verilator COVERIGN on binsof/intersect selects)
# `tool`: a simulator defect loses a point that other metrics show is exercised; the
# evidence must name a TOOL bug; Verilator only, never exported to the IMC exclusions
CATEGORIES = {"constant", "unreachable", "not-connected", "ignore", "tool"}
SHIM = re.compile(r"^logs/[^/]+/raw/[^/]+/shim/(.*)$")


def rel(p):
    p = os.path.normpath(p)
    if p.startswith(ROOT + os.sep):
        p = p[len(ROOT) + 1:]
    m = SHIM.match(p)
    return m.group(1) if m else p


def read_dat(path):
    """Yield (fields, count) for every point in a Verilator coverage.dat."""
    with open(path, errors="replace") as fh:
        for ln in fh:
            if not ln.startswith("C '"):
                continue
            body, cnt = ln.rstrip("\n").rsplit("' ", 1)
            kv = dict(x.split("\x02", 1) for x in body[3:].split("\x01") if "\x02" in x)
            yield kv, int(cnt)


def metric_of(kv):
    page = kv.get("page", "")
    kind = page.split("/", 1)[0]
    return {"v_line": "line", "v_branch": "branch", "v_expr": "expr", "v_toggle": "toggle",
            "v_fsm_state": "fsm", "v_fsm_arc": "fsm", "v_covergroup": "covergroup",
            "v_user": "user"}.get(kind, kind or kv.get("t", "?"))


MERGE_VARIANTS = set()     # cov.toml merge_variants: modules whose __Pz<N> names are one parameter set
UNION_VARIANTS = set()     # cov.toml union_variants: modules built with DIFFERENT parameter sets
                           # (e.g. the bridge's window mask / APB divider); a point counts as
                           # covered if any parameterisation covered it -- the per-module union
                           # IMC reports by module type. Parameters change constants only.


def unvariant(kv):
    """Verilator numbers a module's parameterisations per build (dma_arbiter__Pz1 in one
    bench, __Pz7 in another, same PRIO). For the modules a config declares to have one
    parameter set in every build, drop the suffix so the builds merge into one module."""
    page = kv.get("page", "")
    kind, _, mod = page.partition("/")
    base = re.sub(r"__Pz\d+$", "", mod)
    if base != mod and base in MERGE_VARIANTS:
        kv["page"] = f"{kind}/{base}"
        return kv
    ubase = re.sub(r"__\w+$", "", mod)
    if ubase != mod and ubase in UNION_VARIANTS:
        kv["page"] = f"{kind}/{ubase}"
    return kv


def point_key(kv, metric):
    """Identity of a point in the module-definition view (no hierarchy)."""
    f = rel(kv.get("f", "?"))
    if metric == "covergroup":
        return (metric, f, kv.get("page"), kv.get("h", "").split(".", 1)[-1])
    return (metric, f, kv.get("l"), kv.get("n"), kv.get("o"), kv.get("page"))


def in_scope(f, globs):
    return any(fnmatch.fnmatch(f, g) for g in globs)


def load_runs(cfg):
    """[(summary, test, dat)] for every OK run listed in the configured summaries."""
    runs, missing = [], []
    for s in cfg["suites"]:
        p = os.path.join(ROOT, s)
        if not os.path.exists(p):
            missing.append(s)
            continue
        lines = [l.rstrip("\n").split("\t") for l in open(p)]
        head = lines[1]
        for l in lines[2:]:
            r = dict(zip(head, l))
            if r.get("class") == "OK" and r.get("cov_dat"):
                if os.path.exists(os.path.join(ROOT, r["cov_dat"])):
                    runs.append((s, r["test"], r["cov_dat"]))
                else:
                    missing.append(r["cov_dat"])
    return runs, missing


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config")
    ap.add_argument("--holes", type=int, default=60, help="holes listed per module and metric")
    ap.add_argument("--out", help="report file (default: logs/<block>/summary/cov_<block>.txt)")
    a = ap.parse_args()
    cfg = tomllib.load(open(os.path.join(ROOT, a.config), "rb"))
    blk = cfg["block"]
    tgt_code = float(cfg.get("target_code", 95.0))
    tgt_func = float(cfg.get("target_functional", 100.0))
    design, tb = cfg["design"], cfg["testbench"]
    # functional_files: "glob" or "glob::covergroup-regex"
    cg_design = cfg.get("functional_files", [])
    MERGE_VARIANTS.update(cfg.get("merge_variants", []))
    UNION_VARIANTS.update(cfg.get("union_variants", []))

    runs, missing = load_runs(cfg)
    pts = {}                                   # key -> [count, kv]
    for _, _, dat in runs:
        for kv, c in read_dat(os.path.join(ROOT, dat)):
            kv = unvariant(kv)
            m = metric_of(kv)
            k = point_key(kv, m)
            if k in pts:
                pts[k][0] += c
            else:
                pts[k] = [c, kv]

    # ---- waivers ------------------------------------------------------------------
    wv = []
    wpath = cfg.get("waivers")
    if wpath and os.path.exists(os.path.join(ROOT, wpath)):
        wv = tomllib.load(open(os.path.join(ROOT, wpath), "rb")).get("waiver", [])
    errors = []
    need = ["id", "metric", "file", "match", "category", "reason", "evidence", "reviewer"]
    for w in wv:
        miss = [x for x in need if not str(w.get(x, "")).strip()]
        if miss:
            errors.append(f"waiver {w.get('id', '?')}: missing {miss}")
        w["_rx"] = re.compile(w.get("match", "^$"))
        w["_hit"], w["_cov"] = 0, []

    def label(k, kv):
        m = k[0]
        if m == "covergroup":
            return f"{k[2].split('/', 1)[-1]}.{k[3]}"
        if m == "toggle":
            return kv.get("o", "")
        return f"line:{kv.get('l')} {kv.get('o', '')}"

    def waiver_for(k, kv):
        for w in wv:
            if w.get("metric") == k[0] and fnmatch.fnmatch(k[1], w.get("file", "")) \
                    and w["_rx"].search(label(k, kv)):
                return w
        return None

    # ---- tally ----------------------------------------------------------------------
    # code[scope][module][metric] = [hit, total, waived]; holes[(module, metric)] = [...]
    code = {"design": collections.defaultdict(lambda: collections.defaultdict(lambda: [0, 0, 0])),
            "testbench": collections.defaultdict(lambda: collections.defaultdict(lambda: [0, 0, 0]))}
    func = collections.defaultdict(lambda: [0, 0, 0])      # covergroup -> [hit, total, waived]
    holes = collections.defaultdict(list)
    fholes = collections.defaultdict(list)
    excl = collections.defaultdict(list)                   # covergroup -> illegal/ignore bins
    files = {}
    for k, (c, kv) in sorted(pts.items(), key=lambda x: (x[0][1], str(x[0][2]))):
        m, f = k[0], k[1]
        if m == "covergroup":
            # name + defining file: two covergroups of the same name (a bench's and
            # the bound core model's) are different coverage models
            cg = k[2].split("/", 1)[-1].replace("__vlAnonCG_", "") + f" ({os.path.basename(f)})"
            cgname = k[2].split("/", 1)[-1].replace("__vlAnonCG_", "")
            btype = kv.get("bin_type", "")
            if not any(fnmatch.fnmatch(f, g.split("::")[0]) and
                       (("::" not in g) or re.search(g.split("::", 1)[1], cgname)) for g in cg_design):
                continue
            # illegal_bins / ignore_bins declared in the source are not coverage
            # targets (as in IMC); an illegal bin that was hit is a design error
            if btype in ("illegal", "ignore"):
                excl[cg].append((btype, label(k, kv), c))
                if btype == "illegal" and c:
                    errors.append(f"ILLEGAL bin hit {c} time(s): {label(k, kv)} ({f}:{kv.get('l')})")
                continue
            w = waiver_for(k, kv)
            if w:
                w["_hit"] += 1
                if c:
                    w["_cov"].append(label(k, kv))
                func[cg][2] += 1
                continue
            func[cg][1] += 1
            if c:
                func[cg][0] += 1
            else:
                fholes[cg].append(f"{label(k, kv)}   ({f}:{kv.get('l')})")
            continue
        if m not in CODE:
            continue
        scope = "design" if in_scope(f, design) else "testbench" if in_scope(f, tb) else None
        if not scope:
            continue
        mod = kv.get("page", "/?").split("/", 1)[-1]
        files[mod] = f
        cell = code[scope][mod][m]
        w = waiver_for(k, kv) if scope == "design" else None
        if w:
            w["_hit"] += 1
            if c:
                w["_cov"].append(label(k, kv))
            cell[2] += 1
            continue
        cell[1] += 1
        if c:
            cell[0] += 1
        elif scope == "design":
            holes[(mod, m)].append((kv.get("l"), label(k, kv), f))

    for w in wv:
        if w.get("category") not in CATEGORIES:
            errors.append(f"waiver {w['id']}: category '{w.get('category')}' not in {sorted(CATEGORIES)}")
        if not w["_hit"]:
            errors.append(f"waiver {w['id']}: STALE (matches no point)")
        # an `ignore` waiver mirrors a source-declared ignore_bins the simulator
        # did not apply: its bins are excluded whether hit or not (as in IMC).
        # Every other category claims the point cannot happen: a hit disproves it.
        if w.get("category") == "tool" and not re.search(r"\bTOOL-\d+", str(w.get("evidence", ""))):
            errors.append(f"waiver {w['id']}: category tool needs a TOOL-<n> bug in its evidence")
        if w["_cov"] and w.get("category") != "ignore":
            errors.append(f"waiver {w['id']}: matches {len(w['_cov'])} COVERED point(s), "
                          f"e.g. {w['_cov'][:3]} -- the claim is false")

    # ---- report -----------------------------------------------------------------------
    def pct(h, t):
        return 100.0 * h / t if t else 100.0

    out = []
    out.append(f"Coverage report: block {blk}  (Verilator 5.052, merged per module definition)")
    out.append(f"runs merged : {len(runs)} passing runs from {len(cfg['suites'])} suite summaries")
    for s in cfg["suites"]:
        n = sum(1 for r in runs if r[0] == s)
        out.append(f"   {n:4d}  {s}")
    if missing:
        out.append(f"MISSING     : {missing}")
        errors.append(f"missing coverage inputs: {missing}")
    out.append(f"targets     : design code >= {tgt_code}% per metric per module; "
               f"design functional = {tgt_func}% of bins (after reviewed waivers)")
    out.append("")
    fails = []
    for scope in ("design", "testbench"):
        out.append(f"== {scope.upper()} CODE COVERAGE "
                   f"({'sign-off' if scope == 'design' else 'reported, not sign-off'}) ==")
        hdr = f"{'module':<26} " + " ".join(f"{m:>17}" for m in CODE) + "   waived"
        out.append(hdr)
        tot = collections.defaultdict(lambda: [0, 0, 0])
        for mod in sorted(code[scope]):
            cells, row, nw = code[scope][mod], [], 0
            for m in CODE:
                h, t, wd = cells[m]
                nw += wd
                tot[m][0] += h; tot[m][1] += t; tot[m][2] += wd
                if t == 0:
                    row.append(f"{'-':>17}")
                    continue
                p = pct(h, t)
                bad = scope == "design" and p < tgt_code
                if bad:
                    fails.append(f"{mod} {m} {p:.1f}%")
                row.append(f"{h:>6}/{t:<6}{p:>5.1f}{'!' if bad else ' '}")
            out.append(f"{mod:<26} " + " ".join(row) + f"   {nw}")
        row = []
        for m in CODE:
            h, t, _ = tot[m]
            row.append(f"{h:>6}/{t:<6}{pct(h, t):>5.1f} " if t else f"{'-':>17}")
        out.append(f"{'TOTAL':<26} " + " ".join(row) + f"   {sum(v[2] for v in tot.values())}")
        # the same before any waiver: hits / (target points + waived points)
        row = []
        for m in CODE:
            h, t, wd = tot[m]
            row.append(f"{h:>6}/{t + wd:<6}{pct(h, t + wd):>5.1f} " if t + wd else f"{'-':>17}")
        out.append(f"{'RAW (before waivers)':<26} " + " ".join(row))
        out.append("")

    out.append("== DESIGN FUNCTIONAL COVERAGE (covergroup bins) ==")
    fh, ft = 0, 0
    for cg in sorted(func):
        h, t, wd = func[cg]
        fh += h; ft += t
        bad = pct(h, t) < tgt_func
        if bad:
            fails.append(f"covergroup {cg} {pct(h, t):.1f}%")
        out.append(f"{cg:<46} {h:>5}/{t:<5} {pct(h, t):6.1f}%{'!' if bad else ' '}  waived {wd}")
    out.append(f"{'TOTAL':<46} {fh:>5}/{ft:<5} {pct(fh, ft):6.1f}%")
    fw = sum(v[2] for v in func.values())
    out.append(f"{'RAW (before waivers)':<46} {fh:>5}/{ft + fw:<5} {pct(fh, ft + fw):6.1f}%   "
               f"({fw} waived bins; illegal/ignore bins declared in the source are never targets)")
    out.append("")
    out.append("== ILLEGAL / IGNORE BINS (declared in the source; not targets; illegal must stay 0) ==")
    for cg in sorted(excl):
        for bt, lab, c in excl[cg]:
            out.append(f"   {bt:<8} {lab:<70} hits {c}")
    out.append("")

    out.append(f"== WAIVERS ({len(wv)}) ==")
    for w in wv:
        out.append(f"{w.get('id')}  [{w.get('metric')}/{w.get('category')}]  {w.get('file')}  "
                   f"/{w.get('match')}/  -> {w['_hit']} point(s)")
        out.append(f"    reason  : {w.get('reason')}")
        out.append(f"    evidence: {w.get('evidence')}   reviewer: {w.get('reviewer')}")
    out.append("")

    out.append("== DESIGN HOLES (uncovered, not waived) ==")
    for (mod, m) in sorted(holes):
        lst = holes[(mod, m)]
        out.append(f"-- {mod} ({files.get(mod)}) {m}: {len(lst)}")
        for l, lab, f in lst[:a.holes]:
            src = ""
            if m != "toggle":
                try:
                    src = open(os.path.join(ROOT, f), errors="replace").read().split("\n")[int(l) - 1].strip()
                except (OSError, ValueError, IndexError):
                    pass
            out.append(f"     {lab:<60} {src[:90]}")
        if len(lst) > a.holes:
            out.append(f"     ... {len(lst) - a.holes} more")
    out.append("")
    out.append("== FUNCTIONAL HOLES (bins never hit, not waived) ==")
    for cg in sorted(fholes):
        out.append(f"-- {cg}: {len(fholes[cg])}")
        for x in fholes[cg]:
            out.append(f"     {x}")
    out.append("")
    if errors:
        out.append("== ERRORS ==")
        out += [f"   {e}" for e in errors]
    verdict = "PASS" if not fails and not errors else "FAIL"
    out.append(f"verdict: {verdict}  ({len(fails)} below target, {len(errors)} waiver/input error(s))")
    if fails:
        out.append("below target: " + "; ".join(fails[:60]) + (" ..." if len(fails) > 60 else ""))
    text = "\n".join(out) + "\n"
    dst = a.out or os.path.join(ROOT, "logs", blk, "summary", f"cov_{blk}.txt")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    open(dst, "w").write(text)
    print(text, end="")
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
