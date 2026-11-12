#!/usr/bin/env python3
"""
saif_to_activity.py -- RTL-simulation switching activity for the flattened
ORFS netlist (PD-14).

    python3 saif_to_activity.py <activity.saif> <scope> <out.tcl>

The SAIF comes from an RTL simulation, so it is hierarchical
(tb_chip/dut/u_core/u_soc/...). The ORFS netlist is flat: a net keeps its RTL
path as one name with '.' between the levels (u_soc.u_core.u_if.pc_q[3]).
OpenSTA's read_saif matches hierarchical paths only, so it finds almost none of
these nets. This script does the matching itself:

  1. read every NET under <scope> (for example tb_chip/dut/u_core);
  2. name it as the flat netlist does: the path below <scope>, joined with '.';
  3. write one Tcl line per net:  pd_activity <net> <density> <duty>
     density = TC / DURATION (toggles per ps, the library time unit),
     duty    = T1 / (T0 + T1).

pd_activity (power.tcl) applies it to the net's driver pin if the net exists
in the netlist, and counts the nets it found. OpenSTA propagates the annotated
activity to the logic that is not annotated.
Standard-library Python only.
"""
import re
import sys


def tokens(text):
    # SAIF: parentheses, quoted strings, and atoms; a backslash escapes the next character
    for m in re.finditer(r'\(|\)|"[^"]*"|(?:\\.|[^\s()"])+', text):
        yield m.group(0)


def parse(path):
    """Return (duration_in_timescale_units, timescale_ps, {flat_path: (t0, t1, tc)})."""
    toks = tokens(open(path, errors="replace").read())
    stack = []           # open list nodes: [keyword, ...children]
    nets = {}
    inst = []            # instance names from the root
    duration, ts_ps = None, 1.0
    cur = None
    for t in toks:
        if t == "(":
            node = []
            if cur is not None:
                cur.append(node)
            stack.append(node)
            cur = node
            continue
        if t == ")":
            node = stack.pop()
            kw = node[0] if node and isinstance(node[0], str) else None
            if kw == "INSTANCE":
                inst.pop()
            elif kw == "DURATION":
                duration = float(node[1])
            elif kw == "TIMESCALE":
                val = "".join(x for x in node[1:] if isinstance(x, str))
                m = re.match(r"([\d.]+)\s*([a-z]+)", val)
                if m:
                    ts_ps = float(m.group(1)) * {"fs": 1e-3, "ps": 1, "ns": 1e3, "us": 1e6}[m.group(2)]
            elif kw is not None and kw not in ("T0", "T1", "TX", "TC", "IG", "NET", "SAIFILE") \
                    and stack and stack[-1] and stack[-1][0] == "NET":
                vals = {}
                for ch in node[1:]:
                    if isinstance(ch, list) and len(ch) >= 2 and isinstance(ch[0], str):
                        try:
                            vals[ch[0]] = float(ch[1])
                        except ValueError:
                            pass
                if "TC" in vals:
                    name = kw.replace("\\", "")
                    nets["/".join(inst + [name])] = (vals.get("T0", 0.0), vals.get("T1", 0.0), vals["TC"])
            cur = stack[-1] if stack else None
            continue
        if cur is not None:
            cur.append(t)
            if len(cur) == 2 and cur[0] == "INSTANCE":
                inst.append(t.strip('"').replace("\\", ""))
    return duration, ts_ps, nets


def flat_name(path):
    # Verilator spells generate-block indices __BRA__ n __KET__
    return path.replace("__BRA__", "[").replace("__KET__", "]").replace("/", ".")


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    saif, scope, out = sys.argv[1:]
    duration, ts_ps, nets = parse(saif)
    if not duration:
        sys.exit("saif_to_activity: no DURATION in %s" % saif)
    dur_ps = duration * ts_ps
    pre = scope.strip("/") + "/"
    n = 0
    with open(out, "w") as f:
        f.write("# from %s, scope %s, duration %.0f ps\n" % (saif, scope, dur_ps))
        for path, (t0, t1, tc) in sorted(nets.items()):
            if not path.startswith(pre):
                continue
            net = flat_name(path[len(pre):])
            duty = t1 / (t0 + t1) if (t0 + t1) > 0 else 0.5
            f.write("pd_activity {%s} %.6e %.4f\n" % (net, tc / dur_ps, duty))
            n += 1
    print("saif_to_activity: %d nets under %s, duration %.1f us -> %s" % (n, scope, dur_ps / 1e6, out))


if __name__ == "__main__":
    main()
