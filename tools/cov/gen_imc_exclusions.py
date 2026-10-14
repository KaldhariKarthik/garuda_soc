#!/usr/bin/env python3
"""gen_imc_exclusions.py -- the team's IMC exclusion file from a block's waivers (H5).

    python3 tools/cov/gen_imc_exclusions.py dma      -> flow/cov/dma_exclusions.tcl

Karthik's IMC run (Xcelium coverage) is the authoritative number; the open flow's
waivers (tb/<blk>/cov/<blk>_waivers.toml) are translated into the same format as
flow/cov/clic_exclusions.tcl, one `exclude -inst <instance> -toggle sig\\[bit\\]`
per bit and instance, with the waiver's reason as the comment:
  - toggle waivers: exact (signal and bit); a module waiver is written for every
    instance of the module listed in cov.toml [imc_instances];
  - line / expression / covergroup waivers: IMC numbers blocks and expressions
    itself, so they are written as commented lines naming the source point, to be
    completed in IMC (never guessed);
  - category `tool` (a Verilator defect, TOOL-<n>): not exported, IMC measures
    the point itself.
"""
import sys, os, re, collections, tomllib
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
blk = sys.argv[1]
cfg = tomllib.load(open(os.path.join(ROOT, f"tb/{blk}/cov/cov.toml"), "rb"))
inst = dict(cfg.get("imc_instances", {}))

# Instances not listed by hand are derived from the RTL: with `imc_dut = "<module>"`
# in cov.toml, the instantiations of the design modules are parsed from the design
# files and walked from the DUT top, so every module gets its real instance paths
# (written from the DUT top module, e.g. garuda_core_top.u_mem.u_d_port_ahb_master).
# Not from Verilator's coverage hierarchy: it collapses arrays of instances into
# wildcards (u_mac*) and inlines small modules into their parent. Generate-loop
# instances are not expanded here: list those by hand in [imc_instances] (the DMA).
def _rtl_hier(design_globs, top):
    import glob as _g
    files = sorted({f for gl in design_globs for f in _g.glob(os.path.join(ROOT, gl))})
    mods = {}                                     # module -> source text
    for f in files:
        txt = re.sub(r"//[^\n]*|/\*.*?\*/", "", open(f).read(), flags=re.S)
        for m in re.finditer(r"\bmodule\s+(\w+)(.*?)\bendmodule\b", txt, re.S):
            mods[m.group(1)] = m.group(2)
    kids = {}
    for mname, body in mods.items():
        kids[mname] = [(t, i) for t, i in
                       re.findall(r"^\s*(\w+)\s*(?:#\s*\((?:[^()]|\([^()]*\))*\))?\s+(\w+)\s*\(", body, re.M)
                       if t in mods]
    paths = collections.defaultdict(list)
    def walk(m, path):
        paths[m].append(path)
        for t, i in kids.get(m, []):
            walk(t, path + "." + i)
    if top in mods:
        walk(top, top)
    return paths
if cfg.get("imc_dut"):
    for mod, ps in _rtl_hier(cfg["design"], cfg["imc_dut"]).items():
        inst.setdefault(mod, ps)

wv = tomllib.load(open(os.path.join(ROOT, cfg["waivers"]), "rb")).get("waiver", [])

def tcl_esc(s):
    return s.replace("[", "\\[").replace("]", "\\]")

def comment(s):
    return s.replace('"', "'")

out = [f"# " + "=" * 77,
       f"# {blk}_exclusions.tcl - coverage waivers for the {blk.upper()} (GENERATED, do not edit:",
       f"#     python3 tools/cov/gen_imc_exclusions.py {blk}",
       f"# from {cfg['waivers']}, whose entries carry the evidence: PROVEN",
       f"# properties, literal RTL lines; see tools/cov/cov_report.py and handbook H5).",
       f"#",
       f"# Applied in IMC after loading the merged {blk.upper()} run, e.g.",
       f"#     imc -load <cov_work>/scope/all -init flow/cov/{blk}_exclusions.tcl",
       f"# Instances are written from the DUT top ({', '.join(sorted(set(i.split('.')[0] for v in inst.values() for i in v)))});",
       f"# flow/cov/{blk}_report.tcl maps that top onto the simulation's instance path.",
       f"# Commented lines need IMC's",
       f"# block / expression / bin identifiers and are completed in IMC.",
       f"# " + "=" * 77]
skipped, n = [], 0
for w in wv:
    cat, met = w["category"], w["metric"]
    if cat == "tool":
        skipped.append(w["id"]); continue
    mod = os.path.splitext(os.path.basename(w["file"]))[0]
    if met == "toggle":
        # the match is an exact alternation of labels "sig[bit]:0->1" (gen_toggle_waivers.py)
        body = w["match"].strip("^$")
        body = body[1:-1] if body.startswith("(") and body.endswith(")") else body
        bits = collections.OrderedDict()
        for lab in body.split("|"):
            lab = re.sub(r"\\(.)", r"\1", lab)
            sig = lab.rsplit(":", 1)[0]
            bits[sig] = 1
        out.append(f"# {w['id']} ({cat}): {comment(w['evidence'])}")
        for i in inst.get(mod, [mod]):
            for sig in bits:
                out.append(f'exclude -inst {tcl_esc(i)} -toggle {tcl_esc(sig)} -comment "{comment(w["reason"])}"')
                n += 1
    else:
        out.append(f"# {w['id']} ({cat}, {met}) TO COMPLETE IN IMC: {w['file']} {w['match']}")
        out.append(f"#   reason  : {comment(w['reason'])}")
        out.append(f"#   evidence: {comment(w['evidence'])}")
        for i in inst.get(mod, [mod]) if met != "covergroup" else ["<covergroup scope>"]:
            kind = {"line": "-block <IMC block id of that line>", "expr": "-expression <IMC id>",
                    "branch": "-block <IMC block id>"}.get(met, "<covergroup bin exclusion>")
            out.append(f'# exclude -inst {tcl_esc(i)} {kind} -comment "{comment(w["reason"])}"')
if skipped:
    out.append(f"# not exported (category tool: Verilator defects, IMC measures these points): {', '.join(skipped)}")
p = os.path.join(ROOT, f"flow/cov/{blk}_exclusions.tcl")
open(p, "w").write("\n".join(out) + "\n")
print(f"{os.path.relpath(p, ROOT)}: {n} toggle exclusion(s), {len(skipped)} tool waiver(s) not exported")
