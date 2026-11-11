# Core verification: the G5 record (flow stages F6 and F8 for the core)

1-TOPS gate G5, rows 5.3 to 5.9 (5.1, 5.2 and 5.10 closed on 2026-11-03 and 2026-11-04).
Worked on 2026-11-11 on tree `b1e33d7` plus the changes listed in section 3. No RTL changed.

Simulator: Xcelium 22.09 (`xrun`) for every row of this page, each program compared with
Spike 1.1.1-dev (`~/external/spike-inst`) instruction by instruction (`tools/lockstep.py`)
or by signature (`tools/archtest/sigcheck.py`). Coverage (5.8, 5.9) is read in IMC from
irun 15.2 databases, as for G4 (`Docs/COVERAGE.md`). Commands to replay: `flow/COMMANDS.md`,
G5 rows.

## 1. Row by row

| Row | Criterion | Evidence | Result |
|---|---|---|---|
| 5.3 | rv32mi and the local trap/interrupt tests pass; riscv-arch-test privileged subset | `make archtest_xrun`; `archtest_xrun_2026-11-11.txt`; rv32mi and local tests in `make regress` (G4 4.11) | riscv-arch-test 3.10.0 on Xcelium: **59 of 59** pass (I 39, Zmmul multiply 4, Zifencei 1, privilege 15), every signature equal to Spike's. 15 tests have trap-signature header words that differ exactly as ARCH-DEV-1 (GARUDA's CLIC `mtvec` MODE = 3) predicts; `sigcheck.py` accepts only that exact value. Until now this row had only the open-flow run (Verilator). |
| 5.4 | riscv-dv integrated: random streams generate, compile and run against the core | `make riscv_dv` (`flow/mk/track_a.mk`); `tb/core/riscv_dv/` | The SystemVerilog generator of riscv-dv compiles and runs on Xcelium with the GARUDA target (`tb/core/riscv_dv/target/riscv_core_setting.sv`); each program is assembled, run on tb_boot and compared with Spike. |
| 5.5 | 1000 seeds with a stable pass rate | `riscv_dv_1000_2026-11-11.txt` | **1000 of 1000** pass and match Spike: 10 tests x 100 seeds (arithmetic, random instructions, jumps, loops, memory stress, no-fence, illegal instructions, EBREAK, misaligned access). 11.3 M instructions, 1.59 M stores, 24 587 traps and 974 731 CSR instructions identical to Spike. Pass rate 100% over every test and seed. |
| 5.6 | Random AHB waits 0..8 on I and D; flush and backpressure stress | `make regress_wait`; `make regress_rand SEED=1..20`; `scripts/run_regression.sh` on the flush programs; `regress_rand_2026-11-11.txt` | Fixed waits (I 2, D 3): 66 of 66. Random 0..8 waits on every I and D access: 20 seeds x 66 ISA tests, **1320 of 1320**; flush and back-pressure programs (`t_flush`, `t_hazard`, `t_mem`, `t_loadbranch`) under the same random waits, 10 seeds, **40 of 40**. Every run also matches Spike instruction by instruction. With interrupts on top of the waits, `t_hold_flush_matrix` (`IRQ_EVERY=61`, random D waits) and `t_hazard` (random waits) are in the coverage session (section 4). |
| 5.7 | Dhrystone and CoreMark run with correct results; score per MHz recorded | `sw/bench/`; `make bench`; `bench_2026-11-11.txt` | Both run to completion and pass their own checks (CoreMark: "Correct operation validated", CRCs of the 2K performance run; Dhrystone: 18 of 18 "should be" values). Their fake-timer builds match Spike: CoreMark 675 869 and Dhrystone 504 322 instructions identical. Scores in section 2. |
| 5.8 | Core functional coverage goals met | `imc/core_func_by_type.txt`, `imc/core_func_holes.txt` | **open**: 96.1% (733 of 763 bins) by module type over the 178 core runs, from 91.7% / 84.6% at G4 (section 4). 30 bins left, listed in section 4 with what closes each. |
| 5.9 | Core code coverage >= 95%, every exclusion with a reason | `flow/cov/core_g5_merge.tcl`; `imc/core_code_raw.txt`, `imc/core_code_waived.txt`; `tb/core/cov/core_waivers.toml` | 178 core runs merged in IMC by module type. Raw: statement 99.0% (290/293), expression 100% (73/73), toggle 93.9% (8883/9456), FSM 100%. With the written waivers: **100% on all four** (578 toggle bits and 3 defensive `default:` arms, each with its reason and evidence in `core_waivers.toml`; 586 exclusions applied, 0 dropped). The waivers' `reviewer` field still reads `pending`: section 4. |

## 2. Performance (5.7), read before RTL freeze

There is no performance target in `Design_Docs/`; these numbers are recorded, not judged.

| Benchmark | Waits (I, D) | Cycles | Instructions | CPI | Score |
|---|---|---|---|---|---|
| CoreMark (20 iterations, -O2) | 0, 0 | 11 988 191 | 6 297 136 | 1.90 | **1.67 CoreMark/MHz** |
| CoreMark | 2, 3 | 26 695 399 | 6 297 136 | 4.24 | 0.75 CoreMark/MHz |
| Dhrystone 2.2 (500 runs, -O2) | 0, 0 | 881 074 | 426 038 | 2.07 | **0.323 DMIPS/MHz** (1762 cycles per run) |
| Dhrystone | 2, 3 | 1 936 167 | 426 038 | 4.55 | 0.147 DMIPS/MHz |

`make bench BENCH_ARGS="+IWAIT=2 +DWAIT=3"` gives the second and fourth rows.

Where Dhrystone's instructions go (timed image, 500 runs): software divide `__divsi3`,
`__udivsi3`, `__umodsi3` 35%; byte-at-a-time `strcpy` and `strcmp` 30%; the benchmark
itself the rest. Both follow from decisions already taken: no hardware divide (DN-ISA,
Zmmul only) and a minimal C library. The CPI follows from the micro-architecture
(`Design_Docs/GARUDA-CORE-UARCH-001.md` §7.3, §9.2): every load and store spends at least
two cycles in MEM (one outstanding D-port transfer, no pipelined addresses), a JAL or
predicted-taken branch costs one bubble, a mispredict or JALR two.

## 3. What changed

| Change | Why |
|---|---|
| New `sw/bench/` (CoreMark from EEMBC `1f483d5`, Dhrystone from riscv-tests `ec8e5a2`, both unchanged; GARUDA port, run-time, start-up, linker script), `tools/bench_report.py`, target `bench` | 5.7 had no benchmark. tb_boot has no console: output goes to a RAM block the bench dumps (`sw/bench/README.md`). |
| `sw/bench/rt/crt0_bench.S` zeroes x1..x31 | The register file has no reset (CORE spec, ID). The first lockstep of Dhrystone diverged at instruction 10674: `bench_printf` saved and reloaded s1..s6 that were never written, X on the RTL and 0 on Spike. Not an RTL fault; riscv-tests' benchmark start-up does the same. |
| `flow/regress/run_test.sh` (`prog_*`, `dv_*`), `tools/regress/toml_test.py`, `flow/regress/garuda.vsif` (groups `core_smokes`, `core_riscv_dv`, `core_programs`), `sw/Makefile` (18 programs) | Every core program in the Cadence coverage session, from the same manifests as the open flow. `smoke_core_halt` left the list (it needs an image; the halt bench runs as `prog_halt__*`). |
| `tb/cov/garuda_core_cov_ext.sv` | TB-B5, section 4. |
| `tools/cov/gen_imc_exclusions.py` (escaping, `--type`), four regenerated exclusion files, `flow/cov/core_exclusions_type.tcl`, `flow/cov/core_g5_merge.tcl`, `flow/cov/core_g5_runs.txt` | TOOL-A16, section 4; the core merge by module type. |
| `tools/archtest/build_archtest.py`, target `archtest_xrun` | TOOL-A15: the suite was not found on the lab machine, and with the Vitis GCC 11 of 59 tests did not link and the rest started with a build-id note at the reset vector (0 instructions retired). Fixed; `tb/core/run/archtest.toml` unchanged. |

## 4. Core coverage (5.8, 5.9)

**The session.** Every core test of `flow/regress/garuda.vsif`, 178 runs under irun 15.2 with
coverage (`flow/cov/core_g5_runs.txt`): 21 unit benches, 7 smoke benches, the DSU bench, 63
ISA tests, 18 sanity programs, 38 core programs that until today ran only on the open flow
(new `prog_<suite>__<test>` tests, each one row of `tb/core/run/<suite>.toml` through
`tools/regress/toml_test.py`) and 30 riscv-dv programs (`dv_<test>_s<seed>`). All 178 pass.
Merged in IMC by module type (`flow/cov/core_g5_merge.tcl`), so a module's numbers count
every bench that instantiates it.

Left out: `t_dsu_macsat_rd`, which checks MACSAT as the spec had it before ruling D-32 and
fails by design (DSU-15, `tb/core/run/xfail.tsv`); it is to be rewritten to the ruled spec.

**Code (5.9), per module after the waivers:** every one of the 31 core modules at 100%
statement, expression and toggle (`imc/core_code_waived.txt`). The modules with the most
waived toggle bits are `csr_file` (206), `garuda_core_top` (104), `iport` (55), `if_stage_top`
(50), `imm_gen` (43: U-immediate bits 11:0 and the CSR immediate's upper bits are literal 0,
branch and jump immediates have bit 0 = 0) and `trap_ctrl` (43: cause codes below 32, MEM
causes 5 and 7 only, the word-aligned PC and the mtvec base). The 67 waivers of
`core_waivers.toml` were written on 2026-10-11 with their evidence: 44 cite a property PROVEN
on the whole core (`tb/core/formal/cov_const_sva.sv`), 13 cite the RTL line that makes the
point constant, unreachable or not connected, 10 are `ignore` entries that mirror an `ignore_bins`. Their
`reviewer` field still reads `pending`, so the review of `core_waivers.toml` is part of this
gate's review record.

**Functional (5.8), by covergroup type:**

| Covergroup | Bins | Left |
|---|---|---|
| `garuda_cov` | 99.6% (228/229) | forwarding from EX/MEM while MEM stalls |
| `garuda_cov_vplan` | 97.6% (240/246) | a MUL and a bubble as load-use partners; MTI together with a CLIC interrupt (both pending, each taken); a CLIC wake with MIE = 0 |
| `garuda_cov_ext` | 98.1% (105/107) | IF/ID and ID/EX held and flushed in the same cycle |
| `garuda_core_cov_ext` | 88.4% (160/181) | writes to the read-only CSRs `mip`, `mnxti`, `mintstatus` (both addresses) and `misa` with RC (13 bins); CLIC ids 2 (DMA), SPIS and 0 (timer MTI); a non-zero `mintthresh`; the lowest level nested; a one-cycle sleep; woken by both or by neither |
| **core total** | **96.1% (733/763)** | 30 bins |

Each needs either a program that reaches it or, where the combination cannot happen, a
reason in the covergroup (`ignore_bins` with the spec reference), as `x_csr_illegal` got today.

**A defect in the coverage model, fixed (TB-B5).** `cg_csr` sampled only when a CSR access
commits; a refused access traps and is squashed in EX, so it never commits, and every bin of
a refused access was unreachable. It now samples on commit or refusal, and the impossible
"writable CSR refused" bins are `ignore_bins`.

**A defect in the waiver tooling, fixed (TOOL-A16).** 214 of the 586 core exclusions had never
been applied in IMC (Tcl ran the `[...]` in their comments); the same fault was in the AHB,
bridge and DMA files. The earlier figures "with waivers" were therefore too low, never too high.

## 5. Open in G5

- 5.8: the 30 functional bins above.
- The vManager session of the whole `garuda.vsif` (today's session was run test by test with
  the same `run_test.sh` vManager calls) and the merged coverage back-annotated on the vPlan.
- Review: `flow/reviews/g5_f6_core.md`, with `core_waivers.toml` read by the reviewer.
