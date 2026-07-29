#!/usr/bin/env python3
"""
elf2hex.py -- flat binary -> $readmemh image for tb_boot's ahb_mem_slave.

The memory model is word-addressed with word 0 == BASE_ADDR, so the image is
one 32-bit little-endian word per line, zero-padded, starting at BASE_ADDR.
Anything the binary does not cover is left as an explicit 00000000 line rather
than omitted -- $readmemh would otherwise leave holes at whatever the array
was initialised to, and a hole that reads as 'x' turns into a decode error
thirty cycles later that looks nothing like its cause.

Usage: elf2hex.py <input.bin> <output.hex> [--base 0x10000000] [--words N]
"""
import sys
import argparse


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binfile")
    ap.add_argument("hexfile")
    ap.add_argument("--base", default="0x10000000")
    ap.add_argument("--words", type=int, default=0,
                    help="pad image out to this many words (0 = no padding)")
    args = ap.parse_args()

    with open(args.binfile, "rb") as f:
        data = f.read()

    # pad to a word boundary
    if len(data) % 4:
        data += b"\x00" * (4 - len(data) % 4)

    nwords = len(data) // 4
    if args.words and args.words < nwords:
        sys.exit(f"elf2hex: image is {nwords} words, exceeds --words={args.words}")

    total = args.words if args.words else nwords

    with open(args.hexfile, "w") as f:
        for i in range(total):
            if i < nwords:
                w = int.from_bytes(data[i * 4:i * 4 + 4], "little")
            else:
                w = 0
            f.write(f"{w:08x}\n")

    print(f"elf2hex: {args.binfile} -> {args.hexfile}  "
          f"({nwords} words of content, {total} written, base {args.base})")


if __name__ == "__main__":
    main()
