#!/usr/bin/env python3
"""vplan_trace.py -- trace every vPlan check / cover / test row to what implements it
and to its last result (Track A, DMA plan D10; reusable per block).

    python3 tools/run/vplan_trace.py dma      (config tb/dma/vplan_trace.toml)
    -> logs/<blk>/summary/vplan_trace.txt

For each CHK / COV / TC row of the vPlan CSV, its NAME (after the config's
[alias] table, which records every planned name that the implementation renamed)
is resolved against, in order:
  property   an assert/cover label in the configured SVA files; result from formal
             (PROVEN when the proof task keeps it and passed; a defect-finder task's
             class when the proof leaves it out) and from simulation (bound in every
             bench; the suites are OK with their declared `known` firings)
  covergroup cg_x or cg_x.item in the coverage files; result = the group's line in
             the coverage report (and the item's uncovered bins, if any)
  test       a test name in the configured suite summaries; result = its class
  rule       a [rule] name (the NAME's first word) or prefix of the config
             (scoreboard, register tests, checkers, external suites, static,
             review), with its tests, whole suites (class counts) and evidence
             files (a suite never run or a missing file counts as UNMAPPED)
Anything else is UNMAPPED and is listed for a decision.
"""
import csv, os, re, sys, tomllib, collections

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
blk = sys.argv[1]
cfg = tomllib.load(open(os.path.join(ROOT, f"tb/{blk}/vplan_trace.toml"), "rb"))

def rd(p):
    return open(os.path.join(ROOT, p), errors="replace").read()

def tsv(p):
    p = os.path.join(ROOT, p)
    if not os.path.exists(p):
        return []
    lines = [l.rstrip("\n").split("\t") for l in open(p)]
    return [dict(zip(lines[1], l)) for l in lines[2:]] if len(lines) > 1 else []

# ---- properties -------------------------------------------------------------------
props = {}
for f in cfg["sva_files"]:
    for m in re.finditer(r"^\s*([ac]_\w+)\s*:\s*(assert|cover)\b", rd(f), re.M):
        props[m.group(1)] = (m.group(2), f)
fv_rows = {r["task"]: r for s in cfg["formal_summaries"] for r in tsv(s)}
def flist_files(fl, seen=None):
    """files named by a filelist, nested -f included (comments and +/- options skipped)"""
    seen = set() if seen is None else seen
    out = set()
    for ln in rd(fl).splitlines():
        ln = ln.split("//")[0].strip()
        if not ln or ln.startswith("#"):
            continue
        if ln.startswith("-f "):
            sub = ln[3:].strip()
            if sub not in seen:
                seen.add(sub); out |= flist_files(sub, seen)
        elif not ln.startswith(("-", "+")):
            out.add(ln)
    return out
fv_tasks = []
for man in cfg["formal_manifests"]:
    m = tomllib.loads(rd(man))
    d = m.get("design", {})
    files = (flist_files(d["flist"]) if d.get("flist") else set()) | set(d.get("extra", []))
    files -= set(d.get("exclude", []))
    for t in m.get("task", []):
        fv_tasks.append((os.path.basename(man), t, files))
def formal_of(name):
    out = []
    for man, t, files in fv_tasks:
        if props[name][1] not in files:
            continue                                          # not in this task's design
        script = " ".join(t.get("script", []))
        named = set(re.findall(r"\*(\w+)\*", script)) | set(re.findall(r"n:\S*\.(\w+)\b", script))
        keeps_only = "t:$check" in script and script.rstrip().endswith("%d")
        if t.get("replace"):
            continue                                          # mutants: negative controls, not results
        if keeps_only:
            inc = name in named or any(name.startswith(n.rstrip("*")) for n in named if n.endswith("*"))
        else:
            inc = name not in named
        if inc and t["name"] in fv_rows and t.get("mode") in ("prove", "bmc") and props[name][0] == "assert":
            r = fv_rows[t["name"]]
            out.append(f"{t['name']} {r['result']} {r['class']}")
        if inc and t["name"] in fv_rows and t.get("mode") == "cover" and props[name][0] == "cover":
            out.append(f"{t['name']} {fv_rows[t['name']]['result']}")
    return out

# ---- coverage ---------------------------------------------------------------------
cg_items = collections.defaultdict(set)
for f in cfg["cov_files"]:
    src = rd(f)
    for m in re.finditer(r"^\s*covergroup\s+(\w+)(.*?)endgroup", src, re.S | re.M):
        for it in re.finditer(r"^\s*(\w+)\s*:\s*(coverpoint|cross)\b", m.group(2), re.M):
            cg_items[m.group(1)].add(it.group(1))
rep = rd(cfg["cov_report"]) if os.path.exists(os.path.join(ROOT, cfg["cov_report"])) else ""
cg_line = {m.group(1): m.group(0).strip() for m in re.finditer(r"^(cg_\w+) \(.*$", rep, re.M)}
holes = re.findall(r"^\s+(cg_\w+\.\w+)\.\S+", rep.split("== FUNCTIONAL HOLES")[-1], re.M) if "FUNCTIONAL HOLES" in rep else []

# ---- tests ------------------------------------------------------------------------
tests = {}
for s in cfg["suite_summaries"]:
    for r in tsv(s):
        tests[r["test"]] = f"{r['class']} ({os.path.basename(s)})"

rules = cfg.get("rule", {})
alias = cfg.get("alias", {})
rows = list(csv.DictReader(open(os.path.join(ROOT, cfg["vplan"]), newline="")))
out, tally, unmapped = [], collections.Counter(), []
for r in rows:
    kind = r["NODE_KIND"]
    if kind not in ("CHK", "COV", "TC"):
        continue
    name = r["NAME"].strip()
    targets = alias.get(r["element_id"], alias.get(name, name))
    targets = targets if isinstance(targets, list) else [targets]
    res = []
    for tname in targets:
        base = tname.split()[0]
        if base in props:
            f = formal_of(base)
            res.append(f"{props[base][0]} {base}: sim bound; formal: {'; '.join(f) if f else 'none (simulation only)'}")
        elif base.split(".")[0] in cg_items:
            g, _, it = base.partition(".")
            if it and it not in cg_items[g]:
                res.append(f"covergroup {g}: item {it} MISSING")
            else:
                h = [x for x in holes if x == base] if it else []
                res.append(f"{cg_line.get(g, g + ' (not in report)')}" + (f"; item {it} has holes" if h else ""))
        elif base in tests:
            res.append(f"test {base}: {tests[base]}")
        else:
            rule = rules.get(base) or next((v for k, v in rules.items() if k.endswith("*") and base.startswith(k[:-1])), None)
            if rule:
                st = [f"{t}: {tests[t]}" for t in rule.get("tests", []) if t in tests]
                for sp in rule.get("suites", []):
                    rows_ = tsv(sp)
                    c = collections.Counter(r["class"].split(":")[0] for r in rows_)
                    st.append(f"{os.path.basename(sp)}: " + (", ".join(f"{k} {v}" for k, v in sorted(c.items())) if rows_ else "NO RUN"))
                for ev in rule.get("evidence", []):
                    st.append(f"{ev}: " + ("present" if os.path.exists(os.path.join(ROOT, ev)) else "MISSING"))
                bad = any(x.endswith("NO RUN") or x.endswith("MISSING") for x in st)
                res.append(("UNMAPPED " if bad else "") + f"{rule['what']}" + (f" [{', '.join(st)}]" if st else ""))
            else:
                res.append("UNMAPPED")
    status = "UNMAPPED" if any(x.startswith("UNMAPPED") or "MISSING" in x for x in res) else "mapped"
    tally[(kind, status)] += 1
    if status == "UNMAPPED":
        unmapped.append(f"{r['element_id']} {name}")
    shown = name if targets == [name] else f"{name} -> {', '.join(targets)}"
    out.append(f"{r['element_id']:16} {kind:4} {shown}\n{'':22}{' | '.join(res)}")
head = [f"vPlan trace: {cfg['vplan']} (tools/run/vplan_trace.py {blk})",
        "totals: " + ", ".join(f"{k[0]} {k[1]} {v}" for k, v in sorted(tally.items())), ""]
tail = ["", f"UNMAPPED ({len(unmapped)}): need an alias, an implementation or a decision"] + [f"  {u}" for u in unmapped]
p = os.path.join(ROOT, f"logs/{blk}/summary/vplan_trace.txt")
open(p, "w").write("\n".join(head + out + tail) + "\n")
print(head[1], "->", os.path.relpath(p, ROOT))
for u in unmapped:
    print("  UNMAPPED", u)
