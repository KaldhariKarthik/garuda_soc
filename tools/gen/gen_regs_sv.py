#!/usr/bin/env python3
"""gen_regs_sv.py -- plain-SystemVerilog register package from a SystemRDL file.

    python3.12 tools/gen/gen_regs_sv.py Design_Docs/regs/dma.rdl tb/dma/env/dma_regs_pkg.sv

For benches that do not use UVM (Track A, DMA plan D3; Karthik's plan 2.2). The
RDL is the source; the generated package is checked in, so a simulation does not
need the generator. Expected register values in the DMA benches come from here,
i.e. from the specification as written in the RDL, never from the RTL.

The package gives, for a block whose registers are one regfile array (the
channels) plus top-level registers:
  - <BLK>_NCH, <BLK>_CH_STRIDE: the array size and stride;
  - per register of the regfile, in address order, tables indexed 0..N-1:
      <BLK>_REG_NAME, _OFS (offset in the regfile), _RESET, _WMASK (bits a
      software write sets; sw=rw), _W1C (bits a write of 1 acts on; sw=w),
      _RMASK (bits that can read as 1), _KIND (RW, RO or WO);
  - the same as single constants for each top-level register (<BLK>_<REG>_ADDR,
    _RESET, _RMASK, ...);
  - <BLK>_<REG>_<FIELD>_LSB / _W for every field.
Behaviour a register description cannot express (illegal-value rules, hardware
side effects) is left to the benches and the properties, as the RDL header lists.

Uses systemrdl-compiler (pip install systemrdl-compiler, in ~/tools/venv-a).
"""
import os
import sys
from systemrdl import RDLCompiler, RDLCompileError
from systemrdl.node import RegNode, RegfileNode, FieldNode


def masks(reg):
    """(reset, wmask, w1c, rmask) of a register node."""
    reset = wmask = w1c = rmask = 0
    for f in reg.fields():
        lsb, w = f.lsb, f.width
        m = ((1 << w) - 1) << lsb
        rv = f.get_property("reset")
        if isinstance(rv, int):
            reset |= (rv << lsb) & m
        sw = f.get_property("sw").name          # rw, r, w, ...
        if sw in ("rw", "w") and f.inst_name.upper().startswith("CLR"):
            w1c |= m
        elif sw == "rw":
            wmask |= m
        elif sw == "w":
            w1c |= m
        # a field reads back unless it is write-only or reserved (reads 0)
        if sw in ("rw", "r") and not f.inst_name.upper().startswith("RSVD"):
            rmask |= m
    return reset, wmask, w1c, rmask


def kind(reg):
    sws = {f.get_property("sw").name for f in reg.fields() if not f.inst_name.upper().startswith("RSVD")}
    if "rw" in sws:
        return "REG_RW"
    if sws <= {"r"}:
        return "REG_RO"
    return "REG_WO"


def h32(v):
    return f"32'h{v >> 16:04X}_{v & 0xFFFF:04X}"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, out = sys.argv[1], sys.argv[2]
    rdlc = RDLCompiler()
    try:
        rdlc.compile_file(src)
        root = rdlc.elaborate()
    except RDLCompileError:
        sys.exit(1)
    top = root.top
    blk = top.inst_name.upper()
    rfs = [c for c in top.children() if isinstance(c, RegfileNode)]
    tops = [c for c in top.children() if isinstance(c, RegNode)]
    if len(rfs) != 1 or not rfs[0].is_array:
        sys.exit("expected exactly one regfile array (the channels)")
    rf = rfs[0]
    nch, stride = rf.array_dimensions[0], rf.array_stride
    first = [c for c in top.children(unroll=True) if isinstance(c, RegfileNode)][0]   # channel 0
    regs = sorted((c for c in first.children() if isinstance(c, RegNode)), key=lambda r: r.address_offset)
    L = []
    w = L.append
    w(f"// {os.path.basename(out)} -- GENERATED from {src} by tools/gen/gen_regs_sv.py. Do not edit;")
    w(f"// change the RDL and regenerate. Register map of block '{top.inst_name}' for plain-SV benches.")
    w("`timescale 1ns/1ps")
    w(f"package {top.inst_name}_regs_pkg;")
    w("    typedef enum int {REG_RW, REG_RO, REG_WO} reg_kind_e;")
    w(f"    localparam int {blk}_NCH       = {nch};")
    w(f"    localparam int {blk}_CH_STRIDE = 'h{stride:X};")
    w(f"    localparam int {blk}_NREGS     = {len(regs)};")
    cols = {"NAME": [], "OFS": [], "RESET": [], "WMASK": [], "W1C": [], "RMASK": [], "KIND": []}
    for r in regs:
        rs, wm, w1, rm = masks(r)
        cols["NAME"].append(f'"{r.inst_name}"')
        cols["OFS"].append(f"12'h{r.address_offset:03X}")
        cols["RESET"].append(h32(rs)); cols["WMASK"].append(h32(wm)); cols["W1C"].append(h32(w1))
        cols["RMASK"].append(h32(rm)); cols["KIND"].append(kind(r))
    w(f"    // per-channel registers, indexed 0..{len(regs) - 1} in address order")
    types = {"NAME": "string", "OFS": "logic [11:0]", "RESET": "logic [31:0]", "WMASK": "logic [31:0]",
             "W1C": "logic [31:0]", "RMASK": "logic [31:0]", "KIND": "reg_kind_e"}
    for k, v in cols.items():
        w(f"    localparam {types[k]:12s} {blk}_REG_{k:5s} [{blk}_NREGS] = '{{{', '.join(v)}}};")
    for i, r in enumerate(regs):
        w(f"    localparam int {blk}_{r.inst_name}_IDX = {i};")
    w("    // top-level registers")
    for r in tops:
        rs, wm, w1, rm = masks(r)
        n = f"{blk}_{r.inst_name}"
        w(f"    localparam logic [11:0] {n}_ADDR  = 12'h{r.absolute_address:03X};")
        w(f"    localparam logic [31:0] {n}_RESET = {h32(rs)};")
        w(f"    localparam logic [31:0] {n}_WMASK = {h32(wm)};")
        w(f"    localparam logic [31:0] {n}_RMASK = {h32(rm)};")
        w(f"    localparam reg_kind_e   {n}_KIND  = {kind(r)};")
    w("    // field positions")
    for r in regs + tops:
        for f in r.fields():
            if f.inst_name.upper().startswith("RSVD"):
                continue
            n = f"{blk}_{r.inst_name}_{f.inst_name}"
            w(f"    localparam int {n}_LSB = {f.lsb}, {n}_W = {f.width};")
    w("endpackage")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, "w").write("\n".join(L) + "\n")
    print(f"wrote {out} from {src}: {nch} x {len(regs)} registers + {len(tops)} top-level")


if __name__ == "__main__":
    main()
