#!/usr/bin/env python3
"""
gen_ral.py -- UVM register model from a SystemRDL register description.

    python3 tools/gen/gen_ral.py Design_Docs/regs/clic.rdl tb/clic/uvm/clic_reg_pkg.sv

Uses the open-source SystemRDL compiler and the PeakRDL UVM exporter
(pip3 install --user systemrdl-compiler peakrdl-uvm). The .rdl file is the
source; the generated package is checked in so a simulation does not need the
generator installed.
"""
import sys
from systemrdl import RDLCompiler, RDLCompileError
from peakrdl_uvm import UVMExporter

def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    rdl, out = sys.argv[1], sys.argv[2]
    rdlc = RDLCompiler()
    try:
        rdlc.compile_file(rdl)
        root = rdlc.elaborate()
    except RDLCompileError:
        sys.exit(1)
    UVMExporter().export(root, out)
    print("wrote %s from %s" % (out, rdl))

if __name__ == "__main__":
    main()
