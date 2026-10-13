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
    python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f --defines  # -D flags
    python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f --yosys    # yosys cmds

Order is preserved: the filelists are written bottom-up on purpose, so leaves
appear before the modules that instantiate them.
"""
import sys
import os


# Simulator switches that do not change which sources or macros are compiled.
# -makelib/-endlib and -timescale matter to a simulator, not to the flat list.
# A switch that is not listed here and not handled below is an error: before
# 2026-10-11 every unknown line was dropped without a word (TOOL-15).
IGNORED = ('-sv', '-64bit', '-nocheck', '-timescale', '-makelib', '-endlib',
           '-halargs', '-uvm', '-uvmhome')


def expand(path, seen, srcs, incs, defs):
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
                expand(nxt, seen, srcs, incs, defs)

            elif line.startswith('-incdir') or line.startswith('+incdir+'):
                # +incdir+<dir> used to fall through and be taken for a source
                if line.startswith('+incdir+'):
                    d = line[len('+incdir+'):].strip()
                else:
                    d = line.split(None, 1)[1].strip()
                if d not in incs:
                    incs.append(d)

            # TOOL-15: a define changes WHAT is built - six unit benches use
            # GARUDA_REAL_RTL to drop their inlined DUT snapshot for the real
            # rtl/core module - so it was wrong to discard it with the other
            # switches. Both spellings are accepted.
            elif line.startswith('-define'):
                d = line.split(None, 1)[1].strip()
                if d not in defs:
                    defs.append(d)
            elif line.startswith('+define+'):
                for d in line[len('+define+'):].split('+'):
                    if d and d not in defs:
                        defs.append(d)

            elif line.startswith('-') or line.startswith('+'):
                if line.split()[0] in IGNORED:
                    continue
                sys.stderr.write("ERROR: %s: switch not understood: %s\n"
                                 "       (add it to IGNORED in this script only if it does not\n"
                                 "        change what is compiled)\n" % (path, line))
                sys.exit(1)

            else:
                if line not in srcs:
                    srcs.append(line)


def main():
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        sys.exit(1)

    # Emit LF, never CRLF.  On Windows, Python's text-mode stdout rewrites
    # every newline as CR LF, so every path this script printed arrived at the
    # consumer with a trailing CR glued to it: a shell's $(...) does not word
    # split on CR, so the tool was handed "rtl/core/foo.v<CR>".  iverilog
    # tolerates a stray CR in a filename, which is why the Icarus flow never
    # noticed; Verilator does not, and reports the path as a module it cannot
    # find.  That is what made the expanded filelist look unusable for lint
    # and kept chip-level lint a manual, per-block job.  It applied to every
    # call on Windows regardless of the filelist's own line endings.
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(newline=chr(10))

    top = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else '--sources'

    srcs, incs, defs = [], [], []
    expand(top, set(), srcs, incs, defs)

    missing = [s for s in srcs if not os.path.exists(s)]
    if missing:
        sys.stderr.write("ERROR: %d source(s) listed but not on disk:\n" % len(missing))
        for m in missing:
            sys.stderr.write("    %s\n" % m)
        sys.exit(1)

    if mode == '--incdirs':
        print(' '.join('-I' + d for d in incs))
    elif mode == '--defines':
        print(' '.join('-D' + d for d in defs))
    elif mode == '--yosys':
        # yosys wants the include path and defines on each read_verilog
        flags = ' '.join(['-I' + d for d in incs] + ['-D' + d for d in defs])
        for s in srcs:
            if s.endswith('.vh'):
                continue            # headers are pulled in via `include
            # A .sv file needs -sv. Without it yosys's Verilog-2005 frontend
            # rejects a SystemVerilog port declaration -- the whole chip
            # stopped synthesising at spi_master_clkgen.sv:13 ("input logic
            # clk") the moment the vendored PULP SPI master joined the build,
            # which is why the chip-level cell and latch counts could not be
            # reproduced. Flagged per file rather than globally so the
            # Verilog-2005 sources keep being parsed as Verilog-2005.
            sv = ' -sv' if s.endswith('.sv') else ''
            print('read_verilog%s %s %s' % (sv, flags, s))
    elif mode == '--sources':
        for s in srcs:
            print(s)
    else:
        sys.stderr.write("ERROR: unknown mode %s\n" % mode)
        sys.exit(1)


if __name__ == '__main__':
    main()
