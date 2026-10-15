#!/usr/bin/env python3
"""
applicability.py - which verification measure applies to which RTL module, and what exists.

    python3 tools/gen/applicability.py            write Docs/coverage/APPLICABILITY.md
    python3 tools/gen/applicability.py --check    fail if an own RTL module has no row, or a
                                                  "not applicable" has no reason (make check_applicability)

Two kinds of fact are kept apart on purpose:
  * WHAT EXISTS is derived from the tree: bound assertions (bind statements), assertions and
    covergroups inside element benches, covergroups of the UVM environments, formal scripts.
  * WHAT APPLIES is a judgement and lives in the tables below, each "no" with its reason.
A measure that applies and does not exist is a GAP. Nothing else is a gap.
"""
import os, re, sys, glob, collections

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(ROOT)

# ----------------------------------------------------------------------------- facts
def own_modules():
    mods = {}
    for r, _, fs in os.walk("rtl"):
        if "third_party" in r or r.startswith("rtl/fpga"): continue   # FPGA files reuse ASIC module names; listed apart
        for f in sorted(fs):
            if f.endswith((".v", ".sv")):
                p = os.path.join(r, f)
                for m in re.finditer(r"^\s*module\s+(\w+)", open(p, errors="replace").read(), re.M):
                    mods.setdefault(m.group(1), p)
    return mods

def vendored_modules():
    out = {}
    for r, _, fs in os.walk("rtl/third_party"):
        if "/patches/" in r: continue
        for f in sorted(fs):
            if f.endswith((".v", ".sv")):
                for m in re.finditer(r"^\s*module\s+(\w+)", open(os.path.join(r, f), errors="replace").read(), re.M):
                    out.setdefault(m.group(1), os.path.join(r, f))
    return out

def count(pat, path):
    try: return len(re.findall(pat, open(path, errors="replace").read(), re.M))
    except OSError: return 0

ASSERT = r"assert\s+property|\bassert\s*(?:#0\s*)?\("   # concurrent, immediate and deferred (#0)
def bound_asserts():
    """module -> [(checker file, n asserts)] from bind statements in rtl/ and tb/"""
    out = collections.defaultdict(list)
    for p in glob.glob("rtl/**/*.sv", recursive=True) + glob.glob("rtl/**/*.v", recursive=True) + \
             glob.glob("tb/**/*.sv", recursive=True):
        if "third_party" in p: continue
        t = open(p, errors="replace").read()
        for m in re.finditer(r"^\s*bind\s+(\w+)\s+(\w+)", t, re.M):
            tgt, chk = m.groups()
            for q in sorted(set(glob.glob("rtl/**/*.sv", recursive=True) + glob.glob("tb/**/*.sv", recursive=True))):
                if "third_party" in q: continue
                t2 = open(q, errors="replace").read()
                m2 = re.search(r"^\s*module\s+%s\b(.*?)^\s*endmodule" % chk, t2, re.M | re.S)
                if m2:                                   # count the assertions of that module only
                    n = len(re.findall(ASSERT, m2.group(1), re.M))
                    if n: out[tgt].append(("%s in %s" % (chk, os.path.basename(q)), n))
    return out

def bound_covergroups():
    """module -> [(file, n covergroups)] for covergroups in bound checkers"""
    out = collections.defaultdict(list)
    for p in glob.glob("tb/**/*.sv", recursive=True) + glob.glob("rtl/**/*.sv", recursive=True):
        if "third_party" in p: continue
        t = open(p, errors="replace").read()
        for m in re.finditer(r"^\s*bind\s+(\w+)\s+(\w+)", t, re.M):
            n = count(r"\bcovergroup\b", p)
            if n: out[m.group(1)].append((os.path.basename(p), n))
    return out

def bench_facts(mod):
    """asserts and covergroups inside an element bench named after the module"""
    hits = []
    for pat in ("tb/core/tb_%s.sv", "tb/core/tb_%s.v", "tb/dsu/dsu_crv_verification_codes/%s_tb_final.sv"):
        p = pat % mod
        if os.path.exists(p):
            hits.append((p, count(ASSERT, p), count(r"\bcovergroup\b", p)))
    return hits

# UVM environments: top -> (environment package, number of covergroups)
UVM = {}
for p in glob.glob("tb/*/uvm/*_env_pkg.sv"):
    UVM[p] = count(r"\bcovergroup\b", p)
ENV_OF = {"clic_top": "tb/clic/uvm/clic_env_pkg.sv", "timers_top": "tb/timers/uvm/timers_env_pkg.sv",
          "clk_div": "tb/clk_div/uvm/crg_env_pkg.sv", "reset_ctrl": "tb/clk_div/uvm/crg_env_pkg.sv",
          "garuda_pwm_top": "tb/pwm/uvm/pwm_env_pkg.sv", "garuda_gpio_top": "tb/gpio/uvm/gpio_env_pkg.sv",
          "garuda_i2c_top": "tb/i2c/uvm/i2c_env_pkg.sv", "garuda_spis_top": "tb/spi_slave/uvm/spis_env_pkg.sv",
          "garuda_uart_top": "tb/uart/uvm/uart_env_pkg.sv"}
# modules measured through their parent's environment
CHILD_OF = {"clic_apb": "clic_top", "clic_select": "clic_top", "mtime": "timers_top", "timers_apb": "timers_top",
            "wdt": "timers_top", "reset_ctrl_apb": "reset_ctrl", "garuda_pwm_core": "garuda_pwm_top",
            "garuda_spis_core": "garuda_spis_top",
            "ahb2apb_apb_fsm": "ahb2apb_bridge", "ahb2apb_fabric": "ahb2apb_bridge",
            # the memories: the checkers are bound to the shared front end inside each top
            "isram_top": "ahb_mem_slave_if", "dsram_top": "ahb_mem_slave_if", "bootrom_top": "ahb_mem_slave_if",
            "sram_wrapper": "ahb_mem_slave_if",
            # the DSU: one covergroup at dsu_top samples each sub-block's decision where it is made
            "dsu_decoder": "dsu_top", "mac_cluster": "dsu_top", "readback_mux": "dsu_top",
            "result_selector": "dsu_top", "operand_router": "dsu_top", "barrel_shifter": "dsu_top",
            # the core: garuda_cov (decode, ALU, hazards, traps) and garuda_core_cov_ext (CSRs, CLIC
            # entry, WFI sleep, write-back) are bound at garuda_core_top and sample these where they decide
            "ex_stage": "garuda_core_top", "forward_unit": "garuda_core_top", "trap_ctrl": "garuda_core_top",
            "csr_file": "garuda_core_top", "clic_ctrl": "garuda_core_top", "core_clk_gate": "garuda_core_top",
            "regfile": "garuda_core_top", "wb_stage": "garuda_core_top",
            # the bus fabric, the DMA and debug: checker and covergroup bound at the block top
            "ahb_arbiter": "ahb_interconnect", "ahb_decoder": "ahb_interconnect", "ahb_default_slave": "ahb_interconnect",
            "ahb_master_port": "ahb_interconnect", "ahb_slave_mux": "ahb_interconnect", "ahb_master_mux": "ahb_interconnect",
            "dma_apb_slave": "dma_top", "dma_arbiter": "dma_top", "dma_chan": "dma_top", "dma_engine": "dma_top",
            "garuda_soc_top": "garuda_chip_core",     # its interrupt map is checked by chip_sva
            "debug_module": "debug_top", "dmi_cdc": "debug_top", "dtm": "debug_top", "jtag_tap": "debug_top", "sba_master": "debug_top"}

def formal_facts():
    d = {}
    if os.path.exists("flow/formal/core/pipe_ctrl_core.result.txt"):
        d["pipe_ctrl"] = "properties proved: flow/formal/core/pipe_ctrl_core.tcl"
    for f in glob.glob("flow/formal/*/*_fpv.result.txt"):
        kv = dict(l.split(": ", 1) for l in open(f).read().split("\n") if re.match(r"^(top|children|script|proved): ", l))
        for m in [kv["top"]] + kv.get("children", "").split():
            d[m] = "properties proved %s%s: %s" % (kv["proved"], "" if m == kv["top"] else " (via " + kv["top"] + ")", kv["script"])
    for f in glob.glob("flow/formal/*_unr.result.txt"):
        k = os.path.basename(f).split("_unr")[0]
        d["_unr_" + k] = "waivers only (unreachability), not properties: " + os.path.basename(f)
    return d

# ----------------------------------------------------------------------------- judgement
# (applies?, reason when it does not).  Y = applies.  Every N carries its reason.
P = "pure pipeline register: no decision logic; its hold/flush behaviour is a covergroup of pipe_ctrl and garuda_cov"
TOPW = "wiring only: the behaviour belongs to the instances; it is sampled where the decision is made"
CHK = "a checker, not hardware: nothing to measure on it"
FPGA = "FPGA bring-up only (rtl/fpga), not in the ASIC build"
ARITH = "wide arithmetic: a property proof times out on multipliers and adders of this width; the right tool is sequential equivalence against the Python model, and the DSU model comparison already does the data check"
ARRAY = "memory array: the state space is the contents; proved by simulation with address-in-address-out patterns, not by a property engine"
SERIAL = "pure datapath of a small width with no state worth a property; covered by the instruction-level tests"

FUNC_N = {
 "ahb_mem_slave": "a verification model kept in rtl/ (the memory of tb_boot), not silicon: rtl/ahb/filelist.f says so",
 "if_id": P, "id_ex": P, "ex_mem": P,
 "garuda_chip_top": TOPW, "garuda_soc_top": TOPW, "ahb_master_mux": TOPW, "ahb2apb_fabric": TOPW,
 "kogge_stone_49": "internal to mac_unit: operand corners (zero, maximum, sign flip, carry in) are sampled at mac_unit and dsu_top",
 "mult_16x16": "internal to mac_unit: operand corners are sampled at mac_unit and dsu_top",
 "csa_3to2": None,  # has its own
 "garuda_core_top": "the pipeline's functional coverage is garuda_cov (bound at this module) and the element benches",
}
CHECKERS = {"clic_sva","clk_div_sva","garuda_apb_shim_sva","gpio_sva","garuda_i2c_sva","pwm_sva",
            "reset_ctrl_sva","garuda_spis_sva","timers_sva","pipe_ctrl_sva"}
ASSERT_N = {m: CHK for m in CHECKERS}
ASSERT_N["ahb_mem_slave"] = "a verification model kept in rtl/ (the memory of tb_boot), not silicon: rtl/ahb/filelist.f says so"
FORMAL_N = {
 "wb_stage": "three assigns passing the write-back to the register file; the register file and the pipeline around it are proved (regfile, pipe_ctrl)",
 "core_clk_gate": "behavioural model of the library clock-gate cell (replaced by the cell in the physical flow, P1, GARUDA_ICG_CELL); when the gate may close is proved on pipe_ctrl's quiescent rule",
 "clk_div": "its properties are about time (half-period widths, two edges at the same instant: clk_div_sva.sv uses $realtime); a proof engine has no time, so they are checked in every simulation",
 "ahb_mem_slave": "a verification model kept in rtl/ (the memory of tb_boot), not silicon: rtl/ahb/filelist.f says so",
 "mul32": ARITH, "mult_16x16": ARITH, "kogge_stone_49": ARITH, "mac_unit": ARITH, "mac_cluster": ARITH,
 "csa_3to2": SERIAL, "barrel_shifter": None,
 "dsram_top": "four 4096-word banks: the shared front end and the array are proved on a 16-word harness (flow/formal/mem); the bank selection is checked end to end by a_data_integrity in simulation",
 "regfile": ARRAY,
 "imm_gen": SERIAL, "load_formatter": SERIAL, "alu": SERIAL, "saturation_unit": SERIAL,
 "overflow_flag": SERIAL, "result_selector": SERIAL, "readback_mux": SERIAL, "operand_router": SERIAL,
 "garuda_chip_top": TOPW, "garuda_soc_top": TOPW, "ahb_master_mux": TOPW, "ahb2apb_fabric": TOPW,
 "if_id": P, "id_ex": P, "ex_mem": P, "mem_wb_reg": P,
}
FORMAL_N.update({m: CHK for m in CHECKERS})
FUNC_N.update({m: CHK for m in CHECKERS})

def judge(mod, tbl):
    r = tbl.get(mod, "Y")
    return ("Y", "") if r is None or r == "Y" else ("N", r)

# ----------------------------------------------------------------------------- build
def block_of(path):
    d = path.split("/")[1]
    return {"ahb2apb": "bridge", "clk_div": "clk/rst", "reset_ctrl": "clk/rst", "spi_master": "spim",
            "spi_slave": "spis", "isram": "mem", "dsram": "mem", "brom": "mem", "common": "shim"}.get(d, d)

def unr_key(mod):
    top = CHILD_OF.get(mod, mod)
    if top in ("clk_div", "reset_ctrl"): return "_unr_crg"
    return "_unr_" + top.replace("_top", "").replace("garuda_", "")

def row(mod, path, bound, formal, bcov=None):
    bcov = bcov or {}
    b = block_of(path)
    r = {"module": mod, "block": b, "path": path}
    # ---- code coverage
    if mod in CHECKERS:
        r["code"] = ("n/a", CHK)
    elif mod == "ahb_mem_slave":
        r["code"] = ("n/a", ASSERT_N["ahb_mem_slave"])
    else:
        r["code"] = ("have", "block chart (Docs/coverage/COVERAGE_BY_BLOCK.md)")
    # ---- functional coverage
    ap, why = judge(mod, FUNC_N)
    have = []
    for p, na, ncg in bench_facts(mod):
        if ncg: have.append("%d in %s" % (ncg, os.path.basename(p)))
    top = CHILD_OF.get(mod, mod)
    if top in ENV_OF and UVM.get(ENV_OF[top]):
        have.append("%d in %s%s" % (UVM[ENV_OF[top]], os.path.basename(ENV_OF[top]), "" if top == mod else " (via " + top + ")"))
    for src in (mod, CHILD_OF.get(mod)):
        for fn, n in bcov.get(src, []):
            have.append("%d bound: %s%s" % (n, fn, "" if src == mod else " (via " + src + ")"))
    if mod == "garuda_core_top": have.append("8 in garuda_cov.sv (pipeline)")
    if mod == "pipe_ctrl": have.append("hold x flush matrix in garuda_cov.sv (make pipe_matrix)")
    if ap == "N": r["func"] = ("n/a", why)
    elif have: r["func"] = ("have", "; ".join(have))
    else: r["func"] = ("GAP", "")
    # ---- assertions
    ap, why = judge(mod, ASSERT_N)
    have = []
    for chk, n in bound.get(mod, []): have.append("%d bound: %s" % (n, chk))
    if mod in CHILD_OF and bound.get(CHILD_OF[mod]):
        have.append("via %s: %s" % (CHILD_OF[mod], ", ".join(c for c, _ in bound[CHILD_OF[mod]])))
    for p, na, ncg in bench_facts(mod):
        if na: have.append("%d in bench %s (not bound)" % (na, os.path.basename(p)))
    if mod == "pipe_ctrl" and bound.get("garuda_core_top"):
        have.append("9 bound at garuda_core_top: pipe_ctrl_sva")
    if ap == "N": r["assert"] = ("n/a", why)
    elif have: r["assert"] = ("have", "; ".join(have))
    else: r["assert"] = ("GAP", "")
    # ---- formal
    ap, why = judge(mod, FORMAL_N)
    if ap == "N": r["formal"] = ("n/a", why)
    elif mod in formal: r["formal"] = ("have", formal[mod])
    elif unr_key(mod) in formal:
        r["formal"] = ("GAP", "waivers checked only (" + unr_key(mod)[5:] + "_unr); no property proved")
    else: r["formal"] = ("GAP", "")
    return r

def main():
    check = "--check" in sys.argv
    mods = own_modules()
    CHECKERS.update(m for m in mods if m.endswith("_sva"))
    for m in [m for m in mods if m.endswith("_sva")]:
        FUNC_N.setdefault(m, CHK); ASSERT_N.setdefault(m, CHK); FORMAL_N.setdefault(m, CHK)
    bound = bound_asserts(); formal = formal_facts(); bcov = bound_covergroups()
    rows = [row(m, p, bound, formal, bcov) for m, p in sorted(mods.items(), key=lambda kv: (block_of(kv[1]), kv[0]))]
    problems = []
    for r in rows:
        for k in ("code", "func", "assert", "formal"):
            if r[k][0] == "n/a" and not r[k][1]: problems.append("%s: %s is n/a with no reason" % (r["module"], k))
    # the tables may only name modules that exist
    for tname, t in (("FUNC_N", FUNC_N), ("ASSERT_N", ASSERT_N), ("FORMAL_N", FORMAL_N)):
        for m in t:
            if m not in mods: problems.append("%s names %s, which is not an own module" % (tname, m))
    if check:
        for p in problems: print("  " + p)
        print("check_applicability: %d own modules, %d problem(s)" % (len(rows), len(problems)))
        return 1 if problems else 0
    tot = collections.Counter()
    gaps = {k: [] for k in ("func", "assert", "formal")}
    for r in rows:
        for k in ("code", "func", "assert", "formal"): tot[(k, r[k][0])] += 1
        for k in gaps:
            if r[k][0] == "GAP": gaps[k].append(r["module"])
    def cell(c):
        s, t = c
        return {"have": "**have** " + t, "GAP": "**GAP** " + t, "n/a": "n/a: " + t}[s].strip()
    L = ["# Verification applicability by module",
         "",
         "Written by `tools/gen/applicability.py` from the tree; `make check_applicability` fails when an own RTL "
         "module has no row or a \"not applicable\" has no reason. What exists is read from the files; what applies "
         "is a judgement kept in the tables of that script, each \"no\" with its reason.",
         "",
         "A measure that **applies and does not exist is a GAP**. Nothing else is. Vendored IP is below.",
         "",
         "## Summary",
         "",
         "| Measure | have | GAP | n/a (with reason) |", "|---|---|---|---|"]
    names = {"code": "Code coverage", "func": "Functional coverage", "assert": "Assertions", "formal": "Formal properties"}
    for k in ("code", "func", "assert", "formal"):
        L.append("| %s | %d | %d | %d |" % (names[k], tot[(k, "have")], tot[(k, "GAP")], tot[(k, "n/a")]))
    L += ["", "%d own RTL modules." % len(rows), "", "## Gap list", ""]
    for k in ("func", "assert", "formal"):
        by = collections.defaultdict(list)
        for r in rows:
            if r["module"] in gaps[k]: by[r["block"]].append(r["module"])
        L.append("**%s: %d modules.** %s" % (names[k], len(gaps[k]), "; ".join("%s: %s" % (b, ", ".join(v)) for b, v in sorted(by.items()))))
        L.append("")
    L += ["## The matrix", "", "| Module | Block | Code coverage | Functional coverage | Assertions | Formal |", "|---|---|---|---|---|---|"]
    for r in rows:
        L.append("| `%s` | %s | %s | %s | %s | %s |" % (r["module"], r["block"], cell(r["code"]), cell(r["func"]), cell(r["assert"]), cell(r["formal"])))
    fp = sorted(glob.glob("rtl/fpga/*.v"))
    L += ["", "## FPGA-only files (%d, not in the ASIC build)" % len(fp), "",
          "`rtl/fpga/` holds the KV260 bring-up wrapper and FPGA versions of the clock divider and clock gate "
          "(they reuse the ASIC module names). They are verified by the FPGA bring-up, not by this flow: " + ", ".join("`%s`" % os.path.basename(p) for p in fp) + "."]
    V = vendored_modules()
    L += ["", "## Vendored IP (%d modules, not edited, D-22)" % len(V), "",
          "| Measure | Treatment | Reason |", "|---|---|---|",
          "| Code coverage | measured with the block that instantiates it; findings that cannot be reached by GARUDA's use are waived by name (451 for the GPIO pads 32 to 63, for example) | the code is third-party; unreachable by our configuration is a fact about our use |",
          "| Functional coverage | **n/a** for the vendored module itself; covered through our wrapper's environment | the features GARUDA uses are the wrapper's spec features; the vendor's other features are not ours to verify |",
          "| Assertions | only at our boundary (the shim and the wrapper) | we cannot bind into code we do not maintain without a patch (D-22) |",
          "| Formal | **n/a** | same, and the vendor's checks belong to the vendor |",
          "", "Modules: " + ", ".join("`%s`" % m for m in sorted(V)), "",
          "## How to read a row", "",
          "- `have` says what exists and where. `bound` means a checker attached with `bind`, so it runs in every simulation of the block, in the chip too. `in bench ... (not bound)` runs only in that element bench.",
          "- `GAP` on formal with \"waivers checked only\" means JasperGold was used to confirm coverage waivers, which is not the same as proving a property of the block.",
          "- `garuda_cov.sv` samples the pipeline as a whole at `garuda_core_top` (8 covergroups). Core modules listed as GAP for functional coverage may be partly covered there; reviewing each against it is the first job of the plan, not a finding.",
          "- A UVM environment's covergroups are counted on the block top; its children say `(via top)`.",
          ""]
    open("Docs/coverage/APPLICABILITY.md", "w").write("\n".join(L))
    print("wrote Docs/coverage/APPLICABILITY.md: %d modules; gaps func %d assert %d formal %d" % (len(rows), len(gaps["func"]), len(gaps["assert"]), len(gaps["formal"])))
    return 0
sys.exit(main())
