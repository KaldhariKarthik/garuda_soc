#!/usr/bin/env python3
"""
garuda_host.py - drive GARUDA on the KV260 PL from Linux on the A53.

Everything goes through two PL peripherals, reached via /dev/mem (run as root):
  AXI GPIO  @ 0xA000_0000   ch1 DATA (0x0) = ctrl word -> GARUDA
                            ch2 DATA (0x8) = stat word <- GARUDA
  UartLite  @ 0xA001_0000   GARUDA uart0 console, 115200 8N1

ctrl: [0] TCK [1] TMS [2] TDI [3] ext_rst_n (1 = run) [4] boot_sel [5] uart0 loopback
stat: [0] TDO [1] MMCM locked [2] hclk heartbeat [3] uart0_tx [7:4] pwm
      [9:8] gpio pads [10] scl [11] sda [31:16] 0x6A5D

A test program is loaded exactly like tb_chip +MODE=jtag does it: the Boot ROM
(boot_sel=1) waits on the JTAG mailbox. Over JTAG we halt, stream the image into
ISRAM via System Bus Access, post {MAGIC, ENTRY} at 0x2000_FFF0 and resume.
Pass/fail is read back from tohost (0x2000_F000) over SBA: 1 = pass,
(n<<1)|1 = step n failed.

The sequences here are the ones fpga/sim/tb_fpga_core.sv proves in simulation.
The --sim backend runs this same file against that simulation through two FIFOs
(fpga/sim/tb_host.sv).

usage:
  sudo python3 garuda_host.py stat
  sudo python3 garuda_host.py idcode
  sudo python3 garuda_host.py run  <image.hex> [--console] [--wdt] [--timeout S]
  sudo python3 garuda_host.py suite [--build ../../../sw/build]
  sudo python3 garuda_host.py console              # just print uart0
"""
import argparse
import ctypes
import mmap
import os
import sys
import time

GPIO_BASE = 0xA000_0000
UART_BASE = 0xA001_0000

C_TCK, C_TMS, C_TDI, C_RSTN, C_BOOTSEL, C_U0LB = 1, 2, 4, 8, 16, 32

TOHOST     = 0x2000_F000
RSTREASON  = 0x4000_9000            # reset_ctrl window 9, {BOOTFAIL, SW, NDM, WDT, EXT}
MBOX       = 0x2000_FFF0
MBOX_MAGIC = 0x4A54_4147
IDCODE     = 0x0000_0DB1

DM_CONTROL, DM_STATUS, SBCS, SBADDR0, SBDATA0 = 0x10, 0x11, 0x38, 0x39, 0x3C
SBCS_32         = 2 << 17
SBCS_AUTOINC    = 1 << 16
SBCS_READONADDR = 1 << 20


# =============================================================================
# Backends: the board (/dev/mem) or the Verilator testbench (FIFOs)
# =============================================================================
class DevMem:
    """32-bit volatile access to the two PL peripherals."""

    def __init__(self):
        fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self._g = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED,
                            mmap.PROT_READ | mmap.PROT_WRITE, offset=GPIO_BASE)
        self._u = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED,
                            mmap.PROT_READ | mmap.PROT_WRITE, offset=UART_BASE)
        os.close(fd)
        # ctypes words, so every access is ONE 32-bit load/store. Byte-wise
        # access would pop the UartLite RX FIFO four times.
        self._ctrl = ctypes.c_uint32.from_buffer(self._g, 0x0)
        self._tri1 = ctypes.c_uint32.from_buffer(self._g, 0x4)
        self._stat = ctypes.c_uint32.from_buffer(self._g, 0x8)
        self._urx  = ctypes.c_uint32.from_buffer(self._u, 0x0)
        self._ust  = ctypes.c_uint32.from_buffer(self._u, 0x8)
        self._uctl = ctypes.c_uint32.from_buffer(self._u, 0xC)
        self._tri1.value = 0                     # ch1 all outputs (also the IP default)

    def wr(self, v):  self._ctrl.value = v
    def rd(self):     return self._stat.value
    def sleep(self, s): time.sleep(s)

    def uart_flush(self): self._uctl.value = 0x2  # reset RX FIFO

    def uart_getc(self):
        return (self._urx.value & 0xFF) if (self._ust.value & 1) else None


class SimFifo:
    """Talk to fpga/sim/tb_host.sv: "W <hex>" / "R 0" / "D <ns hex>" / "Q 0", one per line."""

    def __init__(self, d):
        self._c = open(os.path.join(d, "cmd.fifo"), "w", buffering=1)
        self._r = open(os.path.join(d, "rsp.fifo"), "r")

    def wr(self, v):  self._c.write("W %08x\n" % v)
    def rd(self):
        self._c.write("R 0\n")
        return int(self._r.readline(), 16)
    def sleep(self, s): self._c.write("D %x\n" % max(1, int(s * 1e9)))       # ns of sim time
    def uart_flush(self): pass
    def uart_getc(self):  return None           # the testbench prints uart0 itself
    def close(self):      self._c.write("Q 0\n")


# =============================================================================
# JTAG / DMI / SBA, same sequences as tb_fpga_core.sv
# =============================================================================
class DmiError(Exception):
    pass


class Garuda:
    def __init__(self, io):
        self.io = io
        self.ctrl = C_BOOTSEL | C_U0LB            # reset asserted, TCK low
        self.io.wr(self.ctrl)

    # ---- pins ---------------------------------------------------------------
    def set(self, mask, on):
        self.ctrl = (self.ctrl | mask) if on else (self.ctrl & ~mask)
        self.io.wr(self.ctrl)

    def stat(self):
        return self.io.rd()

    def reset(self, boot_sel=1, loopback=1):
        """Full external reset, as a board supervisor would do it."""
        self.ctrl = (C_BOOTSEL if boot_sel else 0) | (C_U0LB if loopback else 0)
        self.io.wr(self.ctrl)
        self.io.sleep(0.001)
        self.set(C_RSTN, True)
        self.io.sleep(0.005)                     # reset stretch + ROM reaches recovery

    # ---- TAP ----------------------------------------------------------------
    def clk(self, tms, tdi):
        c = (self.ctrl & ~(C_TCK | C_TMS | C_TDI)) | (C_TMS if tms else 0) | (C_TDI if tdi else 0)
        self.io.wr(c)
        self.io.wr(c | C_TCK)
        q = self.io.rd() & 1                     # TDO launched on the previous falling edge
        self.io.wr(c)
        self.ctrl = c
        return q

    def idle(self, n):
        for _ in range(n):
            self.clk(0, 0)

    def tap_reset(self):
        for _ in range(5):
            self.clk(1, 0)
        self.clk(0, 0)                           # -> Run-Test/Idle

    def shift_ir(self, v):
        for m in (1, 1, 0, 0):
            self.clk(m, 0)
        for i in range(5):
            self.clk(i == 4, (v >> i) & 1)
        self.clk(1, 0); self.clk(0, 0)

    def shift_dr(self, v, n):
        self.clk(1, 0); self.clk(0, 0); self.clk(0, 0)
        o = 0
        for i in range(n):
            o |= self.clk(i == n - 1, (v >> i) & 1) << i
        self.clk(1, 0); self.clk(0, 0)
        return o

    def idcode(self):
        self.tap_reset()
        return self.shift_dr(0, 32)

    # ---- DMI ----------------------------------------------------------------
    def dmw(self, a, d):
        # The capture of this scan reports the PREVIOUS op. Busy (3) or sticky
        # error (2) means the DTM will drop the op being shifted in now, so it
        # must not pass silently. On the board the idle below is ~2000 hclk
        # cycles, and busy only happens while the chip is held in reset.
        x = self.shift_dr((a << 34) | (d << 2) | 2, 41)
        self.idle(6)
        if x & 3:
            raise DmiError("DMI status %d before write 0x%02x (op dropped)" % (x & 3, a))

    def dmr(self, a):
        x = self.shift_dr((a << 34) | 1, 41)
        self.idle(6)
        if x & 3:
            raise DmiError("DMI status %d before read 0x%02x (op dropped)" % (x & 3, a))
        x = self.shift_dr((a << 34), 41)
        self.idle(2)
        if x & 3:
            raise DmiError("DMI op status %d reading 0x%02x" % (x & 3, a))
        return (x >> 2) & 0xFFFF_FFFF

    def attach(self):
        """(Re)attach: clear sticky DMI status, activate DM, clear SBA errors."""
        self.shift_ir(0x10)
        self.shift_dr(1 << 16, 32)               # dtmcs.dmireset
        self.shift_ir(0x11)
        self.dmw(DM_CONTROL, 0x0000_0001)
        self.dmw(SBCS, (1 << 22) | (7 << 12) | SBCS_32)

    def halt(self):    self.dmw(DM_CONTROL, 0x8000_0001)
    def resume(self):  self.dmw(DM_CONTROL, 0x4000_0001)

    def sba_write(self, addr, words):
        self.dmw(SBCS, SBCS_32 | (SBCS_AUTOINC if len(words) > 1 else 0))
        self.dmw(SBADDR0, addr)
        for w in words:
            self.dmw(SBDATA0, w)

    def sba_read(self, addr):
        self.dmw(SBCS, SBCS_32 | SBCS_READONADDR)
        self.dmw(SBADDR0, addr)
        return self.dmr(SBDATA0)

    def sberror(self):
        return (self.dmr(SBCS) >> 12) & 7

    # ---- run one program ------------------------------------------------------
    def run(self, *a, **k):
        try:
            return self._run(*a, **k)
        except DmiError as e:
            return "FAIL", str(e)

    def _run(self, image, console=False, wdt=False, timeout=5.0, verify=4):
        self.reset(boot_sel=1, loopback=not console)
        if console:
            self.io.uart_flush()
        idc = self.idcode()
        if idc != IDCODE:
            return "FAIL", "IDCODE 0x%08x (expected 0x%08x) - JTAG path dead" % (idc, IDCODE)
        self.shift_ir(0x11)
        self.dmw(DM_CONTROL, 0x0000_0001)
        self.halt()
        self.sba_write(TOHOST, [0])
        self.sba_write(0x0000_0000, image)
        self.sba_write(MBOX + 4, [0])
        self.sba_write(MBOX, [MBOX_MAGIC])
        if not (self.dmr(DM_STATUS) >> 9) & 1:
            return "FAIL", "hart not halted during load"
        for i in range(min(verify, len(image))):
            v = self.sba_read(4 * i)
            if v != image[i]:
                return "FAIL", "ISRAM[%d] readback 0x%08x != 0x%08x" % (i, v, image[i])
        if self.sberror():
            return "FAIL", "SBA error %d after load" % self.sberror()
        self.resume()

        t0 = time.time()
        reposted = False
        out = bytearray()
        while True:
            if console:
                # drain uart0 first: the 16-deep FIFO lasts ~1.4 ms at 115200
                idle_since = time.time()
                while time.time() - idle_since < 0.3 and time.time() - t0 < timeout:
                    c = self.io.uart_getc()
                    if c is None:
                        self.io.sleep(0.0002)    # << 1.4 ms FIFO-fill time at 115200
                        continue
                    out.append(c)
                    sys.stdout.write(chr(c)); sys.stdout.flush()
                    idle_since = time.time()
            try:
                if wdt:
                    # The program resets the chip once (watchdog). The ROM
                    # mailbox is one-shot, so post it again, but only once
                    # RSTREASON says WDT. By then the reset is over and the ROM
                    # is polling. A post made during the program's own run can
                    # be cut in half by the reset.
                    self.attach()                # the reset took the DM with it
                    if not reposted and (self.sba_read(RSTREASON) & 0x1F) == 0x2:
                        self.sba_write(MBOX + 4, [0])
                        self.sba_write(MBOX, [MBOX_MAGIC])
                        reposted = True
                th = self.sba_read(TOHOST)
            except DmiError:
                if time.time() - t0 > timeout:
                    return "FAIL", "timeout: DMI kept failing"
                self.attach()                    # caught mid-reset: re-attach, poll again
                continue
            if th:
                return ("PASS", "") if th == 1 else ("FAIL", "program reported step %d" % (th >> 1))
            if time.time() - t0 > timeout:
                return "FAIL", "timeout: tohost never written"


def load_hex(path):
    with open(path) as f:
        return [int(l, 16) for l in f if l.strip() and not l.startswith("@")]


# =============================================================================
def cmd_stat(g):
    s1 = g.stat(); g.io.sleep(0.2); s2 = g.stat()
    print("stat      = 0x%08x" % s1)
    print("signature = 0x%04x  %s" % (s1 >> 16, "OK" if s1 >> 16 == 0x6A5D else "WRONG - is the GARUDA bitstream loaded?"))
    print("mmcm lock = %d" % ((s1 >> 1) & 1))
    print("heartbeat = %s" % ("toggling (hclk running)" if (s1 ^ s2) & 4 else "static (check again; ~12 Hz)"))
    print("pwm[3:0]  = %s   gpio[1:0] = %s   scl/sda = %d/%d   uart0_tx = %d" % (
        format((s1 >> 4) & 0xF, "04b"), format((s1 >> 8) & 3, "02b"),
        (s1 >> 10) & 1, (s1 >> 11) & 1, (s1 >> 3) & 1))


SUITE = [  # name, console, wdt, expectation
    ("t_chip_jtag",   False, False, "PASS"),
    ("t_chip_basic",  False, False, "PASS"),
    ("t_chip_irq",    False, False, "PASS"),
    ("t_chip_uart",   False, False, "PASS"),
    ("t_chip_wdt",    False, True,  "PASS"),
    ("t_chip_periph", False, False, "step 4 without an I2C slave at 0x48"),
    ("t_fpga_hello",  True,  False, "PASS + banner"),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["stat", "idcode", "run", "suite", "console"])
    ap.add_argument("image", nargs="?")
    ap.add_argument("--console", action="store_true", help="uart0 to the host UART (not loopback), print it")
    ap.add_argument("--wdt", action="store_true", help="program resets the chip once; re-post the mailbox")
    ap.add_argument("--timeout", type=float, default=5.0)
    ap.add_argument("--build", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "sw", "build"))
    ap.add_argument("--sim", metavar="DIR", help="drive the Verilator testbench through DIR/{cmd,rsp}.fifo")
    a = ap.parse_args()

    io = SimFifo(a.sim) if a.sim else DevMem()
    g = Garuda(io)
    rc = 0
    try:
        if a.cmd == "stat":
            cmd_stat(g)
        elif a.cmd == "idcode":
            g.reset()
            v = g.idcode()
            print("IDCODE = 0x%08x  %s" % (v, "OK" if v == IDCODE else "WRONG (expected 0x%08x)" % IDCODE))
            rc = 0 if v == IDCODE else 1
        elif a.cmd == "console":
            g.set(C_U0LB, False)
            while True:
                c = io.uart_getc()
                if c is not None:
                    sys.stdout.write(chr(c)); sys.stdout.flush()
        elif a.cmd == "run":
            img = load_hex(a.image)
            t = time.time()
            res, why = g.run(img, a.console, a.wdt, a.timeout)
            print("\n%s  %s  (%d words, %.2f s)  %s" % (res, os.path.basename(a.image), len(img), time.time() - t, why))
            rc = 0 if res == "PASS" else 1
        elif a.cmd == "suite":
            print("%-15s %-6s %-6s %s" % ("test", "result", "time", "note"))
            for name, con, wdt, exp in SUITE:
                p = os.path.join(a.build, name + ".hex")
                if not os.path.exists(p):
                    print("%-15s %-6s %-6s missing %s" % (name, "SKIP", "", p)); continue
                t = time.time()
                res, why = g.run(load_hex(p), con, wdt, a.timeout)
                if con: print()
                print("%-15s %-6s %5.2fs %s   [expect: %s]" % (name, res, time.time() - t, why, exp))
    finally:
        if a.sim:
            io.close()
    sys.exit(rc)


if __name__ == "__main__":
    main()
