#!/usr/bin/env python3
"""
gen_chip_regs.py -- the register table of sw/chip/t_chip_regs.c (1-TOPS G6 6.2), from the
SystemRDL sources the block UVM register models are generated from.

    python3 tools/gen/gen_chip_regs.py            write sw/chip/chip_regs.h
    python3 tools/gen/gen_chip_regs.py --check    fail if chip_regs.h is not what the .rdl gives

Every register of every APB window is listed. Per register:
  rst / rstmask  the reset value and the bits checked against it (fields with a reset value)
  rw             bits written with patterns and read back (sw=rw, hw=r, no onwrite side effect)
  ro             bits that must ignore every write (sw=r, hw=na: constants)
  w1c            bits a write may only clear (onwrite=woclr)
  wzero          bits forced to 0 in every pattern written (a 1 there acts, see REASON)
  flags          NOWRITE / NOREAD, each with its REASON in the generated header
Rules, not lists: a register sharing its address with a write-only action register
(THR, CMD, FCR), a FIFO data register (a read pops), and a field the hardware also writes
are excluded by rule. The few registers excluded by name are in NAMED, each with its reason
and the test that covers it instead (D-40: no waiver without a reason).
Python 3.6 (the machine's default python3 has systemrdl-compiler).
"""
import os
import sys
from systemrdl import RDLCompiler
from systemrdl.node import RegNode

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "sw", "chip", "chip_regs.h")

# window, rdl, base (garuda_map.h / TRM 3.3)
WINDOWS = [
    (0,  "spis",   0x40000000), (1,  "spim",   0x40001000), (2,  "i2c",   0x40002000),
    (3,  "uart",   0x40003000), (4,  "uart",   0x40004000), (5,  "dma",   0x40005000),
    (6,  "uart",   0x40006000), (7,  "gpio",   0x40007000), (8,  "pwm",   0x40008000),
    (9,  "crg",    0x40009000), (10, "clic",   0x4000A000), (11, "timers", 0x4000B000),
]
NAMES = {0: "SPIS", 1: "SPIM", 2: "I2C", 3: "UART0", 4: "UART1", 5: "DMA", 6: "UART2",
         7: "GPIO", 8: "PWM", 9: "CRG", 10: "CLIC", 11: "TIMERS"}

F_NOWRITE, F_NOREAD, F_HOLD3 = 1, 2, 4

# Registers excluded by name: (rdl, register) -> (flags, wzero, reason)
NAMED = {
    ("crg", "RSTCTL"): (F_NOWRITE, 0, "SWRST resets the chip; DIVSEL and BOOTFAIL_SET are written and read back by t_chip_cov (runs 1-4)"),
    ("crg", "MEMCTL"): (F_NOWRITE, 0, "ILOCK is write-1-to-set and locks the ISRAM this program runs from; t_chip_cov step 10 and t_chip_flash check it"),
    ("timers", "WDTCTL"): (0, 0x1, "EN is write-1-to-set and starts the watchdog (a chip reset later): forced 0 in every pattern; t_chip_wdt checks it"),
    ("dma", "CR"): (F_HOLD3, 0x1, "EN starts a transfer: forced 0; MODE and SIZE = 3 are reserved and leave the field unchanged ([N-6.1]): checked as such"),
    ("timers", "MTIME_LO"): (F_NOWRITE | F_NOREAD, 0, "the running machine timer (hw=rw): no fixed value to read or write back; t_mtip and the timers UVM environment check it"),
    ("timers", "MTIME_HI"): (F_NOWRITE | F_NOREAD, 0, "as MTIME_LO"),
}

# Fields the hardware sets as soon as reset ends, so the value read at idle is not the
# register's reset value: (rdl, register, field) -> (idle value, the spec line that says so)
IDLE = {
    ("uart", "IRQSTAT", "tx"): (1, "TX holding empty is set by LSR[5] (THRE), which is 1 out of reset (UART spec 7.5 table): IRQSTAT resets to 0 and latches it in the first pclk"),
}

# One .rdl serves several instances; values that differ per instance: window -> {register: value, reason}
INSTANCE = {
    4: {"ID": (0x6A5D1101, "UART1 is block 17 (uart.rdl ID: block number 16, 17 or 18; the reset value there is UART0's)")},
    6: {"ID": (0x6A5D1201, "UART2 is block 18 (as UART1)")},
}

def fields_of(reg):
    out = []
    for f in reg.fields():
        mask = ((1 << (f.msb - f.lsb + 1)) - 1) << f.lsb
        out.append(dict(name=f.inst_name, mask=mask, lsb=f.lsb, sw=f.get_property("sw").name,
                        hw=f.get_property("hw").name, rst=f.get_property("reset"),
                        onread=f.get_property("onread"), onwrite=f.get_property("onwrite")))
    return out

def table():
    rows, notes = [], []
    cache = {}
    for win, rdl, base in WINDOWS:
        if rdl not in cache:
            c = RDLCompiler()
            c.compile_file(os.path.join(ROOT, "Design_Docs", "regs", rdl + ".rdl"))
            cache[rdl] = [r for r in c.elaborate().top.descendants(unroll=True) if isinstance(r, RegNode)]
        regs = cache[rdl]
        by_addr = {}
        for r in regs:
            by_addr.setdefault(r.absolute_address, []).append(r)
        for addr in sorted(by_addr):
            group = by_addr[addr]
            readable = [r for r in group if any(f["sw"] in ("r", "rw") for f in fields_of(r))]
            writeonly = [r for r in group if all(f["sw"] == "w" for f in fields_of(r))]
            name = "/".join(r.get_path().split(".", 1)[1] for r in group)
            if not readable:
                notes.append((win, addr, name, "write-only: every write acts (send, start, kick, set/clear a pin); covered by the block's functional tests and the chip programs"))
                continue
            reg = readable[0]
            fl = fields_of(reg)
            rst = rstmask = rw = ro = w1c = wzero = 0
            flags = 0
            reason = []
            for f in fl:
                if f["rst"] is not None:
                    val = f["rst"]
                    idle = IDLE.get((rdl, reg.inst_name, f["name"]))
                    if idle is not None:
                        val = idle[0]
                        reason.append("idle value of %s.%s is %d: %s" % (reg.inst_name, f["name"], idle[0], idle[1]))
                    rst |= (val << f["lsb"]) & f["mask"]
                    rstmask |= f["mask"]
                if f["sw"] == "rw" and f["hw"] == "r" and f["onwrite"] is None:
                    rw |= f["mask"]
                if f["sw"] == "r" and f["hw"] == "na":
                    ro |= f["mask"]
                if f["onwrite"] is not None and f["onwrite"].name == "woclr":
                    w1c |= f["mask"]
                if f["sw"] == "w":                       # pulse bits sharing a readable register
                    wzero |= f["mask"]
                if f["hw"] == "rw" or (f["onwrite"] is not None and f["onwrite"].name == "woset"):
                    wzero |= f["mask"]
            if writeonly:
                flags |= F_NOWRITE
                reason.append("shares its address with %s (write-only, acts on a write)" % "/".join(r.inst_name for r in writeonly))
            if any(f["sw"] == "r" and f["hw"] == "w" and f["rst"] is None for f in fl) and \
               reg.inst_name in ("RBR", "RXDATA", "RXFIFO"):
                flags |= F_NOREAD
                reason.append("FIFO data: a read pops")
            if any(f["onread"] is not None for f in fl):
                reason.append("read-to-clear (%s): checked as reading the reset value" % reg.inst_name)
            inst = INSTANCE.get(win, {}).get(reg.inst_name)
            if inst is not None:
                rst = inst[0]
                reason.append(inst[1])
            key = (rdl, reg.inst_name)
            if key in NAMED:
                nf, nz, why = NAMED[key]
                flags |= nf
                wzero |= nz
                reason.append(why)
            rw &= ~wzero
            if flags & F_NOREAD:
                rstmask = 0
            if flags & F_NOWRITE:
                rw = 0
            rows.append(dict(win=win, addr=addr + base, name="%s.%s" % (NAMES[win], name), rst=rst,
                             rstmask=rstmask, rw=rw, ro=ro, w1c=w1c, wzero=wzero, flags=flags,
                             reason="; ".join(reason)))
    return rows, notes

def render(rows, notes):
    n_rst = sum(1 for r in rows if r["rstmask"])
    n_rw = sum(1 for r in rows if r["rw"])
    n_ro = sum(1 for r in rows if r["ro"] and not r["flags"] & F_NOWRITE)
    n_w1c = sum(1 for r in rows if r["w1c"] and not r["flags"] & F_NOWRITE)
    L = []
    L.append("/* GENERATED by tools/gen/gen_chip_regs.py from the Design_Docs/regs RDL files -- do not edit.")
    L.append(" * The register table of t_chip_regs.c (1-TOPS G6 6.2). make check_tree fails if it is stale.")
    L.append(" * %d readable registers in 12 APB windows: %d reset-checked, %d with read/write bits, %d with" % (len(rows), n_rst, n_rw, n_ro))
    L.append(" * constant bits written, %d with write-1-to-clear bits; %d write-only addresses not read." % (n_w1c, len(notes)))
    L.append(" *")
    L.append(" * Exclusions, each with its reason:")
    for r in rows:
        if r["reason"]:
            L.append(" *   %-22s %s" % (r["name"], r["reason"]))
    for win, addr, name, why in notes:
        L.append(" *   %-22s %s" % ("%s.%s" % (NAMES[win], name), why))
    L.append(" */")
    L.append("#ifndef CHIP_REGS_H")
    L.append("#define CHIP_REGS_H")
    L.append("#include <stdint.h>")
    L.append("#define CR_NOWRITE 1u")
    L.append("#define CR_NOREAD  2u")
    L.append("#define CR_HOLD3   4u   /* 2-bit fields where 3 is reserved and leaves the field unchanged */")
    L.append("typedef struct { uint32_t addr, rst, rstmask, rw, ro, w1c, wzero, flags; } chip_reg_t;")
    L.append("#define N_CHIP_REGS %du" % len(rows))
    L.append("static const chip_reg_t chip_regs[N_CHIP_REGS] = {")
    for i, r in enumerate(rows):
        L.append("    { 0x%08Xu, 0x%08Xu, 0x%08Xu, 0x%08Xu, 0x%08Xu, 0x%08Xu, 0x%08Xu, %du },   /* %3d %s */" % (
            r["addr"], r["rst"], r["rstmask"], r["rw"], r["ro"], r["w1c"], r["wzero"], r["flags"], i, r["name"]))
    L.append("};")
    L.append("#endif")
    return "\n".join(L) + "\n"

def main():
    rows, notes = table()
    text = render(rows, notes)
    if "--check" in sys.argv:
        old = open(OUT).read() if os.path.exists(OUT) else ""
        if old != text:
            sys.exit("gen_chip_regs: sw/chip/chip_regs.h is stale; run python3 tools/gen/gen_chip_regs.py")
        print("gen_chip_regs: up to date")
        return
    with open(OUT, "w") as fh:
        fh.write(text)
    print("wrote %s: %d registers" % (OUT, len(rows)))

if __name__ == "__main__":
    main()
