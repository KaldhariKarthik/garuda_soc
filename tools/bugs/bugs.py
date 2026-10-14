#!/usr/bin/env python3
"""bugs.py -- the GARUDA bug register: one file per block, one generated index.

    python3.12 tools/bugs/bugs.py check             validate every Docs/bugs/<blk>.md
    python3.12 tools/bugs/bugs.py index             regenerate Docs/BUGS.md
    python3.12 tools/bugs/bugs.py open [--prio P2]  list open items (OPEN, RULING-NEEDED, IN-PROGRESS)
    python3.12 tools/bugs/bugs.py set ID Field=value ... [--note TEXT]
                                                    update one entry (and append a dated note)
    python3.12 tools/bugs/bugs.py add BLK ID Field=value ... --details TEXT
                                                    add a new entry to Docs/bugs/BLK.md
    python3.12 tools/bugs/bugs.py backfill-errata   add a FIXED/legacy row for every ERRATUM <ID>
                                                    cited in rtl/ or tb/ that has no row yet

Each Docs/bugs/<blk>.md holds ONE table with the columns in COLS (this tool
parses it) and a "## Details" section with one "### <ID>" entry per bug.
Process and field rules: Docs/handbook/H3_bugs.md. `check` fails on:
  - an ID defined twice (in one file or across files);
  - a Status or Prio outside the fixed lists;
  - OPEN / RULING-NEEDED / IN-PROGRESS without P1..P3;
  - FIXED without Fixed-in (a commit SHA, or `legacy` for entries migrated from
    the pre-2026-10-11 register) and, unless legacy, without a regression test;
  - a Found date that is not ISO (YYYY-MM-DD) or `legacy`;
  - an `ERRATUM <ID>` cited in rtl/ or tb/ that is not in the register.
"""
import argparse
import datetime as dt
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
# GARUDA_BUGS_DIR lets the self-test check a planted copy without touching Docs/bugs.
DOCS = os.environ.get("GARUDA_BUGS_DIR", os.path.join(ROOT, "Docs", "bugs"))
COLS = ["ID", "Title", "Status", "Prio", "Found-by", "Found", "Fixed-in", "Regression test",
        "Evidence", "Formerly"]
STATUS = ["OPEN", "RULING-NEEDED", "IN-PROGRESS", "FIXED", "CLOSED", "WONTFIX", "DUP"]
OPENISH = {"OPEN", "RULING-NEEDED", "IN-PROGRESS"}
PRIO = ["P1", "P2", "P3", "-"]
BLOCKS = {
    "core": ("RV32IM core (rtl/core)", "Track A"),
    "dsu": ("DSU coprocessor (rtl/dsu)", "Track A"),
    "ahb": ("AHB-Lite interconnect (rtl/ahb)", "Track A"),
    "ahb2apb": ("AHB-to-APB bridge (rtl/ahb2apb)", "Track A"),
    "dma": ("DMA controller (rtl/dma)", "Track A"),
    "debug": ("Debug module + JTAG (rtl/debug)", "Track A"),
    "mem": ("Memories, boot ROM, ISRAM lock", "Track A"),
    "clic": ("CLIC (rtl/clic)", "Track B"),
    "uart": ("UART (rtl/uart + vendored PULP)", "Track B"),
    "i2c": ("I2C (rtl/i2c)", "Track B"),
    "spi_master": ("SPI master (rtl/spi_master)", "Track B"),
    "spi_slave": ("SPI slave (rtl/spi_slave)", "Track B"),
    "gpio": ("GPIO (rtl/gpio)", "Track B"),
    "pwm": ("PWM (rtl/pwm)", "Track B"),
    "timers": ("Timers + watchdog (rtl/timers)", "Track B"),
    "clkrst": ("Clock divider + reset controller", "Track B"),
    "soc": ("Chip integration (rtl/soc)", "Track B"),
    "flow": ("Flow, tools, testbench infrastructure (TOOL, VER, MUT, LINT, FV)", "shared"),
    "spec": ("Specifications across documents (AUD, SPEC)", "owner of each spec"),
}
RTL_DIR_BLOCK = {"core": "core", "dsu": "dsu", "ahb": "ahb", "ahb2apb": "ahb2apb", "apb": "ahb2apb",
                 "dma": "dma", "debug": "debug", "mem": "mem", "brom": "mem", "isram": "mem",
                 "dsram": "mem", "clic": "clic", "uart": "uart", "i2c": "i2c",
                 "spi_master": "spi_master", "spi_slave": "spi_slave", "gpio": "gpio", "pwm": "pwm",
                 "timers": "timers", "clk_div": "clkrst", "reset_ctrl": "clkrst", "soc": "soc",
                 "common": "soc", "plic": "clic"}
PRIO_TEXT = ("P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but "
             "there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).")


# --------------------------------------------------------------------- file I/O
def write_block_file(blk, rows):
    name, owner = BLOCKS[blk]
    p = os.path.join(DOCS, f"{blk}.md")
    with open(p, "w") as f:
        f.write(f"# Bugs: {name}\n\n")
        f.write(f"Owner: {owner}. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). "
                f"Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).\n"
                f"Priorities: {PRIO_TEXT}\n\n")
        f.write("<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. "
                "Run `bugs.py check` before pushing. -->\n")
        f.write("| " + " | ".join(COLS) + " |\n|" + "---|" * len(COLS) + "\n")
        for r in rows:
            f.write("| " + " | ".join(str(r.get(c, "-")).replace("\n", " ") or "-" for c in COLS) + " |\n")
        f.write("\n## Details\n")
        for r in rows:
            f.write(f"\n### {r['ID']}\n\n{r.get('_details', '').strip() or '-'}\n")


def read_block_file(blk):
    p = os.path.join(DOCS, f"{blk}.md")
    if not os.path.exists(p):
        return [], {}, []
    rows, details, problems = [], {}, []
    lines = open(p).read().splitlines()
    i, hdr = 0, None
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("| ID |"):
            hdr = [c.strip() for c in ln.strip().strip("|").split("|")]
            if hdr != COLS:
                problems.append(f"{blk}.md: table header is not {COLS}")
            i += 2
            while i < len(lines) and lines[i].startswith("|"):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                if len(cells) != len(COLS):
                    problems.append(f"{blk}.md line {i + 1}: {len(cells)} cells, want {len(COLS)}")
                else:
                    r = dict(zip(COLS, cells))
                    r["_line"] = i + 1
                    rows.append(r)
                i += 1
            continue
        m = re.match(r"^### (\S+)\s*$", ln)
        if m:
            j = i + 1
            while j < len(lines) and not re.match(r"^### \S+\s*$", lines[j]):
                j += 1
            details[m.group(1)] = "\n".join(lines[i + 1:j]).strip()
            i = j
            continue
        i += 1
    for r in rows:
        r["_details"] = details.get(r["ID"], "")
    return rows, details, problems


def all_rows():
    out, probs = [], []
    for b in BLOCKS:
        rows, _, p = read_block_file(b)
        probs += p
        for r in rows:
            r["_blk"] = b
            out.append(r)
    return out, probs


def rtl_errata():
    """{ID: (path, line, text)} for every `ERRATUM <ID>` cited in rtl/ or tb/ (first citation)."""
    out = {}
    p = subprocess.run(["git", "-C", ROOT, "grep", "-n", "-E", r"ERRATUM[ ]+[A-Z]+(-[A-Z])?-?[0-9]+[a-z]?",
                        "--", "rtl", "tb"], capture_output=True, text=True)
    for ln in p.stdout.splitlines():
        path, lno, text = ln.split(":", 2)
        for m in re.finditer(r"ERRATUM[ ]+([A-Z]+(?:-[A-Z])?-?[0-9]+[a-z]?)", text):
            out.setdefault(m.group(1), (path, int(lno), text.strip()))
    return out


# ------------------------------------------------------------------------ check
def cmd_check(_a):
    rows, errs = all_rows()
    seen = {}
    for r in rows:
        where = f"{r['_blk']}.md line {r['_line']}"
        rid = r["ID"]
        if rid in seen:
            errs.append(f"{where}: {rid} already defined in {seen[rid]}")
        seen[rid] = where
        if r["Status"] not in STATUS:
            errs.append(f"{where}: {rid} status '{r['Status']}' not in {STATUS}")
        if r["Prio"] not in PRIO:
            errs.append(f"{where}: {rid} prio '{r['Prio']}' not in {PRIO}")
        if r["Status"] in OPENISH and r["Prio"] not in ("P1", "P2", "P3"):
            errs.append(f"{where}: {rid} is {r['Status']} without P1..P3")
        if not (r["Found"] == "legacy" or re.match(r"^20\d\d-\d\d-\d\d$", r["Found"])):
            errs.append(f"{where}: {rid} Found '{r['Found']}' is not YYYY-MM-DD or legacy")
        if r["Status"] == "FIXED":
            fi = r["Fixed-in"]
            if fi != "legacy" and not re.match(r"^[0-9a-f]{7,40}$", fi):
                errs.append(f"{where}: {rid} FIXED needs Fixed-in = commit SHA (or legacy)")
            if fi != "legacy" and r["Regression test"] in ("", "-"):
                errs.append(f"{where}: {rid} FIXED needs the regression test that proves it")
        if not r.get("_details"):
            errs.append(f"{where}: {rid} has no '### {rid}' entry under Details")
    for eid, (path, lno, _) in sorted(rtl_errata().items()):
        if eid not in seen:
            errs.append(f"{path}:{lno}: ERRATUM {eid} is cited but not in the register "
                        f"(run `bugs.py backfill-errata`)")
    n_open = sum(1 for r in rows if r["Status"] in OPENISH)
    for e in errs:
        print("ERROR", e)
    print(f"bugs check: {len(rows)} IDs in {len(BLOCKS)} files, {n_open} open, "
          f"{len(errs)} error(s) -> {'PASS' if not errs else 'FAIL'}")
    return 1 if errs else 0


# ------------------------------------------------------------------------ index
def cmd_index(_a):
    rows, probs = all_rows()
    sha = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], capture_output=True,
                         text=True).stdout.strip()
    p = os.path.join(ROOT, "Docs", "BUGS.md")
    with open(p, "w") as f:
        f.write("# GARUDA SoC: bug register (index)\n\n")
        f.write("<!-- GENERATED by tools/bugs/bugs.py index. Do not edit by hand: edit "
                "Docs/bugs/<blk>.md and regenerate. -->\n\n")
        f.write("One file per block under [`Docs/bugs/`](bugs/); this page is generated from them "
                f"(at {sha}, {dt.date.today().isoformat()}). Process: "
                "[`Docs/handbook/H3_bugs.md`](handbook/H3_bugs.md). The register as it stood before "
                "the split (b90b481) is kept verbatim in "
                "[`Docs/bugs/HISTORY_2026.md`](bugs/HISTORY_2026.md); the ID-by-ID mapping is in "
                "[`Docs/bugs/MIGRATION_2026-10-11.md`](bugs/MIGRATION_2026-10-11.md).\n\n")
        f.write(f"Priorities: {PRIO_TEXT}\n\n## Open items by priority\n\n")
        op = [r for r in rows if r["Status"] in OPENISH]
        for pr in ("P1", "P2", "P3"):
            sel = [r for r in op if r["Prio"] == pr]
            f.write(f"### {pr} ({len(sel)})\n\n")
            if sel:
                f.write("| ID | Block | Status | Title |\n|---|---|---|---|\n")
                for r in sel:
                    f.write(f"| {r['ID']} | [{r['_blk']}](bugs/{r['_blk']}.md) | {r['Status']} | {r['Title']} |\n")
            f.write("\n")
        f.write("## Counts per block\n\n| Block | Owner | " + " | ".join(STATUS) + " | Total |\n|"
                + "---|" * (len(STATUS) + 3) + "\n")
        for b, (name, owner) in BLOCKS.items():
            br = [r for r in rows if r["_blk"] == b]
            f.write(f"| [{b}](bugs/{b}.md) | {owner} | "
                    + " | ".join(str(sum(1 for r in br if r["Status"] == s) or "") for s in STATUS)
                    + f" | {len(br)} |\n")
        f.write(f"| **all** | | " + " | ".join(str(sum(1 for r in rows if r["Status"] == s)) for s in STATUS)
                + f" | {len(rows)} |\n")
    print(f"wrote {os.path.relpath(p, ROOT)}: {len(rows)} IDs, {sum(1 for r in rows if r['Status'] in OPENISH)} open")
    return 0


def cmd_open(a):
    rows, _ = all_rows()
    for r in rows:
        if r["Status"] in OPENISH and (not a.prio or r["Prio"] == a.prio):
            print(f"{r['Prio']}  {r['Status']:<14} {r['_blk']:<10} {r['ID']:<9} {r['Title'][:90]}")
    return 0


def cmd_backfill(_a):
    rows, _ = all_rows()
    have = {r["ID"] for r in rows}
    add = {}
    for eid, (path, lno, text) in sorted(rtl_errata().items()):
        if eid in have:
            continue
        parts = path.split("/")
        blk = RTL_DIR_BLOCK.get(parts[1], "flow") if parts[0] in ("rtl", "tb") else "flow"
        if eid.startswith("DSU-") or eid.startswith("OVF-"):
            blk = "dsu"
        title = re.sub(r"^.*ERRATUM[ ]+" + re.escape(eid) + r"[):\s-]*", "", text).strip(" */") or "-"
        title = title.replace("|", "/")[:110]
        add.setdefault(blk, []).append({
            "ID": eid, "Title": title, "Status": "FIXED", "Prio": "-", "Found-by": "RTL comment",
            "Found": "legacy", "Fixed-in": "legacy", "Regression test": "-",
            "Evidence": f"{path}:{lno}", "Formerly": "-",
            "_details": (f"*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, "
                         f"never in the register. First citation `{path}:{lno}`:*\n\n```\n{text}\n```")})
    for blk, new in add.items():
        cur, _, _ = read_block_file(blk)
        write_block_file(blk, cur + new)
        print(f"{blk}: +{len(new)} ({', '.join(r['ID'] for r in new)})")
    if not add:
        print("nothing to back-fill")
    return 0


def _fields(pairs):
    out = {}
    for kv in pairs:
        k, _, v = kv.partition("=")
        if k not in COLS:
            sys.exit(f"unknown field '{k}' (fields: {COLS})")
        out[k] = v.replace("|", "/")
    return out


def cmd_set(a):
    for b in BLOCKS:
        rows, _, _ = read_block_file(b)
        for r in rows:
            if r["ID"] == a.id:
                r.update(_fields(a.fields))
                if a.note:
                    r["_details"] = (r.get("_details", "").rstrip() +
                                     f"\n\n**{dt.date.today().isoformat()}:** {a.note}")
                write_block_file(b, rows)
                print(f"{a.id} ({b}): " + ", ".join(f"{k}={v}" for k, v in _fields(a.fields).items()))
                return 0
    sys.exit(f"{a.id} not found")


def cmd_add(a):
    rows, _, _ = read_block_file(a.blk)
    if any(r["ID"] == a.id for b in BLOCKS for r in read_block_file(b)[0]):
        sys.exit(f"{a.id} already exists")
    r = {c: "-" for c in COLS}
    r.update({"ID": a.id, "Found": dt.date.today().isoformat()})
    r.update(_fields(a.fields))
    r["_details"] = a.details or "-"
    write_block_file(a.blk, rows + [r])
    print(f"added {a.id} to {a.blk}.md")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("check")
    sp.add_parser("index")
    o = sp.add_parser("open")
    o.add_argument("--prio")
    sp.add_parser("backfill-errata")
    st = sp.add_parser("set")
    st.add_argument("id")
    st.add_argument("fields", nargs="*")
    st.add_argument("--note")
    ad = sp.add_parser("add")
    ad.add_argument("blk", choices=list(BLOCKS))
    ad.add_argument("id")
    ad.add_argument("fields", nargs="*")
    ad.add_argument("--details")
    a = ap.parse_args()
    return {"check": cmd_check, "index": cmd_index, "open": cmd_open,
            "backfill-errata": cmd_backfill, "set": cmd_set, "add": cmd_add}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
