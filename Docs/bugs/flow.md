# Bugs: Flow, tools, testbench infrastructure (TOOL, VER, MUT, LINT, FV)

Owner: shared. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).
Priorities: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).

<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. Run `bugs.py check` before pushing. -->
| ID | Title | Status | Prio | Found-by | Found | Fixed-in | Regression test | Evidence | Formerly |
|---|---|---|---|---|---|---|---|---|---|
| TOOL-19 | Two vendored IPs in one elaboration passed -timescale twice and xrun failed *E,OPTNOML | FIXED | P3 | `make test_chip_uart` | 2026-09-22 | legacy | every chip target | HISTORY_2026.md L126 | TOOL-5 |
| TOOL-20 | stale | FIXED | - | - | 2026-09-26 | legacy | - | HISTORY_2026.md L198 | TOOL-6 |
| TB-22 | edge | FIXED | P1 | `make local_sim` | 2026-10-03 | legacy | - | HISTORY_2026.md L215 | - |
| TOOL-7 | "No latches inferred" while the netlist contained one | FIXED | P1 | building the negative control | 2026-10-03 | legacy | - | HISTORY_2026.md L216 | - |
| TOOL-8 | CRLF | FIXED | P2 | whole-chip Verilator lint | 2026-10-03 | legacy | - | HISTORY_2026.md L217 | - |
| TOOL-9 | whole-chip synthesis failed outright | FIXED | P2 | `make local_synth` | 2026-10-03 | legacy | - | HISTORY_2026.md L218 | - |
| TOOL-10 | survives | FIXED | P2 | running it twice | 2026-10-03 | legacy | - | HISTORY_2026.md L219 | - |
| TB-24 | shared | FIXED | P2 | first bind into `tb_ahb2apb` | 2026-10-03 | legacy | - | HISTORY_2026.md L270 | - |
| TOOL-11 | run_blk, run_tb_top and run_tb_elem counted [FAIL] lines only | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L303 | - |
| LINT-1 | 5 errors, 777 warnings | CLOSED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L310 | - |
| FV-1 | AUD-8 therefore stays open on formal | OPEN | P3 | - | 2026-10-04 | - | - | HISTORY_2026.md L344 | - |
| TB-27 | The "randomised soak" loops were not random | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L345 | - |
| TOOL-12 | The Spike lockstep ignores Spike's exit status (the short-log half was fixed by VER-3) | FIXED | P2 | - | 2026-10-04 | c22c00e | selftest_runners lockstep_negctl N5 | Docs/VERIFICATION_LOG_2026-10-11.md; logs/flow/evidence/TOOL-12_before_lockstep_negctl.txt | - |
| TOOL-13 | The Makefile's simulation macros and the Icarus runner never use the simulator's exit status | FIXED | P2 | - | 2026-10-04 | c75fd2b | Karthik negative test (VERIFICATION_LOG) | Docs/VERIFICATION_LOG_2026-10-11.md | - |
| TOOL-14 | The older coverage script cannot fail because a test failed | FIXED | P2 | - | 2026-10-04 | 08249c2 | Karthik negative test (VERIFICATION_LOG) | Docs/VERIFICATION_LOG_2026-10-11.md | - |
| TOOL-15 | The filelist expander silently drops -define lines | FIXED | P3 | - | 2026-10-04 | c75fd2b | Karthik negative test (VERIFICATION_LOG) | Docs/VERIFICATION_LOG_2026-10-11.md | - |
| TOOL-16 | Every UVM simulation under irun 15.2 prints ncsim: *E,IMPDLL: Unable to load the implicit shared object ((null)/top/s... | OPEN | P3 | first UVM run on irun | 2026-10-04 | - | - | HISTORY_2026.md L391 | - |
| VER-1 | Does the new environment catch bugs? | FIXED | - | mutation run, 2026-10-04 | 2026-10-04 | legacy | - | HISTORY_2026.md L392 | - |
| VER-4 | Does the PWM environment catch bugs? | FIXED | - | mutation run, 2026-10-05 | 2026-10-04 | legacy | - | HISTORY_2026.md L400 | - |
| VER-5 | Does the GPIO environment catch bugs? | FIXED | - | mutation run, 2026-10-05 | 2026-10-04 | legacy | - | HISTORY_2026.md L402 | - |
| VER-6 | Does the clock and reset environment catch bugs? | FIXED | - | mutation run, 2026-10-05 | 2026-10-04 | legacy | - | HISTORY_2026.md L404 | - |
| VER-2 | Does the timers environment catch bugs? | FIXED | - | mutation run, 2026-10-04 | 2026-10-04 | legacy | - | HISTORY_2026.md L406 | - |
| TOOL-4 | Icarus silently ignores $random's seed | FIXED | P1 | - | legacy | legacy | - | HISTORY_2026.md L832 | - |
| TB-11 | the SoC/interconnect seed sweep was not varying the bus timing | FIXED | P1 | - | legacy | legacy | - | HISTORY_2026.md L844 | - |
| TB-12 | T12's DMA-grant bound was a statement about the slave, not the arbiter | FIXED | P2 | - | legacy | legacy | - | HISTORY_2026.md L865 | - |
| TOOL-1 | choco install iverilog needs Administrator | CLOSED | - | - | legacy | legacy | - | HISTORY_2026.md L968 | - |
| TOOL-2 | Verilator in the portable bundle has a baked-in absolute path — set VERILATOR_ROOT | CLOSED | - | - | legacy | legacy | - | HISTORY_2026.md L969 | - |
| TOOL-3 | before | CLOSED | - | - | legacy | legacy | - | HISTORY_2026.md L970 | - |
| TOOL-18 | The team flow is unexercised | CLOSED | - | - | legacy | legacy | - | HISTORY_2026.md L971 | TOOL-5 |
| TOOL-6 | *(new)* No RISC-V toolchain on this machine, so the SoC test program is built with the stopgap tools/gen/mini_rv32_as... | CLOSED | - | - | legacy | legacy | - | HISTORY_2026.md L972 | - |
| TOOL-5 | the static checker reported success having checked nothing | FIXED | P1 | - | legacy | legacy | - | HISTORY_2026.md L1072 | - |
| MUT-1 | AHB-1: HWDATA muxed on grant (as spec §3.1 says) | CLOSED | - | - | legacy | legacy | - | HISTORY_2026.md L1099 | - |
| MUT-2 | AHB-2: force_owner reinstated (spec §7.2 literally) | CLOSED | - | - | legacy | legacy | - | HISTORY_2026.md L1100 | - |
| MUT-3 | AHB-2: response hold disabled | CLOSED | - | - | legacy | legacy | - | HISTORY_2026.md L1101 | - |
| MUT-4 | AHB-3: SEQ→NONSEQ rewrite removed | CLOSED | - | - | legacy | legacy | - | HISTORY_2026.md L1102 | - |
| MUT-5 | Data-phase select bypassed (use address-phase HSEL) | CLOSED | - | - | legacy | legacy | - | HISTORY_2026.md L1103 | - |
| MUT-6 | DMA-3: arm latch removed (pre-fix behaviour) | CLOSED | - | - | legacy | legacy | - | HISTORY_2026.md L1104 | - |
| MUT-7 | DMA-3a: en_h qualifier removed from the deferred start | CLOSED | - | - | legacy | legacy | - | HISTORY_2026.md L1105 | - |
| MUT-8a | DMA-3: WAITING abort-path clear removed | CLOSED | - | - | legacy | legacy | - | HISTORY_2026.md L1106 | - |
| MUT-8b | DMA-3a: COMPLETE decline-path clear removed | CLOSED | - | - | legacy | legacy | - | HISTORY_2026.md L1107 | - |
| MUT-9 | DMA-3: CIRC absorb removed | CLOSED | - | - | legacy | legacy | - | HISTORY_2026.md L1108 | - |
| TOOL-21 | rtl/pwm/pwm_sva.sv does not elaborate on Verilator 5.052 ($past of an unpacked-array element in a generate loop) | OPEN | P3 | Track A W4 chip check | 2026-10-11 | - | debug/chip (excluded file) | logs/debug/raw/chip/build_tb_chip.log | - |
| TOOL-22 | Verilator 5.052 get_coverage() returns 0.0% for every covergroup; bins are only in coverage.dat with --coverage-user | OPEN | P3 | Track A W6 (tb_clic_ctrl ELEM-7 fix) | 2026-10-11 | - | - | logs/core/evidence/W6_bench_fixes.txt; Docs/handbook/H5_coverage.md | - |
| TOOL-23 | Verilator 5.052 aborts (internal fault, SIGSEGV) on a class covergroup that samples through a virtual interface | OPEN | P3 | Track A D1 (all 13 dsu-verification benches) | 2026-10-11 | - | dsu/units (covergroups compiled out under VERILATOR by tools/gen/port_dsu_benches.py) | logs/dsu/evidence/D1_dsu_units_2026-10-11.txt | - |
| TOOL-24 | Verilator 5.052 rejects a variable part-select inside $past() (Selection index is constantly unknown or tristated) | OPEN | P3 | dma_sva port (Track A DMA plan D1) | 2026-10-12 | - | - | - | - |
| TOOL-25 | Verilator 5.052 expression coverage never counts the "=> 1" rows of an if inside a begin-end for body when the if body rewrites an operand of its condition | OPEN | P3 | DMA coverage closure (Track A DMA plan D7) | 2026-10-12 | - | logs/flow/evidence/TOOL-25_exprcov/run.sh | logs/flow/evidence/TOOL-25_exprcov/output_2026-10-12.txt | - |
| TOOL-26 | garuda_fv.py classified a k-induction step failure (SBY UNKNOWN) as FAIL | IN-PROGRESS | P3 | core pipe_prove k-induction attempt (Track A wrap-up) | 2026-10-12 | - | tools/run/garuda_fv.py classify | logs/core/raw/fv_trap/pipe_prove/pipe_prove/logfile.txt (DONE (UNKNOWN, rc=4); runner said FAIL) | - |
| TOOL-17 | vendor_sync.py could not run on Windows (paths, encoding, CRLF hashes) | FIXED | P3 | Karthik (Windows) | 2026-10-11 | 8123a52 | vendor_sync.py check (VERIFICATION_LOG) | Docs/VERIFICATION_LOG_2026-10-11.md | - |
| FV-2 | pipe_ctrl proved on free tools (SymbiYosys, assume-guarantee) | CLOSED | - | Karthik | 2026-10-11 | 34cff0e | flow/2_static/fv_pipe_ctrl/sby/pipe_ctrl.sby | Docs/VERIFICATION_LOG_2026-10-11.md | - |

## Details

### TOOL-19

*From `Docs/BUGS.md` at b90b481, line 126, section "1c. Peripherals — vendored IP and wrappers, 2026-09-22/23".*

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| **TOOL-5** | build | FIXED | low | Two vendored IPs in one elaboration passed `-timescale` twice and `xrun` failed `*E,OPTNOML`. The option is now in `rtl/third_party/timescale.f`, included once by each top-level filelist and never by a per-IP one. | `make test_chip_uart` | every chip target |

### TOOL-20

*From `Docs/BUGS.md` at b90b481, line 198, section "1e. Block 14 (SPI slave) — 2026-09-26".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **TOOL-6** | this session | FIXED | The commit that added block 14 went in with `rtl/include/garuda_map.vh` and `sw/common/garuda_map.h` **stale** against the yaml. `garuda_gen.py --check` had reported it, but the check was `&&`-chained ahead of a doc update while `git commit` sat on its own line, so the failure aborted the docs and not the commit. Regenerated in the next commit. The lesson is the shape of the command, not the tool: a gate that does not gate the thing it is protecting is decoration. |

### TB-22

*From `Docs/BUGS.md` at b90b481, line 215, section "1f. The licence-free local flow — 2026-10-03".*

| ID | Where | Status | Severity | Summary | Found by |
|---|---|---|---|---|---|
| **TB-22** | 5 block TBs | **FIXED** | **high (falsely reassuring / wasted debug)** | A reset held low from time 0 never reaches the design. A Verilog async reset is **edge** sensitive in simulation: `always @(posedge clk or negedge rst_n)` is not evaluated merely because `rst_n` is already low at time 0. `tb_crg`, `tb_ahb2apb`, `tb_timers`, `tb_spim` and `tb_dsu_top` declared theirs `= 0`, so no `negedge` ever occurred and every flop whose only reset was that signal stayed X for the entire run. In `clk_div` that flop is `pclk_q`, and `pclk_q <= ~pclk_q` keeps X forever, so `pclk` and `preset_n` never resolved. Measured under Icarus: *neither* `reg a = 0;` *nor* `initial a = 0;` creates the edge — the `always` block is not armed until after time 0. In silicon the reset pin is level sensitive and this cannot happen, so the fix belongs in the testbench: declare the reset de-asserted, assert it at time 0. **`tb_crg` 0 → 43 checks; `tb_ahb2apb` 1 → 20; `tb_timers` 0 → 23; `tb_debug` 15 failures → 0.** | `make local_sim` |

### TOOL-7

*From `Docs/BUGS.md` at b90b481, line 216, section "1f. The licence-free local flow — 2026-10-03".*

| ID | Where | Status | Severity | Summary | Found by |
|---|---|---|---|---|---|
| **TOOL-7** | `scripts/run_synth.sh` | **FIXED** | **high (a gate that could not fail)** | The latch gate printed **"No latches inferred" while the netlist contained one**. It grepped its own log for `\$_?DLATCH`, a pattern that never matches the text yosys writes. It now reads the object list yosys emits with `select -list`, **refuses to report at all if that file is absent**, and allows `core_clk_gate`'s ICG enable latch **by name** so any other latch still fails the run. Proven by injecting a live latch into `clk_div`: exits 1 and names it; reverted, exits 0. The first attempt at that control was itself invalid — yosys optimised the injected latch away because nothing read it — which is also why log-grepping is unreliable in *both* directions: the "Latch inferred" warning fires for latches that are then deleted. Compare `ERR-U3`, where 24 real latches were caught only by synthesis. | building the negative control |

### TOOL-8

*From `Docs/BUGS.md` at b90b481, line 217, section "1f. The licence-free local flow — 2026-10-03".*

| ID | Where | Status | Severity | Summary | Found by |
|---|---|---|---|---|---|
| **TOOL-8** | `scripts/expand_filelist.py` | **FIXED** | medium (blocked chip-level lint) | The expander emitted **CRLF**, so every path it printed carried a trailing CR, and a shell does not word-split on CR. iverilog tolerates a stray CR in a filename — which is why the Icarus flow never noticed — but Verilator reports the path as a module it cannot find. This is what made the expanded filelist look unusable for lint and kept chip-level lint a manual, per-block job (`RTL_LOG_2026-09-16.md:320`). It applied to **every** invocation on Windows regardless of the filelist's own line endings. | whole-chip Verilator lint |

### TOOL-9

*From `Docs/BUGS.md` at b90b481, line 218, section "1f. The licence-free local flow — 2026-10-03".*

| ID | Where | Status | Severity | Summary | Found by |
|---|---|---|---|---|---|
| **TOOL-9** | `scripts/expand_filelist.py` | **FIXED** | medium (blocked whole-chip synthesis) | `--yosys` emitted `read_verilog` with no `-sv`, so yosys's Verilog-2005 front end rejected `input logic clk` at `spi_master_clkgen.sv:13` and **whole-chip synthesis failed outright** from the moment the vendored PULP SPI master joined the build. Flagged per file now, so Verilog-2005 sources keep being parsed as Verilog-2005. | `make local_synth` |

### TOOL-10

*From `Docs/BUGS.md` at b90b481, line 219, section "1f. The licence-free local flow — 2026-10-03".*

| ID | Where | Status | Severity | Summary | Found by |
|---|---|---|---|---|---|
| **TOOL-10** | `scripts/run_sim.sh` | **FIXED** | medium | Two kinds of stale result. (a) Per-testbench results accumulate through a file because the loop runs in a subshell, and the file was not deleted first — a second run reported both runs added together, the same class as a stale `.vvp`. (b) No wall-clock cap, so one hanging testbench hung the regression; and on Windows `timeout` returns 124 while the native `vvp` child **survives**, leaving an orphan spinning in a zero-delay loop that takes a core for the rest of the session. Both fixed; each `.vvp` is also deleted before building and the compile's real exit code gates the run. | running it twice |

### TB-24

*From `Docs/BUGS.md` at b90b481, line 270, section "1g. The APB protocol checker — 2026-10-03".*

| ID | Where | Status | Severity | Summary | Found by |
|---|---|---|---|---|---|
| **TB-24** | `tb/common/apb_checker.v` | **FIXED** | medium (would have mis-attributed traffic) | My own defect, found on the first bind and worth recording because of how it announced itself. The access counter triggered on `PENABLE`'s falling edge without also requiring the slave's own `PSEL` — and APB fans a **shared** PENABLE out to every window, so each per-slave checker counted the whole bus. The tell was windows 1 and 11 of `tb_ahb2apb` reporting byte-identical totals (28 accesses, 12 write, 16 read) for two different windows, and two "abandoned accesses" each that belonged to window 2's timeout. The self-test had not caught it because it drives a single PSEL, which is the same blind spot as checking a per-slave rule on a single-slave bus. Fixed by gating on `p_psel`, and scenario M was added — another window's traffic on the shared PENABLE must register as neither a violation **nor** an access. Verified to discriminate: with the fix reverted, scenario M fails. | first bind into `tb_ahb2apb` |

### TOOL-11

*From `Docs/BUGS.md` at b90b481, line 303, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **TOOL-11** | `Makefile` | FIXED | `run_blk`, `run_tb_top` and `run_tb_elem` counted `[FAIL]` lines only. Simulator assertion failures (`xmsim: *E,ASRTST`) never reached the summary, so four logs carried failing assertions under a PASS: `unit_decode_control` 88, `chip_irq` 3, `elem_garuda_iport_ahb_master` 382, `elem_garuda_prefetch_buffer` 750. The summary now prints an `SVA_FAIL` count and the first failing lines. |

### LINT-1

*From `Docs/BUGS.md` at b90b481, line 310, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **LINT-1** | whole chip, HAL 15.20 | 5 errors left, all dispositioned | First lint run on the chip: 696 errors, 5 749 warnings. With formatting and house-style rules off (`flow/2_static/hal.f`) and the fixes above: **5 errors, 777 warnings**. The five: `CDEFNC` ×2 and `TERMST`/`UNRCHS` are in vendored IP (PULP SPI master, OpenCores I²C); `GLTASR` ×1 is the core's `core_rst_n_i & hartreset_n_i`, which CORE [N-7.33] requires to be combined inside the core. Reasons in `flow/2_static/hal_waivers.txt`. |

### FV-1

*From `Docs/BUGS.md` at b90b481, line 344, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **FV-1** | IFV 15.20 | NOT RUN (no licence) | `Incisive_Formal_Verifier` is not on the licence server (`*F,NSLICN`). The run is set up in `flow/2_static/fv_pipe_ctrl/` (whole core, `pipe_ctrl_sva` bound, free bus and interrupt inputs). **AUD-8 therefore stays open on formal**; the hold-versus-flush cells are pursued in simulation instead (stage 4). |

**2026-10-14:** Karthik 34cff0e: still NOT RUN on IFV; pipe_ctrl proved in SymbiYosys instead (FV-2).

### TB-27

*From `Docs/BUGS.md` at b90b481, line 345, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **TB-27** | five element testbenches | FIXED | **The "randomised soak" loops were not random.** `bit x = $urandom...;` declared inside a loop in a static `initial` is a static variable: its initialiser runs once, at time 0. In `tb_garuda_pc_gen`, `tb_garuda_prefetch_buffer`, `tb_mem_stage`, `tb_mem_wb_reg` and `tb_garuda_if_stage_top` every soak iteration therefore drove the same frozen values. The declarations are now `automatic`. With the stimulus really random all five still pass, which is the first time that statement means anything. |

### TOOL-12

*From `Docs/BUGS.md` at b90b481, line 375, section "1i. Independent audit on free tools — 2026-10-04/05".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **TOOL-12** | `tools/lockstep.py` | OPEN | **The Spike lockstep says MATCH when Spike's log is the one that ends early.** It compares the first `min(len(gold), len(rtl))` commits (line 159) and fails only an RTL log more than 3 short (168-172); when it runs Spike it does not read Spike's exit status (146), and only an empty Spike log is rejected (154). Negative control: the `add` Spike log cut to its first 213 commits (full log 428, RTL 427) prints `MATCH: 213 instructions identical` and exits 0. `scripts/run_regression.sh` and `flow/regress/run_test.sh` treat that line as a pass, so a Spike run that died part-way would leave the rest of the test checked only by its tohost self-check. Also failing when `len(rtl) - len(gold) > 3` closes it. By design only (pc, rd, value) is compared; CSR side effects and store data are not (lines 17-25). Found by: negative control N4 (truncated Spike log). |

**2026-10-14:** FIXED by Karthik in c22c00e (fails when Spike stops short). Track A keeps the stricter check on top (any non-zero Spike exit fails): his version alone does not catch N5 (full log, exit 1).

### TOOL-13

*From `Docs/BUGS.md` at b90b481, line 376, section "1i. Independent audit on free tools — 2026-10-04/05".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **TOOL-13** | `Makefile`, `scripts/run_sim.sh` | OPEN | **The Makefile's simulation macros and the Icarus runner never use the simulator's exit status.** Under `SIM=xrun`, `run_test` (lines 42-49), `run_tb_top` (119-128), `run_tb_elem` (173-184) and `run_blk` (215-223) run `$(XRUN) ...;` and then grep or printf the log; each recipe ends in printf, a grep with an echo fallback or a grep piped into head, so the target exits 0 whatever xrun returned. TOOL-11's SVA_FAIL count is printed, not returned. In `scripts/run_sim.sh`, `run_one` checks vvp's status only for the timeout code 124 (line 158) and returns 0; `verdict_of` (172-186) uses the last PASSED, FAILED or TIMEOUT word and the `[FAIL]` count. Exit status alone is not enough either: Verilator 5.052 with `+verilator+error+limit+1000` exited 0 after 8 assertion failures. A sound verdict needs exit status, pass marker and failure counts together. Found by: code reading during the independent audit; the Verilator figure comes from an SVA self-test. |

**2026-10-14:** FIXED by Karthik in c75fd2b.

### TOOL-14

*From `Docs/BUGS.md` at b90b481, line 377, section "1i. Independent audit on free tools — 2026-10-04/05".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **TOOL-14** | `scripts/run_coverage.sh` | OPEN | **The older coverage script cannot fail because a test failed.** `scripts/run_coverage.sh` sets only `set -u` (line 33), discards each `irun -R` run's console output without reading its exit status (88-91) and judges the run only by grepping its log for the TOHOST pass marker (93-95), so a run with assertion failures can still read PASS; a FAIL or TIMEOUT run's scope is merged anyway (97). The six unit benches are judged by `[FAIL]` lines only (134), without the `*E,ASRTST` count TOOL-11 added to the Makefile, and are merged regardless (136). IMC errors are only printed (159) and the script ends on an `echo` (168), so it exits 0 unless elaboration fails or no scope exists (57-59, 140). `make coverage`, `Docs/COVERAGE.md:49` and `Docs/HANDOFF.md:403` still point to it; the vManager flow (`flow/regress/run_test.sh:94-97`) fails a run on any `*E`. Found by: reading the script after TOOL-11. |

**2026-10-14:** FIXED by Karthik in 08249c2.

### TOOL-15

*From `Docs/BUGS.md` at b90b481, line 378, section "1i. Independent audit on free tools — 2026-10-04/05".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **TOOL-15** | `scripts/expand_filelist.py` | OPEN | **The filelist expander silently drops `-define` lines.** `scripts/expand_filelist.py:59-62` skips every line beginning with `-` other than `-f` and `-incdir`, and still exits 0. Seven filelists carry a define: `tb/core/filelist_{decode_control,imm_gen,reg_file,branch_predict,hazard_forward_unit,id_stage}.f` (`GARUDA_REAL_RTL`, which removes each bench's inlined DUT snapshot) and `tb/soc/filelist_boot_cov.f` (`GARUDA_COV`, which enables `tb_boot`'s coverage self-report). Expanded by this script, a unit bench gets the real RTL and a snapshot module of the same name (for example `rtl/core/decode_control.v:21` and `tb/core/tb_decode_control.sv:59`), so it cannot be built as xrun builds it. Latent today: `run_sim.sh`, `make local_lint` and `run_synth.sh` read none of the seven, although `run_sim.sh`'s header promises the same source list as xrun. Found by: building the unit benches under Verilator, where a replacement expander had to restore the defines. |

**2026-10-14:** FIXED by Karthik in c75fd2b.

### TOOL-16

*From `Docs/BUGS.md` at b90b481, line 391, section "1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)".*

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **TOOL-16** | irun 15.20 with UVM | OPEN (tool, worked around) | P3 | Every UVM simulation under irun 15.2 prints `ncsim: *E,IMPDLL: Unable to load the implicit shared object` (`(null)/top/sv/_sv_export.so`): irun does not build its own stub library for UVM's DPI exports on this machine. Tried `-dpi`, `-snsvdpi`, `-gcc_vers 4.8`, UVM 1.1d, `UVM_NO_DPI`, 32-bit mode; none removes it. The simulation runs and the coverage database is written, and Xcelium 22.09 runs the same environment with no message. irun is used because IMC here reads only its databases. `make uvm_clic` ignores exactly this one line and fails on any other error. | first UVM run on irun |

### VER-1

*From `Docs/BUGS.md` at b90b481, line 392, section "1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)".*

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **VER-1** | CLIC UVM environment, negative control | DONE | n/a | **Does the new environment catch bugs?** Five real defects were planted in copies of the CLIC RTL, one at a time: ties going to the highest ID, the enable mask dropped, an extra offset decoded, the level of a non-candidate not gated, CLICIP read through the enables. **All five fail both the directed and the random test**, each caught independently by the scoreboard and by a bound property. A sixth mutant, `>=` changed to `>` in the selection compare, passes, and correctly: the compared keys are never equal, so it is the same circuit. | mutation run, 2026-10-04 |

### VER-4

*From `Docs/BUGS.md` at b90b481, line 400, section "1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)".*

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **VER-4** | PWM UVM environment, negative control | DONE | n/a | **Does the PWM environment catch bugs?** 21 defects planted one at a time in copies of the PWM core, the PWM top and the shared shim: the prescaler compare put back to equality (PWM-4), the tick one cycle long, no double buffer, no clamp, the channel enable ignored, the pulse one tick long, the counter kept while stopped, a stop that takes effect a cycle late, the channel enables taken from the wrong bits, the clamp flags missing from STATUS, the clamp event as AND instead of OR, PRESCALE stored in 15 bits, a write landing in the setup phase, the interrupt status not sticky, a clear beating its own event, the interrupt not masked by its enable, an alias of IRQEN decoded for reads and one for writes, bit 11 ignored for the IP registers, the IP range one register too long, a 5-bit compare for the duty registers. **20 are caught**, most by a bound property, the cycle compare and a measured-waveform check independently. The 21st, the 5-bit duty compare, passes, and correctly: the shim never selects the IP at the addresses where it would differ. Two of the 20 (the two IRQEN aliases) are caught only by the alias sweep added after VER-2; the random test alone does not reach those addresses often enough. A comment-only change was run as a control and passes. | mutation run, 2026-10-05 |

### VER-5

*From `Docs/BUGS.md` at b90b481, line 402, section "1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)".*

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **VER-5** | GPIO UVM environment, negative control | DONE | n/a | **Does the GPIO environment catch bugs?** 18 defects planted one at a time in copies of the vendored block and the wrapper: rising and falling swapped, INTEN ignored, GPIOEN ignored, the set register acting as an assignment, the clear register not inverting, the shim synchroniser bypassed, the output enable taken from PADOUT, pin 1's type taken from the wrong bits, "either edge" firing on rising only, INTSTATUS replaced instead of accumulated, a read that does not clear, PADIN read one flop early, the decoded range halved, PADDIR resetting to 1, type 11 firing as rising, a second event dropped while the line is high, the input clock enabled per pin, and the edge detector skipping a flop. **All 18 are caught.** At least four of them (swapped edges, "either" as rising only, type 11 as rising, the skipped flop) are also reported by the checks that use only the pads, the registers and the pins (a settled pad is what PADIN reads; a qualifying edge raises the interrupt and nothing else does), which do not share the model's synchroniser; a run prints only its first 20 messages, so the count may be higher. A comment-only change was run as a control and passes. | mutation run, 2026-10-05 |

### VER-6

*From `Docs/BUGS.md` at b90b481, line 404, section "1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)".*

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **VER-6** | clock and reset UVM environment, negative control | DONE | n/a | **Does the clock and reset environment catch bugs?** 21 defects planted one at a time in copies of `clk_div.v`, `reset_ctrl.v` and `reset_ctrl_apb.v`: the stretch halved, the debugger's reset reaching the Debug Module, hartreset resetting the system, the cause priority swapped, the cause accumulated instead of replaced, the cause not clearable, the watchdog cause not recorded, the debugger's reset not stretched, DIVSEL reset by any reset, the lock clearable, BOOTFAIL on the wrong bit, the boot-select flag on the wrong bit, an extra offset decoded, the ratio switched at any moment instead of when all dividers are low, the wrong divider tap for ratio 4, DIVBUSY stuck low, pclk_phase inverted, pclk made from the wrong clock, the core's reset asserted synchronously, the preset synchroniser not chained to hreset, and one synchroniser flop on the reset pin instead of two. **19 are caught**, the clock ones by properties that measure time on the pins (a switch at the wrong moment shows as a short pulse on hclk and pclk). **Two are not, and neither is visible in an RTL simulation by nature:** the unchained preset synchroniser still releases after hreset because pclk is the slower clock, which is all the specification asks; and a one-flop synchroniser behaves like a two-flop one until a real flop goes metastable, which is what the static clock-domain check is for. The first version of the random test did not catch the un-clearable cause register; its clears were then widened from one bit to any mask. A comment-only change was run as a control and passes. | mutation run, 2026-10-05 |

### VER-2

*From `Docs/BUGS.md` at b90b481, line 406, section "1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)".*

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **VER-2** | timers UVM environment, negative control | DONE | n/a | **Does the timers environment catch bugs?** 23 defects planted one at a time in copies of `rtl/timers`: the compare made strict, the shadow latched on every cycle, the compare reset value, a kick accepted with one bit wrong, EN made clearable, the warning compare made strict, the request raised one count early, a reload taking effect without a kick, two strobes per write, two strobes per read, no error on the read-only register, an extra offset decoded, the low word read live, the 32-bit carry dropped, a kick at count 0 rescuing the system, read data made combinational, WARNEN locked after enable, the request not sticky, a write landing in the setup phase, an alias of the kick register decoded, an alias of MTIME_LO latching the shadow, address bit 11 ignored. **22 are caught**, most by the scoreboard and a bound property independently. The other one, read data allowed to change after the access has ended, passes, and correctly: nothing on the bus can see it. One of the 22 (the alias of the kick register) survived the first version of the environment, which had no aliasing stimulus; a directed alias sweep, alias bins in `cg_tmr_apb` and the property `a_unmapped_no_strobe` were added because of that. A comment-only change was run as a control and passes. | mutation run, 2026-10-04 |

### TOOL-4

*From `Docs/BUGS.md` at b90b481, line 832, section "TOOL-4 — Icarus silently ignores `$random`'s seed  ·  `FIXED` · **Severity: high (falsely reassuring)**".*

#### TOOL-4 — Icarus silently ignores `$random`'s seed  ·  `FIXED` · **Severity: high (falsely reassuring)**

Icarus Verilog 14 accepts `$random(seed)` and **ignores the seed**. A 10-seed
sweep produced byte-identical stimulus and reported 10 passes — *one run counted
ten times*. Verified with a 6-line standalone case (all seeds →
`48, -99, -39, -9`). Replaced everywhere with an explicit 32-bit xorshift PRNG,
which also reproduces identically on any simulator — which matters for replaying
a failing seed under VCS.

> **This is the most dangerous entry in this document.** It did not produce a
> wrong answer; it produced a **falsely reassuring** one.

### TB-11

*From `Docs/BUGS.md` at b90b481, line 844, section "TB-11 — the SoC/interconnect seed sweep was not varying the bus timing  ·  `FIXED` · **Severity: high (falsely reassuring)**".*

#### TB-11 — the SoC/interconnect seed sweep was not varying the bus timing  ·  `FIXED` · **Severity: high (falsely reassuring)**

**New this session — TOOL-4 wearing different clothes, and worth the emphasis
because it recurred in code written by someone who had just read the TOOL-4
writeup.**

- **Symptom:** a `+SEED` sweep over `tb_soc_ahb` reported identical numbers for
  every seed (`longest DMA request-to-grant wait = 12 hclk`, same cycle count).
- **Root cause:** `ahb_lite_sram` seeded its PRNG from a **parameter**, fixed at
  elaboration. The `+SEED` plusarg was parsed and then never reached the slave
  models, so every run of a single build drew the same wait states. The stimulus
  varied; the *bus timing*, which is what actually finds interconnect bugs, did
  not.
- **Fix:** `seed_i` is now a runtime **input**, sampled out of reset, XORed with
  a per-instance parameter salt so four slaves in one testbench do not stall on
  the same cycles. The generator advances on every accepted transfer.
- **Evidence it works:** SoC cycle counts now move with the seed
  (5721 / 5743 / 5745 / 5789 / 5740), and the fix immediately exposed **14
  previously-hidden failures** in the interconnect regression (all of which were
  an over-tight testbench bound, TB-12).

### TB-12

*From `Docs/BUGS.md` at b90b481, line 865, section "TB-12 — T12's DMA-grant bound was a statement about the slave, not the arbiter  ·  `FIXED` · **Severity: medium**".*

#### TB-12 — T12's DMA-grant bound was a statement about the slave, not the arbiter  ·  `FIXED` · **Severity: medium**

Once TB-11 was fixed, T12 began failing at `GWAIT=10`: "DMA granted after 14
cycles" against a hard-coded bound of 6. The DUT was correct — while HREADY is
low the bus is genuinely busy and the grant is *supposed* to be frozen. The
check was rewritten to count **arbitration boundaries** (accepted address
phases) rather than cycles, and asserts ≤2. That is wait-state independent and
says the thing that actually matters. It still catches `MUT-2`.

### TOOL-1

*From `Docs/BUGS.md` at b90b481, line 968, section "Toolchain environment issues — TOOL-1, 2, 3, 5".*

| ID | One-line |
|---|---|
| TOOL-1 | `choco install iverilog` needs Administrator. Portable `oss-cad-suite` into the session scratchpad instead; nothing installed system-wide. |

### TOOL-2

*From `Docs/BUGS.md` at b90b481, line 969, section "Toolchain environment issues — TOOL-1, 2, 3, 5".*

| ID | One-line |
|---|---|
| TOOL-2 | Verilator in the portable bundle has a baked-in absolute path — set `VERILATOR_ROOT`. Also: it needs `+incdir+path`, not `-I path`. |

### TOOL-3

*From `Docs/BUGS.md` at b90b481, line 970, section "Toolchain environment issues — TOOL-1, 2, 3, 5".*

| ID | One-line |
|---|---|
| TOOL-3 | `yosys.exe` needs `oss-cad-suite/lib` **before** `bin` on PATH, with unix-style paths. |

### TOOL-18

*From `Docs/BUGS.md` at b90b481, line 971, section "Toolchain environment issues — TOOL-1, 2, 3, 5".*

| ID | One-line |
|---|---|
| TOOL-5 | No Cadence/Synopsys/Vivado tools available. **The team flow is unexercised.** |

### TOOL-6

*From `Docs/BUGS.md` at b90b481, line 972, section "Toolchain environment issues — TOOL-1, 2, 3, 5".*

| ID | One-line |
|---|---|
| TOOL-6 | *(new)* No RISC-V toolchain on this machine, so the SoC test program is built with the stopgap `tools/gen/mini_rv32_asm.py`. The `.S` is plain GNU as syntax and builds either way; delete the generated `.hex` once `sw/Makefile` can run. |

### TOOL-5

*From `Docs/BUGS.md` at b90b481, line 1072, section "TOOL-5 — the static checker reported success having checked nothing  ·  `FIXED` · **Severity: high (falsely reassuring)**".*

#### TOOL-5 — the static checker reported success having checked nothing  ·  `FIXED` · **Severity: high (falsely reassuring)**

- **Where:** the ad-hoc elaboration checker used while no simulator was
  available (`scripts/`-adjacent, session tooling).
- **Symptom:** "0 errors, 0 warnings" on its first run, with no output at all —
  indistinguishable from "matched nothing".
- **Root cause:** the instantiation regex matched nothing on the first attempt,
  and a checker that checks nothing reports a clean run.
- **Fix:** it now counts the instantiations it cross-checked and **exits
  non-zero if that count is zero**, and it was validated against deliberately
  corrupted copies (a mistyped port, a missing module, an undefined macro)
  before any of its results were believed.
- **Lesson:** this is **TOOL-4 and TB-11 wearing a third set of clothes**. Any
  check that can pass by doing nothing must report how much it did. Three
  separate instances of this failure mode are now in this register; it is the
  single most recurrent defect class in the project.

---

### MUT-1

*From `Docs/BUGS.md` at b90b481, line 1099, section "6.1 Mutation testing — do the tests actually catch the bugs?".*

| ID | Mutation | Result |
|---|---|---|
| MUT-1 | AHB-1: HWDATA muxed on `grant` (as spec §3.1 says) | **8 failures**, all T14 |

### MUT-2

*From `Docs/BUGS.md` at b90b481, line 1100, section "6.1 Mutation testing — do the tests actually catch the bugs?".*

| ID | Mutation | Result |
|---|---|---|
| MUT-2 | AHB-2: `force_owner` reinstated (spec §7.2 literally) | **1 failure**, T12 — DMA starved |

### MUT-3

*From `Docs/BUGS.md` at b90b481, line 1101, section "6.1 Mutation testing — do the tests actually catch the bugs?".*

| ID | Mutation | Result |
|---|---|---|
| MUT-3 | AHB-2: response hold disabled | **39 failures**, T13 and the soak |

### MUT-4

*From `Docs/BUGS.md` at b90b481, line 1102, section "6.1 Mutation testing — do the tests actually catch the bugs?".*

| ID | Mutation | Result |
|---|---|---|
| MUT-4 | AHB-3: SEQ→NONSEQ rewrite removed | slave-side checker: **79** `SEQ following a SINGLE burst` |

### MUT-5

*From `Docs/BUGS.md` at b90b481, line 1103, section "6.1 Mutation testing — do the tests actually catch the bugs?".*

| ID | Mutation | Result |
|---|---|---|
| MUT-5 | Data-phase select bypassed (use address-phase HSEL) | **394 failures** across T1, T13, T16 |

### MUT-6

*From `Docs/BUGS.md` at b90b481, line 1104, section "6.1 Mutation testing — do the tests actually catch the bugs?".*

| ID | Mutation | Result |
|---|---|---|
| MUT-6 | DMA-3: arm latch removed (pre-fix behaviour) | **10 failures**, T18 and T19 |

### MUT-7

*From `Docs/BUGS.md` at b90b481, line 1105, section "6.1 Mutation testing — do the tests actually catch the bugs?".*

| ID | Mutation | Result |
|---|---|---|
| MUT-7 | DMA-3a: `en_h` qualifier removed from the deferred start | **1 failure**, T20a |

### MUT-8a

*From `Docs/BUGS.md` at b90b481, line 1106, section "6.1 Mutation testing — do the tests actually catch the bugs?".*

| ID | Mutation | Result |
|---|---|---|
| MUT-8a | DMA-3: WAITING abort-path clear removed | **PASSES — uncovered, and known to be redundant.** See DMA-3a. |

### MUT-8b

*From `Docs/BUGS.md` at b90b481, line 1107, section "6.1 Mutation testing — do the tests actually catch the bugs?".*

| ID | Mutation | Result |
|---|---|---|
| MUT-8b | DMA-3a: COMPLETE decline-path clear removed | **1 failure**, T20a |

### MUT-9

*From `Docs/BUGS.md` at b90b481, line 1108, section "6.1 Mutation testing — do the tests actually catch the bugs?".*

| ID | Mutation | Result |
|---|---|---|
| MUT-9 | DMA-3: CIRC absorb removed | **1 failure**, T20b |

### TOOL-21

Building tb_chip on Verilator 5.052 at b90b481 stops at rtl/pwm/pwm_sva.sv:44:106 `$past(duty_s[c])` inside the per-channel generate loop: "Illegal assignment of constant to unpacked array". Every chip-level Verilator run is BLOCKED by it (the audit at aae00a2 predates the file). Xcelium accepts it. Options for the owner (Karthik): sample duty_s[c] into a per-channel helper flop and compare against that, which every tool reads; or keep the file Xcelium-only and say so. Track A's debug/chip suite excludes the file, declared in the manifest and in every log header.

### TOOL-22

Every element bench prints FUNCTIONAL COVERAGE = 0.00 % under the runner. Measured: covergroups compile and sample (iff honoured); get_coverage() is 0.0 % even in a --coverage-user build, where coverage.dat holds per-bin counts equal to the bench's own counters (tb_clic_ctrl: 2257/1120/2224 etc.). Rule (H5): Verilator functional numbers come from coverage.dat via verilator_coverage; the printed percentage is never quoted. Tool limitation, not a design or bench defect; stays OPEN until the E9 coverage flow reads coverage.dat.

### TOOL-23

Verilator 5.052 aborts elaboration with "internal fault" (verilator_bin SIGSEGV, rc 139) on a covergroup declared inside a class whose coverpoints read a virtual-interface member (`covergroup cg; coverpoint vif.sig; endgroup` in a monitor class). Seen on all 13 dsu-verification sub-block benches; the same file without the covergroup builds. Workaround (tools/gen/port_dsu_benches.py): the covergroups and their new/sample/get_coverage are compiled out under `ifdef VERILATOR` through small macros; Xcelium compiles them unchanged. Nothing is lost on Verilator, whose get_coverage() reads 0 anyway (TOOL-22). Report upstream with a reduced case.

### TOOL-24

In rtl/dma/dma_sva.sv, `$past(eng_st == E_RA && f_r9_bad(sar[32*eng_ch +: 32]))` failed to build: '%Error: Selection index is constantly unknown or tristated: lsb=8'bxxx00000 width=32'. The same part-select outside $past builds and runs. Workaround in place: compute the indexed value as a wire outside the assertion (sar_bad_cur / dar_bad_cur) and take $past of the wire. Rule for H4: no variable part-select inside $past(). yosys-slang accepts both forms.

### TOOL-25

Verilator 5.052 `--coverage-expr`: in a `for` loop whose body is a `begin ... end` block, an `if` whose own body rewrites (blocking `=`) an operand of its condition never counts the condition's "=> 1" rows; the "=> 0" rows count normally. Seen on rtl/dma/dma_arbiter.v:29 (`if (eligible_i[n] && (!grant_valid_o || PRIO[3*n +: 3] > best))`, body sets grant_valid_o and best): 0 hits on both "=> 1" rows over all 64 eligible values, while line and branch coverage of the same if are 100 %. Removing only the `begin ... end` around the loop body gives 96 and 62 hits; keeping it but not rewriting the operands also counts. So the counters look evaluated after the body has run. Reproducer and output: logs/flow/evidence/TOOL-25_exprcov/ (run.sh). Handling: coverage waiver category `tool` (H5), Verilator only, never exported to the IMC exclusions; the report fails once the rows count (tool fixed, waiver removed). Report upstream with repro_fails.v.

### TOOL-26

`tools/run/garuda_fv.py` decided FAIL whenever the SBY log contained "returned FAIL". In prove mode with the smtbmc engine, SBY writes "returned FAIL for induction" when only the induction step fails, which is not a counterexample: the run ends `DONE (UNKNOWN, rc=4)` and the basecase had passed. The runner reported the core pipe_prove k-induction attempt as `FAIL props: a_no_gate_with_flush` (from the induction trace). Fixed: an induction-only failure is UNRESOLVED ("k-induction step failed; basecase passed"), and a FAIL needs a basecase / bmc / pdr failure. Earlier results are unaffected: every previous prove task used abc pdr, which has no induction step.

### TOOL-17

Karthik's entry (section 1k, efea71e): paths came out with backslashes so every vendored file read UNRECORDED, and hashes were of CRLF text. Fixed in 8123a52. (Track A had seen a different TOOL-17 claim on 2026-10-11 and did not log it.)

### FV-2

Karthik's entry (section 1k): not a defect, a result. With every input free, 8 of 9 assertions proved, all 13 matrix covers and 4 vacuity covers hit. Commit 34cff0e (AUD-8/FV-1).
