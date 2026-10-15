#!/usr/bin/env python3
"""vcd_table.py <file.vcd> <clock> <signal-suffix> ... : print the value of each signal at every
rising edge of <clock>, one row per cycle. Signals are matched by the end of their full name, so
'u_eng.st' finds 'dma_top.u_eng.st'. Used to read JasperGold counterexamples saved with
visualize -save -vcd."""
import sys, re
def main():
    f, clk, want = sys.argv[1], sys.argv[2], sys.argv[3:]
    scope, ids, names, width = [], {}, {}, {}
    cur = {}; snap = {}; rows = []; t = 0
    lines = open(f, errors="replace").read().split("\n")
    i = 0
    while i < len(lines):
        l = lines[i].strip(); i += 1
        if l.startswith("$scope"): scope.append(l.split()[2])
        elif l.startswith("$upscope"): scope.pop()
        elif l.startswith("$var"):
            p = l.split(); code, name = p[3], ".".join(scope + [p[4]])
            if len(p) > 6 and p[5].startswith("["): name += p[5]
            ids.setdefault(code, []).append(name); width[code] = int(p[2])
        elif l.startswith("$enddefinitions"): break
    def find(s):
        for c, ns in ids.items():
            for n in ns:
                base = re.sub(r"\[\d+:\d+\]$", "", n)
                if base.endswith(s) or n.endswith(s): return c
        return None
    codes = [find(s) for s in want]; ck = find(clk)
    prev_ck = "0"
    for l in lines[i:]:
        l = l.strip()
        if not l: continue
        if l[0] == "#":
            snap = dict(cur)            # values as they were before this time step: what a flop samples
            continue
        if l[0] in "01xz" and len(l) > 1 and not l.startswith(("b", "r")):
            v, c = l[0], l[1:]
        elif l[0] in "bB":
            v, c = l[1:].split()
        else: continue
        if c == ck:
            if prev_ck == "0" and v == "1":
                rows.append([snap.get(x, "?") for x in codes])
            prev_ck = v
        cur[c] = v
    rows.append([cur.get(x, "?") for x in codes])     # the values after the last edge: where a failure shows
    def fmt(v):
        if v in ("?",) or set(v) - set("01"): return v
        n = int(v, 2); return str(n) if n < 1024 else hex(n)
    print("cyc " + " ".join("%10s" % s[-10:] for s in want))
    for k, r in enumerate(rows): print("%3d " % k + " ".join("%10s" % fmt(v) for v in r))
main()
