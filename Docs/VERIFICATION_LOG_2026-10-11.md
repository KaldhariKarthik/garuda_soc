# GARUDA — fixes on free tools, 2026-10-11

**What this is.** A record of the open items closed on 2026-10-11 with free tools on one Windows laptop
(no Cadence licence), what was run to check each one, and what could **not** be run. Every RTL and
testbench change listed here still needs the xrun regression at the lab before it counts as closed.
Read with `Docs/BUGS.md` §1k.

**What it is not.** Signoff. Nothing here replaces Xcelium, Incisive coverage or Genus.

---

## The machine, and what Windows would not let run

Windows 11 with **Smart App Control on**. It blocks unsigned binaries it has no reputation for, and
it blocked a large part of the toolchain. Some binaries were blocked on every attempt; others were
blocked on their first launch and allowed later.

| Blocked | Effect |
|---|---|
| `vvp.exe`, `ivl.exe` (both oss-cad-suite builds) | **Icarus cannot run at all.** The block regression used Verilator instead (`SIM=verilator`, below). |
| `yosys.exe` (2026-10-11 build), `bitwuzla.exe`, oss-cad-suite's bundled Python | Yosys taken from the 2026-08 build; SymbiYosys run with the system Python. |
| `riscv-none-elf-objcopy.exe` and part of `riscv-none-elf-gcc` | **No firmware could be built.** The two new core-level tests are written but not run. |
| Some Verilator-built simulation binaries (event 3118, "Smart App Control Block") | Those benches report NO-VERDICT, which counts as a failure. They were not run here. |

None of this was worked around. Inside WSL, Linux binaries are not subject to Smart App Control, so
everything below marked "not run here" can be re-run there.

## Tool versions

| Tool | Version | Source |
|---|---|---|
| Verilator | 5.053 devel rev v5.052-362-ge9f8cb2d9 | oss-cad-suite 2026-10-11 |
| Yosys | 0.69+185 (git sha1 fb1a2fdae) | oss-cad-suite 2026-08, with the 2026-10-11 `lib/` for readline |
| SymbiYosys + z3 | oss-cad-suite 2026-10-11 | run with Python 3.14 and `click` |
| g++ / make | GCC 16.2.0 / GNU Make 4.4.1 | w64devkit 2.10.0 |
| riscv-none-elf-gcc | 15.2.0 | xPack 15.2.0-1 (partly blocked, see above) |

All of these lived in the session's temp folder and are not part of the repository.

---

## 1. T-13 and T-14: fail before the fix, pass after

`tb/core/tb_trap_ctrl.v` drives `trap_ctrl` directly, with `mem_stall_i` now under its control.
`SIM=verilator ./scripts/run_sim.sh tb_trap_ctrl`:

| RTL | Checks | Result |
|---|---|---|
| HEAD, with the 7 T-14 checks | 47 | **4 FAIL**: latch armed under H2, handler held |
| T-14 fix, same checks | 47 | PASS |
| T-14 fix only, plus the 17 T-13 checks | 64 | **6 FAIL**: no trap, MRET popped, target mepc, MRET not squashed (load and store) |
| Both fixes | 64 | PASS |

The core-level tests `sw/tests/t_lead1_mret_buserr.S` and `t_lead2_wfi_buserr.S` are in `ATESTS`.
**They were not built or run here** (toolchain blocked). Run them with
`+ERR_EN=1 +ERR_BASE=10020000 +ERR_SIZE=1000`, with and without `+DWAIT`.

## 2. Formal (SymbiYosys)

`sby -f flow/2_static/fv_pipe_ctrl/sby/pipe_ctrl.sby`, every task PASS:

- **prove:** 8 of 9 `pipe_ctrl_sva` assertions hold for every input combination. The one assumption,
  A1, is discharged by G1 and G2.
- **cover:** all 13 hold-by-register matrix cells are reachable, and so are the 4 new vacuity covers
  (one per implication's trigger).
- **g1_prove / g1_cover:** `d_port_ahb_master` never raises `err_pulse` under `mem_stall`. It is not
  vacuous: both an error and a stall are reachable.
- **g2_prove / g2_cover:** `trap_ctrl` squashes ID/EX under H2 only for a MEM-point exception. It is
  not vacuous.
- **`a_no_gate_with_flush`** is not a `pipe_ctrl` property. All five of its disjuncts fail with free
  inputs, so it needs a whole-core run.
- **Mutation check:** four planted defects were each caught by the expected assertion:
  - H2 no longer defers redirects
  - flush-beats-hold removed
  - T-9's `~h2` on EX traps removed
  - HREADY dropped from `err_pulse`

**UART-3**, BMC to depth 24 of "a count at or past the divisor restarts at 0": fails on the vendored
`uart_tx` with a counterexample, passes on the patched one.

**PWM-3:** Yosys `equiv_make` / `equiv_simple` / `equiv_induct` proves the new `garuda_pwm_top`
equivalent to the old one. `proc_dlatch` infers latches for the old `k` and none for the new
module.

## 3. Block regression, `SIM=verilator ./scripts/run_sim.sh all`

The same run was made on HEAD (`b90b481`) in a separate worktree, with only the runner and TB-34
applied, and on the final tree.

| Group | Benches | Result |
|---|---|---|
| Passed, same on both | tb_chk_self 6, tb_apbchk_self 35, tb_crg 43, tb_ahb_ic 802, tb_bridge 22, tb_mem 18, tb_dma 63, tb_clic 17, tb_debug 93, tb_apb_shim 25, tb_spis 73 | identical results |
| Verilator cannot build (same on both) | tb_i2c, tb_gpio (`pullup` / `pulldown` strength unsupported); tb_pwm (internal error in `pwm_sva.sv`) | not run here |
| Blocked by Smart App Control | varies between runs: tb_timers, tb_spim, tb_uart, tb_dsu, tb_trap_ctrl | not run in the full run; tb_trap_ctrl ran on its own (§1) |

Before TB-34, tb_crg, tb_bridge and tb_timers stopped at time 0 on `a_pclk_subset_hclk`.

## 4. Whole chip

**`make local_lint`.** HEAD and the final tree give the same 17 warnings. Both hit the same two
`%Error`s, an internal error in this Verilator development build on `rtl/pwm/pwm_sva.sv:48`. The
2026-10-03 run on 5.052 had none. **No warning or error was added.**

**`./scripts/run_synth.sh garuda_chip_top`.** One latch on both, the expected one in
`core_clk_gate`. Two warnings that HEAD prints are gone from the final tree:
- PWM-3: three `proc_dlatch` warnings for `garuda_pwm_top.k`
- UART-4: one "Async reset value ... is not constant" warning

## 5. Tooling: negative tests

| Item | How it was tested | Result |
|---|---|---|
| TOOL-12 | Stand-in Spike that dies after 8 of 10 instructions | MISMATCH, exit 1. HEAD: MATCH, exit 0 |
| TOOL-13 | Stand-in xrun, 14 log and exit-code cases through every macro | Every failing case fails. HEAD Makefile: exit 0 on all four failing cases tried |
| TOOL-14 | Stand-in irun/IMC with good, assertion-failed and died runs | Only good merged, exit 1. HEAD: all three PASS, merged, exit 0 |
| TOOL-15 | `--defines` on three filelists | `-DGARUDA_REAL_RTL`, `-DGARUDA_COV`, none |
| TOOL-17 | `vendor_sync --check` on Windows, then with a vendored file edited | Passes clean, MODIFIED and PATCH DRIFT when edited |

## 6. Not run here: re-run in WSL or at the lab

- **Core-level tests:** `t_lead1_mret_buserr` and `t_lead2_wfi_buserr` (T-13, T-14).
- **Block benches:** tb_uart (UART-3, UART-4), tb_dsu_top with and without its `.mem` files (TB-35),
  test_pc_gen (TB-32) and test_chip (TB-30), and tb_timers and tb_spim.
- **Regression:** the full xrun regression on the final tree, for every RTL change above.
- **Testbench fixes not made:** TB-33 and ELEM-8 still need fixing. Both need changes that could not
  be run here (this Verilator build segfaults on the class-based element benches, HEAD included).
