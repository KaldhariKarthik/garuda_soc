#!/usr/bin/env python3
"""
unr_check.py - are the coverage waivers of a block confirmed by JasperGold?

    python3 tools/gen/unr_check.py <exclusions.tcl> <jg run.log> <imc detail report> [<jg vacuity log>]

Reads the waivers of flow/cov/<blk>_exclusions.tcl, the item list that
flow/formal/unr_block.tcl printed (JasperGold coverage app, stimuli coverage, all
inputs free), and IMC's detailed block and expression report of the same block
(flow/formal/unr_block.sh makes both). For each waiver:

    CONFIRMED   JasperGold says no input sequence reaches the item (dead code)
    REACHABLE   JasperGold found a way: the waiver is wrong, the item needs a test
    RESET ONLY  the item is in a reset branch; JasperGold holds reset off, so this
                is not a verdict and the waiver is not confirmed
    NOT CHECKED the item is not in JasperGold's list (a property module, or code
                under `ifndef SYNTHESIS: the run leaves both out), or the two tools
                describe it too differently to match

How the items are matched:
    toggle      by instance and signal bit
    block       IMC's block number -> its source line (IMC's report) -> JasperGold's
                statement and branch items that start on that line; if there is
                none, the smallest branch that contains the line
    expression  by source line: the row in which every term is true (the row that
                takes the branch) must be dead; or, when the two tools write the
                rows differently, as many rows must be dead in JasperGold as
                simulation never hit; anything else is NOT CHECKED
    assertion   by name, in the log of flow/formal/vacuity_block.tcl (property app):
                the precondition of an assertion, or a cover itself, proven
                unreachable

Exit status 1 if any waiver is REACHABLE.
"""
import re
import sys


def read_jg(log):
    """-> list of (status, type, instance, first line, last line, cause, description)"""
    items = []
    for l in open(log, errors="replace"):
        if not l.startswith("ITEM|"):
            continue
        _, st, typ, inst, _file, loc, cause, desc = l.rstrip("\n").split("|", 7)
        m = re.match(r"\((\d+),\d+\)-\((\d+),\d+\)", loc)
        items.append((st, typ, inst, int(m.group(1)) if m else 0, int(m.group(2)) if m else 0, cause, desc))
    return items


def read_imc(report):
    """-> blocks[(instance, number)] = (line, kind, count);
          exprs[(instance, 'i.j')] = (line, [(row, hit, rval, terms)])"""
    blocks, exprs, inst, cur = {}, {}, None, None
    for l in open(report, errors="replace"):
        m = re.match(r"^Instance name: (\S+)", l)
        if m:
            inst, cur = m.group(1), None
            continue
        m = re.match(r"^(\d+)\s+(\d+)\s+(\d+)\s+(code block|true part of|false part of|implicit else|a case item of|\S.*?)\s+\d+\s", l)
        if m and inst:
            blocks[(inst, int(m.group(2)))] = (int(m.group(3)), m.group(4), int(m.group(1)))
            continue
        m = re.match(r"^index: (\d+\.\d+) grade: \S+ \(\d+/\d+\) line: (\d+)", l)
        if m and inst:
            cur = (inst, m.group(1))
            exprs[cur] = (int(m.group(2)), [])
            continue
        m = re.match(r"^(\d+\.\d+)\.(\d+)\s+\|\s+(\d+)\s+\|(?:\s+(\d)\s+\|)?\s+(.*)$", l)
        if m and cur and m.group(1) == cur[1]:
            exprs[cur][1].append((int(m.group(2)), int(m.group(3)), m.group(4), m.group(5).split()))
    return blocks, exprs


def verdict(found):
    if not found:
        return "NOT CHECKED"
    if any(i[0] == "covered" for i in found):
        return "REACHABLE"
    if all(i[0] == "deadcode" for i in found):
        return "CONFIRMED"
    return "RESET ONLY"


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    wfile, log, imc = sys.argv[1:4]
    vac = {}
    if len(sys.argv) > 4:
        for l in open(sys.argv[4], errors="replace"):
            if l.startswith("VAC|"):
                p = l.rstrip("\n").split("|")
                vac[(p[1], p[2])] = p[3]
    items = read_jg(log)
    if not items:
        sys.exit("no ITEM line in %s: was it made by flow/formal/unr_block.tcl?" % log)
    blocks, exprs = read_imc(imc)
    tops = sorted(set(k[0].split(".")[0] for k in blocks) | set(k[0].split(".")[0] for k in exprs))

    def rel(inst):                      # IMC's "top.u_x" -> JasperGold's "u_x"
        for t in tops:
            if inst == t:
                return ""
            if inst.startswith(t + "."):
                return inst[len(t) + 1:]
        return inst.split(".", 1)[1] if "." in inst else ""

    tog = {}
    for it in items:
        m = re.match(r'toggle for signal bit "([^"]+)"', it[6])
        if m:
            tog.setdefault(m.group(1), []).append(it)      # the name carries its path below the top
    count = {}
    lines = []

    def note(kind, v, text):
        count.setdefault(kind, {}).setdefault(v, 0)
        count[kind][v] += 1
        if v != "CONFIRMED":
            lines.append("  %-11s %-10s %s" % (v, kind, text))

    for l in open(wfile):
        m = re.match(r'^exclude -inst (\S+) -(\w+) (\S+)', l)
        if not m:
            continue
        inst, kind, what = m.group(1).replace("\\", ""), m.group(2), m.group(3).replace("\\", "")
        r = rel(inst)
        if kind == "assertion":
            st = vac.get((inst, what))
            v = {"unreachable": "CONFIRMED", "covered": "REACHABLE"}.get(st, "NOT CHECKED")
            note(kind, v, "%s %s (%s)" % (inst, what, "JasperGold: %s" % st if st else "no property-app run given"))
        elif "_sva" in inst.split(".")[-1]:
            note(kind, "NOT CHECKED", "%s %s (inside a property module)" % (inst, what))
        elif kind == "toggle":
            name = (r + "." if r else "") + what
            found = tog.get(name) or [i for n, v in tog.items() if n.startswith(name + "[") for i in v]
            note(kind, verdict(found), "%s %s" % (inst, what))
        elif kind == "block":
            b = blocks.get((inst, int(what)))
            if not b:
                note(kind, "NOT CHECKED", "%s block %s (not in IMC's report)" % (inst, what))
                continue
            line, bkind, cnt = b
            code = [i for i in items if i[2] == r and i[1] in ("statement", "branch")]
            # an implicit else or default has no line of its own: both tools put it on the line of
            # its "if" or "case", and JasperGold names it the same way
            implicit = ("implicit else", "implicit default")
            if bkind in implicit:
                found = [i for i in code if i[3] == line and i[6] == bkind]
            else:
                found = [i for i in code if i[3] == line and i[6] not in implicit]
            if not found:
                around = sorted((i for i in code if i[1] == "branch" and i[3] <= line <= i[4] and i[4] > i[3]), key=lambda i: i[4] - i[3])
                found = around[:1]
            v = verdict(found)
            note(kind, v, "%s block %s, line %d, %s%s" % (inst, what, line, bkind,
                 "" if found else " (no item of JasperGold there: code under `ifndef SYNTHESIS, which the run leaves out)"))
        elif kind == "expression":
            e = exprs.get((inst, what))
            if not e:
                note(kind, "NOT CHECKED", "%s expression %s (not in IMC's report)" % (inst, what))
                continue
            line, rows = e
            unhit = [x for x in rows if x[1] == 0]
            jg = [i for i in items if i[2] == r and i[1] == "expression" and i[3] == line]
            alltrue = [i for i in jg if "~" not in i[6].split("truthtable")[-1]]
            takes = len(unhit) == 1 and unhit[0][2] == "1" and "-" not in unhit[0][3]
            if not jg:
                note(kind, "NOT CHECKED", "%s expression %s, line %d (no item of JasperGold there: code under `ifndef SYNTHESIS)" % (inst, what, line))
            elif takes and alltrue:
                note(kind, verdict(alltrue), "%s expression %s, line %d, the row that takes the branch" % (inst, what, line))
            elif unhit and len(unhit) == sum(1 for i in jg if i[0] == "deadcode") and all(i[0] != "unreachable" for i in jg):
                # the same number of rows that simulation never hit and that JasperGold cannot reach
                note(kind, "CONFIRMED", "%s expression %s, line %d" % (inst, what, line))
            else:
                note(kind, "NOT CHECKED", "%s expression %s, line %d: %d row(s) not hit in simulation, JasperGold has %d of %d rows dead there; rows not matched one to one"
                     % (inst, what, line, len(unhit), sum(1 for i in jg if i[0] != "covered"), len(jg)))
        else:
            note(kind, "NOT CHECKED", "%s %s (a kind of waiver this script does not know)" % (inst, what))

    out = ["Waivers of %s against JasperGold" % wfile,
           "JasperGold: %d cover items; %d covered, %d dead code, %d reachable only in reset"
           % (len(items), sum(1 for i in items if i[0] == "covered"), sum(1 for i in items if i[0] == "deadcode"),
              sum(1 for i in items if i[0] == "unreachable")),
           "",
           "%-11s %6s %10s %10s %11s %12s" % ("kind", "total", "CONFIRMED", "REACHABLE", "RESET ONLY", "NOT CHECKED")]
    bad = 0
    for kind in ("toggle", "block", "expression", "assertion"):
        c = count.get(kind, {})
        if c:
            out.append("%-11s %6d %10d %10d %11d %12d" % (kind, sum(c.values()), c.get("CONFIRMED", 0), c.get("REACHABLE", 0),
                                                         c.get("RESET ONLY", 0), c.get("NOT CHECKED", 0)))
            bad += c.get("REACHABLE", 0)
    if lines:
        out += ["", "Not confirmed, one by one:"] + lines
    sys.stdout.write("\n".join(out) + "\n")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
