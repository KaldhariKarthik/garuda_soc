# GARUDA verification plan against the five 1-TOPS phases

1-TOPS item 1.14 asks for a feature-to-test-to-coverage mapping across the five verification phases. That mapping is in the vPlanner CSVs: one per block, `tb/<block>/GARUDA_<BLOCK>_vplan.csv`, plus the top level `flow/1_vplan/garuda_soc.csv`.

In each CSV, every feature row (`SECTION`) holds three kinds of child rows:
- its checks (`CHK`: a property or a scoreboard rule);
- its coverage items (`COV`: a covergroup or a cover property);
- its tests (`TC`).

This page says which vPlan sections belong to which phase, which bench runs them, and which rows of the 1-TOPS workbook close when the phase is done. Written 2026-11-03.

## Phase 1: unit (1-TOPS gate G4, items 4.1 to 4.9)

| vPlan | Sections | Bench | Checks and coverage |
|---|---|---|---|
| `tb/core/GARUDA_CORE_vplan.csv` | A Instruction set; B CSRs; C Exceptions; E Pipeline (unit parts) | the core unit and element benches, `tb/core/tb_*.sv` / `.v` (`make test_core`, `make test_elements`, `make test_units`) | each bench's own scoreboard; unit covergroups (`unit_alu`, `unit_branch_unit`, `unit_decode_control` and the others in `Docs/coverage/COVERAGE_BY_BLOCK.md`); properties in `rtl/core/*_sva.sv` |
| `tb/dsu/GARUDA_DSU_vplan.csv` | A Instructions; B Numeric contract; C Encoding | `tb/dsu/tb_dsu_top` against `DSUModel` (`make test_dsu`) | result-by-result compare; `rtl/dsu/dsu_sva.sv`, `dsu_arith_sva.sv` |

## Phase 2: core sanity (G4, items 4.10 to 4.14)

| vPlan | Sections | Bench | Checks and coverage |
|---|---|---|---|
| `tb/core/GARUDA_CORE_vplan.csv` | D Interrupts; E Pipeline (hazards in programs); F WFI and the clock gate; G Reset and the debugger | `tb/soc/tb_boot.sv` with the directed programs `sw/tests/*.S` (`make test_sanity`) | Spike lockstep (`tools/lockstep.py`); hold-versus-flush matrix `t_hold_flush_matrix`; `cg_decode`, trap and interrupt covergroups |
| `tb/dsu/GARUDA_DSU_vplan.csv` | D In the pipeline; E Observation and clocking | `tb_boot` with `t_dsu*.S` | lockstep; DSU properties |

## Phase 3: core with software and random streams (G5)

| vPlan | Sections | Bench | Checks and coverage |
|---|---|---|---|
| `tb/core/GARUDA_CORE_vplan.csv` | H Whole programs; I Clock and timing | `tb_boot` (`make regress`, `make regress_wait`, `make regress_rand`, `make riscv_dv`) | Spike lockstep on every retired instruction; riscv-tests rv32ui, rv32um, rv32mi; riscv-dv; core code and functional coverage in IMC |
| `tb/dsu/GARUDA_DSU_vplan.csv` | F The workloads it exists for | `tb_boot` | lockstep |
| `flow/1_vplan/garuda_soc.csv` | Stage 4 - CPU core | as above | as above |

## Phase 4: SoC without the core (G6, items 6.1 to 6.8)

Each block is first closed in its own environment. The SoC bench of item 6.1 then drives `garuda_soc_top` from an AHB master agent in place of the core.

| vPlan | Bench now | Checks and coverage |
|---|---|---|
| `tb/clic/GARUDA_CLIC_vplan.csv`, `tb/timers/...TIMERS...`, `tb/clk_div/...CLKRST...`, `tb/pwm/...PWM...`, `tb/gpio/...GPIO...`, `tb/uart/...UART...`, `tb/i2c/...I2C...`, `tb/spi_slave/...SPIS...`, `tb/dma/...DMA...` | the block's UVM environment `tb/<block>/uvm/` (`make uvm_<block>`) | generated register model (reset, access policy, bit bash); reference model and scoreboard; covergroups; bound properties; planted-defect run (`planted.result.txt`) |
| `tb/spi_master/GARUDA_SPIM_vplan.csv` | `tb/spi_master/tb_spim` and the Mirafra UVM environment `tb/spi_master/uvm_mirafra/` | vendored-IP VIP |
| `tb/ahb/GARUDA_AHB_vplan.csv`, `tb/ahb2apb/GARUDA_AHB2APB_vplan.csv` | `tb_ahb_ic`, `tb_ahb2apb` and JasperGold (`flow/formal/`) | protocol checkers `tb/common/apb_checker.v`, AHB checker; proven properties |
| `tb/debug/GARUDA_DEBUG_vplan.csv` | `tb_debug` | DMI and SBA checks; `dmi_cdc` properties |
| `tb/mem/GARUDA_MEM_vplan.csv` | A Bus slaves; B ISRAM write lock, in `tb_mem` | slave properties; lock rules |
| `flow/1_vplan/garuda_soc.csv` | Stage 3 - Block and IP; Stage 5 - Integration (bus, interrupt lines, DMA request lines, bus faults) | `tb/soc/tb_chip.sv` with `t_chip_integ` until the 6.1 bench exists |

## Phase 5: full SoC (G6, items 6.9 to 6.18)

| vPlan | Sections or tests | Bench | Checks and coverage |
|---|---|---|---|
| `flow/1_vplan/garuda_soc.csv` | Stage 6 - SoC top: `t_chip_basic`, `t_chip_irq`, `t_chip_wdt`, `t_chip_flash`, `t_chip_uart`, `t_chip_periph`, `t_chip_integ`, `t_chip_jtag` | `tb/soc/tb_chip.sv` from the pins, with the flash, UART, SPI and I2C models (`make test_chip`) | self-checking C programs (`sw/chip/`); chip properties `rtl/soc/chip_sva.sv`, `chip_pads_sva.sv`; chip covergroups `tb/soc/chip_cov.sv` |
| `tb/mem/GARUDA_MEM_vplan.csv` | C Boot; D With the rest of the chip; E Clock, reset and power | `tb_chip` | boot from flash with CRC; ILOCK |

## What closes a phase

A phase closes when every feature of its sections meets the block sign-off criteria in `flow/0_signoff_criteria.md`:
- every check passing;
- 100% functional coverage of the coverage items;
- at least 95% code coverage, with every hole waived in writing;
- every property triggered;
- no open P1 or P2 bug.

When a phase closes, the matching rows of the 1-TOPS workbook are marked Done:
- phases 1 and 2: G4;
- phase 3: G5;
- phases 4 and 5: G6.
