# Clock and reset domain crossings on the whole chip (1-TOPS item 3.15)

JasperGold 2022.09p002, CDC app, `flow/2_static/cdc/cdc_chip.tcl` on `garuda_chip_top`. Final run on 2026-11-03.

Run from the repository root in tcsh:

    source /home/install/cshrc
    /home/install/JASPER/bin/jg -allow_unsupported_OS -cdc -batch -no_jges -proj sim/cdc_chip flow/2_static/cdc/cdc_chip.tcl

Reports are in `reports/`:
- `domains.csv`, `pairs.csv`, `schemes.csv`, `reset_schemes.csv`, `clock_groups.csv`;
- `violations.csv`: what is left unwaived, header only, so **0**;
- `waivers.csv`: every waiver with its reason.

## Result

**0 unwaived violations.** The run without waivers reported 364 violations. Every one was read and falls into one of the classes below. Each waiver in the script matches only its own tag and a narrow name pattern, so a new violation still appears.

## What the script tells the tool

| Intent | How |
|---|---|
| Clocks | `refclk`, `tck`, and the three clocks `clk_div` makes from `refclk` with flops (`aon_clk_o`, `hclk_o`, `pclk_o`). Each of the three is an environmental stopat plus `clock`: the tool does not follow a clock through a flop, and without this it found no crossing at all. |
| Clock groups | `{refclk aon_clk hclk pclk}` is synchronous (one family, CLKRST §9.1); `tck` is asynchronous to it |
| Reset | only the pin `ext_rst_n`. The tool traces the five resets `reset_ctrl` makes from it. Declaring those nets as resets cuts them and hides `reset_ctrl`'s synchronisers. |
| Pins | JTAG pins on `tck`. Outputs on `pclk`. The asynchronous inputs (`boot_sel`, UART rx, SPI-slave pins, SPI-master MISO, I2C, GPIO) are `async_to_all`. The black-boxed memory arrays are on `hclk`. |
| The DMI handshake | 4 `handshake` schemes, one per payload bus: the DTM's request address, data and op (`tck` to `hclk`), and the DM's read data (`hclk` to `tck`). Each is mapped to the toggles and synchronisers in `dmi_cdc` (DEBUG [N-7.16]). |

## What the tool found

| Item | Result |
|---|---|
| Clock domains | 5 |
| Crossing pairs | 74, all at the debug port (`tck` and `hclk`) or at a pin |
| Synchronisers | 12 two-flop (NDFF) and 4 handshake, all passed. NDFF covers `dmi_cdc`'s two toggles and the input pins. |

## Classes of violation, read and waived

| Tag | Count | Where | Why it is safe |
|---|---|---|---|
| `RDC_RS_DFRS` | 306 | a flop with a reset feeding a storage array with none: DSRAM (144), the register file (93), ISRAM (35), boot ROM (34) | The arrays have no reset by design, and their contents are undefined after a reset. Writes need a valid AHB data phase, which a reset ends. The register file's write enable comes from `mem_wb.reg_write`, which resets to 0. |
| `RDC_RS_DFRS` | 4 | vendored I2C `bit_controller.dout`, `dscl_oen` | One-cycle delayed copies without reset: they follow their source within one `pclk` |
| `RST_NO_SYNC` | 29 | `clk_div` (7), `reset_ctrl` (7), TAP / DTM / `dmi_cdc` ack (15) | Reset by the pin, with no release synchroniser, on purpose. The divider must run before any synchronised reset exists (D-14). In `reset_ctrl`, every flop's D equals its reset value at release. The JTAG side is reset at power-on with `tck` stopped, and the TAP also resets on five TMS-high clocks (IEEE 1149.1). |
| `RST_RS_CONV` | 4 | `reset_ctrl` request logic (3); `core_rst_n & hartreset_n` in the core (1) | Re-registered before use; the core AND is CORE [N-7.33] and the HAL GLTASR waiver |
| `RST_RS_RIDP` | 2 | `hreset_n` used as data | On purpose: `preset_n` releases after it, and it clears the watchdog request flop (`rdc_review.md`, crossings 1 and 2) |
| `CDC_PR_FOUT` | 7 | DMI request payload | Fans out to several Debug Module registers; stable for the whole handshake |
| `CDC_NO_SYNC` | 4 | `i2c_scl`, `i2c_sda`, `gpio0`, `gpio1` | Bidirectional pins: the `pclk` drive into the pad leaves the chip and is not an on-chip crossing. The input side is synchronised in the shim (NDFF, passed). |
| `CNV_ST_CONV` | 8 | GPIO interrupt status; APB read-data mux in the bridge; SPI-slave shifter | GPIO: one bit per pin. Bridge: one window is selected per read, so bits from different peripherals never meet. SPI slave: oversampled, and SCLK ≤ `pclk`/6 (SPIS [N-7.1a]) keeps MOSI stable around the detected edge. |

The reset-domain review that HAL could not do (`flow/2_static/rdc_review.md`, plan task 3.5) is now backed by this tool run. Crossing 5 of that review (the debugger halting the core under a live bus) is closed in the RTL by RDC-1.
