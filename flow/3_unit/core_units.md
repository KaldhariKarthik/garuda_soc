# Core units and core sanity: the G4 record (flow stages F5, F6 at unit level)

1-TOPS gate G4, rows 4.1 to 4.9 and 4.11 to 4.16 (4.10 closed on 2026-11-03).
Worked on 2026-11-10 on tree `45aef55` (the RTL of `acb29f7`) plus the bench changes
listed in section 4. No RTL changed.

Simulator for coverage: irun 15.2 (IMC and vManager on this machine read only a 15.2
database, `Docs/COVERAGE.md`). Every run goes through `flow/regress/run_test.sh <test>`, the
script vManager calls for `flow/regress/garuda.vsif`, so each result here is one row of
the regression session. The Spike co-simulation and the Verilator rows use
`tools/run/garuda_run.py` (`source tools/run/env.sh` first).

## 1. Row by row

| Row | Criterion | Evidence | Result |
|---|---|---|---|
| 4.1 | PC unit: directed tests pass, code coverage reviewed | `tb/core/tb_garuda_pc_gen.sv`; `imc/unit_garuda_pc_gen.summary.txt` | pass; statements 10/10, toggle 128/133, bins 13/13. A halfword redirect target was added so bit 1 of both pointers toggles. The 5 toggle holes are bit 0 of the redirect, PC and fetch PC and bits 1:0 of the commit PC, constant by architecture and waived with formal proof (CT-PCBIT0, CT-PCALIGN). JasperGold `pc_gen` 4/4. |
| 4.2 | Decoder: a directed test per opcode and funct combination; opcode x funct3 x funct7 cross closed | `tb/core/tb_decode_control.sv` (`cg_encoding`); `imc/unit_decode_control.summary.txt` | 3211 of 3211 decodes match the model; bins 213/213. New: every opcode with a funct3 field x all eight funct3 values, OP funct3 x five funct7 classes, both shift-immediates x funct7, the four SYSTEM words and five near misses, FENCE / FENCE.I (absent from the bench until now) and 16-bit / all-zero words. Statements 63/65 (the two `default` items of full 8-way cases, waiver CW-006), expressions 20/20, toggle 117/117. At core level `cg_decode.x_op_f3` is 100% after the reserved encodings were made `ignore_bins` (they are checked here). JasperGold `decode` 12/12. |
| 4.3 | Register file: x0 write, same-cycle read and write | `tb/core/tb_reg_file.sv` | pass; sequences `x0_hardwired_zero`, `bypass_matrix` (rs1, rs2, both), every register written and read; bins 102/102; statements 3/3, expressions 11/11, toggle 177/178 (reset never falls again after time 0: a mid-run reset is a core test). JasperGold `regfile` 5/5. |
| 4.4 | ALU: matches the model; corners 0x8000_0000, 0x7FFF_FFFF, 0, -1; shifts 0, 1, 31, >31 | `tb/core/tb_alu.sv` (`x_op_a_corner`, `x_op_b_corner`, `x_shift_amount`) | 2317 of 2317 checks; bins 152/152; every operation on every pair of the four corners, every shift by 0, 1, 31, 32 and 33; statements 13/13, toggle 105/105. |
| 4.5 | Branch unit: full compare matrix; rs1 < rs2, = and > covered signed and unsigned | `tb/core/tb_branch_unit.sv` (`x_f3_rel`) | 7718 of 7718 checks; bins 64/64; the cross of the six branch conditions with five relations (equal, less, greater, and the two mixed-sign pairs where signed and unsigned disagree), both predictions. Toggle 266/271: the word-aligned PC bits and JALR bit 0, waived (CT-PCALIGN, CT-PCBIT0). JasperGold `branch_unit` 5/5. |
| 4.6 | MDU: MUL, MULH, MULHSU, MULHU covered; DIV, DIVU, REM, REMU trap; stall sequences | `tb/core/tb_mul32.sv`; `tb/core/tb_decode_control.sv`; `sw/tests/t_hazard.S`; riscv-tests `p-div`, `p-divu`, `p-rem`, `p-remu` | MUL family x operand signs, bins 29/29. DIV family: decode assertion A2 and `cg_encoding` (OP funct3 4..7 with funct7 0000001) show it decodes illegal; the four riscv-tests pass only through the illegal-instruction trap and `sw/riscv-tests/env/p/divrem_emu.S`. The multiplier is single cycle (UARCH, `mul32`), so it has no stall of its own: `t_hazard` cases 5, 11, 14 to 16, 19 and 23 run MUL behind the load-use interlock, forwarded, and under random wait states, in step with Spike. Toggle 232/233: `funct3[2]` is the divide half, which never reaches the multiplier. |
| 4.7 | MIU: every size x offset; signed and unsigned loads | `tb/core/tb_load_store_unit.sv`, `tb/core/tb_load_formatter.sv` | LSU bins 59/59: size x offset, size x load and store misalignment, size x offset x signedness (no LWU in RV32). Formatter bins 39/39: the five load types x four offsets, and the sign of the result. Toggle: `hsize_o[2]` constant (waived); the formatter's two implicit `default` branches are reached only by an X select (hit by `unit_mem_stage`). JasperGold `load_store_unit` 3/3. |
| 4.8 | Hazard logic: rs1, rs2 and both-operand hazards; ALU-, LOAD- and STORE-to-use | `tb/core/tb_hazard_forward_unit.sv` (`x_collide_producer`); new `tb/core/tb_forward_unit.sv`; core `cg_hazard_lu` | Load-use unit: bins 118/118, including which source collides (none, rs1, rs2, both) for an ALU and a load producer. Forwarding unit, until now reached only by a smoke test: new bench, 5088 of 5088 checks against a model of DS-001 §11.1, bins 31/31, expressions 12/12, toggle 28/28; two planted defects (MEM/WB over EX/MEM; x0 forwarded) fail 196 and 96 checks. Core level: `cp_load_use_consumer` 8/8 (ALU rs1, rs2, both; store data; store address; branch; JALR; load address). JasperGold `hazard_forward_unit` 1/1, `forward_unit` 2/2. |
| 4.9 | Unit regression 100% pass, directed and random | `seeds_2026-11-10.txt` | 21 unit benches x 20 seeds: 420 of 420 pass (irun `-svseed`; different seeds give different stimulus). On Verilator the changed benches pass too. |
| 4.11 | One self-checking sanity test per class | 63 riscv-tests in `garuda.vsif`; `cosim` | All 63 pass on irun; 57 match Spike instruction by instruction, 6 cannot by design (`p-div` etc., `p-sbreak`, `p-mcsr`, `scripts/run_regression.sh`). Spike co-simulation of every ISA and core program: 112 of 112, 0 mismatches. |
| 4.12 | Reset vector; interrupt at a clean boundary; CLIC `mtvec` jump and `mepc` | `t_irq`, `t_clic`, `t_mtip`, `t_wfi`, `t_core_irq_nest`, `t_core_preempt` | The first retired instruction is at `0x1000_0000` (commit log). The four interrupt programs pass on irun and match Spike with the interrupts applied from the spec; nesting and preemption match Spike with and without wait states. |
| 4.13 | RAW, WAR, WAW, control and structural hazard tests | new `sw/tests/t_hazard.S` (35 cases) | Passes with no waits and with random waits on both ports (four timings), and in step with Spike in two. A wrong expectation planted in case 21 makes it fail with code `0x2b` (case 21). Structural: memory operations behind waited ones and the register file written and read in one cycle are in `t_hazard`; the DSU busy hold is `t_dsu_b2b`. |
| 4.14 | 100% RV32I opcode coverage; every M op; every load and store size | `imc/core_cg_garuda_cov.txt`, `imc/core_cg_vplan.txt` | On the 81 core programs merged: every legal opcode x funct3 (with FENCE and FENCE.I, which the covergroup had no bin for), every load and store size, `cg_mul` (MUL, MULH, MULHSU, MULHU x signs) at 100%. |
| 4.15 | Every CSR read and written; every trap cause; T-13, T-14 | `make csr_map`; `t_cov_csr`; `cg_trap`; `t_lead1_mret_buserr`, `t_lead2_wfi_buserr` | `csr_map`: all 4096 addresses read, 0 mismatches against `Design_Docs/regs/core_csr.yaml`, every difference from Spike explained. `t_cov_csr` writes every writable CSR with four patterns through all six CSR instructions, checks WARL masks, writes the counters, traps on read-only writes: pass. `cg_trap.cp_cause` 10/10 once `t_cov_fault` (the only source of cause 1) joined the session. T-13, T-14 pass. JasperGold `csr_file` 9/9, `trap_ctrl` 10/10, `csr_rw` 1/1. |
| 4.16 | Prefetch, I-port, predictor: flush on redirect, full / empty, AHB waits, predictor directions | `tb/core/tb_garuda_prefetch_buffer.sv`, `tb_garuda_iport_ahb_master.sv`, `tb_branch_predict.sv` | Prefetch bins 30/30 (occupancy empty to full x read/write, flush from empty, part and full); I-port 31/31 (HTRANS x HREADY wait states, occupancy x issue, redirect x valid); predictor 27/27, now with BP_DIS and FENCE.I driven (they were tied to 0) and two new assertions. PF_DIS and the fetch stop are tied off in the unit benches; at core level `t_core_ctl` runs one workload under all 16 `mgarudactl` settings (pass) and the halt suite stops fetch under a running program (4 of 4). JasperGold `prefetch` 4/4, `if_stage` 15/15, `branch_predict` 5/5. |

## 2. Unit-level code coverage of every core module

All 28 passing unit and smoke runs merged in IMC (`imc/unit_merged_summary.txt`). A hole is
matched against `tb/core/cov/core_waivers.toml` by signal and line (`imc/unit_holes.txt`).

| Module | Statement | Expression | Toggle | FSM | Holes with no waiver in `core_waivers.toml` |
|---|---|---|---|---|---|
| `alu` | 100.00% (13/13) | n/a | 100.00% (105/105) | n/a | 0 |
| `branch_predict` | n/a | n/a | 96.09% (221/230) | n/a | 0 |
| `branch_unit` | 100.00% (8/8) | n/a | 98.15% (266/271) | n/a | 0 |
| `clic_ctrl` | n/a | n/a | 96.46% (109/113) | n/a | 0 |
| `csr_file` | 66.18% (45/68) | 73.33% (11/15) | 26.50% (260/981) | n/a | 543 |
| `csr_rw` | n/a | n/a | 98.26% (113/115) | n/a | 2 |
| `d_port_ahb_master` | 92.31% (12/13) | 100.00% (6/6) | 96.62% (143/148) | 100.00% | 1 |
| `decode_control` | 96.92% (63/65) | 100.00% (20/20) | 100.00% (117/117) | n/a | 0 |
| `ex_mem` | 100.00% (7/7) | n/a | 20.27% (45/222) | n/a | 173 |
| `ex_stage` | 75.00% (6/8) | n/a | 60.56% (579/956) | n/a | 375 |
| `forward_unit` | n/a | 100.00% (12/12) | 100.00% (28/28) | n/a | 0 |
| `garuda_if_stage_top` | n/a | n/a | 78.68% (251/319) | n/a | 20 |
| `garuda_iport_ahb_master` | 100.00% (19/19) | 100.00% (9/9) | 78.39% (243/310) | n/a | 15 |
| `garuda_pc_gen` | 100.00% (10/10) | n/a | 96.24% (128/133) | n/a | 0 |
| `garuda_prefetch_buffer` | 100.00% (15/15) | n/a | 96.62% (143/148) | n/a | 1 |
| `hazard_forward_unit` | n/a | n/a | 100.00% (17/17) | n/a | 0 |
| `id_ex` | 100.00% (7/7) | n/a | 10.38% (49/472) | n/a | 420 |
| `id_stage` | n/a | n/a | 98.22% (553/563) | n/a | 3 |
| `if_id` | 100.00% (7/7) | n/a | 16.91% (23/136) | n/a | 109 |
| `imm_gen` | 100.00% (8/8) | n/a | 86.69% (280/323) | n/a | 0 |
| `load_formatter` | 100.00% (14/14) | n/a | 100.00% (96/96) | n/a | 0 |
| `load_store_unit` | 100.00% (4/4) | n/a | 99.07% (106/107) | n/a | 0 |
| `mem_stage` | n/a | n/a | 96.07% (391/407) | n/a | 3 |
| `mem_wb_reg` | 100.00% (5/5) | n/a | 100.00% (81/81) | n/a | 0 |
| `mul32` | n/a | n/a | 99.57% (232/233) | n/a | 1 |
| `pipe_ctrl` | n/a | n/a | 22.15% (35/158) | n/a | 123 |
| `regfile` | 100.00% (3/3) | 100.00% (11/11) | 99.44% (177/178) | n/a | 1 |
| `trap_ctrl` | 85.71% (6/7) | n/a | 32.08% (179/558) | n/a | 337 |
| `wb_stage` | n/a | n/a | 100.00% (76/76) | n/a | 0 |

How to read it:

- **The modules with a SystemVerilog unit bench** (every row of this gate but 4.15) have no
  unexplained hole. What has no waiver is, by module: `rst_n_i` never falling again after
  time 0 (`regfile`, `d_port_ahb_master`, `garuda_prefetch_buffer`, `mem_stage`, `id_stage`,
  the I-port and IF top: the benches reset once, a reset in the middle of a run is a core
  test, `t_cov_rereset`); `csr_rw` `instr[3:2]` (every CSR instruction has opcode 1110011,
  so they are constant in its bench); `mul32` `funct3[2]` (the divide half); the I-port's
  HSIZE / HBURST / HPROT bits (constant by design) and instruction-data bits 0, 1, 16 and 17
  (the bench's instruction words never vary there; a straight data path, toggled at core
  level); PF_DIS and the fetch stop on the I-port, IF top and `id_stage`, and FENCE.I on
  `id_stage` (tied off in those benches, run at core level as in 4.16); `mem_stage`
  `d_hprot_o[1:0]` (constant data-access attributes).
- **The pipeline registers and control** (`id_ex`, `if_id`, `ex_mem`, `pipe_ctrl`, `ex_stage`,
  `csr_file`, `trap_ctrl`) have only the plain-Verilog smoke benches of the first
  bring-up. Their unit numbers are low and are not the measure: their code coverage
  target is set at core level, on every core program merged (G5 rows 5.8 and 5.9,
  `Docs/coverage/COVERAGE_BY_BLOCK.md`), and their behaviour is proven in JasperGold
  (`id_ex` 3/3, rerun today on the inlined RTL; `if_id` 3/3; `ex_mem` 3/3; `csr_file` 9/9;
  `trap_ctrl` 10/10; `core_all` 69/70, `pipe_ctrl_core`).

## 3. Core-level covergroups (81 programs merged)

`imc/core_cg_summary.txt`: `garuda_cov` 91.7% (210/229), `garuda_cov_vplan` 84.6% (208/246).
At 100%: the decode cross (4.2, 4.14), every trap cause (4.15), the ALU and MUL groups, the
load-use consumers (4.8), the counter writes (4.15, `t_cov_csr`). The remaining holes are G5 work (row 5.8, core functional
coverage): forwarding from EX/MEM during a D-port stall, D-port NONSEQ in a wait state,
DSU operations, CSR address group x operation, interrupt-versus-timer and wake corners. Most are hit by
programs that so far run only on Verilator (`tb/core/run/covtests.toml`); G5 brings them
into the session.

## 4. What changed for this gate

Benches (no RTL):
- `tb_decode_control.sv`: FENCE / FENCE.I modelled, `fencei_o` connected and in the
  assertions; sweeps of every opcode x funct3, funct3 x funct7, SYSTEM words, 16-bit and
  all-zero words; `cg_encoding`.
- `tb_alu.sv`: operand-corner sweep; corner and shift-amount crosses.
- `tb_branch_unit.sv`: compare matrix; funct3 x relation cross.
- `tb_load_store_unit.sv`: store-misalign and signedness crosses.
- `tb_hazard_forward_unit.sv`: collision-kind cross.
- `tb_forward_unit.sv`, `filelist_forward_unit.f`: new (in `test_elements`,
  `tb/core/run/elements.toml`, `garuda.vsif`).
- `tb_branch_predict.sv`: BP_DIS and FENCE.I driven, modelled, asserted and covered.
- `tb_garuda_pc_gen.sv`: a halfword redirect target.
- `tb/cov/garuda_cov.sv`: MISC-MEM bin; reserved encodings as `ignore_bins`.

Programs and flow:
- `sw/tests/t_hazard.S`: new; in `sw/Makefile`, `tb/core/run/sanity.toml`,
  `tb/core/run/cosim.toml` (regenerated), `garuda.vsif` (two timings).
- `garuda.vsif` and `make sw`: `t_cov_fault`, `t_cov_csr` added.
- `flow/regress/run_test.sh`: `smoke_<name>` for the plain-Verilog benches, `SVSEED`, a
  fresh library per run, the two `t_hazard` timings.
- `tools/run/env.sh`: Spike, GCC, oss-cad-suite and z3 found on the lab machine.
- Bug register: TOOL-A13 (`Docs/bugs/track_a.md`).

## 5. Open items carried

- Core bugs still open are documentation and disposition items, none P1 or P2: CORE-2
  (unused parameter), ELEM-7 (a guide names covergroups that do not exist), AUD-9, AUD-11
  and AUD-12 rows (specification wording), TB-42 and TB-45 (DSU bench limits, covered at
  core level).
- Core functional and code coverage to target with waivers: G5 rows 5.8 and 5.9.
