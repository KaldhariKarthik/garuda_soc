# 1-TOPS gate G3: SoC integration, evidence notes

Written 2026-11-03. Rows of the GARUDA 1-TOPS workbook whose evidence is a check rather than one test.

## 3.9 Boot ROM: reproducible from source

The 4 KiB boot ROM image is built from `sw/bootrom/` (`rom_start.S`, `boot.c`, `spim.c`, `link_rom.ld`) by `sw/Makefile`, rule `$(BUILD)/bootrom.hex`. The RTL loads it through the `BROM_INIT_FILE` parameter of `rtl/brom/bootrom_top.v`.

The image was built twice from a clean `sw/build`. Each build used the following tcsh commands, from the repository root:

    rm -f sw/build/bootrom.elf sw/build/bootrom.bin sw/build/bootrom.hex
    make -C sw build/bootrom.hex
    sha256sum sw/build/bootrom.hex sw/build/bootrom.bin

Both builds gave the same result, and it matches the image the chip tests of 2026-11-03 ran with:

| File | SHA-256 | Size |
|---|---|---|
| `bootrom.bin` | `0903e117d4a0f3164afd277112a4a5b88cb9a6a2c0b166b3cb5b5af5fe1a3765` | 820 bytes of 4096 |
| `bootrom.hex` | `a893b83e17dce6c25a1617f034f60219d1fa8383e57038b52d2e0547be33b6d0` | 1024 words; unused words are 0, an illegal instruction |

Toolchain: Vitis GNU `riscv64-amd-linux-gnu-gcc`, rv32im (G0 item 0.3).

## 3.12 System control: boot_sel, reset, ILOCK

The `boot_sel` path, from pin to firmware:

| Step | Where |
|---|---|
| The pin, with a pull-down at the pad | `rtl/soc/garuda_chip_top.v`, port `boot_sel` (pin 26, PHYS §3.1) |
| Two-flop synchroniser on `pclk` (it is an asynchronous input) | `rtl/reset_ctrl/reset_ctrl_apb.v`, `bsel_q` |
| Readable at `CLKSTAT[8]` | reset_ctrl, APB window 9 (DECISIONS D-19) |
| The boot ROM reads it once, at step 2 of the boot sequence: 1 means recovery (wait for JTAG), 0 means flash boot | `sw/bootrom/boot.c` (`CLKSTAT_BOOTSEL`) |
| After a good flash boot the ROM sets `MEMCTL.ILOCK` | `sw/bootrom/boot.c`; `rtl/mem/` |

There is no ROM remap: the reset vector is fixed at `0x1000_0000` (deviation D-A6).

Reset control is `rtl/reset_ctrl/`. It has four sources (`ext_rst_n`, watchdog, `ndmreset`, software), a 1024-cycle stretch, and the cause in `RSTREASON`. Clock control is `rtl/clk_div/` (DIVSEL).
