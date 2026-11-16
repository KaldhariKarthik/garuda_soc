#!/usr/bin/env python3
"""rtl_ports.py - module headers and instance connections of the chip's RTL (a light parser).

    python3 tools/rtl_ports.py modules            every module: file, ports (name, direction)
    python3 tools/rtl_ports.py instances          every instance: parent, module, name, .port(expr) list
    python3 tools/rtl_ports.py clkrst             clock/reset ports and what each instance ties to them

Reads the files of rtl/soc/filelist_chip.f. Used to plan the zero-waiver renames (HAL DIFCLK,
DIFRST, ALOWID); it understands the ANSI headers and named port connections this code base uses.
"""
import os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KW = set("""module endmodule input output inout wire reg logic integer parameter localparam assign always
always_ff always_comb always_latch begin end if else case casez casex endcase default for generate
endgenerate genvar function endfunction task endtask initial signed unsigned posedge negedge or and
not bind assert property cover assume""".split())


def strip_comments(t):
    t = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), t, flags=re.S)
    t = re.sub(r"//[^\n]*", "", t)
    t = re.sub(r'"(\\.|[^"\\])*"', '""', t)
    return t


def files():
    env = dict(os.environ)
    env.pop("LD_LIBRARY_PATH", None)
    out = subprocess.check_output(["python3", "scripts/expand_filelist.py", "rtl/soc/filelist_chip.f"], cwd=ROOT, env=env)
    return out.decode().split()


def match_paren(t, i):
    """t[i] == '(' ; return index of the matching ')'."""
    d = 0
    for j in range(i, len(t)):
        if t[j] == "(":
            d += 1
        elif t[j] == ")":
            d -= 1
            if d == 0:
                return j
    return -1


def modules(fs):
    mods = {}
    for f in fs:
        t = strip_comments(open(os.path.join(ROOT, f), errors="replace").read())
        for m in re.finditer(r"\bmodule\s+(\w+)\s*(#\s*\()?", t):
            name = m.group(1)
            i = m.end()
            if m.group(2):
                i = match_paren(t, m.end() - 1) + 1
            k = t.find("(", i)
            e = match_paren(t, k)
            hdr = t[k + 1:e]
            ports, dirn = [], None
            for piece in hdr.split(","):
                dm = re.search(r"\b(input|output|inout)\b", piece)
                if dm:
                    dirn = dm.group(1)
                ids = re.findall(r"[A-Za-z_]\w*", re.sub(r"\[[^\]]*\]", "", piece))
                ids = [x for x in ids if x not in KW]
                if ids:
                    ports.append((ids[-1], dirn))
            mods[name] = (f, ports)
    return mods


def instances(fs, mods):
    out = []
    for f in fs:
        t = strip_comments(open(os.path.join(ROOT, f), errors="replace").read())
        parents = [(m.start(), m.group(1)) for m in re.finditer(r"\bmodule\s+(\w+)", t)]
        for m in re.finditer(r"\b(\w+)\s*(#\s*\()?", t):
            mod = m.group(1)
            if mod not in mods or mod in KW:
                continue
            i = m.end()
            if m.group(2):
                e = match_paren(t, m.end() - 1)
                if e < 0:
                    continue
                i = e + 1
            n = re.match(r"\s*(\w+)\s*(\[[^\]]*\])?\s*\(", t[i:])
            if not n or n.group(1) in KW:
                continue
            k = i + n.end() - 1
            e = match_paren(t, k)
            body = t[k + 1:e]
            conns = re.findall(r"\.(\w+)\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)", body)
            par = [p for p in parents if p[0] < m.start()]
            out.append((f, par[-1][1] if par else "?", mod, n.group(1), [(a, b.strip()) for a, b in conns]))
    return out


CLKRST = re.compile(r"(clk|tck|rst|reset|RSTN|CLK|HRESETn|nReset|clr)", re.I)


def main():
    fs = files()
    mods = modules(fs)
    what = sys.argv[1] if len(sys.argv) > 1 else "clkrst"
    if what == "modules":
        for k, (f, ps) in sorted(mods.items()):
            print("%s\t%s\t%s" % (k, f, " ".join("%s:%s" % p for p in ps)))
    elif what == "instances":
        for f, par, mod, inst, conns in instances(fs, mods):
            print("%s\t%s\t%s\t%s\t%s" % (f, par, mod, inst, " ".join(".%s(%s)" % c for c in conns)))
    else:
        insts = instances(fs, mods)
        for k, (f, ps) in sorted(mods.items()):
            cr = [p for p, d in ps if CLKRST.search(p) and d == "input"]
            if not cr:
                continue
            print("%s  (%s)" % (k, f))
            for p in cr:
                ties = sorted(set("%s<-%s" % (par, dict(c).get(p, "?")) for _, par, mod, _, c in insts if mod == k))
                print("    %-16s %s" % (p, ", ".join(ties)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
