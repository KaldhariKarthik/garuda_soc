#!/usr/bin/env python3
"""
mutate.py - plant defects in a copy of a block and record who notices.

    python3 tools/mutate.py <spec.py>

The spec file defines:
  FILES   the block's RTL files (and its sva file), copied for every mutant
  BENCH   the bench file list, in which the block's own file list line is replaced
  FL_LINE the line of BENCH that pulls the block's file list in (e.g. "-f rtl/dma/filelist.f")
  KEEP    lines of that file list to keep as they are (a vendored file list, a -sv), optional
  TOP     the bench top;  ARGS  extra simulator arguments (optional)
  MUTANTS [(name, file, old text, new text), ...]
For every mutant the copy is simulated with assertions on; the table says which assertions fired
([SVA-FAIL] lines) and whether the bench itself failed. Copies and logs go to sim/lab/<NAME>/mut/.
A mutant whose text is not found exactly once is reported and skipped, never guessed.
"""
import os, re, sys, subprocess, runpy
cfg = runpy.run_path(sys.argv[1])
name = cfg["NAME"]; files = cfg["FILES"]; args = cfg.get("ARGS", "")
base = {f: open(f).read() for f in files}
res = []
for mname, f, old, new in cfg["MUTANTS"]:
    d = "sim/lab/%s/mut/%s" % (name, mname.split()[0]); os.makedirs(d, exist_ok=True)
    for p, t in base.items(): open(os.path.join(d, os.path.basename(p)), "w").write(t)
    tgt = os.path.join(d, os.path.basename(f)); s = open(tgt).read()
    if s.count(old) != 1:
        print("%-46s PATTERN FOUND %d TIMES, skipped" % (mname, s.count(old))); continue
    open(tgt, "w").write(s.replace(old, new))
    inc = "".join("-incdir %s\n" % x for x in cfg.get("INCDIRS", [])) + "".join(l + "\n" for l in cfg.get("KEEP", []))
    lst = inc + "\n".join(os.path.join(d, os.path.basename(p)) for p in files if p.endswith((".v", ".sv"))) + "\n"
    fl = open(cfg["BENCH"]).read().replace(cfg["FL_LINE"], lst)
    open(d + "/files.f", "w").write(fl)
    subprocess.call("irun -64bit -sv -assert -f %s/files.f -top %s %s -nclibdirname %s/INCA -l %s/run.log >/dev/null 2>&1"
                    % (d, cfg["TOP"], args, d, d), shell=True)
    log = open(d + "/run.log", errors="replace").read()
    fired = sorted(set(re.findall(r"\[SVA-FAIL\] (a_\w+)", log)))
    bench = "FAIL" if re.search(r"RESULT: FAILED|\[FAIL\]|TIMEOUT|\*E,(VLGERR|ELBERR)", log) else "pass"
    if re.search(r"\*E,(VLGERR|ELBERR|CUVMUR)", log): bench = "BUILD ERROR"
    res.append((mname, fired, bench))
    print("%-46s assertions: %-50s bench: %s" % (mname, ",".join(fired) or "none", bench), flush=True)
a = sum(1 for r in res if r[1]); b = sum(1 for r in res if r[2] == "FAIL")
print("%s: %d mutants; assertions caught %d, bench caught %d" % (name, len(res), a, b))
