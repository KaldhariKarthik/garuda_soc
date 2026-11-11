#!/usr/bin/env python3
"""bench_report.py -- read a benchmark's result block and give the verdict (plan 5.7).

    python3 tools/bench_report.py <sigfile> [--bench coremark|dhrystone]

<sigfile> is the dump tb_boot writes with +SIGFILE=<f> +SIGBEGIN=10030000
+SIGEND=10034000 (one 32-bit word per line). Layout: sw/bench/rt/bench_rt.h.

Prints the program's own text, then one verdict line:
  BENCH coremark PASS  iterations=30 cycles=... instret=... CPI=... CoreMark/MHz=...
  BENCH dhrystone PASS runs=500 cycles=... DMIPS/MHz=...
FAIL if the block is missing (bad magic), the program's self-check failed
(CoreMark: "Correct operation validated." absent or an ERROR line; Dhrystone:
any value differing from its "should be" line), or the counters are absent.
Exit status 0 only on PASS.
"""
import argparse, re, struct, sys

MAGIC = 0x48424E47

ap = argparse.ArgumentParser()
ap.add_argument("sig")
ap.add_argument("--bench", choices=["coremark", "dhrystone"])
a = ap.parse_args()

words = [int(l, 16) for l in open(a.sig) if l.strip()]
if len(words) < 8 or words[0] != MAGIC:
    print(f"BENCH {a.bench or '?'} FAIL  no result block (magic {words[0] if words else 0:#010x})")
    sys.exit(1)
c0, c1, i0, i1, loglen, fake = words[1:7]
raw = b"".join(struct.pack("<I", w) for w in words[8:])[:loglen]
text = raw.decode("ascii", "replace")
print(text.rstrip())
print("-" * 72)

bench = a.bench or ("coremark" if "CoreMark" in text else "dhrystone")
cyc, ins = (c1 - c0) & 0xFFFFFFFF, (i1 - i0) & 0xFFFFFFFF
bad = []
if not cyc or not ins:
    bad.append("counters not recorded")
tag = " (fake timer: lockstep build, no score)" if fake else ""

if bench == "coremark":
    m = re.search(r"Iterations\s*:\s*(\d+)", text)
    it = int(m.group(1)) if m else 0
    if "Correct operation validated." not in text:
        bad.append("CoreMark did not validate its CRCs")
    if re.search(r"ERROR", text):
        bad.append("ERROR line in the CoreMark output")
    if not it:
        bad.append("no iteration count")
    score = "" if fake or not it or not cyc else \
        f" CoreMark/MHz={it * 1e6 / cyc:.3f}"
    detail = f"iterations={it} cycles={cyc} instret={ins}" + \
             (f" CPI={cyc / ins:.3f}" if ins else "") + score
else:
    m = re.search(r"Trying (\d+) runs", text)
    runs = int(m.group(1)) if m else 0
    lines = text.splitlines()
    checked = 0
    for k, l in enumerate(lines[:-1]):
        sb = re.match(r"\s+should be:\s+(.*)$", lines[k + 1])
        got = re.match(r"\s*[\w>-]+:\s+(.*)$", l)
        if sb and got and "implementation-dependent" not in sb.group(1):
            checked += 1
            if got.group(1).strip() != sb.group(1).strip():
                bad.append(f"{l.strip()} (should be {sb.group(1).strip()})")
    if checked < 15:
        bad.append(f"only {checked} self-check values found")
    if not runs:
        bad.append("no run count")
    score = "" if fake or not runs or not cyc else \
        f" cycles/run={cyc / runs:.1f} DMIPS/MHz={runs * 1e6 / cyc / 1757:.3f}"
    detail = f"runs={runs} values_checked={checked} cycles={cyc} instret={ins}" + \
             (f" CPI={cyc / ins:.3f}" if ins else "") + score

if bad:
    print(f"BENCH {bench} FAIL  " + "; ".join(bad))
    sys.exit(1)
print(f"BENCH {bench} PASS  {detail}{tag}")
