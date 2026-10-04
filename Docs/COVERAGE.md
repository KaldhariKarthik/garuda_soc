# GARUDA coverage — status and signoff notes

## 2026-10-04: first collection over the whole SoC

Everything below this section is the 2026-08-04 core-and-DSU measurement and is
kept as history. This is the first time coverage has been collected on the SoC
blocks and the chip, and the first on the Rev 4.0 RTL.

- Collected by the vManager session `flow/regress/garuda.vsif`: 119 runs (12 block
  benches, 20 core unit benches, DSU vs model, 63 ISA tests, 12 sanity programs,
  3 integration benches, 8 chip programs), all passing, each under irun 15.2 with
  `-coverage all`. Merged with IMC by `flow/regress/merge_cov.sh` into
  `sim/cov_merged/` (`imc -load sim/cov_merged/merged` to browse).
- Numbers are IMC's overall average per module definition (block, expression and
  toggle together), from `sim/cov_merged/module_summary.txt`.

| Area | Module, overall average |
|---|---|
| **Core** | `garuda_core_top` 88.79%, `decode_control` 83.72%, `pipe_ctrl` 86.08%, `trap_ctrl` 82.50%, `csr_file` 72.85%, `garuda_if_stage_top` 60.57%, `id_stage` 91.99%, `ex_stage` 93.77%, `mem_stage` 84.77%, `d_port_ahb_master` 97.03%, `garuda_iport_ahb_master` 84.09%, `garuda_prefetch_buffer` 85.81%, `regfile` 100.00%, `clic_ctrl` 50.00% |
| **DSU** | `dsu_top` 99.74%, `mac_unit` 97.57%, `saturation_unit` 81.68%, `overflow_flag` 83.33%, `barrel_shifter` 100.00%, `dsu_stall` 100.00% |
| **Bus** | `ahb_interconnect` 68.41%, `ahb_arbiter` 96.77%, `ahb2apb_bridge` 86.21%, `ahb2apb_apb_fsm` 98.71%, `garuda_apb_shim` 95.60%, `ahb_mem_slave_if` 95.34% |
| **System** | `dma_top` 55.45%, `dma_chan` 89.61%, `dma_engine` 94.26%, `dma_apb_slave` 77.03%, `clic_top` 64.52%, `clic_apb` 81.94%, `clic_select` 54.64%, `timers_top` 75.39%, `mtime` 87.20%, `wdt` 87.94%, `reset_ctrl` 87.26%, `reset_ctrl_apb` 90.09%, `clk_div` 97.73%, `debug_module` 81.53%, `dtm` 90.61%, `jtag_tap` 95.32%, `dmi_cdc` 97.06%, `sba_master` 94.03% |
| **Peripherals** | `garuda_spim_top` 89.84%, `garuda_i2c_top` 92.45%, `garuda_uart_top` 88.59%, `garuda_gpio_top` 64.17%, `garuda_pwm_top` 95.76%, `garuda_pwm_core` 100.00%, `garuda_spis_top` 91.38%, `garuda_spis_core` 100.00% |
| **Top** | `garuda_soc_top` 56.00%, `garuda_chip_top` 54.80% |

Of the 54 design modules listed, 16 are at or above 95%, 18 are between 85% and
95%, and 20 are below 85%. **Coverage is not closed and no bar is claimed.**

Covergroups (`tb/cov/garuda_cov.sv`, core only): hazard 97.9%, ahb 92.5%,
ldst 91.0%, trap 90.0%, decode 87.5%, dsu 82.0%; alu is fully covered and so does
not appear in the uncovered report. There are no covergroups on the SoC blocks.

What the low numbers are, as far as they have been looked at:

- `garuda_chip_top`, `garuda_soc_top`, `dma_top`, `ahb_interconnect`, `timers_top`:
  wiring-only modules whose score is toggle on wide buses (address and data bits
  that the chip programs never drive high). Not reviewed bit by bit.
- `clic_ctrl` 50%, `clic_select` 54.6%, `clic_top` 64.5%: the CLIC was not
  reached by the block-level review on 2026-10-04 and its bench is the original
  15 checks. This is a real gap.
- `garuda_if_stage_top` 60.6%, `csr_file` 72.9%: the two gaps named in Category C
  below (prefetch corners, CSR sweep) are still open.
- `garuda_gpio_top` 64.2%: thin wrapper, bench not extended on 2026-10-04.

---

Generated 2026-08-04 from a merged database of 80 runs.
See `docs/HANDOFF.md` for the full verification handoff; this file covers coverage only.
Reproduce with `./scripts/run_coverage.sh`; reports land in `sim/cov/`.

---

## The flow, and why it is split across two simulators

The regression runs on **Xcelium 22.09**. Coverage is collected on **Incisive 15.20**.
That is deliberate, not an accident of habit:

IMC on this machine is Incisive 15.20 and **cannot read an Xcelium 22.09 coverage
database** —

```
*E,DBERR: Error loading database file ... serialization exception
```

There is no format-downgrade option in `xrun`, no UCIS XML export, and no newer IMC
installed. The fix was to move the *writer* back rather than the reader forward:
`irun` 15.20 is installed, matches IMC's vintage, and the design builds and runs under
it unchanged.

| tool | role |
|---|---|
| `xrun` (Xcelium 22.09) | regression / correctness signoff. Every one of the 23 RTL bugs was found here. |
| `irun` (Incisive 15.20) | coverage collection only |
| `imc` (Incisive 15.20) | merge + report |

Both simulators consume the **same filelists**, so a test measured here is the same test
that passes there. As a side benefit the functional-coverage percentages were
cross-checked between the two and agree exactly, which is an independent check on the
covergroups themselves. When VCS arrives it becomes a third cross-check rather than the
enabler.

### Two traps worth knowing

1. **`-initial_model union_all` is mandatory.** IMC's default is `primary_run`, which
   builds the merged model from the *first* run only and silently discards every run
   whose top module differs. With the default, all seven unit-level databases —
   including `tb_dsu_top`'s 645-test sweep — contributed **nothing**, and the merge
   reported no error while doing it. The DSU internals sat unchanged at their
   system-level numbers and looked like a real coverage gap.
2. **`report -summary` does not show covergroups.** Its Functional column reads `n/a`
   even when covergroups are present and populated. Use
   `report -detail -metrics covergroup`.

---

## Where coverage stands

**Code coverage (merged): `garuda_core_top` instance tree at 73.24%**
(was 62.71% before the closure work).

### The shortfall is toggle, not logic

Split by metric across the design modules:

| metric | mean |
|---|---|
| block (statement) | **98.5%** |
| expression (branch) | **96.1%** |
| **toggle** | **86.0%** |

This matters for how the remaining work is scoped. Statement and branch coverage are
effectively closed — `clic_ctrl`, `garuda_if_stage_top`, `garuda_pc_gen` and `trap_ctrl`
have **zero uncovered blocks** yet score 60-82% overall. What is missing is bits of wide
buses that never change state, not logic that never ran.

Toggle demands every bit of every signal go 0->1 *and* 1->0. Ordinary test programs use
small constants and low addresses, so the upper half of every 32-bit datapath sits still.
`sw/tests/t_cov.S` attacks this directly - complementary patterns
(0000_0000 / FFFF_FFFF / 5555_5555 / AAAA_AAAA) through registers, ALU operands, store
data, addresses spread across the map, every writable CSR, and a routine linked at
0x1002_0000 so the PC's upper bits move.
**24 of 44 design modules are at or above 95% overall**, including every DSU datapath block —
`barrel_shifter`, `mult_16x16`, `readback_mux`, `result_selector`, `dsu_decoder`,
`forward_unit`, `load_formatter`, `mul32`, `wb_stage`, `csr_rw`,
`hazard_forward_unit` at 100%; `dsu_top` 99.65%, `csa_3to2` 99.17%,
`kogge_stone_49` 98.65%.

**Functional coverage (merged):**

| covergroup | |
|---|---|
| alu | **100%** |
| hazard | 97.92% |
| trap | 90.00% |
| ahb | 88.54% |
| ldst | 88.00% |
| decode | 86.98% |
| dsu | 64.00% |

> **The 88.54% AHB figure is inflated and must not be quoted as-is.** `cg_ahb`
> counted every SEQ transfer as coverage with no cross against HBURST, so the
> number went *up* because of ERRATUM BUS-A — a coverpoint that rewarded a
> protocol violation. The cross now exists (`x_i_trans_burst`) with the illegal
> combination in `ignore_bins`, so this figure will move when re-measured.
> See `docs/ORACLES.md`.

**The signoff bar of ≥95% statement/branch/toggle is NOT met.** What follows is the
per-module accounting the plan's Coverage row 10 requires: every module below the bar
either carries a written justification or a named next action. Nothing here is waived
because it was inconvenient to test.

---

## Category A — excluded, not silicon

These are verification constructs. They must be **excluded from the DUT metric**, not
chased; covering them measures the testbench, not the chip.

| entity | why |
|---|---|
| `ahb_mem_slave` (69.09%) | Verification memory model standing in for a TCM and interconnect that do not exist yet. Its own header states it verifies nothing about arbitration, decode or the bridge. |
| `tb_boot`, `tb_dsu_top`, `tb_top` | testbenches |
| `garuda_cov` | the covergroup module itself |
| `branch_if`, `hazard_if`, `id_stage_if`, `imm_gen_if`, `regfile_if` (0%) | SystemVerilog interfaces belonging to the unit testbenches |

## Category B — RESOLVED, previously believed blocked

This section previously claimed `clic_ctrl` was blocked on an unresolved SHV memory-model
decision, because driving `shv=1` produced interrupts after which `mepc` read as 0.

**That diagnosis was wrong.** The corruption was ERRATUM T-4 — interrupt entry was not
gated on a valid instruction in EX, so an interrupt landing on a pipeline bubble latched
`mepc = idex_pc = 0`. SHV merely exposed it more often, arriving at arbitrary points in
the instruction stream rather than at one fixed offset.

With T-4 fixed, **SHV vectoring works end to end** through a 4096-entry jump table. That
also settles `clic_ctrl.v`'s open question by evidence rather than by decision: the RTL
implements the jump-instruction interpretation, and it is correct.

`clic_ctrl` is now at **65.06%** (from 5.58%). The remainder is toggle coverage on the
`mtvt` / `vector_target_o` upper bits, which is the same wide-bus toggle problem as every
other module below the bar — not a blocker.

## Category C — genuine gaps, with the test that closes each

| entity | | next action |
|---|---|---|
| `garuda_if_stage_top` | 58.36% | Prefetch-buffer fill/drain corners: buffer full, redirect with 2 fetches in flight, back-to-back redirects. Extend `t_flush` with deeper I-port wait states and tighter redirect spacing. |
| `csr_file` | 67.93% | Unimplemented-CSR reject paths and the counter CSRs. Most of the CSR *space* is never addressed. A directed CSR sweep walking every implemented address plus a sample of unimplemented ones. |
| `garuda_pc_gen` | 75.94% | Redirect-source priority combinations (trap vs EX vs ID in the same cycle). |
| `trap_ctrl` | 79.59% | Exception-priority matrix: MEM-point vs EX-point vs interrupt arriving together. Only a few of the ~7 causes have been raised simultaneously with another. |
| `overflow_flag`, `saturation_unit` | 77.78%, 81.68% | DSU saturation corners. The generator already randomises operands; needs directed values that land exactly on the 48-bit clamp boundaries. |
| `garuda_prefetch_buffer`, `garuda_iport_ahb_master`, `mem_stage`, `pipe_ctrl`, `branch_predict`, `ex_stage`, `if_id`, `id_stage`, `branch_unit`, `imm_gen`, `ex_mem`, `d_port_ahb_master` | 82–94% | Within reach of 95% from randomised-seed sweeps; run `make regress_rand` across more seeds and re-measure before writing new tests. |

## Known scope limit — state this, do not let the number imply otherwise

`rtl/clic/` **is empty**. The CLIC block does not exist as RTL; only `clic_ctrl.v`, the
core-side handshake, does. The verification plan asks for a CLIC arbitration covergroup —
there is nothing to cover. The same is true of `dma`, `debug`, `isram`, `dsram`,
`ahb2apb` and every peripheral: empty directories. Coverage here describes **core + DSU
only**.

---

## Reproducing

```bash
source scripts/setup_env.sh
./scripts/run_coverage.sh          # collect 79 runs, merge, report
```

Outputs:

| file | |
|---|---|
| `sim/cov/summary.txt` | instance-hierarchy code coverage |
| `sim/cov/module_summary.txt` | per module-definition (the signoff view) |
| `sim/cov/functional.txt` | covergroup detail, bin level |
| `sim/cov/detail.txt` | full per-line detail for triage |

Note `functional.txt` is an *uncovered* report: a covergroup at 100% does not appear in
it at all. `cg_alu`'s absence is the pass, not a missing measurement.
