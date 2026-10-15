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
    # PeakRDL maps every block with UVM_NO_ENDIAN. UVM 1.1d/1.2 accept that for a
    # register as wide as the bus; the IEEE 1800.2 library refuses every access
    # (UVM/REG/MAPNOENDIANESS, BUGS TOOL-25). APB is little-endian.
    with open(out) as fh:
        text = fh.read()
    n = text.count("UVM_NO_ENDIAN")
    with open(out, "w") as fh:
        fh.write(text.replace("UVM_NO_ENDIAN", "UVM_LITTLE_ENDIAN"))
    print("wrote %s from %s (%d map(s) set little-endian)" % (out, rdl, n))

if __name__ == "__main__":
    main()
