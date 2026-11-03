# Clock-domain crossings on the whole chip: first JasperGold CDC run (1-TOPS item 3.15)

JasperGold 2022.09p002, CDC app, `flow/2_static/cdc/cdc_chip.tcl` on `garuda_chip_top`. Run on 2026-11-03. Run from the repository root in tcsh:

    source /home/install/cshrc
    /home/install/JASPER/bin/jg -allow_unsupported_OS -cdc -batch -no_jges -proj sim/cdc_chip flow/2_static/cdc/cdc_chip.tcl

The tool's reports are in `reports/`.

## Setup that made the analysis work

- **The three clocks `clk_div` makes from `refclk` are declared.** Without this the run found no crossing at all: the tool does not follow a clock through a flop by itself, so `hclk`, `pclk` and `aon_clk` (and everything they clock) were unclocked. Each one now has an environmental stopat on the divider output (`stopat -env`) and its own `clock` command.
- **Clock groups:** `{refclk aon_clk hclk pclk}` is one synchronous family and `tck` is asynchronous to it (TRM §2, CLKRST §9.1).

## What the run shows

| Report | Result |
|---|---|
| Domains (`domains.csv`) | 5: `refclk`, `aon_clk`, `hclk`, `pclk` (one synchronous group) and `tck` |
| Crossing pairs (`pairs.csv`) | 56, **every one between `tck` and `hclk`**, which is the debug port. No other asynchronous crossing exists in the chip, as the TRM states. |
| Synchronisers found (`schemes.csv`) | 2, both two-flop (NDFF), both passed: `u_debug.u_cdc.req_s` (tck to hclk) and `u_debug.u_cdc.ack_s` (hclk to tck), the request/acknowledge toggles of `dmi_cdc` |
| Pairs with no recognised scheme | 54 pairs, reported as 20 `CDC_NO_SYNC` destinations. Every one is DMI payload behind that handshake: 19 Debug Module registers on hclk (`sbaddr`, `sbdata`, `sbaccess`, `dmactive`, `ndmreset`, `hartreset`, `haltforced`, `hold0..2`, `rdata_o` and the other `sb*` fields) and the DTM's `rsp_q` on tck. |

The payload is held stable by the toggle handshake from the moment the request toggles until the acknowledge returns (DEBUG [N-7.16]), so it needs no synchroniser of its own. This is the same set HAL reports and waives (`flow/2_static/hal_waivers.txt`, CLOCK DOMAIN). The proper closure is to declare the handshake to JasperGold as a scheme, for example:

    check_cdc -scheme -add MUX_NDFF -map {{data ...} {dout ...} {sready ...} {dready ...}}

The tool then checks the payload against the handshake instead of reporting it.

## Not finished: setup still to write

The other 357 violations come from setup that has not been written yet. They are not findings about the design.

| Tag | Count | What is missing |
|---|---|---|
| `RDC_RS_DFRS` | 310 | The internal resets (`hreset_n`, `preset_n`, `core_rst_n`, `dm_rst_n`, `ext_hrst_n`, `ext_prst_n`, the TAP reset) are not declared yet. Only `ext_rst_n` is. The reset-domain review `flow/2_static/rdc_review.md` lists them, and each has to be declared with its domain. |
| `PRT_IS_UNCK` | 39 | The input pins have no clock assigned. JTAG pins belong to `tck`. UART rx, SPI slave, I2C, GPIO, `boot_sel` and `ext_rst_n` are asynchronous and are synchronised inside (GPIO R-7, the `boot_sel` path in `flow/signoff/g3/README.md`). Each needs `config_rtlds -port`. |
| `RST_NO_SYNC` | 29 | Follows from the undeclared resets |
| `CDC_PR_FOUT` | 7 | Warnings: fan-out of a crossing; to be read once the scheme is declared |
| `RST_RS_CONV`, `RST_RS_RIDP` | 4, 2 | Reset convergence and reset in a data path; to be read once the resets are declared. The AND of the two core resets is known and waived in HAL (CORE [N-7.33]). |

## State of row 3.15

**In Progress.**
- The clock-domain half is confirmed: one asynchronous boundary, synchronisers present, and the payload explained.
- Still to do:
  - declare the handshake scheme;
  - declare the port clocks;
  - declare the internal resets, and redo the reset-domain review with the tool (plan task 3.5; RDC-1 is fixed in the RTL).
