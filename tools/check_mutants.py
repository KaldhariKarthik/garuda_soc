#!/usr/bin/env python3
"""check_mutants.py - every planted defect still applies to the RTL (TOOL-A24, 2026-11-19).

    python3 tools/check_mutants.py        exit 1 on any recipe that no longer applies or
                                          any generated mutant that is not current

Three kinds of negative controls are kept in this tree, and each went stale silently once
the F4 renames and rewrites changed the text they anchor on:

  tools/gen/gen_{ahb,apb,dma,dsu}_mutants.py   generate tb/<blk>/mut/*.v. Each generator is
      run on a scratch copy (rtl/ linked, tb/<blk>/{run,mut} copied); it stops on a pattern
      that is not found exactly once, and the files it writes must equal the ones checked in.
  flow/mutation/*_mutants.py, tb/dsu/dsu_mutants.py   tools/mutate.py specs: every old text
      must occur exactly once in its file.
  tb/*/uvm/planted.txt   scripts/planted_defects.sh lists: every sed -E -z expression must
      change its file.

tools/formal_mutants.py checks the formal negative controls itself; make check_tree runs both.
"""
import filecmp, os, runpy, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = {"ahb": "gen_ahb_mutants.py", "ahb2apb": "gen_apb_mutants.py",
       "dma": "gen_dma_mutants.py", "dsu": "gen_dsu_mutants.py"}


def check_generators():
    bad = 0
    for blk, gen in GEN.items():
        with tempfile.TemporaryDirectory() as t:
            os.makedirs(os.path.join(t, "tools/gen"))
            shutil.copy(os.path.join(ROOT, "tools/gen", gen), os.path.join(t, "tools/gen", gen))
            os.symlink(os.path.join(ROOT, "rtl"), os.path.join(t, "rtl"))
            for sub in ("run", "mut"):
                src = os.path.join(ROOT, "tb", blk, sub)
                if os.path.isdir(src):
                    shutil.copytree(src, os.path.join(t, "tb", blk, sub))
            r = subprocess.run([sys.executable, os.path.join(t, "tools/gen", gen)], cwd=t,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
            if r.returncode:
                print("check_mutants: %s fails: %s" % (gen, r.stdout.strip().splitlines()[-1:]))
                bad += 1
                continue
            for sub in ("mut", "run"):
                a, b = os.path.join(ROOT, "tb", blk, sub), os.path.join(t, "tb", blk, sub)
                if not os.path.isdir(b):
                    continue
                for n in sorted(os.listdir(b)):
                    if not os.path.exists(os.path.join(a, n)):
                        print("check_mutants: tb/%s/%s/%s is not checked in (run tools/gen/%s)" % (blk, sub, n, gen))
                        bad += 1
                    elif not filecmp.cmp(os.path.join(a, n), os.path.join(b, n), shallow=False):
                        print("check_mutants: tb/%s/%s/%s is not current (run tools/gen/%s)" % (blk, sub, n, gen))
                        bad += 1
    return bad


def check_specs():
    bad = 0
    specs = sorted(os.path.join("flow/mutation", f) for f in os.listdir(os.path.join(ROOT, "flow/mutation"))
                   if f.endswith("_mutants.py")) + ["tb/dsu/dsu_mutants.py"]
    for p in specs:
        cfg = runpy.run_path(os.path.join(ROOT, p))
        fl = cfg["FL_LINE"]
        if fl.startswith("-f ") and not os.path.exists(os.path.join(ROOT, fl[3:].strip())):
            print("check_mutants: %s: file list %s is missing" % (p, fl[3:].strip()))
            bad += 1
        for m in cfg["MUTANTS"]:
            n = open(os.path.join(ROOT, m[1])).read().count(m[2])
            if n != 1:
                print("check_mutants: %s: '%s' found %d times in %s" % (p, m[0], n, m[1]))
                bad += 1
    return bad


def check_planted():
    bad = 0
    for blk in sorted(os.listdir(os.path.join(ROOT, "tb"))):
        lst = os.path.join(ROOT, "tb", blk, "uvm", "planted.txt")
        if not os.path.exists(lst):
            continue
        for k, line in enumerate(open(lst), 1):
            if not line.strip() or line.startswith("#"):
                continue
            f, expr, what = [x.strip() for x in line.split("@@")]
            with tempfile.NamedTemporaryFile("w", delete=False) as t:
                t.write(open(os.path.join(ROOT, f)).read())
            subprocess.run(["sed", "-i", "-E", "-z", expr, t.name], check=True)
            same = filecmp.cmp(os.path.join(ROOT, f), t.name, shallow=False)
            os.unlink(t.name)
            if same:
                print("check_mutants: tb/%s/uvm/planted.txt:%d changes nothing in %s (%s)" % (blk, k, f, what))
                bad += 1
    return bad


def main():
    bad = check_generators() + check_specs() + check_planted()
    print("check_mutants: %s" % ("every planted defect applies" if not bad else "%d problem(s)" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
