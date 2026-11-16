#!/usr/bin/env python3
"""rename_rtl.py - apply the zero-waiver rename table (HAL ALOWID, IDLENG, NUMSUF, DIFCLK, DIFRST, ...).

    python3 tools/rename_rtl.py flow/2_static/renames.tsv [--dry]

Table rows (tab-separated; '#' starts a comment):
    port    MODULE  OLD  NEW   the port of MODULE: renamed in the module (header and body) and in
                               the named connection .OLD( of every instance of MODULE in rtl/, tb/,
                               flow/ (Verilog and SystemVerilog files)
    local   MODULE  OLD  NEW   an identifier inside MODULE only (a net, register, parameter, label
                               or instance name), in the module's text, its comments included
    param   MODULE  OLD  NEW   a parameter of MODULE: in the module, and in every #(.OLD(..)) override
    global  OLD     NEW        a name unique to the chip (instance, macro): whole words in every text
                               file of the TEXT_DIRS, so hierarchical paths in scripts follow
    module  OLD     NEW        a module: its definition and every instantiation, bind and
                               file-list line; the file itself is renamed by a `file` row
    file    OLD     NEW        git mv OLD NEW, and every reference to the path in rtl/ tb/ flow/
                               tools/ scripts/ sw/ Makefile, Design_Docs/ and Docs/guides/

Every rename is on whole words. History is never rewritten: logs/, Docs/bugs/, Docs/DECISIONS.md
and flow/signoff/runs/ keep the names they were written with.
"""
import os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIRS = ["rtl", "tb", "flow", "sw"]
TEXT_DIRS = ["rtl", "tb", "flow", "tools", "scripts", "sw", "Design_Docs", "Docs/guides", "Docs/coverage"]
TEXT_FILES = ["Makefile"]
NEVER = ("logs/", "Docs/bugs/", "Docs/DECISIONS.md", "flow/signoff/runs/", "flow/ZERO_WAIVER.md",
         "flow/2_static/renames.tsv", "rtl/third_party/HASHES.txt")
HDL = (".v", ".sv", ".svh", ".vh")


def tracked(dirs, exts=None):
    out = subprocess.check_output(["git", "ls-files"] + dirs, cwd=ROOT).decode().split("\n")
    out = [f for f in out if f and not f.startswith(NEVER) and os.path.isfile(os.path.join(ROOT, f))]
    if exts:
        out = [f for f in out if f.endswith(exts)]
    return out


def mask(t):
    """Comments and strings blanked (same length, newlines kept): positions match t."""
    out = list(t)
    i, n = 0, len(t)
    while i < n:
        if t.startswith("//", i):
            j = t.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif t.startswith("/*", i):
            j = t.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if t[k] != "\n":
                    out[k] = " "
            i = j
        elif t[i] == '"':
            j = i + 1
            while j < n and t[j] != '"':
                j += 2 if t[j] == "\\" else 1
            for k in range(i + 1, min(j, n)):
                out[k] = " "
            i = j + 1
        else:
            i += 1
    return "".join(out)


def match_paren(t, i):
    d = 0
    for j in range(i, len(t)):
        if t[j] == "(":
            d += 1
        elif t[j] == ")":
            d -= 1
            if d == 0:
                return j
    return -1


def module_spans(t, m):
    """(start, end) of each `module NAME ... endmodule` in masked text m."""
    out = {}
    for mm in re.finditer(r"\bmodule\s+(\w+)", m):
        e = m.find("endmodule", mm.end())
        out.setdefault(mm.group(1), []).append((mm.start(), len(m) if e < 0 else e + 9))
    return out


def word_sub(seg, old, new, keep_dot=False):
    """Whole-word rename; with keep_dot, `.old` (a child's port in a named connection, or a
    hierarchical reference) is left alone: it belongs to another module."""
    lb = r"(?<![\w$`.'])" if keep_dot else r"(?<![\w$`'])"   # ' : never the base of a literal (16'b0)
    return re.sub(lb + r"%s(?![\w])" % re.escape(old), new, seg)


def instance_spans(m, module):
    """(start, end) of the port-connection list of every instance of `module` in masked text m."""
    out = []
    for mm in re.finditer(r"(?<![\w.])%s\s*(#\s*\()?" % re.escape(module), m):
        i = mm.end()
        if mm.group(1):
            e = match_paren(m, mm.end() - 1)
            if e < 0:
                continue
            i = e + 1
        n = re.match(r"\s*(\w+)\s*(\[[^\]]*\])?\s*\(", m[i:])
        if not n or n.group(1) in ("module", "endmodule"):
            continue
        k = i + n.end() - 1
        e = match_paren(m, k)
        if e > 0:
            out.append((k, e))
    return out


def apply_rows(rows, dry):
    hdl = tracked(SRC_DIRS, HDL)
    texts = {}

    def get(f):
        if f not in texts:
            texts[f] = open(os.path.join(ROOT, f), errors="surrogateescape").read()
        return texts[f]

    changed = set()
    for row in rows:
        kind = row[0]
        if kind == "param":
            # a parameter: in the module, and in every #(.OLD(...)) override of an instance
            mod, old, new = row[1:4]
            for f in hdl:
                t = get(f)
                if mod not in t:
                    continue
                m = mask(t)
                for s, e in reversed(module_spans(t, m).get(mod, [])):
                    seg = word_sub(t[s:e], old, new, keep_dot=True)
                    if seg != t[s:e]:
                        t = t[:s] + seg + t[e:]
                        changed.add(f)
                        m = mask(t)
                for mm in reversed(list(re.finditer(r"(?<![\w.])%s\s*#\s*\(" % re.escape(mod), m))):
                    k = mm.end() - 1
                    e = match_paren(m, k)
                    seg = re.sub(r"\.%s(\s*\()" % re.escape(old), r".%s\1" % new, t[k:e])
                    if seg != t[k:e]:
                        t = t[:k] + seg + t[e:]
                        changed.add(f)
                texts[f] = t
            continue
        if kind == "global":
            # a name unique to the chip (an instance, a macro): whole words in every text file,
            # hierarchical paths in formal scripts and documents included
            old, new = row[1:3]
            for f in tracked(TEXT_DIRS) + TEXT_FILES:
                t = get(f)
                t2 = word_sub(t, old, new)
                if t2 != t:
                    texts[f] = t2
                    changed.add(f)
            continue
        if kind in ("port", "local"):
            mod, old, new = row[1:4]
            hit = False
            for f in hdl:
                t = get(f)
                if not re.search(r"\bmodule\s+%s\b" % re.escape(mod), t):
                    continue
                m = mask(t)
                for s, e in reversed(module_spans(t, m).get(mod, [])):
                    seg = word_sub(t[s:e], old, new, keep_dot=True)
                    if seg != t[s:e]:
                        t = t[:s] + seg + t[e:]
                        hit = True
                        m = mask(t)
                texts[f] = t
                changed.add(f)
            # `bind MOD sva_module inst ( ... );` - the expressions name MOD's own signals
            for f in hdl:
                t = get(f)
                if "bind" not in t or mod not in t:
                    continue
                m = mask(t)
                for bm in reversed(list(re.finditer(r"\bbind\s+%s\s+\w+\s*(#\s*\([^;]*?\))?\s*\w+\s*\(" % re.escape(mod), m))):
                    k = bm.end() - 1
                    e = match_paren(m, k)
                    seg = word_sub(t[k:e], old, new, keep_dot=True)
                    if seg != t[k:e]:
                        t = t[:k] + seg + t[e:]
                        changed.add(f)
                        hit = True
                texts[f] = t
            if not hit:
                print("rename_rtl: %s %s %s: not found in the module" % (kind, mod, old))
            if kind == "port":
                for f in hdl:
                    t = get(f)
                    if mod not in t:
                        continue
                    m = mask(t)
                    for s, e in reversed(instance_spans(m, mod)):
                        seg = re.sub(r"\.%s(\s*\()" % re.escape(old), r".%s\1" % new, t[s:e])
                        if seg != t[s:e]:
                            t = t[:s] + seg + t[e:]
                            changed.add(f)
                    texts[f] = t
        elif kind == "module":
            old, new = row[1:3]
            for f in tracked(TEXT_DIRS) + TEXT_FILES:
                t = get(f)
                t2 = word_sub(t, old, new)
                if t2 != t:
                    texts[f] = t2
                    changed.add(f)
        elif kind == "file":
            old, new = row[1:3]
            if not dry:
                if old in texts:                 # edits made to the file by earlier rows go with it
                    with open(os.path.join(ROOT, old), "w", errors="surrogateescape") as fh:
                        fh.write(texts.pop(old))
                subprocess.check_call(["git", "mv", old, new], cwd=ROOT)
            for f in tracked(TEXT_DIRS) + TEXT_FILES:
                f2 = new if f == old else f
                t = texts.pop(f, None)
                if t is None:
                    p = os.path.join(ROOT, f2)
                    if not os.path.isfile(p):
                        continue
                    t = open(p, errors="surrogateescape").read()
                t2 = t.replace(old, new)
                texts[f2] = t2
                if t2 != t:
                    changed.add(f2)
            changed.discard(old)
        else:
            raise SystemExit("rename_rtl: unknown row kind %r" % kind)
    for f in sorted(changed):
        if f not in texts:
            continue
        if dry:
            print("would change", f)
        else:
            with open(os.path.join(ROOT, f), "w", errors="surrogateescape") as fh:
                fh.write(texts[f])
    print("rename_rtl: %d rows, %d files %s" % (len(rows), len(changed), "to change" if dry else "changed"))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    rows = []
    for ln in open(sys.argv[1]):
        ln = ln.split("#", 1)[0].rstrip()
        if ln.strip():
            rows.append(ln.split())
    apply_rows(rows, "--dry" in sys.argv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
