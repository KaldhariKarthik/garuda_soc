#!/usr/bin/env python3
"""toggle_holes.py -- group a block's uncovered design toggle points by signal.

    python3 tools/cov/toggle_holes.py tb/core/cov/cov.toml [module ...]

For triage: one line per signal with the bits that never rose / never fell,
so a hole reads as "csr_file mtvec_r[31:8] never rose" instead of 400 points.
"""
import collections, fnmatch, os, re, sys, tomllib
sys.path.insert(0, os.path.dirname(__file__))
import cov_report as cr

cfg = tomllib.load(open(os.path.join(cr.ROOT, sys.argv[1]), "rb"))
only = set(sys.argv[2:])
runs, _ = cr.load_runs(cfg)
pts = {}
for _, _, dat in runs:
    for kv, c in cr.read_dat(os.path.join(cr.ROOT, dat)):
        if cr.metric_of(kv) != "toggle":
            continue
        f = cr.rel(kv.get("f", "?"))
        if not cr.in_scope(f, cfg["design"]):
            continue
        k = (kv.get("page"), f, kv.get("o"))
        pts[k] = pts.get(k, 0) + c
sig = collections.defaultdict(lambda: {"rise": [], "fall": [], "n": 0})
for (page, f, o), c in pts.items():
    mod = page.split("/", 1)[-1]
    if only and mod not in only:
        continue
    m = re.match(r"^(.*?)(?:\[(\d+)\])?:(0->1|1->0)$", o or "")
    if not m:
        continue
    name, bit, d = m.group(1), m.group(2), m.group(3)
    e = sig[(mod, name)]
    e["n"] += 1
    if c == 0:
        e["rise" if d == "0->1" else "fall"].append(int(bit) if bit else 0)
def rng(b):
    b = sorted(set(b)); out = []; i = 0
    while i < len(b):
        j = i
        while j + 1 < len(b) and b[j + 1] == b[j] + 1: j += 1
        out.append(f"{b[j]}:{b[i]}" if j > i else f"{b[i]}"); i = j + 1
    return ",".join(reversed(out))
for (mod, name), e in sorted(sig.items()):
    if e["rise"] or e["fall"]:
        print(f"{mod:<24} {name:<34} bits {e['n']//2:>3}  never 0->1 [{rng(e['rise'])}]  never 1->0 [{rng(e['fall'])}]")
