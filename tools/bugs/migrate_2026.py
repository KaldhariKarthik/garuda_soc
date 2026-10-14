#!/usr/bin/env python3
"""migrate_2026.py -- one-time split of Docs/BUGS.md into Docs/bugs/<blk>.md.

    python3.12 tools/bugs/migrate_2026.py            (from the repo root)

Reads the register as it stood (Docs/BUGS.md at the execution baseline),
writes one file per block with a single parseable table plus a Details
section that keeps every original entry VERBATIM, archives the original as
Docs/bugs/HISTORY_2026.md, and writes Docs/bugs/MIGRATION_2026-10-11.md: one
row per ID with the block, the raw status and how it was normalised, so the
mapping can be reviewed line by line. IDs are never changed, except the
proven collisions (one ID naming two different defects), which get a new ID
with the old one in the Formerly column.

Afterwards tools/bugs/bugs.py owns the files (index, check). Kept in the repo
as the record of how the split was made.
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
from bugs import BLOCKS, COLS, write_block_file  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BASE = "b90b481"
IDRE = r"(?:[A-Z]{1,5}(?:-[A-Z])?-[0-9]+[a-z]?|BUS-[A-D]|RTL-C[0-9]*)"

PREFIX_BLOCK = {
    "T": "core", "C": "core", "P": "core", "CORE": "core", "I": "core", "D": "core",
    "BUS": "core", "RDC": "core", "ELEM": "core", "OPEN": "core", "SVA": "core",
    "DSU": "dsu", "OVF": "dsu", "AHB": "ahb", "BRG": "ahb2apb", "APB": "ahb2apb",
    "DMA": "dma", "SPEC": "dma", "ENG": "dma", "CRG": "clkrst", "SIM": "clkrst",
    "CLIC": "clic", "DBG": "debug", "CDC": "debug", "GPIO": "gpio", "PWM": "pwm",
    "UART": "uart", "ERR-U": "uart", "I2C": "i2c", "SPIM": "spi_master", "SPIS": "spi_slave",
    "INT": "soc", "RTL-C": "soc", "TOOL": "flow", "VER": "flow", "MUT": "flow",
    "LINT": "flow", "FV": "flow", "VIP": "spi_master", "AUD": "spec", "TB": "flow",
}
TB_DIR_BLOCK = {"core": "core", "soc": "soc", "dsu": "dsu", "ahb": "ahb", "ahb2apb": "ahb2apb",
                "dma": "dma", "debug": "debug", "mem": "mem", "uart": "uart", "i2c": "i2c",
                "spi_master": "spi_master", "spi_slave": "spi_slave", "gpio": "gpio",
                "pwm": "pwm", "timers": "timers", "clic": "clic", "clk_div": "clkrst",
                "reset_ctrl": "clkrst", "apb": "ahb2apb", "common": "flow", "models": "flow"}

# Proven collisions (one ID, two different defects): (line of the occurrence
# that gives up the ID) -> new ID. The detailed section-6 entries keep theirs.
RENUMBER = {971: "TOOL-18", 126: "TOOL-19", 198: "TOOL-20", 125: "TB-36"}
# Same defect reported twice: the later, fuller entry wins; both texts are kept.
MERGE_KEEP_LAST = {"TB-15", "ELEM-4", "AUD-8"}

# Priority for entries that are still open and carry none in the register.
# (P-definitions: flow/0_signoff_criteria.md. "proposed" = until Karthik rules.)
OPEN_PRIO = {
    "T-13": ("P1", "proposed: a precise fault is lost"),
    "T-14": ("P1", "proposed: the core can sleep in the handler"),
    "PWM-2": ("P2", "proposed: an ESC input can see a glitch (owner K rules)"),
    "TOOL-13": ("P2", "proposed: a failing simulation can be reported as passing"),
    "TOOL-14": ("P2", "proposed: coverage merges failing runs and cannot fail"),
    "AUD-4": ("P3", "proposed"), "AUD-9": ("P3", "proposed"), "AUD-11": ("P3", "proposed"),
    "SPIM-2": ("P3", "proposed (vendored)"), "UART-3": ("P3", "proposed (vendored)"),
    "UART-4": ("P3", "proposed (vendored)"), "PWM-3": ("P3", "proposed"),
    "FV-1": ("P3", "proposed: superseded by the SBY flow (plan P0.9), close when it lands"),
    "TB-30": ("P3", "proposed"), "TB-32": ("P3", "proposed"), "TB-33": ("P3", "proposed"),
    "ELEM-8": ("P3", "proposed"), "TOOL-15": ("P3", "proposed"),
}
# Entries whose table has no Status column, or whose status words are not a
# lifecycle state. Each decision is quoted from the entry's own text.
STATUS_OVERRIDE = {
    **{f"SPEC-{n}": ("FIXED", "'each resolved on the record in docs/DMA_RTL_LOG.md 9.4'") for n in range(1, 13)},
    **{f"TB-{n}": ("FIXED", "DMA bring-up testbench fixes ('every such check was converted')") for n in range(1, 9)},
    **{m: ("CLOSED", "mutation record, not a defect") for m in
       ("MUT-1", "MUT-2", "MUT-3", "MUT-4", "MUT-5", "MUT-6", "MUT-7", "MUT-8a", "MUT-8b", "MUT-9")},
    "TOOL-1": ("CLOSED", "Windows-session environment note, superseded"),
    "TOOL-2": ("CLOSED", "Windows-session environment note, superseded"),
    "TOOL-3": ("CLOSED", "Windows-session environment note, superseded"),
    "TOOL-18": ("CLOSED", "environment note (no Cadence tools), superseded"),
    "TOOL-6": ("CLOSED", "environment note (no RISC-V toolchain), superseded"),
    "DMA-3a": ("FIXED", "part of the DMA-3 fix"),
    "SPIS-1": ("CLOSED", "design decision"),
    "SPIS-2": ("CLOSED", "'MEASURED, caveated': a stated measurement, not a defect"),
    "SPIS-3": ("WONTFIX", "'ACCEPTED, bounded'"),
}
# New entries from the Track A baseline (2026-10-11) and the audit.
ADDITIONS = [
    {"ID": "T-16", "blk": "core", "Title": "An EX exception on the instruction parked behind a WFI is taken during the sleep",
     "Status": "RULING-NEEDED", "Prio": "P3", "Found-by": "audit formal (TC-2 refuted)", "Found": "2026-10-05",
     "Regression test": "-", "Evidence": "Obsidian GARUDA Audit Working Notes; local/formal core_prove tc", "Formerly": "audit note 'T-12'",
     "_details": ("Found by the free-tool audit (2026-10-05) when the trap_ctrl contract TC-2 was refuted: an EX-point "
                  "exception on the instruction parked behind a WFI is taken while the core sleeps; the core then waits "
                  "at the handler entry for the wake. Legal (WFI may complete early) but CSR writes move earlier than a "
                  "reader of the spec expects. The audit called it 'T-12', which collides with the team's T-12 (the "
                  "interrupt-level stack); renumbered T-16. Ruling needed: accept and document, or hold the exception "
                  "until the wake. Covered by the WFI wake matrix (plan E12).")},
    {"ID": "TB-48", "blk": "core", "Title": "tb_mem_wb_reg a_capture relies on an asynchronous disable iff",
     "Status": "OPEN", "Prio": "P3", "Found-by": "Track A baseline (Verilator 5.052)", "Found": "2026-10-11",
     "Regression test": "core/elements E_mem_wb_reg", "Evidence": "logs/core/summary/elements.tsv", "Formerly": "-",
     "_details": ("`tb/core/tb_mem_wb_reg.sv:75` `a_capture` fires once at the reset release under Verilator 5.052, "
                  "which applies `disable iff` at clock edges only (IEEE 1800 16.12 makes it asynchronous; pinned by "
                  "the SVA self-test, `p_async_disable`). The scoreboard passes 38/38. Fix (W6): write the property "
                  "so it does not depend on the disable timing, e.g. gate on a registered reset. Until then the row is "
                  "XFAIL:TB-48 on Verilator; Xcelium is the authority.")},
    {"ID": "TB-35", "blk": "dsu", "Title": "tb_dsu_top ends its stimulus on an X sentinel that 2-state simulators never see",
     "Status": "OPEN", "Prio": "P3", "Found-by": "audit F-09; Track A baseline", "Found": "2026-10-04",
     "Regression test": "dsu/model tb_dsu_top", "Evidence": "logs/dsu/summary/model.tsv", "Formerly": "audit F-09",
     "_details": ("`tb/dsu/tb_dsu_top.sv:138` counts tests until `stim[...] !== 32'hxxxx_xxxx`. Under 2-state "
                  "Verilator the sentinel never matches, so the bench reads past the 445 records (40960 compared, "
                  "162060 mismatches, all from test 445 on). On Icarus (4-state) it is 445/0. Fix (D2/E7): size the "
                  "run from the generator's record count (+NTESTS) instead of a sentinel.")},
]
TOOL12 = {"Title": "The Spike lockstep ignores Spike's exit status (the short-log half was fixed by VER-3)", "Status": "IN-PROGRESS", "Prio": "P2", "Regression test": "tb/core/selftest/lockstep_negctl.py N5",
          "Evidence": "logs/flow/evidence/TOOL-12_before_lockstep_negctl.txt"}


def norm_status(raw):
    r = re.sub(r"[*`]", "", raw).upper()
    if re.search(r"NEEDS (AN )?(OWNER )?(DECISION|RULING)|OWNER TO RULE|RULING", r):
        return "RULING-NEEDED"
    if "PARTLY" in r:
        return "OPEN"
    if r.startswith("OPEN") or " OPEN" in r or "NOT RUN" in r or "WORKED AROUND" in r:
        return "OPEN"
    if "WAIVED" in r:
        return "WONTFIX"
    if re.search(r"NOT A BUG|MOOT|DISPOSITIONED|NO DEFECT|REVIEWED|AVOIDED|CLOSED", r):
        return "CLOSED"
    if re.search(r"FIXED|PROVED|DONE|RESOLVED|CORRECTED|DOCUMENTED|KILLED|CAUGHT", r):
        return "FIXED"
    return None


def prio_of(raw_prio, raw_sev):
    for raw in (raw_prio, raw_sev):
        m = re.search(r"\bP([123])\b", raw or "")
        if m:
            return f"P{m.group(1)}"
    s = (raw_sev or "").lower()
    if "high" in s:
        return "P1"
    if "medium" in s:
        return "P2"
    if "low" in s:
        return "P3"
    return "-"


def block_of(bid, where):
    w = where or ""
    m = re.search(r"\btb/([a-z_0-9]+)/", w)
    pre = re.sub(r"-[0-9]+[a-z]?$|-[A-D]$", "", bid)
    if bid.startswith("RTL-C"):
        pre = "RTL-C"
    if pre in ("TB", "ELEM", "VER", "TOOL") and m and m.group(1) in TB_DIR_BLOCK:
        return TB_DIR_BLOCK[m.group(1)]
    if pre == "TB":
        for k, v in (("tb_chip", "soc"), ("tb_boot", "core"), ("tb_dma", "dma"), ("tb_uart", "uart"),
                     ("tb_i2c", "i2c"), ("tb_spi", "spi_master"), ("ahb", "ahb"), ("apb", "ahb2apb"),
                     ("clic", "clic"), ("pwm", "pwm"), ("gpio", "gpio"), ("timer", "timers"),
                     ("core", "core"), ("dsu", "dsu")):
            if k in w.lower():
                return v
    return PREFIX_BLOCK.get(pre, "spec")


def title_of(text):
    t = re.sub(r"`", "", text)
    m = re.search(r"\*\*(.+?)\*\*", t)
    s = m.group(1) if m else re.split(r"(?<=[.;])\s", t, 1)[0]
    s = re.sub(r"\s+", " ", s).strip().rstrip(".")
    return (s[:117] + "...") if len(s) > 120 else s


def parse(lines):
    ents, sec, hdr, date, hdr_raw = [], "", None, "legacy", ""
    i = 0
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("#"):
            sec, hdr = ln.lstrip("#").strip(), None
            dm = re.search(r"(20\d\d-\d\d-\d\d)", ln)
            if ln.startswith("## "):
                date = dm.group(1) if dm else "legacy"
            m = re.match(r"^#{3,4} (" + IDRE + r") — (.*)", ln)
            if m:
                j = i + 1
                while j < len(lines) and not re.match(r"^#{1,4} ", lines[j]):
                    j += 1
                head = m.group(2)
                parts = [p.strip() for p in head.split("·")]
                stat = " / ".join(re.sub(r"`", "", p) for p in parts[1:] if "Severity" not in p)
                sev = next((p for p in parts if "Severity" in p), "")
                ents.append({"id": m.group(1), "line": i + 1, "sec": sec, "date": date,
                             "title": re.sub(r"[`*]", "", parts[0]).strip(), "raw_status": stat,
                             "raw_sev": sev, "raw_prio": "", "where": "", "found_by": "-",
                             "test": "-",
                             # demoted one level so it never competes with the
                             # "### <ID>" anchors of the per-block Details section
                             "text": "\n".join(("#" + x) if x.startswith("###") else x
                                               for x in lines[i:j]).rstrip()})
                i = j
                continue
            i += 1
            continue
        if ln.startswith("|"):
            cells = [c.strip() for c in ln.strip().strip("|").split("|")]
            c0 = re.sub(r"\*", "", cells[0])
            if re.match(r"^:?-+:?$", c0):
                i += 1
                continue
            if c0 in ("ID", "Bug", "#"):
                hdr = [re.sub(r"\*", "", c).strip().lower() for c in cells]
                hdr_raw = ln
                i += 1
                continue
            m = re.match("^(" + IDRE + ")$", c0)
            if m and hdr:
                row = dict(zip(hdr, cells))
                summ = row.get("summary") or row.get("one-line") or row.get("mutation") or ""
                ents.append({
                    "id": m.group(1), "line": i + 1, "sec": sec, "date": date,
                    "title": title_of(summ) if summ else "-",
                    "raw_status": row.get("status", row.get("result", row.get("class", ""))),
                    "raw_sev": row.get("severity", ""), "raw_prio": row.get("priority", ""),
                    "where": row.get("where", row.get("block", "")),
                    "found_by": re.sub(r"\s+", " ", row.get("found by", "-"))[:80] or "-",
                    "test": re.sub(r"\s+", " ", row.get("test", "-"))[:80] or "-",
                    # the original header row comes with it, so the entry renders as a table
                    "text": hdr_raw + "\n|" + "---|" * len(hdr) + "\n" + ln})
        i += 1
    return ents


def main():
    # One-time tool: after the split the per-block files are maintained by hand
    # and with `bugs.py set/add`; a rerun would overwrite those edits.
    if os.path.exists(os.path.join(ROOT, "Docs", "bugs", "core.md")) and "--force" not in sys.argv:
        sys.exit("Docs/bugs/ already exists: the split is done. Rerunning would overwrite "
                 "later edits (use --force only to redo the split from scratch).")
    # Always the register as committed at the baseline, never the working file:
    # after the split Docs/BUGS.md is the GENERATED index (a rerun once parsed it).
    src = subprocess.run(["git", "-C", ROOT, "show", f"{BASE}:Docs/BUGS.md"], capture_output=True,
                         text=True, check=True).stdout
    lines = src.splitlines()
    ents = parse(lines)
    # renumber proven collisions
    for e in ents:
        e["formerly"] = "-"
        if e["line"] in RENUMBER:
            e["formerly"] = e["id"]
            e["id"] = RENUMBER[e["line"]]
    # merge same-defect duplicates (keep the later entry, keep both texts)
    by = {}
    for e in ents:
        if e["id"] in by and e["id"] in MERGE_KEEP_LAST:
            prev = by[e["id"]]
            e["text"] = prev["text"] + "\n\n" + e["text"]
            e["date"] = prev["date"] if prev["date"] != "legacy" else e["date"]
        elif e["id"] in by:
            sys.exit(f"unresolved duplicate {e['id']} at lines {by[e['id']]['line']} and {e['line']}")
        by[e["id"]] = e
    rows, report, review = {b: [] for b in BLOCKS}, [], []
    for e in sorted(by.values(), key=lambda x: x["line"]):
        st = norm_status(e["raw_status"])
        flag = ""
        if e["id"] in STATUS_OVERRIDE:
            st, why = STATUS_OVERRIDE[e["id"]]
            flag = f"status set by hand: {why}"
        if st is None:
            st, flag = "OPEN", "status not recognised: set OPEN, review"
        if e["id"] == "TOOL-12":
            st, flag = TOOL12["Status"], "fix on branch a/p0-infra (Spike exit status), lands with its commit"
        pr = prio_of(e["raw_prio"], e["raw_sev"])
        if st in ("OPEN", "RULING-NEEDED") and e["id"] in OPEN_PRIO:
            pr = OPEN_PRIO[e["id"]][0]
            flag = (flag + "; " if flag else "") + OPEN_PRIO[e["id"]][1]
        if st in ("OPEN", "RULING-NEEDED") and pr == "-":
            pr, flag = "P3", (flag + "; " if flag else "") + "open without priority: P3 set, review"
        blk = block_of(e["id"], e["where"] + " " + e["text"][:300])
        if re.match(r"^TB-[1-8]$", e["id"]):
            blk = "dma"          # 'Eight defects from the DMA block-level bring-up'

        fixed = "legacy" if st in ("FIXED", "CLOSED", "WONTFIX") else "-"
        rows[blk].append({
            "ID": e["id"], "Title": e["title"].replace("|", "/"), "Status": st, "Prio": pr,
            "Found-by": e["found_by"].replace("|", "/"), "Found": e["date"], "Fixed-in": fixed,
            "Regression test": e["test"].replace("|", "/"),
            "Evidence": f"HISTORY_2026.md L{e['line']}", "Formerly": e["formerly"],
            "_details": f"*From `Docs/BUGS.md` at {BASE}, line {e['line']}, section \"{e['sec']}\".*\n\n{e['text']}"})
        if e["id"] == "TOOL-12":
            rows[blk][-1].update({k: v for k, v in TOOL12.items() if k != "Status"})  # title, prio, test, evidence
            rows[blk][-1]["Status"] = TOOL12["Status"]
            pr = TOOL12["Prio"]
        report.append((e["id"], blk, e["raw_status"][:60].replace("|", "/"), st, pr, e["formerly"], flag))
        if flag and ("review" in flag or "proposed" in flag):
            review.append(e["id"])
    for a in ADDITIONS:
        r = dict(a)
        blk = r.pop("blk")
        r["Fixed-in"] = "-"
        rows[blk].append(r)
        report.append((r["ID"], blk, "(new 2026-10-11)", r["Status"], r["Prio"], r["Formerly"], "added"))
    os.makedirs(os.path.join(ROOT, "Docs", "bugs"), exist_ok=True)
    hist = os.path.join(ROOT, "Docs", "bugs", "HISTORY_2026.md")
    with open(hist, "w") as f:
        f.write(f"<!-- Docs/BUGS.md as it stood at {BASE}, archived verbatim on 2026-10-11 when the\n"
                f"     register was split per block (Docs/bugs/<blk>.md). Do not edit: history only.\n"
                f"     Line numbers below are the ones the per-block files cite. -->\n")
        f.write(src)
    for b in BLOCKS:
        write_block_file(b, rows[b])
    with open(os.path.join(ROOT, "Docs", "bugs", "MIGRATION_2026-10-11.md"), "w") as f:
        f.write(f"# Bug register split, 2026-10-11\n\nSource: `Docs/BUGS.md` at {BASE} (archived as "
                f"`HISTORY_2026.md`). {len(report)} IDs. Made by `tools/bugs/migrate_2026.py`.\n\n"
                "Rules: status normalised to OPEN / RULING-NEEDED / IN-PROGRESS / FIXED / CLOSED / "
                "WONTFIX / DUP (WAIVED -> WONTFIX; MOOT, not a bug, dispositioned -> CLOSED); "
                "priority from the Priority column, else Severity high/medium/low -> P1/P2/P3; "
                "fixed entries carry Fixed-in `legacy` (no SHA was recorded).\n\n"
                f"Collisions renumbered: {', '.join(f'{v} (formerly the one at line {k})' for k, v in RENUMBER.items())}. "
                f"Same-defect duplicates merged: {', '.join(sorted(MERGE_KEEP_LAST))}.\n\n"
                f"**Needs review ({len(review)}):** {', '.join(review) or 'none'}\n\n"
                "| ID | Block | Status as written | Status | Prio | Formerly | Note |\n|---|---|---|---|---|---|---|\n")
        for r in report:
            f.write("| " + " | ".join(str(x) if x else "" for x in r) + " |\n")
    print(f"{len(report)} IDs -> " + ", ".join(f"{b}={len(rows[b])}" for b in BLOCKS if rows[b]))
    print(f"needs review: {review}")


if __name__ == "__main__":
    main()
