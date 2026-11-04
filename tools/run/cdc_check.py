#!/usr/bin/env python3
"""cdc_check.py -- structural clock-domain-crossing check of the whole chip (Track A, 2026-11-01).

    python3.12 tools/run/cdc_check.py flow/2_static/cdc_chip.toml

Netlist: Yosys (read, hierarchy, proc, flatten, opt_clean) of the synthesis top with the SRAMs as
black boxes, as the ASAP7 flow builds it. Each flop's clock is traced back through buffers,
inverters, muxes and divider flops (Q -> CLK) to a top-level port: that port is the flop's CLOCK
ROOT. Roots in one `[[family]]` are synchronous (refclk, its dividers hclk / pclk / aon_clk: the
SDC's generated clocks, timed by STA); different families are asynchronous.

A crossing is a path from a flop (or a non-clock input port declared asynchronous) of one family to
the D or enable of a flop of another. Rules (the usual structural CDC sign-off rules):
  R1  the first flop it reaches is a SYNCHRONISER first stage: its D is the source itself, with no
      logic in between (a combinational path can glitch and be sampled mid-transition);
  R2  that first stage feeds exactly one flop, in its own clock domain (the second stage), and no
      logic (a metastable value must not fan out);
  R3  every other crossing is a VIOLATION unless the manifest waives it with a reason (a multi-bit
      payload held stable and qualified by a synchronised strobe, as in dmi_cdc).
Reported: the synchronisers found (with their source and the SDC exception, if the manifest
lists one), the violations, and stale waivers. A structural check: it says what CAN go wrong, not
how likely it is (MTBF needs the 28 nm cells: flow/pdk_arrival.md).
"""
import fnmatch
import json
import os
import subprocess
import sys
import tomllib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FF = {"$dff", "$dffe", "$adff", "$adffe", "$sdff", "$sdffe", "$sdffce", "$dffsr", "$dffsre",
      "$aldff", "$aldffe", "$dlatch", "$adlatch"}
PASS_CELLS = {"$not", "$pos", "$buf", "$mux", "$and", "$or", "$xor", "$xnor", "$logic_not",
              "$_NOT_", "$_BUF_", "$_MUX_", "$_AND_", "$_OR_"}


def expand_flist(path):
    out = subprocess.run([sys.executable, os.path.join(ROOT, "scripts/expand_filelist.py"), path],
                         cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    inc = subprocess.run([sys.executable, os.path.join(ROOT, "scripts/expand_filelist.py"), path, "--incdirs"],
                         cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    return out, inc


def netlist(cfg):
    files, incs = expand_flist(cfg["flist"])
    files = [f for f in files if not any(fnmatch.fnmatch(f, x) for x in cfg.get("exclude", []))]
    repl = cfg.get("replace", {})                # negative controls: a planted defect swapped in
    missing = sorted(set(repl) - set(files))
    if missing:
        sys.exit(f"cdc_check: replace key(s) not in the file list: {missing}")
    files = [repl.get(f, f) for f in files]
    files += cfg.get("extra", [])
    oss = os.environ.get("OSS_CAD", os.path.expanduser("~/tools/oss-cad-suite"))
    out = os.path.join(ROOT, "logs", "common", "raw", f"cdc_{cfg['top']}.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    defs = " ".join(f"-D{d}" for d in ["SYNTHESIS"] + cfg.get("defines", []))
    incl = " ".join(f"-I{os.path.join(ROOT, i[2:] if i.startswith('-I') else i)}" for i in incs)
    script = (f"read_verilog -sv {defs} {incl} " + " ".join(os.path.join(ROOT, f) for f in files)
              + f"; hierarchy -top {cfg['top']}; proc; flatten; opt_clean; write_json {out}")
    r = subprocess.run([os.path.join(oss, "bin", "yosys"), "-q", "-p", script], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"cdc_check: yosys failed:\n{r.stderr[-3000:]}")
    return json.load(open(out))["modules"][cfg["top"]]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    cfg = tomllib.load(open(os.path.join(ROOT, sys.argv[1]), "rb"))
    m = netlist(cfg)
    names = {}
    for n, w in m["netnames"].items():
        user = not n.startswith("$")
        for b in w["bits"]:
            if isinstance(b, int) and (user or b not in names):
                names[b] = n
    drv = {}                                     # bit -> (cellname, cell)
    loads = {}                                   # bit -> [(cellname, pin)]
    for cn, c in m["cells"].items():
        for pin, d in c.get("port_directions", {}).items():
            for b in c["connections"][pin]:
                if not isinstance(b, int):
                    continue
                if d == "output":
                    drv[b] = (cn, c)
                else:
                    loads.setdefault(b, []).append((cn, pin))
    port_of = {}
    for p, pd in m["ports"].items():
        for b in pd["bits"]:
            if isinstance(b, int):
                port_of[b] = p
    ffs = {cn: c for cn, c in m["cells"].items() if c["type"] in FF}
    if not ffs:
        sys.exit("cdc_check: no flops (wrong top?)")
    q_of = {}
    for cn, c in ffs.items():
        for b in c["connections"].get("Q", []):
            q_of[b] = cn

    fam_of_port = {}
    for f in cfg["family"]:
        for p in f["roots"]:
            fam_of_port[p] = f["name"]
    async_in = {p: d for p, d in cfg.get("async_input", {}).items()}

    memo = {}

    def clock_root(bit, depth=0):
        if bit in memo:
            return memo[bit]
        memo[bit] = "?"
        if depth > 200:
            return "?"
        if bit in port_of:
            r = port_of[bit]
        elif bit in q_of:                         # a divider flop or a clock-gate latch: its clock's root
            cc = ffs[q_of[bit]]["connections"]
            r = clock_root((cc.get("CLK") or cc.get("EN"))[0], depth + 1)
        elif bit in drv:
            cn, c = drv[bit]
            roots = set()
            for pin, d in c["port_directions"].items():
                if d == "input" and pin not in ("S",):     # a clock mux's select is not a clock
                    for b in c["connections"][pin]:
                        if isinstance(b, int):
                            rr = clock_root(b, depth + 1)
                            if rr not in ("?", "const"):
                                roots.add(rr)
            r = sorted(roots)[0] if len(roots) == 1 else ("|".join(sorted(roots)) if roots else "const")
        else:
            r = "const"
        memo[bit] = r
        return r

    def family(root):
        parts = root.split("|")
        fams = {fam_of_port.get(p, f"?{p}") for p in parts}
        return fams.pop() if len(fams) == 1 else "|".join(sorted(fams))

    dom = {}
    for cn, c in ffs.items():
        clk = c["connections"].get("CLK") or c["connections"].get("EN")
        dom[cn] = family(clock_root(clk[0])) if clk else "none"

    def qname(cn):
        return names.get(ffs[cn]["connections"]["Q"][0], cn)

    # fan-in of every flop D/EN: (direct?, source) where source is a flop or an async input port
    def sources(bits):
        out, seen, todo = set(), set(), [(b, True) for b in bits]
        while todo:
            b, direct = todo.pop()
            if not isinstance(b, int) or (b, direct) in seen:
                continue
            seen.add((b, direct))
            if b in q_of:
                out.add(("ff", q_of[b], direct))
            elif b in port_of:
                if port_of[b] in async_in:
                    out.add(("port", port_of[b], direct))
            elif b in drv:
                cn, c = drv[b]
                for pin, d in c["port_directions"].items():
                    if d == "input":
                        todo += [(x, False) for x in c["connections"][pin]]
        return out

    waive = {(w["to"], w["from"]): w for w in cfg.get("waiver", [])}
    used, viol, syncs = set(), [], []

    def bitname(b, cn):
        return names.get(b, cn)

    def waiver(dname, sname):
        return next((v for k, v in waive.items() if fnmatch.fnmatch(dname, k[0]) and fnmatch.fnmatch(sname, k[1])), None)

    first_stage = {}                     # Q bit of a first stage -> (cell, source name, source domain)
    # bit level: a multi-bit register (req_s[2:0]) is one cell; stage 1 -> stage 2 inside it is not logic
    for cn, c in ffs.items():
        d_dom = dom[cn]
        dbits = c["connections"].get("D", [])
        qbits = c["connections"].get("Q", [])
        groups = [(dbits[k], qbits[k] if k < len(qbits) else None, False) for k in range(len(dbits))]
        groups += [(b, None, True) for b in c["connections"].get("EN", [])]
        for dbit, qbit, is_en in groups:
            for kind, src, direct in sources([dbit]):
                s_dom = dom[src] if kind == "ff" else async_in[src]
                if s_dom == d_dom or "none" in (s_dom, d_dom):
                    continue
                sname = qname(src) if kind == "ff" else src
                dname = qname(cn)
                if direct and not is_en and qbit is not None:
                    first_stage[qbit] = (cn, sname, s_dom)
                    continue
                w = waiver(dname, sname)
                if w:
                    used.add((w["to"], w["from"]))
                else:
                    viol.append(f"R1 {dname} [{d_dom}] <- {sname} [{s_dom}] through logic")
    # R2: each first-stage bit feeds flop D pins of its own domain only (the second stage), no logic
    for qbit, (cn, sname, s_dom) in first_stage.items():
        fan = loads.get(qbit, [])
        ff_loads = [lc for lc, pin in fan if lc in ffs and pin == "D" and dom[lc] == dom[cn]]
        other = [(lc, pin) for lc, pin in fan if not (lc in ffs and pin == "D" and dom[lc] == dom[cn])]
        dname = qname(cn)
        w = waiver(dname, sname)
        if ff_loads and not other:
            syncs.append(f"SYNC  {dname} [{dom[cn]}] <- {sname} [{s_dom}] -> {qname(ff_loads[0])}")
        elif w:
            used.add((w["to"], w["from"]))
            syncs.append(f"WAIVED {dname} [{dom[cn]}] <- {sname} [{s_dom}] ({w['reason'][:80]})")
        else:
            viol.append(f"R2 {dname} [{dom[cn]}] <- {sname} [{s_dom}]: first-stage bit {bitname(qbit, cn)} fans out to "
                        f"{len(other)} non-synchroniser load(s): {sorted({m['cells'][l]['type'] for l, _ in other})}")
    stale = sorted(set(waive) - used)
    fams = {}
    for d in dom.values():
        fams[d] = fams.get(d, 0) + 1
    print(f"clock families: {fams}")
    for s in sorted(set(syncs)):
        print(s)
    for v in sorted(set(viol)):
        print("VIOLATION " + v)
    for s in stale:
        print(f"STALE WAIVER {s[0]} <- {s[1]}")
    n = len(set(viol)) + len(stale)
    verdict = "PASS" if n == 0 else "FAIL"
    print(f"cdc_check {cfg['top']}: {len(ffs)} flops, {len(set(syncs))} synchronisers, {len(set(viol))} violation(s), "
          f"{len(stale)} stale waiver(s) -> {verdict}")
    if cfg.get("block") and cfg.get("suite"):
        tsv = os.path.join(ROOT, "logs", cfg["block"], "summary", f"{cfg['suite']}.tsv")
        os.makedirs(os.path.dirname(tsv), exist_ok=True)
        with open(tsv, "w") as f:
            f.write(f"# cdc_check suite={cfg['suite']} top={cfg['top']} manifest={sys.argv[1]}\ntask\tresult\tclass\tdetail\n")
            for v in sorted(set(viol)):
                f.write(f"crossing\tFAIL\tUNEXPECTED\t{v}\n")
            for s in stale:
                f.write(f"waiver\tFAIL\tUNEXPECTED\tstale {s[0]} <- {s[1]}\n")
            f.write(f"cdc_{cfg['top']}\t{verdict}\t{'OK' if n == 0 else 'UNEXPECTED'}\t{len(ffs)} flops, {len(set(syncs))} synchronisers, {len(set(viol))} violations\n")
    return 1 if n else 0


if __name__ == "__main__":
    sys.exit(main())
