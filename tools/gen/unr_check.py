#!/usr/bin/env python3
"""
unr_check.py - are the coverage waivers of a block confirmed by JasperGold?

    python3 tools/gen/unr_check.py <exclusions.tcl> <top instance> <jg run.log> [<result file>]

Reads the toggle waivers of flow/cov/<blk>_exclusions.tcl and the item lists that
flow/formal/unr_block.tcl printed (JasperGold coverage app, stimuli coverage, all
inputs free). A waived bit is CONFIRMED when JasperGold says no input sequence
toggles it (status deadcode or unreachable), and REACHABLE when JasperGold found
a way: then the waiver is wrong and the bit needs a test. Exit status 1 if any
waiver is REACHABLE.

Block and expression waivers are given by IMC's own index numbers, which
JasperGold does not use; they are counted and not matched one by one.
"""
import re
import sys


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    wfile, top, log = sys.argv[1:4]
    status, cur, counts = {}, None, {}
    for l in open(log, errors="replace"):
        m = re.match(r"^==== ITEMS (\w+) ====", l)
        if m:
            # only these three are verdicts on reachability
            cur = m.group(1) if m.group(1) in ("covered", "unreachable", "deadcode") else None
            continue
        if l.startswith("==== END"):
            cur = None
        if cur and re.match(r"^\|[A-Z]", l):
            counts[cur] = counts.get(cur, 0) + 1
            m = re.search(r'toggle for signal bit "([^"]+)"', l)
            if m:
                status[m.group(1)] = cur
    if not status:
        sys.exit("no item list in %s: was it made by flow/formal/unr_block.tcl?" % log)
    tog, other = [], 0
    for l in open(wfile):
        m = re.match(r'^exclude -inst (\S+) -(\w+) (\S+)', l)
        if not m:
            continue
        if m.group(2) != "toggle":
            other += 1
            continue
        path = m.group(1)[len(top):].lstrip(".") if m.group(1).startswith(top) else m.group(1)
        tog.append((path + "." if path else "") + m.group(3).replace("\\", ""))
    conf, reach, skipped = [], [], []
    for name in tog:
        keys = [name] if name in status else [k for k in status if k.startswith(name + "[")]
        if not keys:
            skipped.append(name)
        elif all(status[k] != "covered" for k in keys):
            conf.append(name)
        else:
            reach.append(name)
    out = []
    out.append("Waivers of %s against JasperGold (%s)" % (wfile, log))
    out.append("JasperGold cover items: " + ", ".join("%s %d" % (k, counts[k]) for k in sorted(counts)))
    out.append("  of them toggle bits: %d, not reachable: %d" % (len(status), sum(1 for v in status.values() if v != "covered")))
    out.append("Toggle waivers: %d" % len(tog))
    out.append("  CONFIRMED not reachable : %d" % len(conf))
    out.append("  REACHABLE (waiver wrong): %d" % len(reach))
    out.append("  not in JasperGold's list: %d (inside a property module, which the run leaves out)" % len(skipped))
    for n in reach:
        out.append("    REACHABLE: " + n)
    for n in skipped:
        out.append("    not in list: " + n)
    out.append("Block, expression and assertion waivers, not matched one by one: %d" % other)
    text = "\n".join(out) + "\n"
    sys.stdout.write(text)
    if len(sys.argv) > 4:
        open(sys.argv[4], "w").write(text)
    return 1 if reach else 0


if __name__ == "__main__":
    sys.exit(main())
