# GARUDA SoC: which tests give the coverage

Written 2026-10-16 from IMC 15.2, tree `bcc0728` plus the TOOL-29 rename. Every figure is a covered/total pair IMC printed. To compare like with like, all three columns are measured the same way: merged with `-initial_model union_all`, reported per module type, added over the modules of the block, **before any waiver** (so the waived blocks read lower here than in `COVERAGE_BY_BLOCK.md`).

- **Directed**: the 122 runs of `flow/regress/garuda.vsif` (block benches, unit and element benches, ISA and sanity programs, chip programs).
- **UVM**: the block's UVM environment, register test + directed test + 20 random seeds (nine blocks have one).
- **Both**: the directed runs and every UVM run merged into one database.
- **Code** is statement + expression + toggle + FSM items together. Functional coverage is not in the comparison: the UVM covergroups and the bound covergroups are different plans, so it is shown per source.

## What it shows

1. **Where a block has a UVM environment, the UVM environment gives more code coverage than the directed benches, on all nine.** The largest differences: CLIC 96.1% against 62.4%, timers 94.0% against 76.1%, DMA 76.6% against 62.0%, GPIO 52.5% against 41.7%. Every assertion of the eight track B blocks is triggered by the UVM runs; the directed runs leave up to 14% of them untriggered (SPI slave 85.7%, timers 88.9%, CLIC 90.0%; GPIO and UART none).
2. **Merging the directed runs with the UVM runs adds something on three blocks only:** DMA +1.5 points (the directed bench `tb_dma` reaches statements and expressions the UVM environment does not: 99.1% against 98.1% and 97.8% against 89.1%), UART +0.9, I2C +0.1. On the other six the directed runs add nothing the UVM runs do not already cover.
3. **For the eight track B blocks one UVM test carries almost all of it.** IMC's ranking needs one or two runs per block, usually `directed_s1`; the 20 random seeds are redundant for code coverage on every block (they still check behaviour on new values, and on timers and GPIO a single seed is the top run). More seeds will not raise these numbers; new directed scenarios or constraints will.
4. **The nine blocks without a UVM environment depend on one or two benches each:** `san_t_cov` gives 57% of the core on its own; `dsu` 94% of the DSU; `tb_ahb_ic_wait` 58% of the AHB; `chip_integ` 59% of the bridge; `tb_mem` 80% of the memories; `tb_debug` all of debug's 80.8%; `tb_spim` 51% of the SPI master. The lowest are SPI master (55.5%), the chip wiring (56.0%), AHB (70.7%) and the bridge (79.0%): a UVM environment for those would be the largest gain left.
5. **Recommendation for the chart:** keep measuring the eight track B blocks on their UVM environments (as `COVERAGE_BY_BLOCK.md` does); measure the DMA on **both merged**, now that it has a UVM environment (78.1% code, against 62.0% today), once its covergroup is fixed (point 6).
6. **Two findings from this run, both in the DMA UVM environment (track A):**
   - `random_s12` fails (14 UVM_ERRORs, `sim/uvm_dma/random_s12.log`): the first is `sb_stat` on channel 0, DUT `SR.REMAINING` 12 against 21 in the model; the arbitration and status errors that follow come from it. The other 21 runs pass. Not yet debugged: model or RTL. It is left out of every figure here.
   - `cg_dma_xfer` declares `cp_soff` and `cp_doff` on an `int` with no bins, so IMC makes 64 automatic bins over the whole 32-bit range and every real offset (0 to 3) falls in the first: 1 of 64 each, and their cross with the size `x_size_offset` has 12,034 bins of which 1 can ever be hit. IMC therefore reports the environment's covergroups as 2.7% of bins (347/12626) where the average per covergroup is 88.8%; without those three items it is 74.1% (344/464). Fix: explicit bins `{[0:3]}` on both.

## The commands (IMC 15.2, from the repository root)

```
imc -exec <tcl>       with, for the merge of one source:
merge -runfile <list of run directories> -out <dir>/merged -overwrite -initial_model union_all
load -run <dir>/merged
report -summary -type -metrics block:expression:toggle:fsm:assertion:covergroup -out <dir>/type_summary.txt
```
and for the ranking of one block, `rank -runfile <list> -elements_file <file> -text -out <dir>/rank.txt`, where the elements file has one line `-type <module>` per module of the block (the module lists are those of `tools/gen/cov_chart.py`). The run lists are the 122 passing directories `sim/run_test/<test>/cov_work/garuda/<test>/` and the passing `sim/uvm_<blk>/cov_work/scope/<test>/`.

## Code coverage by source

| Block | Directed | UVM | Both | Better source | Gain from merging |
|---|---|---|---|---|---|
| RV32IM core | 85.0% (8228/9676) | – | 85.0% (8228/9676) | directed (no UVM environment) | – |
| DSU | 95.7% (3664/3828) | – | 95.7% (3664/3828) | directed (no UVM environment) | – |
| AHB interconnect | 70.7% (1174/1661) | – | 70.7% (1174/1661) | directed (no UVM environment) | – |
| AHB to APB bridge | 79.0% (1174/1486) | – | 79.0% (1174/1486) | directed (no UVM environment) | – |
| Memories | 92.4% (996/1078) | – | 92.4% (996/1078) | directed (no UVM environment) | – |
| DMA | 62.0% (2315/3732) | 76.6% (2859/3732) | 78.1% (2914/3732) | UVM | +1.5 points |
| Debug | 79.5% (1465/1842) | – | 79.5% (1465/1842) | directed (no UVM environment) | – |
| CLIC | 62.4% (739/1185) | 96.1% (1139/1185) | 96.1% (1139/1185) | UVM | none |
| Timers and watchdog | 76.1% (1176/1546) | 94.0% (1454/1546) | 94.0% (1454/1546) | UVM | none |
| Clock divider and reset | 81.7% (318/389) | 86.6% (337/389) | 86.6% (337/389) | UVM | none |
| PWM | 96.0% (509/530) | 96.4% (511/530) | 96.4% (511/530) | UVM | none |
| GPIO | 41.7% (537/1289) | 52.5% (677/1289) | 52.5% (677/1289) | UVM | none |
| UART | 86.4% (785/909) | 87.8% (798/909) | 88.7% (806/909) | UVM | +0.9 points |
| I2C | 87.8% (638/727) | 94.6% (688/727) | 94.8% (689/727) | UVM | +0.1 points |
| SPI master | 55.5% (1283/2313) | – | 55.5% (1283/2313) | directed (no UVM environment) | – |
| SPI slave | 89.8% (317/353) | 90.1% (318/353) | 90.1% (318/353) | UVM | none |
| APB shim (shared by six peripherals) | 98.0% (245/250) | – | 98.0% (245/250) | directed (no UVM environment) | – |
| Chip and SoC top (wiring) | 56.0% (1550/2767) | – | 56.0% (1550/2767) | directed (no UVM environment) | – |

## Per metric, the nine blocks with a UVM environment

| Block | Metric | Directed | UVM | Both |
|---|---|---|---|---|
| DMA | statement | 99.1% | 98.1% | 99.1% |
| DMA | expression | 97.8% | 89.1% | 97.8% |
| DMA | toggle | 60.3% | 75.7% | 77.1% |
| DMA | FSM | 100.0% | 100.0% | 100.0% |
| DMA | assertions triggered | 100.0% | 96.2% | 100.0% |
| DMA | functional | 75.8% (bound covergroups) | – (UVM covergroups) | – |
| CLIC | statement | 100.0% | 100.0% | 100.0% |
| CLIC | toggle | 61.7% | 96.1% | 96.1% |
| CLIC | assertions triggered | 90.0% | 100.0% | 100.0% |
| CLIC | functional | – (bound covergroups) | 100.0% (UVM covergroups) | – |
| Timers and watchdog | statement | 100.0% | 100.0% | 100.0% |
| Timers and watchdog | expression | 100.0% | 100.0% | 100.0% |
| Timers and watchdog | toggle | 74.9% | 93.8% | 93.8% |
| Timers and watchdog | assertions triggered | 88.9% | 100.0% | 100.0% |
| Timers and watchdog | functional | – (bound covergroups) | 100.0% (UVM covergroups) | – |
| Clock divider and reset | statement | 100.0% | 100.0% | 100.0% |
| Clock divider and reset | expression | 100.0% | 100.0% | 100.0% |
| Clock divider and reset | toggle | 75.7% | 82.2% | 82.2% |
| Clock divider and reset | assertions triggered | 90.5% | 100.0% | 100.0% |
| Clock divider and reset | functional | – (bound covergroups) | 100.0% (UVM covergroups) | – |
| PWM | statement | 100.0% | 100.0% | 100.0% |
| PWM | expression | 100.0% | 100.0% | 100.0% |
| PWM | toggle | 95.6% | 96.1% | 96.1% |
| PWM | assertions triggered | 94.4% | 100.0% | 100.0% |
| PWM | functional | – (bound covergroups) | 100.0% (UVM covergroups) | – |
| GPIO | statement | 52.5% | 53.8% | 53.8% |
| GPIO | expression | 94.4% | 94.4% | 94.4% |
| GPIO | toggle | 38.3% | 51.5% | 51.5% |
| GPIO | assertions triggered | 100.0% | 100.0% | 100.0% |
| GPIO | functional | – (bound covergroups) | 100.0% (UVM covergroups) | – |
| UART | statement | 92.9% | 92.5% | 93.4% |
| UART | expression | 97.0% | 100.0% | 100.0% |
| UART | toggle | 82.8% | 84.9% | 85.9% |
| UART | FSM | 100.0% | 100.0% | 100.0% |
| UART | assertions triggered | 100.0% | 100.0% | 100.0% |
| UART | functional | – (bound covergroups) | 98.1% (UVM covergroups) | – |
| I2C | statement | 98.4% | 98.4% | 98.9% |
| I2C | expression | 75.0% | 75.0% | 75.0% |
| I2C | toggle | 82.5% | 92.7% | 92.7% |
| I2C | FSM | 98.2% | 100.0% | 100.0% |
| I2C | assertions triggered | 95.0% | 100.0% | 100.0% |
| I2C | functional | – (bound covergroups) | 100.0% (UVM covergroups) | – |
| SPI slave | statement | 100.0% | 100.0% | 100.0% |
| SPI slave | expression | 100.0% | 100.0% | 100.0% |
| SPI slave | toggle | 87.4% | 87.7% | 87.7% |
| SPI slave | assertions triggered | 85.7% | 100.0% | 100.0% |
| SPI slave | functional | – (bound covergroups) | 100.0% (UVM covergroups) | – |

## Which runs carry the coverage (IMC `rank`)

IMC ranks every run against the modules of the block (code, assertions, covergroups, weight 1 each). **Optimized** runs are the smallest set that reaches the same total; a **redundant** run adds nothing the optimized set does not already cover. A redundant run can still be worth keeping (a random seed checks behaviour on new values even when it reaches no new line); what the ranking says is where the coverage comes from.

### RV32IM core

Total 87.0% (11056/12704) with 35 of 105 runs that reach the block at all; 70 redundant.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `san_t_cov` | 7201 | 56.68% | 56.68% |
| 2 | `unit_id_stage` | 486 | 60.51% | 14.24% |
| 3 | `unit_garuda_if_stage_top` | 474 | 64.24% | 7.61% |
| 4 | `unit_mem_stage` | 407 | 67.44% | 8.66% |
| 5 | `chip_integ` | 285 | 69.69% | 56.08% |
| 6 | `unit_branch_unit` | 213 | 71.36% | 3.55% |
| 7 | `unit_garuda_iport_ahb_master` | 165 | 72.66% | 3.43% |
| 8 | `unit_d_port_ahb_master` | 145 | 73.80% | 2.41% |
| 9 | `unit_garuda_prefetch_buffer` | 144 | 74.94% | 2.36% |
| 10 | `unit_imm_gen` | 137 | 76.02% | 3.35% |
| 11 | `unit_garuda_pc_gen` | 132 | 77.05% | 2.09% |
| 12 | `unit_mem_wb_reg` | 125 | 78.04% | 2.25% |
| 13 | `unit_reg_file` | 119 | 78.98% | 2.44% |
| 14 | `unit_csr_rw` | 115 | 79.88% | 1.75% |
| 15 | `unit_load_store_unit` | 110 | 80.75% | 1.73% |
| 16 | `unit_alu` | 108 | 81.60% | 1.77% |
| 17 | `unit_mul32` | 103 | 82.41% | 2.64% |
| 18 | `san_t_clic` | 94 | 83.15% | 46.49% |
| 19 | `unit_decode_control` | 88 | 83.84% | 2.13% |
| 20 | `san_t_dsu_b2b` | 78 | 84.45% | 47.05% |
| 21 | `unit_load_formatter` | 77 | 85.06% | 1.46% |
| 22 | `unit_branch_predict` | 71 | 85.62% | 2.79% |
| 23 | `unit_clic_ctrl` | 56 | 86.06% | 0.85% |
| 24 | `chip_wdt` | 30 | 86.30% | 49.76% |
| 25 | `isa_p_illegal` | 28 | 86.52% | 45.51% |
| 26 | `unit_hazard_forward_unit` | 24 | 86.70% | 0.32% |
| 27 | `isa_p_csr` | 10 | 86.78% | 46.63% |
| 28 | `san_t_hold_flush_matrix` | 10 | 86.86% | 53.60% |
| 29 | `isa_p_ma_fetch` | 5 | 86.90% | 45.65% |
| 30 | `chip_basic` | 3 | 86.93% | 53.79% |
| 31 | `chip_flash` | 3 | 86.95% | 52.59% |
| 32 | `isa_p_mcsr` | 3 | 86.97% | 40.77% |
| 33 | `isa_p_sbreak` | 3 | 87.00% | 43.47% |
| 34 | `isa_p_zicntr` | 3 | 87.02% | 41.61% |
| 35 | `chip_jtag` | 1 | 87.03% | 46.36% |

### DSU

Total 95.7% (3664/3828) with 3 of 86 runs that reach the block at all; 83 redundant.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `dsu` | 3614 | 94.41% | 94.41% |
| 2 | `san_t_hold_flush_matrix` | 45 | 95.59% | 35.63% |
| 3 | `chip_jtag` | 5 | 95.72% | 22.94% |

### AHB interconnect

Total 69.8% (1565/2243) with 7 of 10 runs that reach the block at all; 3 redundant.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `tb_ahb_ic_wait` | 1299 | 57.91% | 57.91% |
| 2 | `chip_jtag` | 186 | 66.21% | 45.43% |
| 3 | `chip_integ` | 65 | 69.10% | 54.48% |
| 4 | `chip_wdt` | 8 | 69.46% | 45.25% |
| 5 | `chip_irq` | 3 | 69.59% | 52.39% |
| 6 | `chip_basic` | 2 | 69.68% | 50.78% |
| 7 | `chip_flash` | 2 | 69.77% | 48.95% |

### AHB to APB bridge

Total 79.4% (1335/1682) with 7 of 9 runs that reach the block at all; 2 redundant.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `chip_integ` | 996 | 59.22% | 59.22% |
| 2 | `chip_flash` | 202 | 71.22% | 48.81% |
| 3 | `tb_bridge` | 91 | 76.63% | 42.87% |
| 4 | `chip_uart` | 22 | 77.94% | 41.85% |
| 5 | `chip_periph` | 18 | 79.01% | 46.02% |
| 6 | `chip_wdt` | 4 | 79.25% | 33.17% |
| 7 | `chip_irq` | 2 | 79.37% | 44.77% |

### Memories

Total 92.2% (1190/1291) with 4 of 10 runs that reach the block at all; 6 redundant.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `tb_mem` | 1032 | 79.94% | 79.94% |
| 2 | `chip_wdt` | 150 | 91.56% | 70.33% |
| 3 | `chip_flash` | 7 | 92.10% | 77.38% |
| 4 | `chip_basic` | 1 | 92.18% | 79.86% |

### DMA

Total 79.9% (3286/4113) with 5 of 30 runs that reach the block at all; 25 redundant, of which 19 are UVM random seeds.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `tb_dma` | 2592 | 63.02% | 63.02% |
| 2 | `UVM reg_s1` | 597 | 77.53% | 53.49% |
| 3 | `UVM directed_s1` | 84 | 79.58% | 61.61% |
| 4 | `chip_wdt` | 9 | 79.80% | 4.21% |
| 5 | `chip_irq` | 4 | 79.89% | 16.78% |

### Debug

Total 80.8% (1701/2105) with 1 of 9 runs that reach the block at all; 8 redundant.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `tb_debug` | 1701 | 80.81% | 80.81% |

### CLIC

Total 95.8% (1561/1630) with 1 of 31 runs that reach the block at all; 30 redundant, of which 20 are UVM random seeds.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `UVM directed_s1` | 1561 | 95.77% | 95.77% |

### Timers and watchdog

Total 95.2% (1848/1941) with 2 of 31 runs that reach the block at all; 29 redundant, of which 19 are UVM random seeds.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `UVM random_s11` | 1845 | 95.05% | 95.05% |
| 2 | `UVM directed_s1` | 3 | 95.21% | 82.07% |

### Clock divider and reset

Total 89.6% (484/540) with 2 of 33 runs that reach the block at all; 31 redundant, of which 19 are UVM random seeds.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `UVM directed_s1` | 482 | 89.26% | 89.26% |
| 2 | `UVM random_s1` | 2 | 89.63% | 87.41% |

### PWM

Total 97.0% (647/667) with 1 of 31 runs that reach the block at all; 30 redundant, of which 20 are UVM random seeds.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `UVM directed_s1` | 647 | 97.00% | 97.00% |

### GPIO

Total 53.9% (718/1331) with 3 of 31 runs that reach the block at all; 28 redundant, of which 19 are UVM random seeds.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `UVM random_s1` | 689 | 51.77% | 51.77% |
| 2 | `UVM reg_s1` | 25 | 53.64% | 48.91% |
| 3 | `chip_wdt` | 4 | 53.94% | 9.39% |

### UART

Total 89.0% (900/1011) with 3 of 31 runs that reach the block at all; 28 redundant, of which 19 are UVM random seeds.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `UVM directed_s1` | 891 | 88.13% | 88.13% |
| 2 | `tb_uart` | 8 | 88.92% | 78.83% |
| 3 | `UVM random_s1` | 1 | 89.02% | 63.60% |

### I2C

Total 95.3% (827/868) with 2 of 31 runs that reach the block at all; 29 redundant, of which 20 are UVM random seeds.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `UVM directed_s1` | 826 | 95.16% | 95.16% |
| 2 | `chip_basic` | 1 | 95.28% | 19.12% |

### SPI master

Total 56.8% (1384/2435) with 3 of 9 runs that reach the block at all; 6 redundant.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `tb_spim` | 1245 | 51.13% | 51.13% |
| 2 | `chip_integ` | 97 | 55.11% | 35.48% |
| 3 | `chip_flash` | 42 | 56.84% | 46.90% |

### SPI slave

Total 91.4% (381/417) with 2 of 31 runs that reach the block at all; 29 redundant, of which 19 are UVM random seeds.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `UVM directed_s1` | 380 | 91.13% | 91.13% |
| 2 | `UVM random_s10` | 1 | 91.37% | 87.77% |

### APB shim (shared by six peripherals)

Total 98.0% (338/345) with 4 of 15 runs that reach the block at all; 11 redundant.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `tb_spis` | 291 | 84.35% | 84.35% |
| 2 | `tb_spim` | 35 | 94.49% | 77.10% |
| 3 | `tb_i2c` | 11 | 97.68% | 74.78% |
| 4 | `tb_apb_shim` | 1 | 97.97% | 44.64% |

### Chip and SoC top (wiring)

Total 56.0% (1550/2767) with 8 of 8 runs that reach the block at all; 0 redundant.

| # | Run | Adds (items) | Cumulative | On its own |
|---|---|---|---|---|
| 1 | `chip_integ` | 987 | 35.67% | 35.67% |
| 2 | `chip_flash` | 376 | 49.26% | 32.16% |
| 3 | `chip_jtag` | 65 | 51.61% | 11.20% |
| 4 | `chip_uart` | 51 | 53.45% | 28.48% |
| 5 | `chip_periph` | 45 | 55.08% | 30.86% |
| 6 | `chip_wdt` | 12 | 55.51% | 15.65% |
| 7 | `chip_irq` | 10 | 55.87% | 21.76% |
| 8 | `chip_basic` | 4 | 56.02% | 27.94% |

