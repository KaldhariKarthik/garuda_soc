#!/usr/bin/env python3
"""rdc_check.py -- structural reset-domain-crossing check (Track A, 2026-11-01, DBG-9).

    python3.12 tools/run/rdc_check.py tb/debug/formal/rdc_dmi_cdc.toml

A flop F with an asynchronous reset R_F must not take, through combinational logic only, a
value from a flop G whose asynchronous reset R_G is a different net: R_G asserts at a time
unrelated to F's clock, so G changes under F's sampling edge (and a multi-bit G passes through
states it never holds, e.g. a counter 11 -> 10 -> 00) -- the glitch DBG-6 was meant to remove.
Exempt destinations: synchroniser stages (wires marked ASYNC_REG), which are built to sample an
asynchronous input. Exempt crossings: reset ordering declared in the manifest ([implies]: a source
domain whose reset always asserts the destination's reset too, e.g. POR -> DM reset, FC-1), so the
destination is in reset whenever the source can glitch. Module input ports are given a reset domain in the manifest. Every other
crossing is a violation unless the manifest waives it with a reason.

Netlist from Yosys (oss-cad-suite): read, proc, flatten, opt_clean, write_json. The check is
structural, so it states what can glitch, not how likely it is (that is MTBF, D3).
"""
import json
import os
import subprocess
import sys
import tomllib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FF_ASYNC = {"$adff", "$adffe", "$dffsr", "$dffsre", "$aldff", "$aldffe"}
FF_SYNC = {"$dff", "$dffe", "$sdff", "$sdffe", "$sdffce"}


def netlist(files, top, defines):
    oss = os.environ.get("OSS_CAD", os.path.expanduser("~/tools/oss-cad-suite"))
    out = os.path.join(ROOT, "logs", "common", "raw", f"rdc_{top}.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    d = " ".join(f"-D{x}" for x in defines)
    script = (f"read_verilog -sv {d} " + " ".join(os.path.join(ROOT, f) for f in files)
              + f"; hierarchy -top {top}; proc; flatten; opt_clean; write_json {out}")
    r = subprocess.run([os.path.join(oss, "bin", "yosys"), "-q", "-p", script],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"rdc_check: yosys failed:\n{r.stderr[-2000:]}")
    return json.load(open(out))["modules"][top]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    cfg = tomllib.load(open(os.path.join(ROOT, sys.argv[1]), "rb"))
    m = netlist(cfg["files"], cfg["top"], cfg.get("defines", []))
    names = {}                                   # bit -> wire name (prefer user names)
    async_reg = set()
    for n, w in m["netnames"].items():
        user = not n.startswith("$")
        for b in w["bits"]:
            if isinstance(b, int) and (user or b not in names):
                names[b] = n
            if user and str(w.get("attributes", {}).get("ASYNC_REG", "")).strip('"').upper() in ("TRUE", "1", "00000000000000000000000000000001"):
                async_reg.add(b)
    port_dom = {}                                # port bit -> reset-domain name
    for p, dom in cfg.get("port_domain", {}).items():
        if p not in m["ports"]:
            sys.exit(f"rdc_check: port_domain names no port: {p}")
        for b in m["ports"][p]["bits"]:
            port_dom[b] = dom
    rst_name = {}                                # reset net bit -> domain name (via ports)
    for p, dom in cfg.get("reset_domain", {}).items():
        if p not in m["ports"]:
            sys.exit(f"rdc_check: reset_domain names no port: {p}")
        for b in m["ports"][p]["bits"]:
            rst_name[b] = dom
    drivers, ffs = {}, []                        # bit -> cell; flop list
    for cn, c in m["cells"].items():
        for pin, dirn in c.get("port_directions", {}).items():
            if dirn == "output":
                for b in c["connections"][pin]:
                    if isinstance(b, int):
                        drivers[b] = (cn, c)
        if c["type"] in FF_ASYNC | FF_SYNC:
            ffs.append((cn, c))
    if not ffs:
        sys.exit("rdc_check: no flops found (wrong top?)")

    def ff_domain(c):
        if c["type"] in FF_SYNC:
            return "none"
        r = c["connections"].get("ARST") or c["connections"].get("CLR") or c["connections"].get("AD") or []
        b = r[0] if r else None
        if b not in rst_name:
            # follow one inverter/buffer to a named reset port
            if b in drivers and drivers[b][1]["type"] in ("$not", "$logic_not", "$pos"):
                a = drivers[b][1]["connections"]["A"][0]
                b = a if a in rst_name else b
        return rst_name.get(b, f"net:{names.get(b, b)}")

    q_of = {}
    for cn, c in ffs:
        for b in c["connections"]["Q"]:
            q_of[b] = (cn, c)

    def sources(bits):
        seen, todo, out = set(), list(bits), set()
        while todo:
            b = todo.pop()
            if not isinstance(b, int) or b in seen:
                continue
            seen.add(b)
            if b in q_of:
                out.add(("ff", b))
            elif b in port_dom:
                out.add(("port", b))
            elif b in drivers:
                cn, c = drivers[b]
                for pin, dirn in c["port_directions"].items():
                    if dirn == "input":
                        todo += c["connections"][pin]
        return out

    implies = {k: set(v) for k, v in cfg.get("implies", {}).items()}
    waive = {(w["to"], w["from"]): w for w in cfg.get("waiver", [])}
    used, viol, rows = set(), [], []
    for cn, c in ffs:
        qn = names.get(c["connections"]["Q"][0], cn)
        if all(b in async_reg for b in c["connections"]["Q"] if isinstance(b, int)):
            continue                              # a synchroniser stage: built for this
        dom = ff_domain(c)
        if dom == "none":
            continue                              # no async reset: nothing can glitch it by reset
        ins = []
        for pin in ("D", "EN"):
            ins += c["connections"].get(pin, [])
        for kind, b in sources(ins):
            if kind == "ff":
                src = q_of[b][1]
                sdom, sname = ff_domain(src), names.get(b, "?")
            else:
                sdom, sname = port_dom[b], names.get(b, "?")
            if sdom in (dom, "none") or sname == qn or dom in implies.get(sdom, set()):
                continue
            key = (qn, sname)
            row = f"{qn} [{dom}] <- {sname} [{sdom}]"
            if key in waive:
                used.add(key)
                rows.append(f"WAIVED     {row}  ({waive[key]['reason']})")
            else:
                viol.append(row)
    for r in sorted(set(rows)):
        print(r)
    for v in sorted(set(viol)):
        print(f"VIOLATION  {v}")
    stale = sorted(set(waive) - used)
    for s in stale:
        print(f"STALE WAIVER {s[0]} <- {s[1]} (matches no crossing)")
    n = len(set(viol)) + len(stale)
    verdict = "PASS" if n == 0 else "FAIL"
    print(f"rdc_check {cfg['top']}: {len(ffs)} flops, {len(set(viol))} violation(s), "
          f"{len(set(rows))} waived, {len(stale)} stale waiver(s) -> {verdict}")
    # summary in the runner's TSV form, so regress_a_report sees the verdict (make -k keeps going
    # past a failing target; only the summary file reaches the report)
    if cfg.get("block") and cfg.get("suite"):
        tsv = os.path.join(ROOT, "logs", cfg["block"], "summary", f"{cfg['suite']}.tsv")
        os.makedirs(os.path.dirname(tsv), exist_ok=True)
        with open(tsv, "w") as f:
            f.write(f"# rdc_check suite={cfg['suite']} block={cfg['block']} top={cfg['top']} manifest={sys.argv[1]}\n")
            f.write("task\tresult\tclass\tdetail\n")
            for v in sorted(set(viol)):
                f.write(f"crossing\tFAIL\tUNEXPECTED\t{v}\n")
            for s_ in stale:
                f.write(f"waiver\tFAIL\tUNEXPECTED\tstale waiver {s_[0]} <- {s_[1]}\n")
            for r in sorted(set(rows)):
                f.write(f"crossing\tWAIVED\tOK\t{r[11:].split('  (')[0]}\n")
            f.write(f"rdc_{cfg['top']}\t{verdict}\t{'OK' if n == 0 else 'UNEXPECTED'}\t{len(ffs)} flops, {len(set(viol))} violations, {len(set(rows))} waived\n")
    return 1 if n else 0


if __name__ == "__main__":
    sys.exit(main())
