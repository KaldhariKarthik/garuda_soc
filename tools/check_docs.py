#!/usr/bin/env python3
"""
check_docs.py -- is any .docx older than the .md it was exported from?

Design_Docs carries a .md and a .docx for most specifications, with no
generator between them: the .docx were produced by hand. That is two sources of
truth, and it is the condition that produced AUD-2 (the window-numbering error
that sat in four specs). See Design_Docs/README.md for the ruling: **the .md is
normative and the .docx is an export.**

This script makes the drift visible instead of leaving it to be discovered:

    --check    exit 1 if any .docx is older than its .md, or missing
    --report   print the table without failing

"Older" is by git commit date, not filesystem mtime, so a fresh clone gives the
same answer as the machine the edit was made on.

Regenerating (needs pandoc, which is not installed on the sim host):

    make docs          # or, per file:
    pandoc -f gfm -t docx -o Design_Docs/X.docx Design_Docs/X.md
"""
import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(ROOT, "Design_Docs")


def git_date(path):
    """Last commit date of a path, or None if never committed."""
    try:
        # NB: no capture_output= / text= here - the sim host is Python 3.6.
        out = subprocess.check_output(
            ["git", "log", "-1", "--format=%cI", "--", path],
            cwd=ROOT, stderr=subprocess.DEVNULL).decode().strip()
        return out or None
    except subprocess.CalledProcessError:
        return None


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true")
    g.add_argument("--report", action="store_true")
    args = ap.parse_args()

    mds = sorted(f for f in os.listdir(DOCS) if f.endswith(".md")
                 and f != "README.md")

    stale, missing, ok = [], [], []
    for md in mds:
        docx = md[:-3] + ".docx"
        dp = os.path.join(DOCS, docx)
        if not os.path.exists(dp):
            missing.append(md)
            continue
        md_d, dx_d = git_date(os.path.join(DOCS, md)), git_date(dp)
        if md_d and dx_d and dx_d < md_d:
            stale.append((md, md_d[:10], dx_d[:10]))
        else:
            ok.append(md)

    print("| Document | .md | .docx | state |")
    print("|---|---|---|---|")
    for md, m, d in stale:
        print("| `%s` | %s | %s | **STALE** |" % (md[:-3], m, d))
    for md in missing:
        print("| `%s` | %s | — | **NO .docx** |" % (md[:-3], (git_date(os.path.join(DOCS, md)) or "?")[:10]))
    for md in ok:
        print("| `%s` | %s | up to date | ok |" % (md[:-3], (git_date(os.path.join(DOCS, md)) or "?")[:10]))

    print("\ncheck_docs: %d up to date, %d stale, %d with no .docx"
          % (len(ok), len(stale), len(missing)))

    if args.check and (stale or missing):
        print("\nThe .md is normative (Design_Docs/README.md). Regenerate the")
        print("exports with `make docs` before circulating them, or delete them.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
