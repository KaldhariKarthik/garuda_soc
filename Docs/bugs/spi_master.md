# Bugs: SPI master (rtl/spi_master)

Owner: Track B. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).
Priorities: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).

<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. Run `bugs.py check` before pushing. -->
| ID | Title | Status | Prio | Found-by | Found | Fixed-in | Regression test | Evidence | Formerly |
|---|---|---|---|---|---|---|---|---|---|
| SPIM-1 | IO1 | FIXED | P1 | `tb_spim` byte compare | 2026-09-22 | legacy | `t_spim_flash_read`; 11 register-level checks passed *with the bug present* | HISTORY_2026.md L117 | - |
| SPIM-2 | HAL TERMST/UNRCHS: state MODE is never entered and has no exit; | OPEN | P3 | - | 2026-10-04 | - | - | HISTORY_2026.md L311 | - |
| VIP-1 | 51 tests: 16 with no UVM errors, 35 with scoreboard errors. The same 51 on Mirafra's own RTL and top give the identic... | CLOSED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L343 | - |

## Details

### SPIM-1

*From `Docs/BUGS.md` at b90b481, line 117, section "1c. Peripherals — vendored IP and wrappers, 2026-09-22/23".*

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| **SPIM-1** | 13 SPI | FIXED | **high** (every read returns zero) | Our wrapper connected MISO to the vendored engine's `spi_sdi0`. Upstream's lanes are quad-SPI pads: single-bit mode drives IO0 (`sdo0` = MOSI) and shifts in **IO1** (`data_int_next = {data_int[30:0], sdi1}`). Nothing complained — chip select, SCLK, command and address were all correct on the wire and the flash returned the right bytes; only the data read back as zero. Ruling D-23 came out of this. | `tb_spim` byte compare | `t_spim_flash_read`; 11 register-level checks passed *with the bug present* |

### SPIM-2

*From `Docs/BUGS.md` at b90b481, line 311, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **SPIM-2** | `rtl/third_party/pulp/axi_spi_master/src/spi_master_controller.sv` | OPEN (vendored) | HAL `TERMST`/`UNRCHS`: state `MODE` is never entered and has no exit; in it chip-select is held low with the clock running. Unreachable in normal operation, but a state register upset would hang the SPI master until reset. A recovery arc to `IDLE` is a one-line vendor patch; not applied today because it needs a patch record under the vendoring mechanism. |

### VIP-1

*From `Docs/BUGS.md` at b90b481, line 343, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **VIP-1** | Mirafra UVM environment on the SPI master | RUN, no defect attributed to GARUDA | Mirafra's `pulpino__spi_master__ip_verification` (their APB VIP on the registers, their SPI VIP on the pins, register model, scoreboard) was run against the block as integrated, `garuda_spim_top`, on Xcelium 22.09 with UVM 1.2. It ships a Questa makefile only; on Xcelium it needs `-scu` (its packages are imported at file scope) and `-timescale 1ns/1ps`, and it does not elaborate under irun 15.2, so its coverage cannot be opened in IMC here. **51 tests: 16 with no UVM errors, 35 with scoreboard errors. The same 51 on Mirafra's own RTL and top give the identical result, test for test**, so the 35 are the environment's behaviour on this simulator and not a defect in the GARUDA block: its scoreboard compares APB write data with MOSI only, so read tests and tests with no SPI traffic are reported as mismatches. One real difference between the two RTL copies: Mirafra's `spi_master_rx.sv` samples MISO on lane 0, upstream (which GARUDA vendors) samples lane 1, and the GARUDA wrapper wires the board MISO there. The read path is therefore **not** checked by this environment; it is checked by `tb_spim` and by the flash boot test. |
