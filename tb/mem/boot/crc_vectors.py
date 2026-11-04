#!/usr/bin/env python3
"""crc_vectors.py -- memories vPlan F22 (Track A, 2026-11-01): the Boot ROM's CRC routine IS the
IEEE 802.3 CRC-32 (poly 0x04C11DB7 reflected, init and xorout all ones, GARUDA-MEM-SPEC-001
[N-8.8]) that tools/mkbootimg.py writes (Python zlib.crc32). The ROM's own C source
(sw/bootrom/boot.c, crc32_words, not a copy) is compiled for the host and run on known and random
vectors; every result must equal zlib.crc32. Writes logs/mem/summary/crc_vectors.tsv.
Run: python3.12 tb/mem/boot/crc_vectors.py"""
import os, random, subprocess, sys, tempfile, zlib
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
HARNESS = r'''
#include <stdio.h>
#include <stdlib.h>
#include "boot.c"          /* the ROM source itself: crc32_words is static in it */
int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "rb"); static uint32_t buf[16384]; size_t n = fread(buf, 1, sizeof buf, f);
    printf("%08x\n", crc32_words(buf, (uint32_t)n)); return 0;
}
'''
def vectors():
    yield "empty", b""
    yield "one word 0", b"\x00" * 4
    yield "one word ones", b"\xff" * 4
    yield "check string x4", b"123456789abc"          # 12 bytes (word multiple)
    yield "GARD header", bytes.fromhex("44524147" "98020000" "00000000" "00000000" "58d73467" "00000000")
    rnd = random.Random(0x5EED)
    for n in (8, 64, 700, 4096):
        yield f"random {n} B", bytes(rnd.randrange(256) for _ in range(n))
    yield "64 KiB pattern", bytes((i * 131 + 7) & 0xFF for i in range(65536))
def main():
    rows, bad = [], 0
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "h.c"); exe = os.path.join(d, "h")
        open(src, "w").write(HARNESS)
        r = subprocess.run(["gcc", "-O1", "-w", "-I", os.path.join(ROOT, "sw/bootrom"), "-I", os.path.join(ROOT, "sw/common"),
                            src, "-o", exe], capture_output=True, text=True)
        if r.returncode:
            sys.exit("crc_vectors: host build of sw/bootrom/boot.c failed:\n" + r.stderr[-2000:])
        for name, data in vectors():
            p = os.path.join(d, "v.bin"); open(p, "wb").write(data)
            got = int(subprocess.run([exe, p], capture_output=True, text=True, check=True).stdout, 16)
            want = zlib.crc32(data) & 0xFFFFFFFF
            ok = got == want; bad += not ok
            rows.append((name, "PASS" if ok else "FAIL", "OK" if ok else "UNEXPECTED", f"rom {got:08x} zlib {want:08x} ({len(data)} B)"))
            print(f"  {'PASS' if ok else 'FAIL'}  {name:18} rom {got:08x}  zlib {want:08x}")
    out = os.path.join(ROOT, "logs/mem/summary/crc_vectors.tsv")
    with open(out, "w") as f:
        f.write("# crc_vectors (memories vPlan F22): sw/bootrom/boot.c crc32_words vs zlib.crc32\ntest\tresult\tclass\tdetail\n")
        for r_ in rows: f.write("\t".join(r_) + "\n")
    print(f"crc_vectors: {len(rows)} vectors, {bad} mismatch(es) -> {'PASS' if not bad else 'FAIL'}")
    return 1 if bad else 0
if __name__ == "__main__":
    sys.exit(main())
