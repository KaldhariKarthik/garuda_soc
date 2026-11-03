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

## 3.16 Floating and unconnected nets

Genus `check_design` on the elaborated RTL of `garuda_chip_top`, before any optimisation, so constant propagation hides nothing. SRAMs are black boxes. Run from the repository root in tcsh:

    source /home/install/cshrc
    /home/install/GENUS211/bin/genus -batch -no_gui -files flow/signoff/g3/floating_nets.tcl -log sim/g3_float/genus

Run on 2026-11-03. Reports are in `out/`.

| Check | Result |
|---|---|
| Undriven pins and ports, at every level (`out/undriven.rpt`) | **none** |
| Unresolved references, empty modules (`out/unresolved.rpt`) | none |
| Unloaded ports (`out/unloaded.rpt`) | none |
| Unloaded flops | 35: three registers, each explained below |
| Multiply driven pins (`out/multidriven.rpt`) | 4 flop inputs and 4 hierarchical pins: the bidirectional pads, explained below |

**The 35 unloaded flops: each is unused on purpose.**

| Flops | Register | Why nothing reads it |
|---|---|---|
| 32 | `u_pc_gen/pc_o` (`rtl/core/garuda_pc_gen.v`), the architectural PC | `garuda_if_stage_top.v` leaves the port unconnected on purpose: the pipeline uses the PC tag stored with each prefetch-buffer entry. The unit bench `tb_garuda_pc_gen` checks it. Synthesis removes it. |
| 2 | `spi_mode` in the vendored `spi_master_controller.sv` | The quad and dual SPI modes are not exposed; GARUDA's SPI master is single-bit (SPIM spec). |
| 1 | `sync1_q` in the PWM's APB shim | The shared shim carries a pad-input synchroniser. The PWM has no input pin, so `pad_async_i` is tied to 0 and `pad_sync_o` is left open (`rtl/pwm/garuda_pwm_top.v`). |

**The multiply driven pins** are `i2c_scl_i`, `i2c_sda_i` and `gpio_i[1:0]`, and the first synchroniser flop behind each. Each is a bidirectional pin, modelled as `assign pin = oe ? out : 1'bz` and read back as the input. Genus counts the tristate output and the port as two drivers of one net. A pad cell from the PDK's IO library replaces this model, with separate output, enable and input pins, and the count goes to 0 (G7/G8).

Nothing here needs an RTL change.
