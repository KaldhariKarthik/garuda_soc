# GARUDA verification — lab handoff

**Status at 2026-10-14.** This file tells the next engineer at the lab machine what passes,
what waits for a run, and what waits for a decision. The history of the earlier rounds is in
`Docs/logs/ENGINEERING_LOG.md`, the dated logs and git history. The Linux (WSL) environment and
physical design are in `Docs/handoff/CLAUDE_HANDOFF.md`.

---

## 1. State in one table

The last full run on Cadence tools was on 2026-10-04 (stages 1 to 6 of `flow/COMMANDS.md`).
All results below are from that run unless a row says otherwise.

| Stage | What ran | Result |
|---|---|---|
| 1 vPlan | A feature-level plan per block (`tb/<block>/GARUDA_<BLOCK>_vplan.csv`), 512 features | Done. 27 features are places where a spec is silent or wrong (AUD-12) |
| 2 Static | HAL lint (whole chip), HAL clock-domain check (`debug_top`), reset-domain review | 5 lint errors, each waived in `flow/2_static/hal_waivers.txt`. RDC review: `flow/2_static/rdc_review.md` |
| 2 Formal | `pipe_ctrl` in SymbiYosys (FV-2, 2026-10-11/12) | 8 of 9 properties proved, 17 of 17 covers reached. The 9th is a whole-core property |
| 3 Block | 15 block testbenches; UVM environments for CLIC, timers, PWM, GPIO, clock/reset | All pass. Each UVM environment catches its planted defects (VER-1, VER-2, VER-4, VER-5, VER-6) |
| 4 Core | 20 unit and element testbenches; 64 ISA tests (58 in Spike lockstep, also with random waits); 12 sanity programs; DSU against its model; 200 riscv-dv programs in lockstep | All pass, 0 assertion failures |
| 5 Integration | Interconnect, bridge, shim, `t_chip_integ` | All pass |
| 6 Chip | 8 chip programs from the pins, 2 also with X-propagation | All pass, 0 AHB protocol violations |
| Synthesis | Genus 21.1, generic, SRAMs black-boxed (`make synth`) | 67,460 cells, 7,909 flops, 1 latch (the ICG). **May be low:** see PD-1 |
| Coverage | vManager, 119 runs, IMC merge | Collected, not closed. See `Docs/COVERAGE.md` |

## 2. Run first: changes not yet run on xrun

These changes were made after 2026-10-04 on free tools. Each one is checked by the method
named in `Docs/bugs/archive/BUGS_HISTORY.md` §1k or §1l. None has passed the lab regression yet.

| Change | Files | Run this |
|---|---|---|
| T-13, T-14 (trap control) | `rtl/core/trap_ctrl.v` | `make regress_all`, then the two tests below |
| UART-3, UART-4 (vendor patch) | `rtl/third_party/pulp/apb_uart_sv/` | `make test_uart` |
| PWM-3 (latch) | `rtl/pwm/garuda_pwm_top.v` | `make test_pwm`, `make uvm_pwm` |
| TB-30, TB-32, TB-35 (testbench resets, DSU stimulus check) | `tb/soc/tb_chip.sv`, `tb/core/tb_garuda_pc_gen.sv`, `tb/dsu/tb_dsu_top.sv` | `make test_chip`, `make test_pc_gen`, `make test_dsu` |
| P1, P2, P3 (physical-design hooks, D-28) | `core_clk_gate.v`, `garuda_chip_top.v` (now a wrapper of `garuda_chip_core`), `sram_wrapper.v` | `make test_chip`. P1 and P3 are behind defines that simulation does not set |
| TOOL-13 (make fails when a simulation fails) | `Makefile`, `scripts/sim_verdict.sh` | Use `make -k` to run a full group |

Run the T-13 and T-14 tests by hand. They are built by `make sw` but are not in the sanity list:

```bash
for t in t_lead1_mret_buserr t_lead2_wfi_buserr; do
  for w in "" "+DWAIT=3"; do
    xrun -f tb/soc/filelist_boot.f -top tb_boot -xmlibdirname sim/$t/xcelium.d \
         -l sim/$t/run$w.log +HEX=sw/build/$t.hex +COMMIT=sim/$t/commit.log \
         +MAXCYC=20000 +ERR_EN=1 +ERR_BASE=10020000 +ERR_SIZE=1000 $w
  done
done
```

Each run must end in `TOHOST=1 -> PASSED`.

## 3. Decisions the owner must make

Each item is open in `Docs/bugs/archive/BUGS_HISTORY.md`. None is an RTL change that a verification engineer can
make alone.

| ID | Priority | Decision |
|---|---|---|
| T-12 | **P1** | Nested interrupts and exceptions in a handler leave the interrupt level wrong. Fix needs `mcause.mpil` (changes what handlers read) |
| RDC-1 | P2 | A debugger halt resets the core in the middle of a waited store |
| GPIO-2 | P2 | Five spec/IP differences; INTTYPE `11` (level) raises no interrupt |
| AUD-12 | P2 | 27 spec-vs-RTL differences found while writing the plans |
| PWM-2 | — | PWM pins are combinational and can glitch |
| APB-1 | low | The bridge timeout abandons an APB access; state it in the spec or change it |
| CRG-3, SIM-1, C-16, AUD-13 | P3 | Reset-cause priority, a simulation/silicon ordering difference on pclk, missing standard CSRs, the PSLVERR rule |
| AUD-9 | — | DSU port names do not match its spec |
| OPEN-2 | — | Are the supply pads inside the 40? Decides whether the 4 SPI-slave pins are bonded (`WITH_SPI_SLAVE`) |

INT-2 moved the DMA error interrupts from CLIC IDs 7..12 to 8..13. The yaml, RTL and
specifications now agree (2026-10-14). The owner confirms the move.

## 4. Set up the shell

Do this in each new terminal:

```bash
cd ~/garuda_soc
source scripts/setup_env.sh      # expect six OK lines
```

| Tool | Location | Use |
|---|---|---|
| Xcelium 22.09 `xrun` | `/home/install/XCELIUM2209/tools/bin` | Regression |
| Incisive 15.20 `irun`, `hal`, `imc` | `/home/install/INCISIVE152` | Coverage, lint, coverage merge |
| RISC-V GCC | `/home/vivado/2025.2/Vitis/gnu/riscv/linux_toolchain/lin64/bin` | Prefix `riscv64-amd-linux-gnu-` |
| Spike | `~/external/spike-inst/bin/spike` | Golden ISS |
| riscv-tests, riscv-dv | `~/external/riscv-tests`, `~/external/riscv-dv` | Test sources |

The licence is `5280@192.168.6.16`. **Caution:** without it, `xrun` compiles and elaborates,
then stops at simulation with `xmsim: *F,NOLICN`. This looks like a design fault. It is not.

## 5. Run the regression

```bash
make regress_all        # core, elements, blocks, sanity, DSU, ISA, chip
make -k regress_all     # the same, but do not stop at the first failure
make help               # every target
```

The vManager flow with coverage is in `flow/COMMANDS.md` ("Stages 3 to 6").

## 6. Traps that look like RTL defects

1. **Spike's UART is at `0x1000_0000`,** which is GARUDA's reset vector. `tools/lockstep.py`
   passes `--disable-dtb --pc=0x10000000 --priv=m`. Keep these options.
2. **The Vitis GCC makes position-independent code by default.** `la t0, tohost` then loads
   zero, and the store goes to address 0. Use `lla`. Keep `-fno-pic -no-pie -mno-relax`.
3. **Spike's ISA string must name every extension:** `rv32im_zicsr_zifencei_zicntr`.
   `rv32im` alone does not include Zicsr.
4. **IMC 15.20 cannot read an Xcelium 22.09 database.** Collect coverage with `irun`. Merge
   with `-initial_model union_all`. Read covergroups with `report -detail -metrics covergroup`.
5. **Suspect the testbench.** Most first-run failures in this project were testbench
   defects (`Docs/bugs/archive/BUGS_HISTORY.md` §6 and §1h). When the RTL and a model disagree, examine both.

## 7. Debug a failing test

1. **Read the lockstep result.** `cat sim/regress/<test>.lockstep.txt` shows the first
   instruction where GARUDA and Spike disagree. Only the first divergence is important.
2. **Disassemble.** `riscv64-amd-linux-gnu-objdump -d sw/riscv-tests/build/<test>.elf`
3. **Use the probes in `tb_boot`.** Limit them to a window with `+DBGFROM` and `+DBGTO`.

| Plusarg | Shows |
|---|---|
| `+DBGBUS` | Instruction fetch: bus address, data, each pipeline stage |
| `+DBGTRAP` | Trap entry: cause, target, each exception source |
| `+DBGD` | Data bus, address phase and data phase |
| `+DBGM` | MEM stage and the write-back handshake |
| `+DBGEX` | EX stage, hazard and stall signals |
| `+DBGACC` | DSU accumulators |

4. **Look at waveforms.** Add `+WAVES`, then `simvision sim/<dir>/waves.shm`.

## 8. Test environments for the ISA suite

| Environment | Reports through | Used for |
|---|---|---|
| `sw/riscv-tests/env/riscv_test.h` | A direct `tohost` store | rv32ui, rv32um |
| `sw/riscv-tests/env/p/riscv_test.h` | ECALL and a trap handler | rv32mi, `ma_data`, divide and remainder |

The p-environment has a software DIV/REM emulator (`divrem_emu.S`). GARUDA has no hardware
divider. Spike lockstep does not apply to `p-div/divu/rem/remu`, `p-csr`, `p-mcsr` and
`p-ma_fetch`; these pass their own self-check. Excluded tests: `breakpoint` (no Sdtrig),
`pmpaddr` (no PMP), `instret_overflow`.

## 9. Next work, in order

1. Run §2 at the lab.
2. Get the owner's decisions in §3. T-12 first.
3. Coverage closure (`Docs/COVERAGE.md`): CLIC, `garuda_if_stage_top`, `csr_file`, GPIO.
4. Write the 27 tests that the specifications plan and nobody wrote (AUD-11).
5. TB-33 and ELEM-8 (testbench defects, open).
6. Gate-level simulation and DFT, when there is a netlist and a DFT decision.
