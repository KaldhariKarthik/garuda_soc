# GARUDA: the design flow, stage by stage

This is the industry RTL-to-GDS flow as it applies to GARUDA. The 1-TOPS signoff
workbook (gates G0 to G9) is filled from it: every stage below lists the workbook rows
its outputs close. Work is planned gate by gate, and inside a gate it runs in the order
of the stages here.

Written 2026-11-10. Scope until the 28 nm PDK arrives: **F0 to F9, up to RTL freeze**.
F10 to F16 are listed so the whole flow is visible; nothing in them is planned yet.

| Stage | Name | Main tools | Workbook rows | State (2026-11-10) |
|---|---|---|---|---|
| F0 | Tools and environment | every tool below; GCC, Spike | G0 | done (0.5 waits for the PDK, 0.6 at each gate close) |
| F1 | Specification and architecture freeze | documents in `Design_Docs/` | G1 1.1 to 1.13, 1.15 | done |
| F2 | Verification plan | vPlanner; `tb/*/GARUDA_*_vplan.csv` | G1 1.14 | done |
| F3 | RTL design: core, peripherals, SoC integration | editor; HAL for every change | G2 2.1 to 2.10, 2.14 to 2.17; G3 3.1 to 3.13, 3.17 to 3.22 | done except 3.10 (SRAM macros wait for the PDK) |
| F4 | Static checks: lint, CDC, RDC, X-propagation, coding rules | HAL; JasperGold Superlint and CDC; xrun `-xprop` | G2 2.11 to 2.13; G3 3.14 to 3.16 | done 2026-11-10 (`core_lint.md`, `coding_rules.md`, `xprop/`, Superlint rerun at one hour per group); X-propagation reaches every block of design logic (two tasks inlined by ruling, proven equivalent by LEC) |
| F5 | Block and unit verification: UVM, bound SVA, formal, mutation | xrun / irun; JasperGold FPV and UNR; Verilator for mutants | G4 4.1 to 4.9, 4.15, 4.16 | core units done 2026-11-10 (`flow/3_unit/`); every mutant set killed; block coverage closure carried to F8 |
| F6 | Core verification: ISA tests, Spike lockstep, random programs, benchmarks | irun; Spike; riscv-dv | G4 4.10 to 4.14; G5 5.1 to 5.7, 5.10 | G4 rows done 2026-11-10; G5 next |
| F7 | SoC verification: without the core, then the whole chip with C programs | irun; UVM; `sw/chip` | G6 6.1 to 6.14, 6.18 | in progress |
| F8 | Regression and coverage closure; bug curve | vManager; IMC; JasperGold UNR | G5 5.8, 5.9; G6 6.15 to 6.17 | in progress |
| F9 | **RTL freeze**: review and tag | git | G6 6.19 | not started; **end of the current plan** |
| F10 | Synthesis and timing constraints | Genus; `flow/constraints/garuda.sdc` | G7 | waits for the PDK (a 45 nm trial exists: `flow/signoff/g1/`) |
| F11 | DFT: scan, MBIST, boundary scan | Modus | G7 | waits for the PDK |
| F12 | Logic equivalence | Conformal LEC | G7 | waits for the PDK |
| F13 | Place and route | Innovus | G8 | waits for the PDK |
| F14 | Timing and power signoff | Innovus `timeDesign` (no Tempus or Voltus on this machine) | G8 | waits for the PDK |
| F15 | Physical verification: DRC, LVS | PVS, Pegasus | G8, G9 | waits for the PDK |
| F16 | Gate-level simulation and tape-out | xrun on the netlist | G9 | waits for the PDK |

Bugs from every stage go to `Docs/bugs/track_a.md` (core, DSU, buses, DMA, debug,
memories, tools) or `Docs/bugs/track_b.md` (peripherals). Decisions are in
`Docs/DECISIONS.md`. Commands to reproduce each stage by hand are in `flow/COMMANDS.md`.

---

## F0 Tools and environment

**Purpose.** Every tool the flow needs is installed, licensed and shown to run on a
small case.
**Entry.** None.
**Exit.** One hello-world run per tool with its output kept; the RISC-V compiler builds
an RV32IM program; Spike runs it; one command runs the whole regression and prints a
single PASS/FAIL line.
**Outputs.** `flow/signoff/g0/` (cases and tool output); `Makefile` target
`regress_all`; `flow/signoff/runs/*_regress_all.txt`.
**Rows.** G0 0.1 to 0.7.
**Reproduce.** `flow/COMMANDS.md`, "Replay by gate", G0.

## F1 Specification and architecture freeze

**Purpose.** What is being built is written down and frozen before verification
measures against it.
**Entry.** F0.
**Exit.** Core spec (ISA, pipeline, privilege, CSR table with reset values, trap model),
microarchitecture document, TRM (memory map, interrupt map, clocks and resets, pins,
boot), block specs, area and frequency targets; every later change goes through
`Docs/DECISIONS.md`.
**Outputs.** `Design_Docs/GARUDA-CORE-SPEC-001.md`, `GARUDA-CORE-UARCH-001.md`,
`GARUDA-TRM-001.md`, `GARUDA-PHYS-SPEC-001.md`, one `GARUDA-<BLOCK>-SPEC-001.md` per
block; `garuda_system.yaml` (the generated maps follow it); `flow/signoff/g1/` (trial
synthesis for the gate budget).
**Rows.** G1 1.1 to 1.13, 1.15.

## F2 Verification plan

**Purpose.** Every feature has a check method, a coverage item and an owner before bench
code is written.
**Entry.** F1 for the features it covers.
**Exit.** A vPlan per block and one for the chip, each feature mapped to a 1-TOPS phase;
the sign-off criteria fixed (`flow/0_signoff_criteria.md`).
**Outputs.** `tb/*/GARUDA_*_vplan.csv` (16 plans); `flow/1_vplan/garuda_soc.csv`;
`flow/1_vplan/1TOPS_PHASES.md`; `flow/1_vplan/traceability/`.
**Rows.** G1 1.14.

## F3 RTL design

**Purpose.** The RTL implements the frozen spec; every block is integrated at its TRM
address with its interrupt, DMA and pin connections.
**Entry.** F1; F2 for the block.
**Exit.** Every block coded and integrated; HAL shows no new findings against the
baseline; the address decode checked from the chip.
**Outputs.** `rtl/`; `rtl/soc/garuda_soc_top.v`, `rtl/soc/garuda_chip_top.v`;
`flow/signoff/g3/`.
**Rows.** G2 2.1 to 2.10, 2.14 to 2.17; G3 3.1 to 3.13, 3.17 to 3.22.

## F4 Static checks

**Purpose.** Problems that simulation finds late or never: lint, clock and reset domain
crossings, X-propagation, floating nets, coding rules.
**Entry.** F3 for the code checked.
**Exit.** HAL at its baseline with every rule explained; Superlint findings read and
explained; CDC and RDC at 0 unwaived; an X-propagation run on the chip sanity tests
with no X reaching a register that matters; a coding-rule scan of `rtl/`.
**Outputs.** `flow/2_static/hal_baseline.txt`, `hal_waivers.txt`; `flow/2_static/superlint/`;
`flow/2_static/cdc/`; `flow/2_static/rdc_review.md`; `flow/signoff/g3/` (floating nets);
`flow/2_static/core_lint.md` (core lint, 2.12); `flow/2_static/coding_rules.md` (2.11);
`flow/2_static/xprop/` (X-propagation).
**Rows.** G2 2.11 to 2.13; G3 3.14 to 3.16.

## F5 Block and unit verification

**Purpose.** Each block, and each unit of the core, meets the sign-off criteria on its
own.
**Entry.** F2 plan and F3 RTL for the block; F4 clean for it.
**Exit.** The nine criteria of `flow/0_signoff_criteria.md` for every block: features
checked, functional and code coverage at target or waived, assertions passing and
triggered, no open P1 or P2, regression over 20 seeds, lint, register tests, formal on
the assigned features. Where a mutant set exists, every mutant killed.
**Outputs.** `tb/<block>/` benches and `tb/<block>/uvm/`; `rtl/*/*_sva.sv`;
`flow/formal/<block>/*_fpv.result.txt`; `flow/cov/<block>_exclusions.tcl`;
`flow/mutation/`, `flow/mutation/results/`, `logs/dma/evidence/`;
`Docs/coverage/COVERAGE_BY_BLOCK.md`; `flow/3_unit/` (core units, G4).
**Rows.** G4 4.1 to 4.9, 4.15, 4.16.

**Exit table by block (2026-11-10).** Bench: the block's own runs in `make regress_all`,
`gate_a` and `gate_b` on 2026-11-10. Formal: `flow/formal/<block>/*.result.txt`. Mutants:
planted defects killed, `flow/mutation/results/` (DMA `logs/dma/evidence/dma_mut_2026-11-10.txt`,
DSU `logs/dsu/evidence/dsu_mut_2026-10-11.txt`); an "equivalent" mutant is proven so in
JasperGold. Coverage: statement / toggle / functional from IMC, 2026-10-16
(`Docs/coverage/COVERAGE_BY_BLOCK.md`), "w" = after the written waivers; it is
measured again at F8. No block has an open P1 or P2 bug.

| Block | Bench | Formal | Mutants | Coverage (stmt / toggle / functional) | Still to do for F5 exit |
|---|---|---|---|---|---|
| RV32IM core | 21 unit benches x 20 seeds, 63 ISA tests, 112 programs in step with Spike | every unit proof full; `core_all` 69/70 | no set (the new `forward_unit` bench kills 2 of 2) | 97.6% / 84.6% / 90.8%; units in `flow/3_unit/core_units.md` | core coverage with waivers (G5 5.8, 5.9) |
| DSU | pass | 20/20 | 7 of 7 | 100% / 95.6% / 60.0% | functional coverage; TB-42, TB-45 |
| AHB interconnect | pass (802 checks) | 20/20 | 8 of 8 | 98.6% / 69.1% / 71.8% | toggle and functional holes, waivers |
| AHB to APB bridge | pass | 17/17 | 8 of 8 | 93.0% / 78.3% / 38.4% | functional coverage, waivers |
| Memories | pass | 13/13; D-SRAM bank 2/2 | 7 of 7, 1 equivalent | 85.7% / 92.8% / 77.2% | statement holes, waivers |
| DMA | pass, and its UVM bench | 486 proven | 24 of 24, 1 equivalent | 99.1% / 60.3% / 75.8% | toggle and functional holes, waivers |
| Debug | pass | 26/26 | 10 of 10 | 96.5% / 77.1% / 90.0% | holes, waivers |
| CLIC | pass (UVM) | 76/76 | no set | 100% / 100% w / 100% | none |
| Timers and watchdog | pass (UVM) | 26/26 | no set | 100% / 100% w / 100% | none |
| Clock divider and reset | pass (UVM) | `reset` 14/17 (3 undetermined) | no set | 100% / 100% w / 100% | the 3 reset-duration proofs |
| PWM | pass (UVM) | 56/56 | no set | 100% w / 100% w / 100% | none |
| GPIO | pass (UVM) | 25/25 | no set | 100% w / 100% w / 100% | none |
| UART | pass (UVM) | 38/38 | no set | 83.1% / 66.7% / 98.1% | coverage and waivers |
| I2C | pass (UVM) | 47/49 (2 undetermined) | no set | 100% w / 100% w / 100% | the 2 undetermined proofs |
| SPI master | pass | 34/34 | 6 of 6 | 67.3% / 54.5% / 39.1% (directed only) | coverage: UVM runs into the merge |
| SPI slave | pass (UVM) | 38/38 | no set | 100% w / 100% w / 100% | none |

## F6 Core verification

**Purpose.** The core runs real programs correctly: every instruction against a
reference model, under random programs, interrupts and bus waits.
**Entry.** F5 for the core units.
**Exit.** ISA tests pass in lockstep with Spike; riscv-dv seeds pass (1000 agreed);
trap and privileged tests pass; memory-latency randomisation passes; CoreMark and
Dhrystone run and report a score per MHz; core bug list closed.
**Outputs.** `sw/riscv-tests/`, `tools/lockstep.py`; riscv-dv runs; `sw/bench/` (to be
written); `Docs/bugs/track_a.md`.
**Rows.** G4 4.10 to 4.14; G5 5.1 to 5.7, 5.10.

## F7 SoC verification

**Purpose.** The blocks work together: register access across the chip, every
peripheral path, interrupts end to end, boot, traffic from all four bus masters.
**Entry.** F5 for the blocks involved; F6 sanity for runs with the core.
**Exit.** SoC UVM bench with the core replaced by an AHB master agent; chip register
model reset and bit-bash; per-peripheral use cases; interrupt and decode checks; boot
from ROM and from flash; bare-metal C suite; random traffic with resets and no hang.
**Outputs.** `tb/soc/uvm/` (to be written); `tb/soc/tb_chip.sv`; `sw/chip/`;
`flow/signoff/runs/`.
**Rows.** G6 6.1 to 6.14, 6.18.

## F8 Regression and coverage closure

**Purpose.** One regression on one commit, coverage merged across it, every hole closed
or waived in writing, and a bug curve that has flattened.
**Entry.** F5 to F7 running.
**Exit.** vManager session from `flow/regress/garuda.vsif` all passing; merged coverage
back-annotated on the vPlans; core and SoC code coverage at least 95% with UNR-backed
waivers; bug curve flat.
**Outputs.** `flow/regress/`; `flow/cov/`; `flow/nightly/bug_curve.csv`;
`Docs/coverage/`.
**Rows.** G5 5.8, 5.9; G6 6.15 to 6.17.

## F9 RTL freeze

**Purpose.** The RTL handed to synthesis is fixed and its state is recorded.
**Entry.** F4 to F8 exit criteria met, or each gap accepted in writing.
**Exit.** A freeze review record: open bugs, waivers, coverage and formal status per
block; `make gate_a`, `make gate_b` and `make regress_all` passing on the freeze commit;
local tag `1tops-rtl-freeze`, pushed by Karthik.
**Outputs.** `flow/reviews/` (freeze record); `flow/signoff/runs/`.
**Rows.** G6 6.19.

---

## Evidence by stage

Evidence stays where it was first committed (the workbook rows point at those paths).
New evidence is written into the folder of its stage.

| Stage | Where the evidence is |
|---|---|
| F0 | `flow/signoff/g0/`, `flow/signoff/runs/` |
| F1 | `Design_Docs/`, `garuda_system.yaml`, `flow/signoff/g1/`, `Docs/DECISIONS.md` |
| F2 | `flow/1_vplan/`, `tb/*/GARUDA_*_vplan.csv`, `flow/0_signoff_criteria.md` |
| F3 | `rtl/`, `flow/signoff/g3/` |
| F4 | `flow/2_static/`, `flow/signoff/g3/` |
| F5 | `flow/formal/`, `flow/cov/`, `flow/mutation/`, `tb/<block>/`, `logs/<block>/evidence/` |
| F6 | `sw/riscv-tests/`, `tools/lockstep.py`, `flow/nightly/` |
| F7 | `tb/soc/`, `sw/chip/`, `flow/signoff/runs/` |
| F8 | `flow/regress/`, `flow/cov/`, `Docs/coverage/`, `flow/nightly/` |
| F9 | `flow/reviews/`, `flow/signoff/runs/` |

## Replays

Each gate already closed is replayed by Karthik from `flow/COMMANDS.md`, "Replay by gate".

| Gate | Stages | Replayed by K (date) |
|---|---|---|
| G0 | F0 | |
| G1 | F1, F2 | |
| G2, G3 | F3, F4 | |
| G4 | F5, F6 (unit level) | |
