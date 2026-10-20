# GARUDA coverage — status

> **The current figures, block by block, are in `Docs/coverage/COVERAGE_BY_BLOCK.md`**
> (statement, expression, toggle, FSM, functional, assertions triggered, and every
> exclusion with its justification), made by `make cov_chart` from IMC's reports, first on
> 2026-10-12. Every block can also be run and merged by hand: `flow/cov/all_blocks_report.tcl`.
> The merged core figures measured on 2026-10-04 were too low: the merge had left out
> nineteen of the twenty unit and element benches (entry TOOL-B5 in `Docs/bugs/track_b.md`).

**Status at 2026-10-14.** The whole-SoC measurement in this file is from 2026-10-04, the first
on the whole SoC and on the Rev 4.0 RTL. **Coverage is not closed, and no bar is claimed.**
The sign-off targets are in `flow/0_signoff_criteria.md` (rows 2 and 3).

The core-only measurement of 2026-08-04 is in git history. Its figures do not apply to the
current RTL.

---

## 1. How to collect it

Use the vManager session. Do not use `scripts/run_coverage.sh` for sign-off: it covers the
core and DSU runs only.

```bash
source scripts/setup_env.sh
export PATH=/home/install/INCISIVE152/tools/bin:$PATH
# vManager: flow/regress/garuda.vsif (119 runs, 8 in parallel, about 8 minutes)
flow/regress/merge_cov.sh          # IMC merge into sim/cov_merged/
imc -load sim/cov_merged/merged    # browse
```

The full commands are in `flow/COMMANDS.md` ("Stages 3 to 6"). The UVM targets
(`make uvm_clic`, `uvm_timers`, `uvm_pwm`, `uvm_gpio`, `uvm_crg`) collect block coverage of
their own.

### Rules for IMC

1. **Collect with `irun` 15.20, not `xrun`.** IMC on this machine is 15.20. It cannot read an
   Xcelium 22.09 database (`*E,DBERR: ... serialization exception`). Both simulators read the
   same filelists.
2. **Merge with `-initial_model union_all`.** The default, `primary_run`, keeps only the runs
   whose top module matches the first run. It discards the others and reports no error.
3. **Read covergroups with `report -detail -metrics covergroup`.** `report -summary` shows
   `n/a` for functional coverage even when the covergroups have data.
4. **The functional report lists uncovered bins only.** A covergroup at 100% is not in it.

---

## 2. Result, 2026-10-04

119 runs, all passing: 12 block testbenches, 20 core unit testbenches, the DSU against its
model, 63 ISA tests, 12 sanity programs, 3 integration testbenches, 8 chip programs.
Figures are IMC's overall average per module definition (block, expression and toggle together).

| Area | Module, overall average |
|---|---|
| **Core** | `garuda_core_top` 88.79%, `decode_control` 83.72%, `pipe_ctrl` 86.08%, `trap_ctrl` 82.50%, `csr_file` 72.85%, `garuda_if_stage_top` 60.57%, `id_stage` 91.99%, `ex_stage` 93.77%, `mem_stage` 84.77%, `d_port_ahb_master` 97.03%, `garuda_iport_ahb_master` 84.09%, `garuda_prefetch_buffer` 85.81%, `regfile` 100.00%, `clic_ctrl` 50.00% |
| **DSU** | `dsu_top` 99.74%, `mac_unit` 97.57%, `saturation_unit` 81.68%, `overflow_flag` 83.33%, `barrel_shifter` 100.00%, `dsu_stall` 100.00% |
| **Bus** | `ahb_interconnect` 68.41%, `ahb_arbiter` 96.77%, `ahb2apb_bridge` 86.21%, `ahb2apb_apb_fsm` 98.71%, `garuda_apb_shim` 95.60%, `ahb_mem_slave_if` 95.34% |
| **System** | `dma_top` 55.45%, `dma_chan` 89.61%, `dma_engine` 94.26%, `dma_apb_slave` 77.03%, `clic_top` 64.52%, `clic_apb` 81.94%, `clic_select` 54.64%, `timers_top` 75.39%, `mtime` 87.20%, `wdt` 87.94%, `reset_ctrl` 87.26%, `reset_ctrl_apb` 90.09%, `clk_div` 97.73%, `debug_module` 81.53%, `dtm` 90.61%, `jtag_tap` 95.32%, `dmi_cdc` 97.06%, `sba_master` 94.03% |
| **Peripherals** | `garuda_spim_top` 89.84%, `garuda_i2c_top` 92.45%, `garuda_uart_top` 88.59%, `garuda_gpio_top` 64.17%, `garuda_pwm_top` 95.76%, `garuda_pwm_core` 100.00%, `garuda_spis_top` 91.38%, `garuda_spis_core` 100.00% |
| **Top** | `garuda_soc_top` 56.00%, `garuda_chip_top` 54.80% |

Of the 54 design modules: 16 are at or above 95%, 18 are between 85% and 95%, 20 are below 85%.

Core covergroups (`tb/cov/garuda_cov.sv`): hazard 97.9%, ahb 92.5%, ldst 91.0%, trap 90.0%,
decode 87.5%, dsu 82.0%, alu 100%. The SoC blocks have no covergroups in this run; the UVM
environments added covergroups for CLIC, timers, PWM, GPIO and clock/reset after it.

The SoC-level run was made before the fixes of 2026-10-11 and before the P2 top split. Collect
it again after the lab run in `Docs/HANDOFF.md` §2.

---

## 3. Gaps, and the work that closes each

| Module | Gap | Next action |
|---|---|---|
| `clic_ctrl`, `clic_select`, `clic_top` | The SoC run used the original 15-check bench | Merge the `uvm_clic` coverage; write the six CLIC tests from AUD-11 |
| `garuda_if_stage_top` | Prefetch-buffer corners: buffer full, redirect with two fetches in flight, back-to-back redirects | Extend `t_flush` with deeper I-port waits and closer redirects |
| `csr_file` | Unimplemented-CSR paths and counter CSRs | Merge `t_cov`'s CSR sweep and `make csr_map`; decide C-16 |
| `trap_ctrl` | Exception priority when MEM-point, EX-point and interrupt arrive together | An exception-priority matrix test |
| `garuda_gpio_top` | Thin wrapper; the SoC bench was not extended | Merge the `uvm_gpio` coverage |
| `saturation_unit`, `overflow_flag` | 48-bit clamp boundaries | Directed values on the clamp boundaries |
| `garuda_chip_top`, `garuda_soc_top`, `dma_top`, `ahb_interconnect`, `timers_top` | Wiring modules; toggle on wide buses | Review toggle bit by bit, then waive in `flow/cov/<blk>_exclusions.tcl` with one reason per line |

### Exclude, do not chase

These are verification constructs, not silicon. Keep them out of the design metric:
`ahb_mem_slave` (the flat memory model in `tb_boot`), the testbench tops, `garuda_cov`, and
the SystemVerilog interfaces of the unit testbenches.

## 4. Functional coverage without IMC (Verilator), and how it compares

The sign-off figures stay IMC's (`make cov_chart`, on the lab machine). Functional coverage can
also be measured anywhere with Verilator 5.053 (`source scripts/setup_open_tools.sh`) and read
with `tools/cov_local.py`, which sums the `coverage.dat` files of several runs and sets them
next to the block's latest IMC record in `Docs/coverage/FINDINGS.md`:

```
COV=1 ./scripts/run_uvm_local.sh dma                        # UVM tests, one coverage.dat per test
python3 tools/cov_local.py report  sim/uvm_local/dma/cov/*.dat
python3 tools/cov_local.py compare DMA sim/uvm_local/dma/cov/*.dat --only cg_beat,cg_ctrl
```

A bench is built for it with `--coverage-user` and run with `+verilator+coverage+file+<path>`.

- **Comparable:** covergroup bins. On the same covergroups and tests the two tools agree bin for
  bin: the DMA block bench gives `cg_beat` 97/134 and `cg_ctrl` 25/27 under both, with the same
  holes by name (2026-10-21). Use it to find which stimulus closes which hole before a lab run.
- **Not comparable:** Verilator's line and toggle counts are not IMC's block and toggle counts,
  and Verilator has no FSM or assertion coverage. Those stay IMC-only.
- **The "0 % on Verilator" of the DMA was the tool, not the design:** Verilator 5.052 returned 0.0 %
  from `get_coverage()` for every covergroup (`Docs/bugs/track_a.md` TOOL-A2), so `dma_cov.sv`
  was kept away from Verilator. 5.053 is correct and `dma_cov.sv` now runs under it.
- **DMA after the UVM environment** (2026-10-21, Verilator, block bench plus the UVM register,
  directed and three random runs): `cg_beat` 131/131 (three bins that no test can reach are now
  `ignore_bins`, TB-A6), `cg_ctrl` 26/27; DMA functional 157/158, against 122/161 (75.8 %) on the
  IMC record. The open bin is a re-arm inside the channel's own beat, which is DMA-9 and waits for
  its ruling. `make cov_chart` now merges the `uvm_dma` runs, so the IMC chart should show the
  same once run on the lab machine.
