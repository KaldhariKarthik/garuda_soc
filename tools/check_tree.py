#!/usr/bin/env python3
"""
check_tree.py - things that must never be in the repository, and bug IDs taken twice.

    python3 tools/check_tree.py        (make check_tree)

The repository is public. It fails, naming each file and line, on:

  1. a tracked file that is a technology library, a PDK file, a layout or a
     licence file (by extension: .lib .db .lef .tlef .gds .gds2 .oas .tf .ndm
     .captbl .tch .ict .qrcTechFile .lic, and any file called license.dat).
     A stand-in library used for the rehearsal stays under /home/install and is
     named by path in a script, never copied here.
  2. a licence server address in a tracked file that is run (scripts, make
     files, flow files): the address belongs in scripts/local_env.sh, which is
     not tracked (copy scripts/local_env.sh.example). Logs and hand-off notes
     that quote it as history are listed in HISTORY below.
  3. a bug ID defined twice. A definition is a table row whose first cell is the
     ID, or a heading that starts with it, in Docs/bugs/archive/BUGS_HISTORY.md; in the two track
     files, Docs/bugs/track_a.md and track_b.md, only the rows with the ID in
     bold are definitions (the plain rows there carry over entries of BUGS_HISTORY.md).
     Six IDs were defined twice in Docs/bugs/archive/BUGS_HISTORY.md before the register was split
     into tracks; they are history and are listed in OLD_DUPLICATES. The section
     "1. Open items" of Docs/bugs/archive/BUGS_HISTORY.md is an index of IDs and is not read.
  4. a file in the Docs/ root that is not in DOCS_ROOT. New documents go in the folders
     of Docs/README.md; new defects go in the track registers, not in the archive
     (Docs/DOC_STANDARD.md section 1).
"""
import re
import subprocess
import sys
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BAD_EXT = (".lib", ".db", ".lef", ".tlef", ".gds", ".gds2", ".oas", ".tf", ".ndm", ".captbl", ".tch",
           ".ict", ".qrctechfile", ".lic")
BAD_NAME = ("license.dat",)
# files that quote the licence address as a record of what was done on a date
HISTORY = ("Docs/handoff/HANDOFF.md", "Docs/logs/verification/VERIFICATION_LOG_2026-07-29.md", "tools/check_tree.py")
ADDR = re.compile(r"\b\d{3,5}@(?:\d{1,3}\.){3}\d{1,3}\b")
OLD_DUPLICATES = ("AUD-8", "ELEM-4", "TB-15", "TB-16", "TOOL-5", "TOOL-6")
ID = r"[A-Z][A-Z0-9]{0,5}-[A-Z]?\d+[a-z]?"
# the only files allowed directly in Docs/ (Docs/README.md, "Folder map")
DOCS_ROOT = ("Docs/README.md", "Docs/DOC_STANDARD.md", "Docs/DECISIONS.md", "Docs/COVERAGE.md",
             "Docs/THIRD_PARTY_NOTICES.md")


def main():
    files = subprocess.check_output(["git", "ls-files"], cwd=ROOT, universal_newlines=True).split("\n")
    files = [f for f in files if f]
    bad = []

    for f in files:
        low = f.lower()
        if low.endswith(BAD_EXT) or os.path.basename(low) in BAD_NAME:
            bad.append("library, PDK or licence file is tracked: %s" % f)

    for f in files:
        if f in HISTORY or not os.path.isfile(os.path.join(ROOT, f)):
            continue
        try:
            text = open(os.path.join(ROOT, f), errors="strict").read()
        except (UnicodeDecodeError, OSError):
            continue
        for n, line in enumerate(text.split("\n"), 1):
            if ADDR.search(line):
                bad.append("licence server address in %s:%d (it belongs in scripts/local_env.sh, untracked)" % (f, n))

    for f in files:
        if f.startswith("Docs/") and f.count("/") == 1 and f not in DOCS_ROOT:
            bad.append("file in the Docs/ root: %s (put it in a folder of Docs/README.md)" % f)

    seen = {}
    for f, bold_only in (("Docs/bugs/archive/BUGS_HISTORY.md", False), ("Docs/bugs/track_a.md", True), ("Docs/bugs/track_b.md", True)):
        p = os.path.join(ROOT, f)
        if not os.path.exists(p):
            continue
        index = False
        for n, line in enumerate(open(p).read().split("\n"), 1):
            # a summary table that lists open entries by ID (the "Open items" section of
            # Docs/bugs/archive/BUGS_HISTORY.md, added 2026-10-14) refers to entries; it does not define them
            if line.startswith("## "):
                index = line.lower().startswith("## 1. open items")
            if index:
                continue
            m = re.match(r"^\| \*\*(%s)\*\* \|" % ID, line)
            if not m and not bold_only:
                m = re.match(r"^\| (%s) \|" % ID, line) or re.match(r"^#{2,4} (%s)\b" % ID, line)
            if m:
                seen.setdefault(m.group(1), []).append("%s:%d" % (f, n))
    for i, where in sorted(seen.items()):
        if len(where) > 1 and i not in OLD_DUPLICATES:
            bad.append("bug ID %s is defined %d times: %s" % (i, len(where), ", ".join(where)))

    for b in bad:
        print("  " + b)
    print("check_tree: %d tracked files, %d bug IDs, %d problem(s)" % (len(files), len(seen), len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
