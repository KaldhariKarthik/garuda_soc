# Review record: G5, flow stages F6 and F8 for the core (Xcelium against Spike, benchmarks, core coverage)

Written by the reviewer, not the author (`flow/reviews/TEMPLATE.md`). The author filled in
only the header and the list of what to read and run, on 2026-11-11; every other entry is
the reviewer's.

| | |
|---|---|
| Block or task | 1-TOPS G5 rows 5.3 to 5.9 (5.8 still open); the core coverage merge and its waivers |
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
| **The 67 core waivers (reviewer field `pending`)** | `tb/core/cov/core_waivers.toml`, `tb/core/formal/cov_const_sva.sv` | |
| Covergroup fix | `tb/cov/garuda_core_cov_ext.sv` (`cg_csr`) | |
| Session changes | `flow/regress/run_test.sh` (`prog_*`, `dv_*`), `tools/regress/toml_test.py`, `flow/regress/garuda.vsif` | |
| Bug entries | `Docs/bugs/track_a.md` TOOL-A15, TOOL-A16; `Docs/bugs/track_b.md` TB-B5 | |

## 2. What was run by the reviewer

From `flow/COMMANDS.md`, "Replay by gate", rows R5.1 to R5.6.

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
