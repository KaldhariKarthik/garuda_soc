#!/usr/bin/env python3
"""gen_cadence_cov.py -- Cadence (irun 15.2 + IMC 15.2) coverage scripts for a Track A block.

    python3.12 tools/cov/gen_cadence_cov.py core|dsu|dma|ahb|all

Writes, per block, everything needed to show the block's RTL coverage in Cadence,
measured on EXACTLY the tests the open-flow coverage uses (the suites listed in
tb/<blk>/cov/cov.toml, expanded with the runner's own manifest reader, so the two
flows cannot drift apart):

  flow/cov/<blk>.ccf           coverage config: code coverage on the design modules
                               only (cov.toml `design`), covergroups everywhere
  flow/cov/<blk>_cadence.sh    compile each bench once with -coverage all, run every
                               test with -covtest <test>, check each log's pass marker,
                               merge the passing runs in IMC, then run the report
  flow/cov/<blk>_report.tcl    IMC: load the merge, apply flow/cov/<blk>_exclusions.tcl
                               (mapped onto the simulation's instance path), write the
                               code / waiver / functional reports
  flow/cov/<blk>_ncl.tcl       NCLaunch -input wrapper (the default way Cadence tools are
                               run on this laptop: Obsidian "NCLaunch Guide (C)")

irun 15.2, not Xcelium 22.09: the lab IMC and vManager are 15.2 and cannot read a 22.09
database (flow/COMMANDS.md). Negative controls (tests with `replace`) and xfail rows are
left out, as in the open-flow merge. Verilator-only plusargs are dropped; the runner's
+verilator+seed+N becomes -svseed N.
"""
import os, sys, re, shlex, tomllib, collections

R = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(R, "tools", "run"))
import garuda_run as gr                                   # load_manifest, expand_flist

# where the block's DUT top sits in its main bench (the instance the exclusions map onto)
SCOPE = {"core": "tb_boot.dut", "dsu": "tb_dsu_top.dut", "dma": "tb_dma_env.dut", "ahb": "tb_ahb_env.u_dut"}


def manifests_by_suite():
    out = {}
    for d in sorted(os.listdir(os.path.join(R, "tb"))):
        rd = os.path.join(R, "tb", d, "run")
        if not os.path.isdir(rd):
            continue
        for f in sorted(os.listdir(rd)):
            if f.endswith(".toml"):
                p = os.path.join("tb", d, "run", f)
                try:
                    s = tomllib.load(open(os.path.join(R, p), "rb")).get("suite", {})
                except Exception:
                    continue
                if s.get("kind", "sim") in ("sim", "prog"):
                    out[(s.get("block"), s.get("name"))] = p
    return out


def xfail_set(path):
    xs = set()
    if path and os.path.exists(os.path.join(R, path)):
        for ln in open(os.path.join(R, path)):
            if ln.strip() and not ln.startswith("#"):
                c = ln.rstrip("\n").split("\t")
                if len(c) >= 2:
                    xs.add((c[0], c[1]))
    return xs


def design_modules(cfg):
    import glob
    mods = []
    for gl in cfg["design"]:
        for f in sorted(glob.glob(os.path.join(R, gl))):
            txt = re.sub(r"//[^\n]*|/\*.*?\*/", "", open(f).read(), flags=re.S)
            mods += re.findall(r"\bmodule\s+(\w+)", txt)
    return sorted(set(mods))


def gen(blk):
    cfg = tomllib.load(open(os.path.join(R, f"tb/{blk}/cov/cov.toml"), "rb"))
    mans = manifests_by_suite()
    D = f"sim/cov_{blk}"
    benches = collections.OrderedDict()       # key -> dict(flist file, top, defines, tests)
    missing = []
    for sp in cfg["suites"]:
        m = re.match(r"logs/(\w+)/summary/(\w+)\.cov\.tsv$", sp)
        if not m:
            continue
        sblk, sname = m.groups()
        mp = mans.get((sblk, sname))
        if not mp:
            missing.append(sp)
            continue
        man, s, tests = gr.load_manifest(mp)
        xs = xfail_set(s.get("xfail"))
        bench = man.get("bench")
        for t in tests:
            if t.get("replace") or (sname, t["name"]) in xs:
                continue                         # negative controls and xfail rows: not merged
            if bench:
                fl, top = bench.get("cov_flist", bench["flist"]), bench["top"]
                defs = bench.get("defines", [])
                brep = bench.get("replace", {})
            else:
                fl, top = t.get("cov_flist", t["flist"]), t["top"]
                defs, brep = t.get("defines", []), {}
            if bench and brep:
                continue                         # a replaced bench is not the design
            key = f"{sblk}_{sname}_{top}" if bench else f"{top}_{re.sub(r'[^A-Za-z0-9]', '_', fl)}"
            b = benches.setdefault(key, {"flist": fl, "top": top, "defines": list(defs), "tests": []})
            plus, seed = [], "1"
            for x in t.get("plusargs", []):
                mm = re.match(r"\+verilator\+seed\+(\d+)$", x)
                if mm:
                    seed = mm.group(1)
                elif x.startswith("+verilator+"):
                    continue
                else:
                    plus.append(x.format(raw=f"$D/{key}", name=t["name"]))
            if t.get("hex"):
                plus = [f"+HEX=$R/{t['hex']}", "+COMMIT=/dev/null"] + plus
            b["tests"].append((f"{sname}__{t['name']}", seed, plus, t.get("marker", r"RESULT: PASSED")))

    mods = design_modules(cfg)
    # ---------------------------------------------------------------- .ccf
    ccf = [f"// {blk}.ccf -- GENERATED by tools/cov/gen_cadence_cov.py {blk}: code coverage on the",
           f"// design modules only (tb/{blk}/cov/cov.toml `design`), as the open flow reports it.",
           "// Covergroups (functional coverage) are collected everywhere by -coverage all."]
    ccf += [f"select_coverage -all -module {m}" for m in mods]
    # score expressions the way the open flow does (every operator, every statement),
    # not only && / || in conditions (irun's default, warning COVDCL)
    ccf += ["set_expr_coverable_operators -all", "set_expr_coverable_statements -all"]
    open(os.path.join(R, f"flow/cov/{blk}.ccf"), "w").write("\n".join(ccf) + "\n")

    # ---------------------------------------------------------------- run script
    sh = ["#!/bin/bash",
          f"# {blk}_cadence.sh -- GENERATED by tools/cov/gen_cadence_cov.py {blk}; do not edit.",
          f"# {blk.upper()} RTL coverage in Cadence (irun 15.2 + IMC 15.2) on the same tests as the",
          f"# open-flow coverage (tb/{blk}/cov/cov.toml). Needs the Cadence environment",
          "# (tcsh; source ~/cadence/cshrc; VPN up) and a SIMULATION licence: on this laptop the",
          "# compile/elaborate steps work, the run steps stop at licence -39 until C2S grants it.",
          "# Usage (repo root):  bash flow/cov/" + blk + "_cadence.sh [--compile-only]",
          "# Through NCLaunch:   nclaunch -nokey -directory $PWD -cdslib $PWD/cds.lib -work worklib -input flow/cov/" + blk + "_ncl.tcl",
          "set -u",
          'R="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$R"',
          f'D="$R/{D}"; mkdir -p "$D"',
          'ONLY_COMPILE=0; [ "${1:-}" = "--compile-only" ] && ONLY_COMPILE=1',
          f'COV="-coverage all -covfile $R/flow/cov/{blk}.ccf -covworkdir $D/cov_work -covdesign {blk} -covoverwrite"',
          'echo -e "bench\\ttest\\tverdict\\tlog" > "$D/runs.tsv"',
          'PASSED=()']
    for key, b in benches.items():
        srcs, incs, defs = gr.expand_flist(b["flist"])
        flf = f"$D/{key}.f"
        sh.append(f"\n# ---- bench {b['top']}  ({b['flist']}, {len(b['tests'])} tests)")
        sh.append(f"cat > {flf} <<'EOF'")
        sh += [f"+incdir+{i}" for i in incs] + [f"+define+{d}" for d in defs + b["defines"]] + srcs
        sh.append("EOF")
        sh.append(f'irun -64bit -sv -elaborate -access +r -timescale 1ns/1ps -f {flf} -top {b["top"]} '
                  f'-nclibdirname $D/INCA_{key} $COV -l $D/{key}.compile.log '
                  f'|| {{ echo "COMPILE FAILED: {key} (see $D/{key}.compile.log)"; }}')
        sh.append('if [ $ONLY_COMPILE = 0 ]; then')
        for tn, seed, plus, marker in b["tests"]:
            ps = " ".join(shlex.quote(p) if "$" not in p else f'"{p}"' for p in plus)
            log = f"$D/{tn}.log"
            sh.append(f'  irun -64bit -R -nclibdirname $D/INCA_{key} -covworkdir $D/cov_work -covdesign {blk} '
                      f'-covtest {tn} -svseed {seed} {ps} -l {log} > /dev/null 2>&1; '
                      f'if grep -Eq {shlex.quote(marker)} {log}; then v=PASS; PASSED+=("$D/cov_work/scope/{tn}"); else v=FAIL; fi; '
                      f'echo -e "{key}\\t{tn}\\t$v\\t{log}" >> "$D/runs.tsv"')
        sh.append('fi')
    sh += ['',
           '[ $ONLY_COMPILE = 1 ] && { echo "compile-only: done, logs in ' + D + '"; exit 0; }',
           'echo "runs: $(grep -c PASS "$D/runs.tsv") PASS, $(grep -c FAIL "$D/runs.tsv") FAIL ($D/runs.tsv)"',
           '[ ${#PASSED[@]} -gt 0 ] || { echo "no passing run to merge"; exit 1; }',
           'imc -execcmd "merge ${PASSED[*]} -out $D/cov_work/scope/all -overwrite -initial_model union_all" -logfile $D/imc_merge.log',
           f'imc -exec $R/flow/cov/{blk}_report.tcl -logfile $D/imc_report.log',
           f'echo "reports: $D/code_cov.txt $D/waivers_applied.txt $D/func_cov.txt;  GUI: imc -load $D/cov_work/scope/all"']
    p = os.path.join(R, f"flow/cov/{blk}_cadence.sh")
    open(p, "w").write("\n".join(sh) + "\n")
    os.chmod(p, 0o755)

    # ---------------------------------------------------------------- IMC report
    scope = SCOPE[blk]
    top = cfg.get("imc_dut", scope.split(".")[-1])
    tcl = [f"# {blk}_report.tcl -- GENERATED by tools/cov/gen_cadence_cov.py {blk}.",
           f"#     imc -exec flow/cov/{blk}_report.tcl     (after flow/cov/{blk}_cadence.sh merged the runs)",
           f"# Loads {D}/cov_work/scope/all, applies flow/cov/{blk}_exclusions.tcl (written from the",
           f"# DUT top `{top}`; mapped here onto the main bench's instance {scope}), writes three reports.",
           f"load -run {D}/cov_work/scope/all",
           f"set f [open flow/cov/{blk}_exclusions.tcl r]",
           "set n 0; set bad 0",
           "foreach line [split [read $f] \"\\n\"] {",
           "    if {[string match {exclude *} $line]} {",
           f"        set line [string map {{\"-inst {top}\" \"-inst {scope}\"}} $line]",
           "        if {[catch {eval $line} err]} { incr bad; puts \"exclusion not applied: $line -- $err\" } else { incr n }",
           "    }",
           "}",
           "close $f",
           "puts \"exclusions applied: $n, not applied: $bad\"",
           f"report -summary -inst {scope}... -metrics block:expression:toggle:fsm -out {D}/code_cov.txt",
           f"report -summary -inst {scope}... -metrics toggle -exclComments -out {D}/waivers_applied.txt",
           f"report -detail -metrics covergroup -out {D}/func_cov.txt",
           "exit"]
    open(os.path.join(R, f"flow/cov/{blk}_report.tcl"), "w").write("\n".join(tcl) + "\n")

    # ---------------------------------------------------------------- NCLaunch wrapper
    ncl = [f"# {blk}_ncl.tcl -- GENERATED: run the {blk.upper()} Cadence coverage from NCLaunch",
           "#   nclaunch -nokey -directory $PWD -cdslib $PWD/cds.lib -work worklib -input flow/cov/" + blk + "_ncl.tcl",
           f"catch {{exec bash flow/cov/{blk}_cadence.sh >& {D}/ncl_run.log}} res",
           "puts $res",
           "exit"]
    open(os.path.join(R, f"flow/cov/{blk}_ncl.tcl"), "w").write("\n".join(ncl) + "\n")
    ncc = [l.replace(f"{blk}_cadence.sh >&", f"{blk}_cadence.sh --compile-only >&").replace("ncl_run.log", "ncl_compile.log")
              .replace("run the", "compile and elaborate (no licence-bound run) the") for l in ncl]
    open(os.path.join(R, f"flow/cov/{blk}_ncl_compile.tcl"), "w").write("\n".join(ncc) + "\n")
    nt = sum(len(b["tests"]) for b in benches.values())
    print(f"gen_cadence_cov {blk}: {len(benches)} bench(es), {nt} test(s), {len(mods)} design module(s)"
          + (f"; suites with no manifest: {missing}" if missing else ""))


if __name__ == "__main__":
    for b in (["core", "dsu", "dma", "ahb"] if sys.argv[1] == "all" else sys.argv[1:]):
        gen(b)
