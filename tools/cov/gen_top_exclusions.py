#!/usr/bin/env python3
"""gen_top_exclusions.py - writes flow/cov/top_exclusions.tcl (D-40, 2026-11-21).

The toggle exclusions of the chip top (garuda_chip_top, garuda_chip_core,
garuda_soc_top) come in two kinds, and both are derived, not picked from a
holes list:

  1. Read-data bits that no register of a window can return as 1. The set of
     bits that CAN be 1 is computed from the window's SystemRDL description
     (Design_Docs/regs/<blk>.rdl): every software-readable field that hardware
     or software can change counts in full; a constant field counts with its
     reset value. A read-data bit outside that set is constant 0 by the
     register map, and the UVM register test of the block (RAL bit bash and
     reset-value checks against the same RDL) is the evidence that the RTL
     agrees. Bits inside the set are NOT excluded: t_chip_cov reads them back.
  2. Tie-offs: wires that are constant by construction (PREADY tied 1, the
     instruction port that never writes, HSIZE above word, ...), each listed
     below with its reason and where it is tied.

Usage:  python3 tools/cov/gen_top_exclusions.py            (writes the file)
        python3 tools/cov/gen_top_exclusions.py --check    (fails if it is stale)
cov_chart.py sources the file and fails on any line IMC cannot match.
"""
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "flow/cov/top_exclusions.tcl")

# APB window -> register description; ext index -> window (rtl/include/soc_map_pkg.sv)
WIN = {0: "spis", 1: "spim", 2: "i2c", 3: "uart", 4: "uart", 5: "dma", 6: "uart",
       7: "gpio", 8: "pwm", 9: "crg", 10: "clic", 11: "timers"}
EXT = {0: 0, 1: 1, 2: 2, 3: 3, 4: 4, 5: 6, 6: 7, 7: 8, 8: 9}
# the UART ID register carries the instance's block number in bits 15:8 (uart_top parameter)
UART_BLOCK = {3: 16, 4: 17, 6: 18}
# CLICIP.pending is a hw=w field over all 32 lines, but only the lines with a source can be 1:
# IDs 1-6, 8-22 from irq_src and 23 (CLICSWI, inside the CLIC); 0, 7 and 24-31 are tied 0
# (garuda_soc_top.sv, irq_src assigns)
CLIC_PENDING_POSSIBLE = 0x00FFFF7E


def rdl_mask(blk):
    from systemrdl import RDLCompiler
    from systemrdl.node import FieldNode
    rdlc = RDLCompiler()
    rdlc.compile_file(os.path.join(ROOT, "Design_Docs/regs/%s.rdl" % blk))
    root = rdlc.elaborate()
    m = 0
    for n in root.descendants(unroll=True):
        if not isinstance(n, FieldNode) or not n.is_sw_readable:
            continue
        fm = ((1 << n.width) - 1) << n.lsb
        if not n.is_hw_writable and not n.is_sw_writable and not n.get_property("counter", default=False):
            fm = (n.get_property("reset") or 0) << n.lsb
        if blk == "clic" and n.parent.inst_name == "CLICIP":
            fm &= CLIC_PENDING_POSSIBLE
        m |= fm
    return m


def possible(w, cache={}):
    if WIN[w] not in cache:
        cache[WIN[w]] = rdl_mask(WIN[w])
    m = cache[WIN[w]]
    if w in UART_BLOCK:
        m |= UART_BLOCK[w] << 8
    return m


# (type, signal, window of bit 0 of each 32-bit slice, or a callable slice -> window)
READ_DATA = [
    ("garuda_soc_top", "prdata_all", lambda s: s),
    ("garuda_soc_top", "apb_ext_prdata_i", lambda s: EXT[s]),
    ("garuda_soc_top", "prd_dma", lambda s: 5),
    ("garuda_soc_top", "prd_clic", lambda s: 10),
    ("garuda_soc_top", "prd_tmr", lambda s: 11),
    ("garuda_chip_core", "ext_prdata", lambda s: EXT[s]),
    ("garuda_chip_core", "rst_prdata", lambda s: 9),
    ("garuda_chip_core", "spis_prdata", lambda s: 0),
    ("garuda_chip_core", "spim_prdata", lambda s: 1),
    ("garuda_chip_core", "i2c_prdata", lambda s: 2),
    ("garuda_chip_core", "gpio_prdata", lambda s: 7),
    ("garuda_chip_core", "pwm_prdata", lambda s: 8),
]
WIDTH = {"prdata_all": 12 * 32, "apb_ext_prdata_i": 9 * 32, "ext_prdata": 9 * 32}

PREADY = "every APB slave answers without wait states: PREADY is tied 1 (%s)"
WORD_ONLY = "the AHB is 32 bits wide and no master issues a transfer wider than a word: HSIZE bit 2 is 0"
SINGLE = "%s issues single transfers only, IDLE or NONSEQ, never SEQ or BUSY: HTRANS bit 0 is 0"
ALIGNED = ("word accesses only reach the APB (the bridge answers a sub-word access ERROR before any "
           "APB transfer, N-7.21) and every master aligns them (core misaligned trap, DMA-10, DM sberror 2): "
           "PADDR bits 1:0 are 0")
TIES = [
    # ---- APB ready lines
    ("garuda_soc_top", "pready_all", range(12), PREADY % "garuda_apb_shim.sv, dma_apb_slave.sv, clic_apb.sv, timers_apb.sv, reset_ctrl_apb.sv"),
    ("garuda_soc_top", "apb_ext_pready_i", range(9), PREADY % "garuda_apb_shim.sv, reset_ctrl_apb.sv"),
    ("garuda_soc_top", "rdy_dma", None, PREADY % "dma_apb_slave.sv"),
    ("garuda_soc_top", "rdy_clic", None, PREADY % "clic_apb.sv"),
    ("garuda_soc_top", "rdy_tmr", None, PREADY % "timers_apb.sv"),
    ("garuda_chip_core", "ext_pready", range(9), PREADY % "garuda_apb_shim.sv, reset_ctrl_apb.sv"),
    ("garuda_chip_core", "rst_pready", None, PREADY % "reset_ctrl_apb.sv"),
    ("garuda_chip_core", "spim_pready", None, PREADY % "garuda_apb_shim.sv"),
    ("garuda_chip_core", "i2c_pready", None, PREADY % "garuda_apb_shim.sv"),
    ("garuda_chip_core", "uart_pready", range(3), PREADY % "garuda_apb_shim.sv"),
    ("garuda_chip_core", "gpio_pready", None, PREADY % "garuda_apb_shim.sv"),
    ("garuda_chip_core", "pwm_pready", None, PREADY % "garuda_apb_shim.sv"),
    ("garuda_chip_core", "spis_pready", None, PREADY % "garuda_apb_shim.sv"),
    # ---- APB address low bits
    ("garuda_soc_top", "paddr", range(2), ALIGNED),
    ("garuda_soc_top", "apb_ext_paddr_o", range(2), ALIGNED),
    ("garuda_chip_core", "ext_paddr", range(2), ALIGNED),
    # ---- AHB: the instruction port
    ("garuda_soc_top", "i_hwdata", range(32), "the instruction port never writes: its HWDATA is tied 0 in the core's fetch master"),
    ("garuda_soc_top", "i_hwrite", None, "the instruction port never writes: HWRITE is tied 0 in the core's fetch master"),
    ("garuda_soc_top", "i_hsize", range(3), "the instruction port fetches whole words: HSIZE is the constant 3'b010"),
    ("garuda_soc_top", "i_haddr", range(2), "fetches are word aligned (RV32IM, no C extension; a misaligned target traps before any fetch, isa p_ma_fetch): HADDR bits 1:0 are 0"),
    # ---- AHB: the other masters and the shared bus
    ("garuda_soc_top", "d_hsize", [2], WORD_ONLY),
    ("garuda_soc_top", "m_hsize", [2], WORD_ONLY),
    ("garuda_soc_top", "hsize", [2], WORD_ONLY),
    ("garuda_soc_top", "d_htrans", [0], SINGLE % "the core's data port"),
    ("garuda_soc_top", "m_htrans", [0], SINGLE % "the DMA"),
    ("garuda_soc_top", "s_htrans", [0], SINGLE % "the Debug Module's system bus access"),
    ("garuda_soc_top", "s_hsize", range(3), "System Bus Access supports 32-bit accesses only and refuses any other sbaccess with sberror 3 (debug_module.sv): HSIZE is the constant 3'b010"),
    ("garuda_soc_top", "s_haddr", range(2), "System Bus Access refuses an unaligned address with sberror 2 before any transfer (debug_module.sv): HADDR bits 1:0 are 0"),
    # ---- DSRAM error backstop
    ("garuda_soc_top", "hresp_dsram", None, "the DSRAM answers ERROR only to a misaligned or wider-than-word transfer, which no master issues at the chip (core misaligned trap, DMA-10, DM sberror 2, HSIZE at most word); covered in tb_mem_subsystem misaligned_all"),
    ("garuda_soc_top", "hro_dsram", None, "the DSRAM inserts a wait state only in the first cycle of its two-cycle ERROR, which no master can provoke at the chip (see hresp_dsram); covered in tb_mem_subsystem misaligned_all"),
    # ---- interrupt lines with no source
    ("garuda_soc_top", "irq_src", [0], "CLIC ID 0 is the sentinel: tied 0 (garuda_soc_top.sv, N-7.12)"),
    ("garuda_soc_top", "irq_src", [7], "CLIC ID 7 is reserved, its cause belongs to the machine timer: tied 0 (garuda_soc_top.sv)"),
    ("garuda_soc_top", "irq_src", [23], "CLIC ID 23 is CLICSWI, raised inside the CLIC: the line from outside is tied 0 (garuda_soc_top.sv, N-6.9)"),
    ("garuda_soc_top", "irq_src", range(24, 32), "CLIC IDs 24 to 31 have no source: tied 0 (garuda_soc_top.sv)"),
]


def generate():
    L = ["# =============================================================================",
         "# top_exclusions.tcl - coverage waivers for the TOP block (D-40), measured in the main merge.",
         "# GENERATED by tools/cov/gen_top_exclusions.py from the register descriptions and its tie-off",
         "# list; do not edit by hand. Every line has its reason; cov_chart fails on a line that matches",
         "# nothing (IMC *W,NOMATCH).",
         "# ============================================================================="]
    n_rd = 0
    for typ, sig, winof in READ_DATA:
        width = WIDTH.get(sig, 32)
        for s in range(width // 32):
            w = winof(s)
            m = possible(w)
            for b in range(32):
                if not (m >> b) & 1:
                    L.append('exclude -type %s -toggle %s\\[%d\\] -comment "no register of APB window %d (%s.rdl) can read 1 in bit %d"'
                             % (typ, sig, 32 * s + b, w, WIN[w], b))
                    n_rd += 1
    n_tie = 0
    for typ, sig, bits, why in TIES:
        for b in ([None] if bits is None else bits):
            name = sig if b is None else "%s\\[%d\\]" % (sig, b)
            L.append('exclude -type %s -toggle %s -comment "%s"' % (typ, name, why))
            n_tie += 1
    L.insert(6, "# %d read-data bits that the register map holds at 0, %d tie-offs" % (n_rd, n_tie))
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    text = generate()
    if "--check" in sys.argv:
        cur = open(OUT).read() if os.path.exists(OUT) else ""
        if cur != text:
            sys.exit("gen_top_exclusions: %s is stale; rerun tools/cov/gen_top_exclusions.py" % os.path.relpath(OUT, ROOT))
        print("gen_top_exclusions: up to date")
    else:
        open(OUT, "w").write(text)
        print("gen_top_exclusions: wrote %s" % os.path.relpath(OUT, ROOT))
