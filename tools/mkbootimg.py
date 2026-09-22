#!/usr/bin/env python3
"""
mkbootimg.py -- flat binary -> the boot image sw/bootrom/boot.c expects.

The image is a 32-byte header followed by the ISRAM payload:

    word 0  MAGIC     0x47415244 "GARD"   word 4  TEXT_CRC
    word 1  TEXT_LEN  bytes               word 5  DATA_CRC
    word 2  DATA_LEN  bytes               word 6  reserved, 0
    word 3  ENTRY     address             word 7  reserved, 0

DATA_LEN is normally 0: chip/link_chip.ld puts the load image of .data inside
the ISRAM blob and crt0_chip.S copies it to DSRAM itself, so the ROM only has
one region to move. The field exists for an image that wants DSRAM populated
before _start runs.

BYTE ORDER is the whole point of this tool. boot.c reads the image with
spim_read_word(), which byte-swaps what comes off the wire so that flash byte n
becomes bits [8n+7:8n] of the word (SPIM [N-7.3]). That makes the flash a plain
little-endian byte image -- exactly what objcopy -O binary produces -- and the
output here is that byte stream, one byte per line, for $readmemh into
tb/models/spi_flash_model.sv, whose backing store is byte-wide.

CRC-32 is reflected, poly 0xEDB88320, init 0xFFFFFFFF, final complement: the
bitwise loop in boot.c and Python's zlib.crc32 are the same function.

Usage: mkbootimg.py <text.bin> <out.hex> [--entry 0x0] [--data data.bin]
                    [--bin out.bin] [--size N]
"""
import argparse
import struct
import sys
import zlib

MAGIC = 0x47415244
HDR_BYTES = 32
ISRAM_SIZE = 64 * 1024
DSRAM_SIZE = 64 * 1024


def pad4(b):
    return b + b"\x00" * (-len(b) % 4)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("textbin")
    ap.add_argument("hexfile")
    ap.add_argument("--entry", default="0x0")
    ap.add_argument("--data", help="optional DSRAM payload")
    ap.add_argument("--bin", help="also write the raw image here")
    ap.add_argument("--size", type=int, default=0,
                    help="pad the flash image out to this many bytes (0 = none)")
    args = ap.parse_args()

    with open(args.textbin, "rb") as f:
        text = pad4(f.read())
    data = b""
    if args.data:
        with open(args.data, "rb") as f:
            data = pad4(f.read())

    entry = int(args.entry, 0)

    # The same four checks boot.c makes, so a bad image fails here with a
    # sentence instead of in simulation as a silent jump to boot_fail().
    if len(text) > ISRAM_SIZE:
        sys.exit(f"mkbootimg: text is {len(text)} bytes, ISRAM holds {ISRAM_SIZE}")
    if len(data) > DSRAM_SIZE:
        sys.exit(f"mkbootimg: data is {len(data)} bytes, DSRAM holds {DSRAM_SIZE}")
    if entry >= len(text):
        sys.exit(f"mkbootimg: entry {entry:#x} is outside the {len(text)}-byte text")

    hdr = struct.pack("<8I", MAGIC, len(text), len(data), entry,
                      zlib.crc32(text) & 0xFFFFFFFF,
                      zlib.crc32(data) & 0xFFFFFFFF, 0, 0)
    assert len(hdr) == HDR_BYTES
    img = hdr + text + data

    if args.size:
        if len(img) > args.size:
            sys.exit(f"mkbootimg: image is {len(img)} bytes, exceeds --size={args.size}")
        img += b"\xFF" * (args.size - len(img))     # erased flash reads as ones

    with open(args.hexfile, "w") as f:
        for b in img:
            f.write(f"{b:02X}\n")
    if args.bin:
        with open(args.bin, "wb") as f:
            f.write(img)

    print(f"mkbootimg: {args.textbin} -> {args.hexfile}  "
          f"(text {len(text)} B, data {len(data)} B, entry {entry:#x}, "
          f"flash {len(img)} B)")


if __name__ == "__main__":
    main()
