#!/usr/bin/env python3
"""instret_report.py -- plan 5.12 / sign-off row 12: co-simulation-checked
instructions and workload diversity.

    python3 tools/run/instret_report.py [suite ...]   (default: endurance cosim stress riscv_dv)

Counts, from the per-run logs of the named core suites, only runs whose
verdict is PASS and whose co-simulation line reads 0 mismatches; the count is
the co-simulation's step count (every one compared with Spike). Diversity:
per program, per wait profile, traps and interrupts applied, and the dynamic
instruction-class mix (each program's committed PCs from one commit log of it,
looked up in its hex image, weighted by its checked instructions; the program
path does not depend on bus waits). Writes logs/core/evidence/instret_total.txt
and diversity.txt.
"""
import collections, glob, os, re, sys

R = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
suites = sys.argv[1:] or ["endurance", "cosim", "stress", "riscv_dv"]
COS = re.compile(r"^COSIM: (\d+) steps, (\d+) traps, (\d+) interrupts applied, (\d+) synced, (\d+) mismatches", re.M)
by_prog, by_wait, by_suite = collections.Counter(), collections.Counter(), collections.Counter()
traps = irqs = runs = 0
hexes = {}
for s in suites:
    for log in glob.glob(f"{R}/logs/core/raw/{s}/sim_*_s*.log"):
        t = open(log, errors="replace").read()
        if not re.search(r"^# verdict\s*: PASS", t, re.M):
            continue
        m = COS.search(t)
        if not m or m.group(5) != "0":
            continue
        n = int(m.group(1))
        cmd = re.search(r"^# command\s*: (.*)$", t, re.M).group(1)
        hx = re.search(r"\+HEX=(\S+)", cmd).group(1)
        prog = os.path.basename(hx)[:-4]
        hexes[prog] = hx
        iw = (re.search(r"\+IWAIT=(\d+)", cmd) or [0, "0"])[1]
        dw = (re.search(r"\+DWAIT=(\d+)", cmd) or [0, "0"])[1]
        rnd = "rand" if re.search(r"\+[ID]RAND=1", cmd) else "fixed"
        by_prog[prog] += n; by_wait[f"I{iw}/D{dw} {rnd}"] += n; by_suite[s] += n
        traps += int(m.group(2)); irqs += int(m.group(3)); runs += 1
total = sum(by_prog.values())


def classify(w):
    op, f3, f7 = w & 0x7F, (w >> 12) & 7, w >> 25
    return {0x37: "lui/auipc", 0x17: "lui/auipc", 0x6F: "jal", 0x67: "jalr", 0x63: "branch", 0x03: "load",
            0x23: "store", 0x13: "alu-imm", 0x0F: "fence", 0x0B: "dsu (custom-0)",
            0x33: "mul" if f7 == 1 else "alu-reg",
            0x73: "csr" if f3 else "system (ecall/ebreak/mret/wfi)"}.get(op, "other")


mix = collections.Counter()
nomix = []
all_logs = [p for p in glob.glob(f"{R}/logs/core/raw/*/*.commit.log") if os.path.getsize(p) > 100]
for prog, n in by_prog.items():
    # this program's own commit log: <prog>[_<suffix>].commit.log or cs_<prog>...,
    # never another program with the same prefix (t_core_ctl vs t_core_ctl_arch)
    own = re.compile(rf"^(cs_)?{re.escape(prog)}(_[swde]\d+)?\.commit\.log$")
    logs = [p for p in all_logs if own.match(os.path.basename(p))]
    if prog == "t_perf_mix":
        logs = logs or [p for p in all_logs if os.path.basename(p) == "perf_nowait.commit.log"]
    if not logs or not os.path.exists(hexes[prog]):
        nomix.append(prog); continue
    words = [int(l, 16) for l in open(hexes[prog]) if l.strip() and not l.startswith("@")]
    c = collections.Counter()
    for l in open(logs[0]):
        f = l.split()
        if len(f) == 3 and re.fullmatch(r"[0-9a-f]{8}", f[0]):
            k = (int(f[0], 16) - 0x10000000) >> 2
            if 0 <= k < len(words):
                c[classify(words[k])] += 1
    tot = sum(c.values()) or 1
    for k, v in c.items():
        mix[k] += n * v / tot
os.makedirs(f"{R}/logs/core/evidence", exist_ok=True)
head = f"suites: {' '.join(suites)}; passing co-simulated runs: {runs}"
open(f"{R}/logs/core/evidence/instret_total.txt", "w").write(
    f"Co-simulation-checked instructions (plan 5.12, sign-off row 12)\n{head}\n"
    f"TOTAL: {total:,} instructions, each compared with Spike (target 1e9: {'MET' if total >= 1e9 else 'NOT MET'})\n"
    + "".join(f"  {s:<10} {n:>15,}\n" for s, n in by_suite.most_common()))
d = [f"Workload diversity of the {total:,} checked instructions\n{head}\n",
     f"traps taken: {traps:,}; interrupts applied: {irqs:,}\n", "\nper program:\n"]
d += [f"  {p:<22} {n:>15,}  {100 * n / total:5.1f} %\n" for p, n in by_prog.most_common()]
d.append("\nper bus wait profile (I-port / D-port waits, fixed or random per beat):\n")
d += [f"  {w:<16} {n:>15,}  {100 * n / total:5.1f} %\n" for w, n in sorted(by_wait.items())]
d.append("\ndynamic instruction-class mix (estimated, see header):\n")
d += [f"  {k:<32} {100 * v / total:5.1f} %\n" for k, v in mix.most_common()]
if nomix:
    d.append(f"  (no commit log for: {' '.join(nomix)} -- not in the mix)\n")
open(f"{R}/logs/core/evidence/diversity.txt", "w").write("".join(d))
print(open(f"{R}/logs/core/evidence/instret_total.txt").read())
sys.exit(0 if total >= 1e9 else 1)
