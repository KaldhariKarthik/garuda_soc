#!/usr/bin/env python3
"""
cov_chart.py - the per-block coverage chart, made from IMC's own reports.

    python3 tools/gen/cov_chart.py collect     merge the databases, write IMC's reports
    python3 tools/gen/cov_chart.py report      read the reports, write Docs/coverage/

No number in the output is typed by hand: every figure is a "(covered/total)"
pair that IMC printed, added up over the modules of a block. `make cov_chart`
runs the simulations first and then both steps.

WHERE THE NUMBERS COME FROM
  Blocks with a UVM environment (CLIC, timers, PWM, GPIO, clock and reset):
    the block's own runs, sim/uvm_<blk>/cov_work/scope/*, merged; reported for
    the DUT instance, once as measured and once after the written waivers of
    flow/cov/<blk>_exclusions.tcl.
  Every other block:
    the 119 directed runs of flow/regress/garuda.vsif (block benches, unit and
    element benches, ISA and sanity programs, chip programs), merged with
    -initial_model union_all into sim/cov_all/merged and reported per module
    type, so a module counts what any test at any level did to it. No waiver
    is applied: these blocks have none written yet.

Coverage is collected with irun 15.2 because IMC here is 15.2 (Docs/COVERAGE.md).
"""
import os
import re
import subprocess
import sys
import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ALL = "sim/cov_all"
OUT = "Docs/coverage"
IMC_PATH = "/home/install/INCISIVE152/tools/bin:/home/install/INCISIVE152/bin"

# ----------------------------------------------------------------------------
# The sixteen blocks of the verification plans, in the order of the block list.
# modules: design modules (vendored ones included), sva: property modules and
# bench interfaces that carry the block's assertions.
# uvm: (directory under sim/, DUT instances, waiver file) when the block has a
# UVM environment.
# ----------------------------------------------------------------------------
BLOCKS = [
    dict(key="CORE", name="RV32IM core", plan="tb/core/GARUDA_CORE_vplan.csv", track="A",
         modules="alu branch_predict branch_unit clic_ctrl core_clk_gate csr_file csr_rw decode_control "
                 "d_port_ahb_master ex_mem ex_stage forward_unit garuda_core_top garuda_if_stage_top "
                 "garuda_iport_ahb_master garuda_pc_gen garuda_prefetch_buffer hazard_forward_unit id_ex "
                 "id_stage if_id imm_gen load_formatter load_store_unit mem_stage mem_wb_reg mul32 pipe_ctrl "
                 "regfile trap_ctrl wb_stage",
         sva="pipe_ctrl_sva alu_if branch_if csr_rw_if decode_if dport_if hazard_if id_stage_if if_top_if "
             "imm_gen_if iport_if load_fmt_if lsu_if mem_stage_if memwb_if mul32_if pc_gen_if pfb_if regfile_if",
         cg_types="garuda_cov garuda_core_cov_ext"),
    dict(key="DSU", name="DSU", plan="tb/dsu/GARUDA_DSU_vplan.csv", track="A",
         modules="barrel_shifter csa_3to2 dsu_decoder dsu_stall dsu_top kogge_stone_49 mac_cluster mac_unit "
                 "mult_16x16 operand_router overflow_flag readback_mux result_selector saturation_unit",
         cg_types="dsu_cov"),
    dict(key="AHB", name="AHB interconnect", plan="tb/ahb/GARUDA_AHB_vplan.csv", track="A",
         modules="ahb_arbiter ahb_decoder ahb_default_slave ahb_interconnect ahb_master_mux ahb_master_port "
                 "ahb_slave_mux", sva="ahb_interconnect_sva", cg_types="ahb_interconnect_cov"),
    dict(key="AHB2APB", name="AHB to APB bridge", plan="tb/ahb2apb/GARUDA_AHB2APB_vplan.csv", track="A",
         modules="ahb2apb_apb_fsm ahb2apb_bridge ahb2apb_fabric", sva="ahb2apb_bridge_sva",
         cg_types="ahb2apb_bridge_cov"),
    dict(key="MEM", name="Memories", plan="tb/mem/GARUDA_MEM_vplan.csv", track="A",
         modules="ahb_mem_slave_if sram_wrapper isram_top dsram_top bootrom_top", sva="mem_sva",
         cg_types="mem_cov"),
    dict(key="DMA", name="DMA", plan="tb/dma/GARUDA_DMA_vplan.csv", track="A",
         modules="dma_apb_slave dma_arbiter dma_chan dma_engine dma_top", sva="dma_top_sva dma_chan_sva",
         cg_types="dma_cov"),
    dict(key="DEBUG", name="Debug", plan="tb/debug/GARUDA_DEBUG_vplan.csv", track="A",
         modules="debug_module debug_top dmi_cdc dtm jtag_tap sba_master", sva="debug_sva",
         cg_types="debug_cov"),
    dict(key="CLIC", name="CLIC", plan="tb/clic/GARUDA_CLIC_vplan.csv", track="B",
         modules="clic_apb clic_select clic_top", sva="clic_sva",
         uvm=("uvm_clic", ["clic_top"], "flow/cov/clic_exclusions.tcl")),
    dict(key="TIMERS", name="Timers and watchdog", plan="tb/timers/GARUDA_TIMERS_vplan.csv", track="B",
         modules="mtime timers_apb timers_top wdt", sva="timers_sva",
         uvm=("uvm_timers", ["timers_top"], "flow/cov/timers_exclusions.tcl")),
    dict(key="CLKRST", name="Clock divider and reset", plan="tb/clk_div/GARUDA_CLKRST_vplan.csv", track="B",
         modules="clk_div reset_ctrl reset_ctrl_apb", sva="clk_div_sva reset_ctrl_sva",
         uvm=("uvm_crg", ["clk_div", "reset_ctrl"], "flow/cov/crg_exclusions.tcl")),
    dict(key="PWM", name="PWM", plan="tb/pwm/GARUDA_PWM_vplan.csv", track="B",
         modules="garuda_pwm_core garuda_pwm_top", sva="pwm_sva",
         uvm=("uvm_pwm", ["garuda_pwm_top"], "flow/cov/pwm_exclusions.tcl")),
    dict(key="GPIO", name="GPIO", plan="tb/gpio/GARUDA_GPIO_vplan.csv", track="B",
         modules="garuda_gpio_top apb_gpio", sva="gpio_sva",
         uvm=("uvm_gpio", ["garuda_gpio_top"], "flow/cov/gpio_exclusions.tcl")),
    dict(key="UART", name="UART", plan="tb/uart/GARUDA_UART_vplan.csv", track="B",
         modules="garuda_uart_top apb_uart_sv uart_rx uart_tx uart_interrupt io_generic_fifo", sva="garuda_uart_sva",
         uvm=("uvm_uart", ["tb_uart_uvm.g_uart*.dut"], "flow/cov/uart_exclusions.tcl")),   # three instances: selected by path
    dict(key="I2C", name="I2C", plan="tb/i2c/GARUDA_I2C_vplan.csv", track="B",
         modules="garuda_i2c_top i2c_master_byte_ctrl i2c_master_bit_ctrl", sva="garuda_i2c_sva",
         uvm=("uvm_i2c", ["garuda_i2c_top"], "flow/cov/i2c_exclusions.tcl")),
    dict(key="SPIM", name="SPI master", plan="tb/spi_master/GARUDA_SPIM_vplan.csv", track="B",
         modules="garuda_spim_top apb_spi_master spi_master_apb_if spi_master_clkgen spi_master_controller "
                 "spi_master_fifo spi_master_rx spi_master_tx", sva="garuda_spim_sva", cg_types="spim_cov"),
    dict(key="SPIS", name="SPI slave", plan="tb/spi_slave/GARUDA_SPIS_vplan.csv", track="B",
         modules="garuda_spis_core garuda_spis_top", sva="garuda_spis_sva",
         uvm=("uvm_spis", ["garuda_spis_top"], "flow/cov/spis_exclusions.tcl")),
]
# not one of the sixteen, shown below them
EXTRA = [
    dict(key="SHIM", name="APB shim (shared by six peripherals)", plan="", track="B",
         modules="garuda_apb_shim", sva="garuda_apb_shim_sva", cg_types="garuda_apb_shim_cov"),
    dict(key="TOP", name="Chip and SoC top (wiring)", plan="", track="B",
         modules="garuda_chip_top garuda_chip_core garuda_soc_top", cg_types="chip_cov"),
]
METRICS = ["Block", "Expression", "Toggle", "Fsm", "Assertion"]


def sh(cmd):
    return subprocess.run(cmd, shell=True, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          universal_newlines=True)


def imc(tcl_path):
    env = "export PATH=%s:$PATH; . scripts/setup_env.sh > /dev/null; " % IMC_PATH
    r = sh(env + "imc -exec %s" % tcl_path)
    log = tcl_path.replace(".tcl", ".log")
    with open(os.path.join(ROOT, log), "w") as fh:
        fh.write(r.stdout)
    errs = [l for l in r.stdout.splitlines() if "*E," in l or "*F," in l]
    if r.returncode != 0 or errs:
        sys.stderr.write("IMC failed on %s (exit %d):\n%s\n" % (tcl_path, r.returncode, "\n".join(errs[:8])))
        sys.exit(1)
    return r.stdout


# ============================================================================ collect
def collect():
    os.makedirs(os.path.join(ROOT, ALL), exist_ok=True)
    runs = sorted(d for d in sh("ls -d sim/run_test/*/cov_work/garuda/*/").stdout.split() if os.path.isdir(os.path.join(ROOT, d)))
    passed = []
    for d in runs:
        t = d.rstrip("/").split("/")[-1]
        out = os.path.join(ROOT, "sim/run_test/%s.out" % t)
        if os.path.exists(out) and "GARUDA_RESULT: PASS" in open(out, errors="replace").read():
            passed.append(d)
    if not passed:
        sys.exit("no passing coverage run under sim/run_test - run `make cov_runs` first")
    if len(passed) != len(runs):
        print("cov_chart: %d of %d runs passed; only those are merged" % (len(passed), len(runs)))
    with open(os.path.join(ROOT, ALL, "runs.txt"), "w") as fh:
        fh.write("\n".join(passed) + "\n")

    tcl = ["merge -runfile %s/runs.txt -out %s/merged -overwrite -initial_model union_all -message 1" % (ALL, ALL),
           "load -run %s/merged" % ALL,
           "report -summary -type -metrics block:expression:toggle:fsm:assertion:covergroup -out %s/type_summary.txt" % ALL,
           "report -detail -type * -metrics assertion -out %s/assert_never.txt" % ALL,
           "report -detail -type garuda_cov -metrics covergroup -out %s/cg_core_holes.txt" % ALL,
           ] + ["report -detail -type %s -metrics covergroup -out %s/cg_holes_%s.txt" % (t, ALL, t)
                for b in BLOCKS + EXTRA for t in b.get("cg_types", "").split()] + [
           "exit"]
    open(os.path.join(ROOT, ALL, "merge.tcl"), "w").write("\n".join(tcl) + "\n")
    out = imc("%s/merge.tcl" % ALL)
    lost = [l for l in out.splitlines() if "WEMIN1" in l]
    if lost:
        sys.stderr.write("cov_chart: IMC did not merge %d instance(s): the merged figures would be too low.\n%s\n"
                         % (len(lost), "\n".join(lost[:5])))
        sys.exit(1)

    # covergroups of the unit and element benches live in each bench's own module
    # tb_top and in classes; twenty different tb_top do not merge by type, and
    # the groups of one bench are not those of another, so they are read from
    # each run and added up
    tcl = []
    for d in passed:
        t = d.rstrip("/").split("/")[-1]
        if t.startswith("unit_"):
            tcl += ["load -run %s" % d,
                    "report -summary -type -metrics covergroup -out %s/cg_%s.txt" % (ALL, t)]
    tcl.append("exit")
    open(os.path.join(ROOT, ALL, "cg_units.tcl"), "w").write("\n".join(tcl) + "\n")
    imc("%s/cg_units.tcl" % ALL)

    for b in BLOCKS:
        if "uvm" not in b:
            continue
        d, insts, waivers = b["uvm"]
        scopes = sorted(s for s in sh("ls -d sim/%s/cov_work/scope/*/" % d).stdout.split()
                        if not s.rstrip("/").endswith("/all"))
        okscopes = []
        for s in scopes:
            t = s.rstrip("/").split("/")[-1]
            log = os.path.join(ROOT, "sim/%s/%s.log" % (d, t))
            if os.path.exists(log) and "RESULT: PASSED" in open(log, errors="replace").read():
                okscopes.append(s)
        if not okscopes:
            sys.exit("no passing UVM run under sim/%s - run `make %s` first" % (d, d))
        sel = " ".join(i + "..." for i in insts)
        tcl = ["merge %s -out sim/%s/cov_work/scope/all -overwrite -initial_model union_all" % (" ".join(okscopes), d),
               "load -run sim/%s/cov_work/scope/all" % d,
               "report -summary -inst %s -metrics block:expression:toggle:fsm:assertion -out sim/%s/code_raw.txt" % (sel, d),
               "source %s" % waivers,
               "report -summary -inst %s -metrics block:expression:toggle:fsm:assertion -out sim/%s/code_cov.txt" % (sel, d),
               "report -summary -inst uvm_pkg... -metrics covergroup -out sim/%s/func_sum.txt" % d,
               "report -detail -inst uvm_pkg... -metrics covergroup -out sim/%s/func_holes.txt" % d,
               "report -detail -inst %s -metrics assertion -out sim/%s/assert_never.txt" % (sel, d),
               "report -detail -inst %s -metrics block:expression:toggle:fsm -out sim/%s/holes.txt" % (sel, d),
               "exit"]
        open(os.path.join(ROOT, "sim/%s/chart.tcl" % d), "w").write("\n".join(tcl) + "\n")
        imc("sim/%s/chart.tcl" % d)
        open(os.path.join(ROOT, "sim/%s/chart_runs.txt" % d), "w").write("%d\n" % len(okscopes))
    print("cov_chart: reports written under %s and sim/uvm_*" % ALL)


# ============================================================================ parse
PAIR = re.compile(r"\((\d+)/(\d+)(?:/(\d+))?\)")


def read_summary(path):
    """IMC summary table -> {row name: {column: (covered, total, excluded)}}. Tree prefixes are removed;
    the order of rows is kept in '_order'."""
    rows, order = {}, []
    full = os.path.join(ROOT, path)
    if not os.path.exists(full):
        return rows
    lines = open(full, errors="replace").read().splitlines()
    hdr = next((i for i, l in enumerate(lines) if l.startswith("name ")), None)
    if hdr is None:
        return rows
    h = lines[hdr]
    cols = [(m.start(), m.group(0).strip()) for m in re.finditer(r"\S+(?: \S+)*", h)]
    for l in lines[hdr + 2:]:
        if not l.strip():
            continue
        name = re.sub(r"^[| ]*\|--", "", l[:cols[1][0]]).strip()
        depth = l[:cols[1][0]].count("|")
        vals = {}
        for k, (pos, cname) in enumerate(cols[1:], start=1):
            end = cols[k + 1][0] if k + 1 < len(cols) else len(l)
            m = PAIR.search(l[pos:end])
            if m:
                vals[cname] = (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0))
        key = name
        n = 2
        while key in rows:
            key = "%s#%d" % (name, n)
            n += 1
        rows[key] = vals
        rows[key]["_depth"] = depth
        order.append(key)
    rows["_order"] = order
    return rows


def col(vals, metric):
    for c in (metric, metric + " Covered"):
        if c in vals:
            return vals[c]
    return None


def add(a, b):
    if b is None:
        return a
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def pct(p):
    if p is None or p[1] == 0:
        return None
    return 100.0 * p[0] / p[1]


def fmt(p):
    if p is None or p[1] == 0:
        return "none"
    return "%.1f%% (%d/%d)" % (100.0 * p[0] / p[1], p[0], p[1])


def read_never(path):
    """Assertion detail report -> list of (scope, name, kind) with Finished == 0."""
    out = []
    full = os.path.join(ROOT, path)
    if not os.path.exists(full):
        return out
    scope = ""
    for l in open(full, errors="replace").read().splitlines():
        m = re.match(r"^(?:Type|Instance) name: (\S+)", l)
        if m:
            scope = m.group(1)
            continue
        m = re.match(r"^(\d+)\s+(\d+)\s+(\S+)\s+\d+\s+(.*)$", l)
        if m and m.group(1) == "0":
            kind = "cover" if "cover property" in m.group(4) or m.group(3).startswith("c_") else "assert"
            out.append((scope, m.group(3), kind))
    return out


def read_waivers(path):
    """exclusions file -> list of (metric, instance, item, comment)."""
    out = []
    for l in open(os.path.join(ROOT, path)).read().splitlines():
        m = re.match(r'^exclude -inst (\S+) -(\w+) ?(.*?) -comment "(.*)"\s*$', l)
        if m:
            out.append((m.group(2), m.group(1), m.group(3).replace("\\", ""), m.group(4)))
    return out


def plan_counts(path):
    full = os.path.join(ROOT, path)
    if not path or not os.path.exists(full):
        return (0, 0)
    import csv
    feats = items = 0
    for r in csv.DictReader(open(full, newline="")):
        if r.get("NODE_KIND") == "SECTION" and re.match(r"^F\d+", r.get("NAME", "")):
            feats += 1
        elif r.get("NODE_KIND") in ("CHK", "COV", "TC"):
            items += 1
    return (feats, items)


def gather():
    ts = read_summary("%s/type_summary.txt" % ALL)
    if not ts:
        sys.exit("no %s/type_summary.txt - run `cov_chart.py collect` first" % ALL)
    never_all = read_never("%s/assert_never.txt" % ALL)
    data = []
    for b in BLOCKS + EXTRA:
        d = dict(b)
        mods = b["modules"].split()
        svas = b.get("sva", "").split()
        d["missing"] = [m for m in mods if not any(k == m or k.startswith(m + "_g_") or k.startswith(m + "#") for k in ts if k != "_order")]

        def rows_of(names):
            for k in ts["_order"]:
                base = k.split("#")[0]
                for n in names:
                    if base == n or base.startswith(n + "_g_"):
                        yield k, ts[k]

        merged = {m: (0, 0, 0) for m in METRICS}
        permod = []
        for k, v in rows_of(mods):
            for m in ("Block", "Expression", "Toggle", "Fsm"):
                merged[m] = add(merged[m], col(v, m))
            permod.append((k, {m: col(v, m) for m in ("Block", "Expression", "Toggle", "Fsm")}))
        for k, v in rows_of(svas):
            merged["Assertion"] = add(merged["Assertion"], col(v, "Assertion"))
        d["merged"] = merged
        d["permod"] = permod
        d["never"] = [(s, n, kd) for (s, n, kd) in never_all if s.split(".")[0] in svas]
        d["source"] = "all directed tests, merged"
        d["waivers"] = []
        d["func"] = None

        if b.get("cg_types") and b["key"] != "CORE":
            parts = [(t, col(ts.get(t, {}), "CoverGroup")) for t in b["cg_types"].split()]
            tot = (0, 0, 0)
            for _, p in parts:
                tot = add(tot, p)
            if tot[1]:
                d["func"] = tot
                d["func_parts"] = parts

        if b["key"] == "CORE":
            parts = [("%s (tb_boot: ISA and sanity programs; chip programs)" % t, col(ts.get(t, {}), "CoverGroup"))
                     for t in b["cg_types"].split()]
            for fn in sorted(os.listdir(os.path.join(ROOT, ALL))):
                if fn.startswith("cg_unit_") and fn.endswith(".txt"):
                    r = read_summary("%s/%s" % (ALL, fn))
                    s = (0, 0, 0)
                    for k in r.get("_order", []):
                        s = add(s, col(r[k], "CoverGroup"))
                    if s[1]:
                        parts.append((fn[3:-4], s))
            tot = (0, 0, 0)
            for _, p in parts:
                tot = add(tot, p)
            d["func"] = tot
            d["func_parts"] = parts

        if "uvm" in b:
            dirn, insts, wfile = b["uvm"]
            raw = read_summary("sim/%s/code_raw.txt" % dirn)
            cov = read_summary("sim/%s/code_cov.txt" % dirn)
            if raw and cov:
                r = {m: (0, 0, 0) for m in METRICS}
                w = {m: (0, 0, 0) for m in METRICS}
                # code coverage is counted on the design instances; a bound
                # property module is bench code, and gives the assertion count
                for src, acc in ((raw, r), (cov, w)):
                    sva_depth = None
                    for k in src["_order"]:
                        dep = src[k]["_depth"]
                        if sva_depth is not None and dep <= sva_depth:
                            sva_depth = None
                        if sva_depth is None and k.split("#")[0].endswith("_sva"):
                            sva_depth = dep
                        if sva_depth is None:
                            for m in ("Block", "Expression", "Toggle", "Fsm"):
                                acc[m] = add(acc[m], col(src[k], m))
                        else:
                            acc["Assertion"] = add(acc["Assertion"], col(src[k], "Assertion"))
                d["raw"] = r
                d["waived"] = w
                d["source"] = "the block's UVM environment"
                fs = read_summary("sim/%s/func_sum.txt" % dirn)
                f = (0, 0, 0)
                for k in fs.get("_order", []):
                    f = add(f, col(fs[k], "CoverGroup"))
                d["func"] = f
                d["never_uvm"] = read_never("sim/%s/assert_never.txt" % dirn)
                rf = os.path.join(ROOT, "sim/%s/chart_runs.txt" % dirn)
                d["uvm_runs"] = int(open(rf).read()) if os.path.exists(rf) else 0
            d["waivers"] = read_waivers(wfile)
            d["waiver_file"] = wfile
        d["plan_counts"] = plan_counts(b.get("plan", ""))
        data.append(d)
    return data


# ============================================================================ chart (SVG)
INK, MUTED, GRID, SURF = "#0b0b0b", "#52514e", "#dddcd6", "#fcfcfb"
BAR, BARW = "#2a78d6", "#9cc0ee"        # measured; the part added by written waivers (same hue, lighter)


def shown(d, m):
    """what the chart shows for a block: (measured pair, pair after waivers or None)"""
    if "waived" in d:
        return d["raw"][m], d["waived"][m]
    return d["merged"][m], None


def svg(data, path):
    cols = [("Block", "Statement (block)"), ("Expression", "Expression"), ("Toggle", "Toggle"),
            ("Fsm", "FSM"), ("FUNC", "Functional (covergroups)"), ("Assertion", "Assertions triggered")]
    left, cw, gap, rh, top = 232, 150, 18, 30, 86
    W = left + len(cols) * (cw + gap) + 10
    H = top + len(data) * rh + 64
    o = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" '
         'font-family="Helvetica, Arial, sans-serif" role="img" aria-label="GARUDA coverage by block">' % (W, H, W, H),
         '<rect width="%d" height="%d" fill="%s"/>' % (W, H, SURF),
         '<text x="16" y="28" font-size="17" font-weight="bold" fill="%s">GARUDA SoC: coverage by block</text>' % INK,
         '<text x="16" y="48" font-size="12" fill="%s">Percent covered. Dark bar: as measured. Light extension: '
         'added by written waivers (five blocks have them). Tick: 100%%.</text>' % MUTED]
    for ci, (key, title) in enumerate(cols):
        x = left + ci * (cw + gap)
        o.append('<text x="%d" y="%d" font-size="12" font-weight="bold" fill="%s">%s</text>' % (x, top - 12, INK, title))
    for ri, d in enumerate(data):
        y = top + ri * rh
        if ri == len(BLOCKS):
            o.append('<line x1="16" y1="%d" x2="%d" y2="%d" stroke="%s" stroke-width="1"/>' % (y - 3, W - 10, y - 3, GRID))
        o.append('<text x="16" y="%d" font-size="12.5" fill="%s">%s</text>' % (y + 15, INK, d["name"]))
        for ci, (key, title) in enumerate(cols):
            x = left + ci * (cw + gap)
            bw = cw - 52
            if key == "FUNC":
                meas, wv = d["func"], None
            else:
                meas, wv = shown(d, key)
            o.append('<rect x="%d" y="%d" width="%d" height="12" rx="2" fill="%s"/>' % (x, y + 5, bw, "#efeee9"))
            o.append('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="%s" stroke-width="1"/>' % (x + bw, y + 2, x + bw, y + 20, MUTED))
            p = pct(meas)
            if p is None:
                o.append('<text x="%d" y="%d" font-size="11" fill="%s">none</text>' % (x + bw + 6, y + 15, MUTED))
                continue
            pw = pct(wv) if wv else None
            if pw is not None and pw > p:
                o.append('<rect x="%d" y="%d" width="%.1f" height="12" rx="2" fill="%s"/>' % (x, y + 5, bw * pw / 100.0, BARW))
            o.append('<rect x="%d" y="%d" width="%.1f" height="12" rx="2" fill="%s"/>' % (x, y + 5, max(bw * p / 100.0, 1.5), BAR))
            lab = "%.0f" % (pw if pw is not None else p)
            if pw is not None and abs(pw - p) >= 0.05:
                lab = "%.0f→%.0f" % (p, pw)
            o.append('<text x="%d" y="%d" font-size="11" fill="%s">%s</text>' % (x + bw + 6, y + 15, INK, lab))
    o.append('<text x="16" y="%d" font-size="11" fill="%s">"none": the block has nothing of that kind to cover '
             '(no state machine, no covergroup or no bound property yet). Source: IMC 15.2 reports; see '
             'COVERAGE_BY_BLOCK.md for the counts.</text>' % (H - 22, MUTED))
    o.append("</svg>")
    open(os.path.join(ROOT, path), "w").write("\n".join(o) + "\n")


# ============================================================================ report
def report():
    data = gather()
    os.makedirs(os.path.join(ROOT, OUT), exist_ok=True)
    head = sh("git rev-parse --short HEAD").stdout.strip()
    dirty = bool(sh("git status --porcelain -- rtl tb sw").stdout.strip())
    nruns = len(open(os.path.join(ROOT, ALL, "runs.txt")).read().split())
    today = datetime.date.today().isoformat()
    svg(data, OUT + "/coverage_by_block.svg")

    # ---- csv
    with open(os.path.join(ROOT, OUT, "coverage_by_block.csv"), "w") as fh:
        fh.write("block,source,metric,covered,total,excluded_by_waiver,percent\n")
        for d in data:
            for m in METRICS:
                meas, wv = shown(d, m)
                for tag, p in (("measured", meas), ("after_waivers", wv)):
                    if p and p[1]:
                        fh.write("%s,%s,%s,%d,%d,%d,%.2f\n" % (d["key"], tag, m, p[0], p[1], p[2], pct(p)))
            if d["func"] and d["func"][1]:
                fh.write("%s,measured,Functional,%d,%d,0,%.2f\n" % (d["key"], d["func"][0], d["func"][1], pct(d["func"])))

    L = []
    L.append("# GARUDA SoC: coverage by block")
    L.append("")
    L.append("Written by `tools/gen/cov_chart.py` on %s from IMC 15.2 reports, tree `%s`%s. "
             "No figure here is typed by hand: each is a covered/total pair IMC printed, added over the "
             "modules of the block. To make it again: `make cov_chart`." % (today, head, " plus uncommitted changes" if dirty else ""))
    L.append("")
    L.append("![coverage by block](coverage_by_block.svg)")
    L.append("")
    L.append("## How to read it")
    L.append("")
    L.append("- **Two sources.** The five blocks that have a UVM environment (CLIC, timers, clock and reset, "
             "PWM, GPIO) are measured on that environment's own runs and shown twice: as measured, and after "
             "the written waivers. The other eleven are measured on the %d directed runs of "
             "`flow/regress/garuda.vsif` merged together, counted per module, with no waiver: none has been "
             "written for them yet. A hole in those rows is a hole, not a waived item." % nruns)
    L.append("- **Statement, expression, toggle, FSM** are IMC's block, expression, toggle and FSM "
             "(states, transitions, arcs) metrics. **Functional** is covergroup bins. **Assertions "
             "triggered** counts bound properties and cover properties that finished at least once: a "
             "property that never triggered has checked nothing, however many tests passed.")
    L.append("- The sign-off bar (`flow/0_signoff_criteria.md`) is 100% functional and at least 95% code "
             "coverage with every hole waived in writing. A block is closed only when it meets it.")
    L.append("")
    L.append("## Summary")
    L.append("")
    L.append("| Block | Track | Measured on | Statement | Expression | Toggle | FSM | Functional | Assertions triggered | Waivers |")
    L.append("|---|---|---|---|---|---|---|---|---|---|")
    tot = {m: (0, 0, 0) for m in METRICS}
    for i, d in enumerate(data):
        cells = []
        for m in METRICS:
            meas, wv = shown(d, m)
            final = wv if wv else meas
            if i < len(BLOCKS):
                tot[m] = add(tot[m], final)
            if wv and wv[1] and abs(pct(wv) - (pct(meas) or 0)) >= 0.05:
                cells.append("%s, after waivers %s" % (fmt(meas), fmt(wv)))
            else:
                cells.append(fmt(final))
        nw = len(d["waivers"])
        L.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            d["name"], d["track"], d["source"], cells[0], cells[1], cells[2], cells[3], fmt(d["func"]), cells[4],
            ("%d, in `%s`" % (nw, d["waiver_file"])) if nw else "none written"))
    L.append("")
    code = (0, 0, 0)
    for m in ("Block", "Expression", "Toggle", "Fsm"):
        code = add(code, tot[m])
    L.append("Over the sixteen blocks, counting items (waived items removed for the five blocks that have "
             "waivers): statement %s, expression %s, toggle %s, FSM %s; all four together %s." % (
                 fmt(tot["Block"]), fmt(tot["Expression"]), fmt(tot["Toggle"]), fmt(tot["Fsm"]), fmt(code)))
    L.append("")

    # ---- per block
    L.append("## Block by block")
    for d in data:
        L.append("")
        L.append("### %s" % d["name"])
        L.append("")
        f, it = d["plan_counts"]
        if d.get("plan"):
            L.append("Plan: `%s` (%d features, %d checks and coverage items). Track %s." % (d["plan"], f, it, d["track"]))
            L.append("")
        if "waived" in d:
            L.append("Measured on the UVM environment (%d runs: register test, directed test, random seeds), DUT instance only." % d.get("uvm_runs", 0))
            L.append("")
            L.append("| Metric | As measured | After waivers | Items waived |")
            L.append("|---|---|---|---|")
            for m in METRICS:
                r, w = d["raw"][m], d["waived"][m]
                if r[1] or w[1]:
                    L.append("| %s | %s | %s | %d |" % (m, fmt(r), fmt(w), w[2]))
            L.append("| Functional (covergroup bins) | %s | %s | 0 |" % (fmt(d["func"]), fmt(d["func"])))
            L.append("")
            left = [(m, d["waived"][m]) for m in METRICS if d["waived"][m][1] and d["waived"][m][0] != d["waived"][m][1]]
            if left:
                L.append("**Still open after the waivers:** " + "; ".join("%s %d of %d" % (m, p[1] - p[0], p[1]) for m, p in left) +
                         ". Listed in `sim/%s/holes.txt` after `make cov_chart`." % d["uvm"][0])
                L.append("")
            nv = d.get("never_uvm", [])
            if nv:
                L.append("Properties that never triggered in these runs: " + ", ".join("`%s`" % n for (_, n, _) in nv[:30]) + ".")
                L.append("")
        else:
            L.append("Measured on all directed tests merged, per module. No waiver applied.")
            L.append("")
            L.append("| Module | Statement | Expression | Toggle | FSM |")
            L.append("|---|---|---|---|---|")
            for k, v in d["permod"]:
                L.append("| `%s` | %s | %s | %s | %s |" % (k.replace("_g_", ", generate ").split("#")[0], fmt(v["Block"]), fmt(v["Expression"]), fmt(v["Toggle"]), fmt(v["Fsm"])))
            L.append("| **whole block** | %s | %s | %s | %s |" % tuple(fmt(d["merged"][m]) for m in ("Block", "Expression", "Toggle", "Fsm")))
            L.append("")
            if d["missing"]:
                L.append("Not in any coverage database (never elaborated with coverage on): " + ", ".join("`%s`" % m for m in d["missing"]) + ".")
                L.append("")
            if d["func"] and d["func"][1]:
                L.append("Functional coverage: %s." % fmt(d["func"]))
                if d.get("func_parts"):
                    L.append("")
                    L.append("| Covergroups of | Bins covered |")
                    L.append("|---|---|")
                    for n, p in d["func_parts"]:
                        L.append("| %s | %s |" % (n, fmt(p)))
                L.append("")
            elif d["key"] not in ("SHIM", "TOP"):
                L.append("Functional coverage: no covergroup is defined for this block yet (it has directed benches only).")
                L.append("")
            a = d["merged"]["Assertion"]
            if a[1]:
                L.append("Assertions: %s triggered." % fmt(a) + ((" Never triggered: " + ", ".join("`%s`" % n for (_, n, _) in d["never"]) + ".") if d["never"] else ""))
            else:
                L.append("Assertions: no property is bound to this block yet.")
            L.append("")
        # waivers
        if d["waivers"]:
            L.append("**Exclusions and their justifications** (`%s`, %d lines):" % (d["waiver_file"], len(d["waivers"])))
            L.append("")
            L.append("| Metric | Where | Items | Justification |")
            L.append("|---|---|---|---|")
            groups, order = {}, []
            for (metric, inst, item, comment) in d["waivers"]:
                k = (metric, inst, comment)
                if k not in groups:
                    groups[k] = []
                    order.append(k)
                groups[k].append(item)
            for k in order:
                items = groups[k]
                names = sorted(set(re.sub(r"\[\d+\]$", "", i) for i in items if i))
                show = ", ".join("`%s`" % n for n in names[:6]) + (" and %d more" % (len(names) - 6) if len(names) > 6 else "")
                L.append("| %s | `%s` | %d: %s | %s |" % (k[0], k[1], len(items), show or "the instance", k[2]))
            L.append("")
        elif d["key"] not in ("SHIM", "TOP"):
            L.append("**Exclusions:** none written. They are written when the block is closed (step R8 of the block recipe), each with its reason and, where the reason is \"unreachable\", a JasperGold run that confirms it.")
            L.append("")

    L.append("## Notes on the measurement")
    L.append("")
    L.append("- Twenty core unit and element benches are all a module `tb_top` with the DUT at `tb_top.dut`. IMC merges by instance path and kept only the first of them; the merged core figures were too low and nineteen benches' assertions read as never triggered. Each bench is now elaborated under a top of its own name (`flow/regress/run_test.sh`), and `cov_chart.py` stops if IMC reports an instance it did not merge. Entry TOOL-B5 in `Docs/bugs/track_b.md`.")
    L.append("- The chip and SoC tops hold wiring only; their toggle figure says how much of the chip's interconnect the eight chip programs moved.")
    L.append("- Toggle counts every bit of every signal in both directions. Constant bits (reserved register bits, tied-off inputs) can never toggle and are the usual content of a toggle waiver.")
    open(os.path.join(ROOT, OUT, "COVERAGE_BY_BLOCK.md"), "w").write("\n".join(L) + "\n")
    print("cov_chart: wrote %s/COVERAGE_BY_BLOCK.md, coverage_by_block.svg, coverage_by_block.csv" % OUT)


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("collect", "report"):
        sys.exit(__doc__)
    {"collect": collect, "report": report}[sys.argv[1]]()
