#!/usr/bin/env python3
"""
gen_vplan_csv.py -- note-by-note traceability list for the GARUDA specifications.

    python3 tools/gen/gen_vplan_csv.py              # writes flow/1_vplan/traceability/spec_notes.csv
    python3 tools/gen/gen_vplan_csv.py --unchecked  # also lists notes no test cites

This is NOT the verification plan. The plans are tb/<block>/GARUDA_<BLOCK>_vplan.csv
(each block's specification sections 2, 10 and 11) and flow/1_vplan/garuda_soc.csv.
This list answers a narrower question: which normative note is cited by which check.

The plan mirrors the specifications rather than the test list: every normative
note ([N-x.y]) and every requirement row (R-n) in Design_Docs/GARUDA-*-SPEC-001.md
becomes one plan element, placed under the flow stage that verifies it. An
element is marked as checked only when a testbench or a test program cites its
tag, which is how the block testbenches label their checks:

    [PASS] [N-13.2] SCR is not implemented: decodes, reads 0

Open the result with:   vplanner -standalone     (File > Open, pick the .csv)
Column names follow the vPlanner User Guide, section 2.11 (CSV-based plans).
ELEMENT_ID is stable across regenerations so mappings made in vPlanner survive
a re-import.
"""

import csv
import glob
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "flow", "1_vplan", "traceability", "spec_notes.csv")

COLS = ["NAME", "DEPTH", "NODE_KIND", "element_id", "details",
        "implementation_note", "owner", "priority"]

# spec key -> (stage, block title, where its checks live, command that runs them)
BLOCKS = [
    ("CLKRST", 3, "clk_div + reset_ctrl (21/22)", ["tb/clk_div", "tb/reset_ctrl"], "tb_crg"),
    ("MEM",    3, "memories: isram, bootrom, dsram (3/4/5)", ["tb/mem"], "tb_mem_subsystem"),
    ("DMA",    3, "dma (9)", ["tb/dma"], "tb_dma_top"),
    ("CLIC",   3, "clic (10)", ["tb/clic"], "tb_clic"),
    ("TIMERS", 3, "timers + watchdog (11)", ["tb/timers"], "tb_timers"),
    ("DEBUG",  3, "debug: JTAG, DM, SBA (12)", ["tb/debug"], "tb_debug"),
    ("SPIM",   3, "spi_master (13)", ["tb/spi_master"], "tb_spim"),
    ("SPIS",   3, "spi_slave (14)", ["tb/spi_slave"], "tb_spis"),
    ("I2C",    3, "i2c (15)", ["tb/i2c"], "tb_i2c"),
    ("UART",   3, "uart0/1/2 (16/17/18)", ["tb/uart"], "tb_uart"),
    ("GPIO",   3, "gpio (19)", ["tb/gpio"], "tb_gpio"),
    ("PWM",    3, "pwm (20)", ["tb/pwm"], "tb_pwm"),
    ("CORE",   4, "core (1)", ["tb/core", "sw/tests"], "tb_boot + unit/element testbenches"),
    ("DSU",    4, "dsu (2)", ["tb/dsu"], "tb_dsu_top"),
    ("AHB",    5, "ahb interconnect (6)", ["tb/ahb"], "tb_ahb_interconnect"),
    ("AHB2APB", 5, "ahb2apb bridge + apb fabric (7/8)", ["tb/ahb2apb", "tb/common"], "tb_ahb2apb, tb_apb_shim"),
]
# checks made from the pins can cite any spec; they are searched for every block
CHIP_DIRS = ["tb/soc", "sw/chip"]

STAGES = {
    2: "Stage 2 - Static",
    3: "Stage 3 - Block and IP",
    4: "Stage 4 - CPU Core",
    5: "Stage 5 - Integration",
    6: "Stage 6 - SoC Top",
}
IN_HOUSE = {"PWM", "SPIS", "I2C", "DMA", "CLIC", "TIMERS", "DEBUG", "CLKRST",
            "MEM", "CORE", "DSU", "AHB", "AHB2APB"}

NOTE_RE = re.compile(r"\*\*\[(N-\d+\.\d+[a-z]?)\]\*{0,2}\s*(.*)")
REQ_RE = re.compile(r"^\|\s*(R-\d+)\s*\|\s*(.+?)\s*\|")
HEAD_RE = re.compile(r"^(#{2,3})\s+(.*)")
TAG_RE = re.compile(r"(?:\b([A-Z][A-Z0-9]+)\s+)?\[((?:N-\d+\.\d+[a-z]?)|(?:R-\d+))\]")


def clean(text, limit=320):
    text = re.sub(r"[*`>|]", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text if len(text) <= limit else text[:limit - 3].rstrip() + "..."


def parse_spec(key):
    """Returns [(tag, section heading, text)] in document order."""
    path = os.path.join(ROOT, "Design_Docs", "GARUDA-%s-SPEC-001.md" % key)
    items, seen = [], set()
    section = ""
    lines = open(path, encoding="utf-8").read().splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        h = HEAD_RE.match(line)
        if h and h.group(1) == "##":
            section = clean(h.group(2), 60)
        m = NOTE_RE.search(line)
        r = REQ_RE.match(line)
        if m and m.group(1) not in seen:
            body = [m.group(2)]
            j = i + 1
            while j < len(lines) and lines[j].strip() and not NOTE_RE.search(lines[j]):
                body.append(lines[j])
                j += 1
            seen.add(m.group(1))
            items.append((m.group(1), section, clean(" ".join(body))))
        elif r and r.group(1) not in seen:
            seen.add(r.group(1))
            items.append((r.group(1), section, clean(r.group(2))))
        i += 1
    return items


def citations(dirs, key, own):
    """tag -> [(file, the line that cites it)] for one spec.

    A bare tag belongs to the spec of the directory it is found in; a tag
    written as 'SPIM [N-7.3a]' belongs to the named spec wherever it appears.
    """
    found = {}
    for d in dirs:
        for path in sorted(glob.glob(os.path.join(ROOT, d, "*"))):
            if not os.path.isfile(path) or not path.endswith((".sv", ".v", ".c", ".S", ".h")):
                continue
            for line in open(path, encoding="utf-8", errors="ignore"):
                for spec, tag in TAG_RE.findall(line):
                    if spec == key or (not spec and own):
                        found.setdefault(tag, []).append(
                            (os.path.relpath(path, ROOT), clean(line, 150)))
    return found


def sva_names():
    path = os.path.join(ROOT, "rtl", "core", "pipe_ctrl_sva.sv")
    return re.findall(r"^\s*([a-z_0-9]+)\s*:\s*(assert|cover) property",
                      open(path).read(), flags=re.M)


def row(name, depth, kind="SECTION", eid="", details="", note="", owner="", pri=""):
    # element names become path components in vManager: keep them plain
    name = re.sub(r"\s+", " ", re.sub(r"[^A-Za-z0-9 _.()+=-]", " ", name.replace("/", "-"))).strip()
    return [name, depth, kind, eid, details, note, owner, pri]


def build(list_unchecked):
    rows = [row("GARUDA SoC", 0, eid="GARUDA",
                details="Verification plan for garuda_chip_top, Rev 4.0 specification set. "
                        "Stages follow the flow: vPlan, Static, Block/IP, CPU Core, "
                        "Integration, SoC Top. Generated from the specifications by "
                        "tools/gen/gen_vplan_csv.py; extends the 2026-07-20 core and DSU plans.")]

    # ---- stage 2: static -------------------------------------------------
    rows.append(row(STAGES[2], 1, eid="S2"))
    rows.append(row("Lint (HAL)", 2, eid="S2.LINT",
                    details="HAL on rtl/soc/filelist_chip.f, top garuda_chip_top."))
    for eid, name, det in [
        ("S2.LINT.ERR", "No HAL errors", "Every error fixed in RTL or waived with a written reason."),
        ("S2.LINT.WIDTH", "Width and truncation", "Unequal-length assignments and comparisons reviewed."),
        ("S2.LINT.DRIVE", "Drivers and connectivity", "No undriven, multiply driven or unconnected nets and ports."),
        ("S2.LINT.SYNTH", "Synthesisable RTL", "No latches other than the clock-gate latch, no incomplete sensitivity lists, no simulation-only constructs outside ifndef SYNTHESIS."),
        ("S2.LINT.RESET", "Reset and clock use", "Every flop has a defined reset or a stated reason; no gated or derived clocks outside clk_div and core_clk_gate."),
    ]:
        rows.append(row(name, 3, "CHK", eid, det, "hal -f rtl/soc/filelist_chip.f -top garuda_chip_top"))
    rows.append(row("Clock domain crossings (HAL CDC)", 2, eid="S2.CDC",
                    details="hclk and pclk are synchronous; tck and the SPI slave clock are asynchronous to both."))
    for eid, name, det in [
        ("S2.CDC.DMI", "tck <-> hclk through dmi_cdc", "Debug transport request and response handshake."),
        ("S2.CDC.SPIS", "spi slave sck <-> pclk", "Shift register to register layer in garuda_spis_core."),
        ("S2.CDC.DMA", "dma_cdc_pulse", "Event pulses between the DMA engine and its APB side (DMA-5)."),
        ("S2.CDC.PADS", "asynchronous pads", "UART rx, I2C, GPIO and SPI inputs pass a synchroniser with a defined reset level."),
        ("S2.CDC.RESET", "reset synchronisers", "Asynchronous assert, synchronous release in reset_ctrl."),
    ]:
        rows.append(row(name, 3, "CHK", eid, det, "hal CDC checks, clocks declared in flow/2_static"))
    rows.append(row("Formal (IFV) on pipe_ctrl", 2, eid="S2.FV",
                    details="CORE [N-11.2] hold-versus-flush matrix; BUGS.md AUD-8."))
    for name, kind in sva_names():
        rows.append(row(name, 3, "CHK" if kind == "assert" else "COV", "S2.FV." + name,
                        "%s property in rtl/core/pipe_ctrl_sva.sv" % kind, "ifv, flow/2_static/fv_pipe_ctrl"))

    # ---- stages 3, 4, 5: one section per specification -------------------
    unchecked = []
    for stage in (3, 4, 5):
        rows.append(row(STAGES[stage], 1, eid="S%d" % stage))
        if stage == 4:
            add_core_tests(rows)
        for key, st, title, dirs, tb in BLOCKS:
            if st != stage:
                continue
            items = parse_spec(key)
            cites = citations(dirs, key, own=True)
            for tag, where in citations(CHIP_DIRS, key, own=False).items():
                cites.setdefault(tag, []).extend(where)
            done = sum(1 for tag, _, _ in items if tag in cites)
            pri = "high" if key in IN_HOUSE else "medium"
            rows.append(row(title, 2, eid=key,
                            details="GARUDA-%s-SPEC-001. %d notes and requirements, %d cited by a check."
                                    % (key, len(items), done),
                            note=tb, pri=pri))
            section = None
            for tag, sec, text in items:
                if sec != section:
                    section = sec
                    rows.append(row(sec or "General", 3, eid="%s.SEC.%s" % (key, re.sub(r"\W+", "_", sec))))
                if tag in cites:
                    f, label = cites[tag][0]
                    note = "CHECKED: %s (%d citation%s). %s" % (
                        f, len(cites[tag]), "" if len(cites[tag]) == 1 else "s", label)
                else:
                    note = "NO TAGGED CHECK"
                    unchecked.append((key, tag, text))
                rows.append(row("%s %s" % (tag, clean(text, 70)), 4, "CHK",
                                "%s.%s" % (key, tag), text, note, pri=pri))
        if stage == 5:
            add_integration(rows)

    # ---- stage 6: the chip from the pins ---------------------------------
    rows.append(row(STAGES[6], 1, eid="S6"))
    rows.append(row("Chip tests from the pins (tb_chip)", 2, eid="S6.CHIP",
                    details="garuda_chip_top with the real boot ROM; AHB checker on all four masters and the shared bus."))
    for mode, det in [
        ("basic", "boot path, ILOCK, precise bus faults, DMA R-9"),
        ("irq", "DMA completion through the CLIC, machine timer, watchdog warning, WFI and clock gate"),
        ("wdt", "a real watchdog reset: RSTREASON = WDT, DSRAM survives"),
        ("flash", "boot_sel = 0: ROM reads the image over SPI, checks CRC-32, sets ILOCK, jumps"),
        ("uart", "three UARTs through the pins"),
        ("periph", "SPI master, I2C, GPIO, PWM, SPI slave through the pins"),
        ("integ", "every DMA and peripheral interrupt line to its CLIC ID, every DMA request line to its channel, one precise bus fault per unmapped offset, absent window and sub-word access"),
        ("jtag", "halt, load ISRAM over SBA, mailbox, resume, run"),
    ]:
        rows.append(row("t_chip_%s" % mode, 3, "TC", "S6.CHIP.%s" % mode, det,
                        "sw/chip/t_chip_%s.c on tb/soc/filelist_chip.f" % mode, pri="high"))
    for eid, name, det in [
        ("S6.SVA", "No assertion fires in any chip test", "Simulator assertion errors count as test failures."),
        ("S6.XPROP", "No X reaches a pin or the bus after reset", "X-propagation run from power-on reset."),
        ("S6.CLKDIV", "Every clock divider ratio", "hclk at /2, /4, /8, /16 with pclk = hclk/2."),
        ("S6.RSTMID", "Reset during bus activity", "External and watchdog reset asserted mid-transfer; chip reboots cleanly."),
        ("S6.WAKE", "WFI wake from each source", "Timer, watchdog warning, DMA, each peripheral interrupt."),
    ]:
        rows.append(row(name, 3, "CHK", eid, det, pri="high"))

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(COLS)
        w.writerows(rows)

    total = sum(1 for r in rows if r[2] in ("CHK", "TC", "COV"))
    print("wrote %s: %d elements (%d checks/tests/cover points)"
          % (os.path.relpath(OUT, ROOT), len(rows), total))
    by = {}
    for key, _, _ in unchecked:
        by[key] = by.get(key, 0) + 1
    print("notes with no tagged check: %d  (%s)" % (
        len(unchecked), ", ".join("%s %d" % kv for kv in sorted(by.items(), key=lambda kv: -kv[1]))))
    if list_unchecked:
        for key, tag, text in unchecked:
            print("  %-8s %-9s %s" % (key, tag, clean(text, 110)))


def add_core_tests(rows):
    rows.append(row("ISA tests in lockstep with Spike", 2, eid="S4.ISA",
                    details="rv32ui, rv32um, rv32mi. Each test self-checks and every retired "
                            "instruction is compared against Spike (tools/lockstep.py)."))
    hexes = sorted(glob.glob(os.path.join(ROOT, "sw", "riscv-tests", "build", "*.hex")))
    for h in hexes:
        t = os.path.basename(h)[:-4]
        rows.append(row(t, 3, "TC", "S4.ISA." + t, "", "scripts/run_regression.sh", pri="high"))
    rows.append(row("Core sanity tests", 2, eid="S4.SANITY"))
    for line in open(os.path.join(ROOT, "scripts", "run_sanity.sh")):
        m = re.match(r'\s*"(t_\w+)\|([^|]*)\|', line)
        if m:
            rows.append(row(m.group(1), 3, "TC", "S4.SANITY." + m.group(1), m.group(2),
                            "sw/tests/%s.S on tb_boot" % m.group(1), pri="high"))
    rows.append(row("Stall and timing robustness", 2, eid="S4.TIMING"))
    for eid, name, det in [
        ("S4.TIMING.RAND", "ISA suite under random wait states, 20 seeds", "I and D port waits 0..8 per access."),
        ("S4.TIMING.MATRIX", "t_hold_flush_matrix", "CORE [N-11.2]: 19 hold-versus-flush cells, each checked on architectural state; sw/tests/t_hold_flush_matrix.S."),
        ("S4.TIMING.DSUB2B", "t_dsu_b2b", "DSU instructions back to back through the pipeline; sw/tests/t_dsu_b2b.S."),
        ("S4.TIMING.RANDPROG", "Random programs in lockstep with Spike", "Random instruction streams with random interrupts. NOT RUN: no generator yet."),
    ]:
        rows.append(row(name, 3, "TC", eid, det, pri="high"))
    rows.append(row("Functional coverage (tb/cov/garuda_cov.sv)", 2, eid="S4.COV"))
    src = open(os.path.join(ROOT, "tb", "cov", "garuda_cov.sv")).read()
    for cg in re.findall(r"^\s*covergroup\s+(cg_\w+)", src, flags=re.M):
        rows.append(row(cg, 3, "COV", "S4.COV." + cg, "covergroup %s" % cg))


def add_integration(rows):
    rows.append(row("Chip-level integration checks", 2, eid="S5.INT"))
    for eid, name, det in [
        ("S5.INT.ELAB", "Whole chip elaborates with no unresolved or unconnected ports", "irun -elaborate on rtl/soc/filelist_chip.f; HAL connectivity."),
        ("S5.INT.REGWALK", "Register walk over every APB window", "Reset value, read/write bits, unmapped offsets answer with an error; addresses from sw/common/garuda_map.h."),
        ("S5.INT.IRQ", "Each interrupt line reaches its CLIC ID", "Per garuda_system.yaml clic section."),
        ("S5.INT.DMAREQ", "Each DMA request line reaches its channel", "Per garuda_system.yaml dma section."),
        ("S5.INT.ARB", "Four masters under seed sweep, AHB checker fatal", "iport, dport, sba, dma contending; ADR-0004 priority."),
        ("S5.INT.TOGGLE", "Every inter-block port toggles", "Toggle coverage on block boundary ports in IMC."),
    ]:
        rows.append(row(name, 3, "CHK", eid, det, pri="high"))


if __name__ == "__main__":
    build("--unchecked" in sys.argv[1:])
