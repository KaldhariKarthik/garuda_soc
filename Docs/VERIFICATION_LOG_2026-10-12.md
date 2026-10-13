# GARUDA — B1.7 reruns on Linux (WSL 2), 2026-10-12

**What this is.** The record of Phase B1.7: the Phase A checks that Windows blocked
(`Docs/VERIFICATION_LOG_2026-10-11.md` §6), rerun on the Linux toolchain in `flow/pd/TOOLS.md`.
The rerun was limited to tools already installed. Icarus, Verilator, a RISC-V GCC, Spike and every
SMT solver were deferred by decision and are not installed, so most of the list is still blocked.

**What it is not.** Signoff. Nothing here replaces the lab xrun regression, Incisive coverage or
Genus.

Repo `main` at `e43672f` (clean before the run). RTL, scripts and file modes unchanged.

---

## Tools used

| Tool | Version (command output) |
|---|---|
| Yosys | `Yosys 0.68 (git sha1 38e001a6f, Release, GNU /usr/bin/c++ 11.4.0)` (YosysHQ release, built by ORFS `-common`, `~/tools/OpenROAD-flow-scripts/dependencies/bin`) |
| SymbiYosys | `SBY v0.69` (tag v0.68 = v0.69, commit `b1a1e98c`), same directory |
| Python | 3.10.12 |

## Results

| # | Command (from the repo root) | Result |
|---|---|---|
| 1 | `PATH=$HOME/tools/OpenROAD-flow-scripts/dependencies/bin:$PATH bash scripts/run_synth.sh garuda_chip_top` | **PASS**, exit 0, 6.9 s. 115 source files. `check -assert`: "Found and reported 0 problems". 72,809 generic cells, 7,032 flops, **1 latch, 0 unexpected** (the `core_clk_gate` ICG, allowed by name) |
| 2 | `python3 tools/vendor_sync.py --check` | **PASS**, exit 0: "16 files across 5 IPs match HASHES.txt", "3 file(s) carry a recorded GARUDA patch, and match it". TOOL-17's fix holds on Linux too |
| 3 | `python3 tools/garuda_gen.py --check` | **PASS**, exit 0: generated `garuda_map.vh` / `garuda_map.h` not stale |
| 4 | `PATH=…/dependencies/bin:$PATH sby -f flow/2_static/fv_pipe_ctrl/sby/pipe_ctrl.sby` | **BLOCKED**, exit 16. Every task: `SMT Solver 'z3' not found in path`, ERROR rc=16. Its "unreached cover statements" are a side effect of the solver never running, not a result |

**Synthesis notes (item 1).**
- The final tree's warnings match the 2026-10-11 Windows run: no PWM-3 `garuda_pwm_top.k`
  latch, and no UART-4 "Async reset value … is not constant" warning.
- Remaining warnings: memory-to-register conversions (prefetch buffer, CLIC, FIFOs, PWM, SPI
  slave), legacy `full_case`/`parallel_case` hot comments, limited tri-state support at
  `garuda_chip_top.v:256`, and the expected `core_clk_gate` latch.
- **Not comparable** to the Genus figure in `Docs/HANDOFF.md` (67,460 cells, 7,909 flops): different
  tool, generic cells versus a mapped library, older RTL.
- **Script observation, unchanged:** `run_synth.sh` prints an empty "design hierarchy" block and no
  cell summary under Yosys 0.68, because its `sed`/`grep` patterns don't match this Yosys's
  `stat` layout. The figures above come from `sim/synth/garuda_chip_top/yosys.log`. The latch gate
  reads `latches.txt`, not the log, so it is unaffected.

**SymbiYosys side effect (item 4).** `sby` wrote six `pipe_ctrl_<task>/` folders (git-ignored) and
an extra `flow/2_static/fv_pipe_ctrl/sby/pipe_ctrl/status.sqlite`. `.gitignore` covers
`pipe_ctrl_*/` but not `pipe_ctrl/`, so that folder shows as untracked. It was left in place.

## Stage 1 of tool enablement: z3, then the pipe_ctrl proof (FV-2)

Installed with approval, as root:
`wsl -d Ubuntu-22.04 -u root -- apt-get install -y --no-install-recommends z3`. That added 1 new
package and changed nothing else (0 upgraded, 0 removed). `z3 --version` gives `Z3 version 4.8.12 - 64 bit`;
`dpkg-query -W z3` gives `z3	4.8.12-1`.

`PATH=$HOME/tools/OpenROAD-flow-scripts/dependencies/bin:$PATH sby -f flow/2_static/fv_pipe_ctrl/sby/pipe_ctrl.sby`
(log `~/tools/logs/b17_sby_z3.log`): **sby exit 0, 6 of 6 tasks PASS**, 0 failed, 0 errors, 0
inconclusive, 0 warnings, about 1 s wall time.

| Task | Result |
|---|---|
| prove | PASS: basecase and induction pass, "successful proof by k-induction". All 8 active assertions of `pipe_ctrl_fv.sv` hold under A1. The 9th, `a_no_gate_with_flush`, is compiled out (`ifdef PIPE_CTRL_FV_CONTEXT`) as a whole-core property, matching the 2026-10-11 "8 of 9" |
| cover | PASS: 17 of 17 covers reached, 0 unreached: the 13 hold-by-register matrix cells (`c_h1_*`, `c_h2_*`, `c_h4_*`, `c_h5_*`) and 4 vacuity covers (`v_no_gate`, `v_trap_beats_branch`, `v_h2_defers_flush`, `v_h2_defers_flush_loaduse`) |
| g1_prove | PASS by k-induction (G1: `d_port_ahb_master` raises no `err_pulse` under `mem_stall`) |
| g1_cover | PASS: `g1_err_reachable` (step 3) and `g1_h2_reachable` (step 1) reached, so G1 is not vacuous |
| g2_prove | PASS by k-induction (G2: `trap_ctrl` squashes ID/EX under H2 only for a MEM-point exception) |
| g2_cover | PASS: `g2_squash_under_h2_reachable` reached (step 1) |

This reproduces the 2026-10-11 Windows result (oss-cad-suite z3) on Linux with apt's z3 4.8.12. It
was not rerun here: the four planted-mutation checks, UART-3 BMC and PWM-3 equivalence. Those need
edited copies of the RTL, which is not in scope.

## Still blocked, and on what

| Item (VERIFICATION_LOG_2026-10-11 §6 / runbook B1.7) | Needs |
|---|---|
| `bash scripts/run_sim.sh all` (Icarus) | Icarus Verilog (proposed `v12_0`) |
| `SIM=verilator bash scripts/run_sim.sh all`; `tb_uart` (UART-3/4), `tb_dsu_top` with and without `.mem` (TB-35), `tb_timers`, `tb_spim`; `test_pc_gen` (TB-32), `test_chip` (TB-30) | Verilator (proposed `v5.052`) |
| `make local_lint` | Verilator |
| `make sw`, then `t_lead1_mret_buserr` / `t_lead2_wfi_buserr` through `tb_boot` (T-13, T-14), pre-fix and HEAD, ±`+DWAIT` | RISC-V GCC (xPack candidate, not yet checked) + a simulator; the `tb_boot` command from `tb/soc/filelist_boot.f` has to be written and recorded |
| ISA builds / Spike lockstep | Spike + riscv-tests (proposed pins) |
| TB-33, ELEM-8 | Testbench changes (need approval), then a simulator |
| Full xrun regression | Lab (Cadence licence) |

The 2026-10-03 "1,219 checks / 14 testbenches" figure is still from an older commit and has not been
reproduced here.
