#!/usr/bin/env python3
"""sec_rtl.py - prove RTL modules unchanged in behaviour by a rewrite (JasperGold SEC).

    python3 tools/sec_rtl.py --base <rev> MODULE [MODULE ...]
            [--fl rtl/soc/filelist_chip.f] [--map old=new ...] [--limit 30m]

For each MODULE: the module as it is in git revision <rev> (spec) against the module in the
working tree (imp), both elaborated from the same file list with SYNTHESIS defined and no
multiplier blackboxed. Clocks are inferred; no reset is declared, so the proof starts from
any state in which the two designs' mapped registers agree, which is stronger than starting
from reset. --map gives a port or register renamed by the rewrite (old name in <rev>, new
name now). Must run with the Cadence environment loaded (source /home/install/cshrc).

Writes sim/sec/<MODULE>/sec.log and prints one line per module:
    SEC <MODULE>  PROVEN  <n> outputs/state points
    SEC <MODULE>  FAIL    <reason>                      (exit 1)
Used for the style rewrites of the zero-waiver lint work (flow/ZERO_WAIVER.md), in place
of Conformal LEC, which the licence server does not offer.
"""
import argparse, os, re, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JG = "/home/install/JASPER/bin/jg"


def expand(tree, fl):
    env = dict(os.environ)
    env.pop("LD_LIBRARY_PATH", None)
    files = subprocess.check_output(["python3", os.path.join(ROOT, "scripts/expand_filelist.py"), fl],
                                    cwd=tree, env=env).decode().split()
    incs = subprocess.check_output(["python3", os.path.join(ROOT, "scripts/expand_filelist.py"), fl, "--incdirs"],
                                   cwd=tree, env=env).decode().split()
    files = [os.path.join(tree, f) for f in files]
    incs = ["+incdir+" + os.path.join(tree, i[2:] if i.startswith("-I") or i.startswith("+i") else i) for i in incs]
    return files, incs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--fl", default="rtl/soc/filelist_chip.f")
    ap.add_argument("--map", nargs="*", default=[])
    ap.add_argument("--limit", default="30m")
    ap.add_argument("--defines", nargs="*", default=[], help="extra +define+ names (e.g. GARUDA_RVFI)")
    ap.add_argument("--imp-root", default=ROOT, help="tree holding the rewritten RTL (default: this one)")
    ap.add_argument("--reset", default=None, help="prove from reset (a reset expression, e.g. '!core_rst_n') "
                    "instead of from any matched state: for rewrites that drop unreachable states")
    ap.add_argument("modules", nargs="+")
    a = ap.parse_args()
    rev = subprocess.check_output(["git", "rev-parse", "--short", a.base], cwd=ROOT).decode().strip()
    spec = os.path.join(ROOT, "sim/sec/base_" + rev)
    if not os.path.isdir(spec):
        os.makedirs(spec)
        arch = subprocess.Popen(["git", "archive", rev, "rtl", "scripts", "tb"], cwd=ROOT, stdout=subprocess.PIPE)
        subprocess.check_call(["tar", "-x", "-C", spec], stdin=arch.stdout)
        arch.wait()
    sf, si = expand(spec, a.fl)
    jf, ji = expand(os.path.abspath(a.imp_root), a.fl)
    bad = 0
    for mod in a.modules:
        d = os.path.join(ROOT, "sim/sec", mod)
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        maps = "".join("check_sec -map -spec {%s} -imp {%s}\n" % tuple(m.split("=", 1)) for m in a.map)
        dfs = "".join(" +define+" + x for x in a.defines)
        tcl = """check_sec -analyze -spec -sv09 +define+SYNTHESIS%s %s %s
check_sec -analyze -imp  -sv09 +define+SYNTHESIS%s %s %s
check_sec -elaborate -spec -top %s -bbox_mul 128
check_sec -elaborate -imp  -top %s -bbox_mul 128
check_sec -setup
%sclock -infer
%s
set_prove_time_limit %s
check_sec -generate_verification
check_sec -prove
puts "SECRESULT [check_sec -signoff -get_valid_status]"
puts "SECSUMMARY [get_property_list -include {status proven} -task <embedded>]"
exit
""" % (dfs, " ".join(si), " ".join(sf), dfs, " ".join(ji), " ".join(jf), mod, mod, maps,
       ("reset -expression {%s}" % a.reset) if a.reset else "reset -none", a.limit)
        with open(os.path.join(d, "sec.tcl"), "w") as fh:
            fh.write(tcl)
        log = os.path.join(d, "sec.log")
        for attempt in (1, 2):
            with open(log, "w") as fh:
                subprocess.call([JG, "-allow_unsupported_OS", "-sec", "-batch", "-no_jges", "-proj",
                                 os.path.join(d, "proj"), os.path.join(d, "sec.tcl")], cwd=ROOT, stdout=fh, stderr=subprocess.STDOUT)
            t = open(log, errors="replace").read()
            if attempt == 1 and "ECK040" in t:
                # a combinational module: no clock to infer
                with open(os.path.join(d, "sec.tcl"), "w") as fh:
                    fh.write(tcl.replace("clock -infer\n", "clock -none\n"))
                shutil.rmtree(os.path.join(d, "proj"), ignore_errors=True)
                continue
            break
        m = re.search(r"#proven: (\d+), #unprocessed: (\d+), #undetermined: (\d+), #cex: (\d+)", t)
        errs = re.findall(r"^ERROR.*$", t, re.M)
        if m and int(m.group(2)) == 0 and int(m.group(3)) == 0 and int(m.group(4)) == 0 and int(m.group(1)) > 0 and not errs:
            print("SEC %-28s PROVEN  %s points" % (mod, m.group(1)))
        else:
            bad += 1
            why = errs[0] if errs else (m.group(0) if m else "no result")
            print("SEC %-28s FAIL    %s  (%s)" % (mod, why[:160], os.path.relpath(log, ROOT)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
