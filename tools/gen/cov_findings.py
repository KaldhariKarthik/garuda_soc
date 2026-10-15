#!/usr/bin/env python3
"""
cov_findings.py - every coverage hole of the chip, block by block, from the reports `make cov_chart` wrote.

    python3 tools/gen/cov_findings.py        writes Docs/coverage/FINDINGS.md

Reads:
  Docs/coverage/coverage_by_block.csv   the per-block code and functional figures (cov_chart.py)
  sim/cov_all/cg_holes_<type>.txt       IMC detail reports of each bound covergroup type
  sim/cov_all/cg_core_holes.txt         the same for garuda_cov
  sim/uvm_<blk>/func_holes.txt          the UVM environments' covergroups
A hole is a bin with no hit. Crosses are listed by count with the first few bins named; the full
list is in the IMC report named under each block.
"""
import os, re, csv, collections

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(ROOT)
LINE = re.compile(r"^((?:\| )*)\|--(\S+)\s+([\d.]+%|n/a)\s*(?:\((\d+)/(\d+)\))?")
TOP = re.compile(r"^(\S+)\s+([\d.]+%), ([\d.]+%) \((\d+)/(\d+)\)")

def holes(path):
    """{group: {point: [uncovered bins], ...}} and {group: (cov, tot)} from one IMC detail report"""
    out = collections.OrderedDict(); tot = {}
    if not os.path.exists(path): return out, tot
    grp = point = None
    for l in open(path, errors="replace"):
        m = TOP.match(l)
        if m and not l.startswith("|"):
            grp = m.group(1); point = None
            out.setdefault(grp, collections.OrderedDict())
            tot[grp] = (int(m.group(4)), int(m.group(5)))
            continue
        m = LINE.match(l)
        if not m or grp is None: continue
        depth = len(m.group(1)) // 2
        if depth == 0:
            point = m.group(2); out[grp].setdefault(point, [])
        elif depth == 1 and point and m.group(4) is not None and m.group(4) == "0":
            out[grp][point].append(m.group(2))
    return out, tot

def code_rows():
    rows = collections.defaultdict(dict)
    p = "Docs/coverage/coverage_by_block.csv"
    if os.path.exists(p):
        for r in csv.reader(open(p)):
            if len(r) >= 7 and r[0] != "block":          # block,source,metric,covered,total,excluded,percent
                try: rows[r[0]][(r[1], r[2])] = float(r[6])
                except ValueError: pass
    return rows

# block key -> (title, [report files])
SRC = [
 ("CORE", "RV32IM core", ["sim/cov_all/cg_core_holes.txt", "sim/cov_all/cg_holes_garuda_core_cov_ext.txt"]),
 ("DSU", "DSU", ["sim/cov_all/cg_holes_dsu_cov.txt"]),
 ("AHB", "AHB interconnect", ["sim/cov_all/cg_holes_ahb_interconnect_cov.txt"]),
 ("AHB2APB", "AHB to APB bridge", ["sim/cov_all/cg_holes_ahb2apb_bridge_cov.txt"]),
 ("MEM", "Memories", ["sim/cov_all/cg_holes_mem_cov.txt"]),
 ("DMA", "DMA", ["sim/cov_all/cg_holes_dma_cov.txt"]),
 ("DEBUG", "Debug", ["sim/cov_all/cg_holes_debug_cov.txt"]),
 ("CLIC", "CLIC", ["sim/uvm_clic/func_holes.txt"]),
 ("TIMERS", "Timers and watchdog", ["sim/uvm_timers/func_holes.txt"]),
 ("CLKRST", "Clock divider and reset", ["sim/uvm_crg/func_holes.txt"]),
 ("PWM", "PWM", ["sim/uvm_pwm/func_holes.txt"]),
 ("GPIO", "GPIO", ["sim/uvm_gpio/func_holes.txt"]),
 ("UART", "UART", ["sim/uvm_uart/func_holes.txt"]),
 ("I2C", "I2C", ["sim/uvm_i2c/func_holes.txt"]),
 ("SPIM", "SPI master", ["sim/cov_all/cg_holes_spim_cov.txt"]),
 ("SPIS", "SPI slave", ["sim/uvm_spis/func_holes.txt"]),
 ("SHIM", "APB shim (six peripherals)", ["sim/cov_all/cg_holes_garuda_apb_shim_cov.txt"]),
 ("TOP", "Chip and SoC top (wiring)", ["sim/cov_all/cg_holes_chip_cov.txt"]),
]

def main():
    code = code_rows()
    L = ["# Coverage findings, block by block", "",
         "Written by `tools/gen/cov_findings.py` from the IMC reports of `make cov_chart` (the merged directed "
         "runs, the chip programs and the UVM environments). The figures per block are in "
         "`Docs/coverage/COVERAGE_BY_BLOCK.md`; this file lists **what was never hit**, which is what the next "
         "tests have to aim at. A hole is not a defect: it is a combination the tests did not produce.", "",
         "## Summary", "", "| Block | Code: block | Expression | Toggle | Functional | Uncovered bins |", "|---|---|---|---|---|---|"]
    body = []
    for key, title, files in SRC:
        groups = []; 
        for f in files:
            h, t = holes(f)
            for g in h: groups.append((f, g, h[g], t.get(g)))
        n_holes = sum(len(b) for _, _, pts, _ in groups for b in pts.values())
        c = code.get(key, {})
        def g(m):
            me, wa = c.get(("measured", m)), c.get(("after_waivers", m))
            if me is None: return "-"
            if wa is not None and abs(wa - me) > 0.05: return "%.1f%% (%.1f%% after waivers)" % (me, wa)
            return "%.1f%%" % me
        L.append("| %s | %s | %s | %s | %s | %d |" % (title, g("Block"), g("Expression"), g("Toggle"), g("Functional"), n_holes))
        body += ["", "## %s" % title, ""]
        if not groups:
            body.append("No covergroup report found (files: %s)." % ", ".join("`%s`" % f for f in files)); continue
        for f, grp, pts, tt in groups:
            body.append("**`%s`** %s, from `%s`" % (grp, "(%d of %d bins)" % tt if tt else "", f))
            body.append("")
            any_ = False
            for p, bins in pts.items():
                if not bins: continue
                any_ = True
                shown = ", ".join("`%s`" % b for b in bins[:10])
                body.append("- `%s`: %d uncovered: %s%s" % (p, len(bins), shown, " ..." if len(bins) > 10 else ""))
            if not any_: body.append("- every bin hit")
            body.append("")
    open("Docs/coverage/FINDINGS.md", "w").write("\n".join(L + body) + "\n")
    print("wrote Docs/coverage/FINDINGS.md")
main()
