#!/usr/bin/env python3
"""
expand_filelist.py -- flatten a GARUDA .f filelist into sources + include dirs.

WHY THIS EXISTS
---------------
Every build in this project is driven from a .f filelist, because that is what
guarantees a target verified under one simulator is running exactly the same
source list under another (see the Makefile header). The .f format is a
simulator convention though: xrun and xvlog understand `-f` recursion and
`-incdir`, and yosys, Verilator's older drivers, and most lint tools do not.

Rather than maintain a second, hand-written list of sources for synthesis --
which is how a synthesis run quietly ends up building different RTL from the
one that was simulated -- this expands the authoritative filelist into whatever
flat form a given tool needs.

USAGE
    python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f            # sources
    python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f --incdirs  # -I flags
    python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f --yosys    # yosys cmds

Order is preserved: the filelists are written bottom-up on purpose, so leaves
appear before the modules that instantiate them.
"""
import sys
import os


def expand(path, seen, srcs, incs):
    """Recursively expand one .f file."""
    path = os.path.normpath(path)
    if path in seen:
        return                      # a filelist pulled in twice is not an error
    seen.add(path)

    if not os.path.exists(path):
        sys.stderr.write("ERROR: filelist not found: %s\n" % path)
        sys.exit(1)

    base = os.path.dirname(path)
    with open(path) as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith('//') or line.startswith('#'):
                continue

            if line.startswith('-f '):
                nxt = line[3:].strip()
                if not os.path.exists(nxt):
                    nxt = os.path.join(base, nxt)
                expand(nxt, seen, srcs, incs)

            elif line.startswith('-incdir'):
                d = line.split(None, 1)[1].strip()
                if d not in incs:
                    incs.append(d)

            elif line.startswith('-'):
                # Any other simulator switch (-sv, -64bit, ...) is not a source
                # and is not this script's business.
                continue

            else:
                if line not in srcs:
                    srcs.append(line)


def main():
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        sys.exit(1)

    top = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else '--sources'

    srcs, incs = [], []
    expand(top, set(), srcs, incs)

    missing = [s for s in srcs if not os.path.exists(s)]
    if missing:
        sys.stderr.write("ERROR: %d source(s) listed but not on disk:\n" % len(missing))
        for m in missing:
            sys.stderr.write("    %s\n" % m)
        sys.exit(1)

    if mode == '--incdirs':
        print(' '.join('-I' + d for d in incs))
    elif mode == '--yosys':
        # yosys wants the include path on each read_verilog invocation
        flags = ' '.join('-I' + d for d in incs)
        for s in srcs:
            if s.endswith('.vh'):
                continue            # headers are pulled in via `include
            print('read_verilog %s %s' % (flags, s))
    else:
        for s in srcs:
            print(s)


if __name__ == '__main__':
    main()
