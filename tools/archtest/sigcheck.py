#!/usr/bin/env python3
"""sigcheck.py -- riscv-arch-test signature check against Spike (plan 5.4).

    python3 tools/archtest/sigcheck.py <test.elf> <dut.signature>

Runs the pinned Spike on the same ELF in the GARUDA configuration of
tools/lockstep.py (M-mode only, no PMP, no triggers, memory at tb_boot's
place, 2 MiB as tb_boot's GARUDA_TB_MEM2M build; DN-ISA: zmmul) with +signature, and compares word by word with the
signature tb_boot dumped. Exit 0 when identical.

One exact, documented exception (ARCH-DEV-1, GARUDA CLIC mode): GARUDA's mtvec
MODE field is hardwired to 3 (CLIC; csr_file.v reads {mtvec[31:2], 2'b11}),
Spike's is 0. arch_test.h keeps the MODE bits it reads back when it points
mtvec at its trampoline, and saves that value (xtvec_new) as the table base.
The first word of every trap signature is
    ((V << 4) | E) + MMODE_SIG,   V = spreader return address - xtvec_new
so on GARUDA V is exactly 3 smaller than on Spike while the trap itself lands
in the same place (MODE 3 and MODE 0 both send exceptions to the base).
A differing word is accepted only if it is that header word and equals the
value computed from Spike's word with V-3; any other difference, including
a trap entered through the wrong slot, still fails. The count is printed.
"""
import os, subprocess, sys, tempfile

elf, dut = sys.argv[1], sys.argv[2]
spike = os.environ.get("SPIKE", "spike")
with tempfile.TemporaryDirectory() as d:
    ref = os.path.join(d, "ref.signature")
    cmd = [spike, "--isa=rv32i_zmmul_zicsr_zifencei_zicntr", "--priv=m", "-m0x10000000:0x200000",
           "--disable-dtb", "--pmpregions=0", "--triggers=0", "--pc=0x10000000",   # no boot ROM without the dtb
           f"+signature={ref}", "+signature-granularity=4", elf]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if p.returncode != 0 or not os.path.exists(ref):
        print(f"SPIKE-ERROR rc={p.returncode}: {(p.stderr or p.stdout).strip()[:200]}")
        sys.exit(2)
    r = [l.strip() for l in open(ref) if l.strip()]
d_ = [l.strip() for l in open(dut) if l.strip()]
if len(r) != len(d_):
    print(f"SIGNATURE MISMATCH: dut {len(d_)} words, spike {len(r)} words")
    sys.exit(1)


def clic_header(spike_word):
    """The trap-signature header GARUDA writes where Spike wrote spike_word
    (None if spike_word cannot be a header word)."""
    if spike_word >> 16 or (spike_word & 3) != 3:
        return None
    body = spike_word - 3                 # (V << 4) | E, V a multiple of 4
    vsh, e = body & ~0x3F, body & 0x3C
    if vsh < (3 << 4):
        return None
    return ((vsh - (3 << 4)) | e) + 3


bad, dev = [], []
for i in range(len(r)):
    a, b = int(d_[i], 16), int(r[i], 16)
    if a == b:
        continue
    (dev if clic_header(b) == a else bad).append(i)
if bad:
    i = bad[0]
    print(f"SIGNATURE MISMATCH: {len(bad)} of {len(r)} words differ; first at word {i}: dut {d_[i]} spike {r[i]}"
          + (f" (+{len(dev)} ARCH-DEV-1 header words)" if dev else ""))
    sys.exit(1)
if dev:
    print(f"SIGNATURE MATCH: {len(r)} words; {len(r) - len(dev)} identical to Spike, "
          f"{len(dev)} trap-signature header word(s) differ exactly as ARCH-DEV-1 (CLIC mtvec MODE=3) predicts: "
          + ", ".join(f"w{i} {d_[i]}/{r[i]}" for i in dev[:4]))
else:
    print(f"SIGNATURE MATCH: {len(r)} words identical to Spike")
