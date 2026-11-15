# Review record: G5, flow stages F6 and F8 for the core (Xcelium against Spike, benchmarks, core coverage)

Written by the reviewer, not the author (`flow/reviews/TEMPLATE.md`). The author filled in
only the header and the list of what to read and run, on 2026-11-11; every other entry is
the reviewer's.

| | |
|---|---|
| Block or task | 1-TOPS G5 rows 5.3 to 5.9; the core coverage merge, its waivers and the two `ignore_bins` of 5.8 |
| Author (track) | Claude (both tracks) |
| Reviewer (track) | Karthik |
| Commit reviewed | |
| Date | |
| Verdict | |

## 1. What was read

| Item | Path | Read |
|---|---|---|
| Row-by-row record, performance, coverage | `flow/4_core/core_g5.md` | |
| Arch-test on Xcelium | `flow/4_core/archtest_xrun_2026-11-11.txt` | |
| 1000 riscv-dv seeds | `flow/4_core/riscv_dv_1000_2026-11-11.txt` | |
| Wait-state randomisation | `flow/4_core/regress_rand_2026-11-11.txt` | |
| Benchmarks | `sw/bench/README.md`, `sw/bench/rt/`, `sw/bench/coremark/core_portme.c`, `tools/bench_report.py`, `flow/4_core/bench_2026-11-11.txt` | |
| Core coverage | `flow/cov/core_g5_merge.tcl`, `flow/cov/core_g5_runs.txt`, `flow/4_core/imc/` | |
| The vManager session and the vPlan in vManager | `flow/1_vplan/garuda_core_g5.csv`, `flow/regress/vplan_g5.tcl`, `flow/4_core/vplan_g5_2026-11-16.txt`; `Docs/bugs/track_a.md` TOOL-A17 | |
| **The 67 core waivers (reviewer field `pending`)** | `tb/core/cov/core_waivers.toml`, `tb/core/formal/cov_const_sva.sv` | |
| Covergroup fixes | `tb/cov/garuda_core_cov_ext.sv` (`cg_csr`, `cg_irq`), `tb/cov/garuda_cov_ext.sv` (bind of `cg_pipe`) | |
| Row 5.8 programs and bench options | `sw/tests/t_cov_csr_ro.S`, `sw/tests/t_cov_irq_ids.S` (parts A to J); `tb/soc/tb_boot.sv` (IRQ_ARMC bit 31, `+FSTOP_ON_WFI`) | |
| MACSAT test rewritten to the ruled spec | `sw/tests/t_dsu_macsat_rd.S`; `Docs/bugs/track_a.md` DSU-15 | |
| The two `ignore_bins` of 5.8 and their JasperGold proofs; the CG_DIS path | `flow/4_core/core_g5.md` section 4; `flow/formal/core/cov_g5_unr.tcl`, `.result.txt` | |
| Session changes | `flow/regress/run_test.sh` (`prog_*`, `dv_*`), `tools/regress/toml_test.py`, `flow/regress/garuda.vsif` | |
| Bug entries | `Docs/bugs/track_a.md` TOOL-A15, TOOL-A16, TOOL-A17; `Docs/bugs/track_b.md` TB-B5, TB-B6 | |

## 2. What was run by the reviewer

From `flow/COMMANDS.md`, "Replay by gate", rows R5.1 to R5.9.

| Command | Result |
|---|---|
| | |

## 3. Questions asked and the answers

| # | Question | Answer | Settled |
|---|---|---|---|
| | | | |

## 4. Changes asked for

| # | What | Where | Done in commit |
|---|---|---|---|
| | | | |

## 6. What the reviewer did not check

## Signature
