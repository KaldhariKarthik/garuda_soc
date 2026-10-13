# GARUDA SoC: bug register, track A

Core, DSU, AHB interconnect, AHB2APB bridge, DMA, debug and memories. Kept by the owner
of track A. `Docs/BUGS.md` is the register up to 2026-10-05 and is history: it gets no new
entries. Track B's entries are in `Docs/bugs/track_b.md`.

## How entries are numbered

| Kind of entry | ID | Next free on 2026-10-11 |
|---|---|---|
| A block of this track | the block's own prefix, continuing the numbers of `Docs/BUGS.md` | T-16, C-17, CORE-4, DSU-14, AHB-6, BRG-2, APB-2, DMA-9, DBG-4, RDC-2; MEM-1 is new |
| Anything that is not one block (tools, benches, audits, lint, simulation, verification runs) | the old prefix with the track letter | TOOL-A1, TB-A1, ELEM-A1, AUD-A1, VER-A1, FV-A1 (TOOL-17, TB-34, TB-35 and FV-2 of section 1k were the last without a track letter) |

A block prefix belongs to the block's track, and a prefix that is not a block carries the
track letter, so the two tracks cannot take the same ID. An ID is never reused or
renumbered. `make check_tree` fails when an ID is defined twice.

Status words are those of `Docs/BUGS.md`: `OPEN`, `FIXED`, `WAIVED`, `SPEC`, `DONE`.
Priority: P1 wrong behaviour in the field, P2 wrong behaviour that needs an unusual
condition or a verification hole that could hide one, P3 everything else.
An entry marked FIXED names the test that fails without the fix.

## Carried over from `Docs/BUGS.md`

Entries of this track that were open when the register was split. The full text of each
is in `Docs/BUGS.md` under its ID; this table says what was decided and what was done.
Task numbers are those of the plan of 2026-10-10.

| ID | Subject | Ruling | Task | State | What was done |
|---|---|---|---|---|---|
| T-12 | A second trap inside an interrupt handler leaves the interrupt level wrong | Previous level in `mcause[23:16]`, pushed on every trap, popped by `mret` | 0.1 | OPEN | |
| T-13 | A bus error on the instruction before an MRET is dropped | The audit's test and fix | 0.2 | FIXED 2026-10-11 (`69c79ec`); confirmed on Xcelium 2026-10-12 | The audit's fix and test. Run by track B on 2026-10-11 under Verilator, because the test had not been built where it was written: `t_lead1_mret_buserr` ends in `TOHOST=3 -> FAILED` on the trap controller of `b90b481` and in `TOHOST=1 -> PASSED` on the fix, with no waits, `+DWAIT=2`, and `+DWAIT=5 +DRAND=1`. On the fix the 12 sanity programs and the 64 ISA tests pass, 58 of them matching Spike. `tb_trap_ctrl` 64 checks pass under Icarus and Verilator. On Xcelium, 2026-10-12: both tests pass and are now rows of `scripts/run_sanity.sh` and of the coverage session; `make regress_all` passes (64 ISA tests, 58 matching Spike), `make csr_map` unchanged. |
| T-14 | A bus error on the instruction before a WFI leaves the core asleep | The audit's test and fix | 0.2 | FIXED 2026-10-11 (`69c79ec`); confirmed on Xcelium 2026-10-12 | As T-13: `t_lead2_wfi_buserr` times out (15 instructions retired) on `b90b481` and passes on the fix, in the same three bus timings. |
| RDC-1 | A debugger halt resets the core under a bus that is not in reset | The core reset waits, bounded, for the core's bus transfers to end | 0.3 | OPEN | |
| C-16 | Four groups of CSRs trap where v1.12 says they exist | Read 0, ignore writes | 0.4 | OPEN | |
| AUD-13 (rule, DMA) | PSLVERR decided block by block | One rule in the bridge specification; DMA stops raising PSLVERR on a read-only write | 0.5 | OPEN | |
| TB-32 | `tb_garuda_pc_gen` relies on a time-zero reset edge | Fixed as the entry says | 0.6 | FIXED 2026-10-11 (`7769511`); confirmed on Xcelium 2026-10-12 | Verilator stops with an internal fault on the class-based element benches, on Linux as on Windows, so this needed Xcelium: `make test_elements` passes all fourteen on 2026-10-12, `garuda_pc_gen` included. |
| TB-33 | `tb_id_stage` can never generate a bubble | Fixed as the entry says | 0.6 | OPEN | |
| ELEM-8 | `tb_d_port_ahb_master` withdraws a waiting transfer | Fixed as the entry says | 0.6 | OPEN | |
| AUD-12 (1) | DMA reach: yaml and AHB specification against DMA R-9 and the RTL | Specification corrected to the RTL | 0.7 | OPEN | |
| AUD-12 (2) | Clock gates in DMA and DSU that do not exist | Specification corrected to the RTL | 0.7 | OPEN | |
| AUD-12 (3) | Branch prediction: specification says none, RTL has a static predictor | Specification corrected to the RTL | 0.7 | OPEN | |
| AUD-12 (5) | Specifications name `spec/regs/<block>.yaml`, which does not exist | Specification corrected; final form in task 2.5 | 0.7 | OPEN | |
| AUD-12 (6) | Window numbers in AHB2APB and MEM | Specification corrected to the RTL | 0.7 | OPEN | |
| AUD-12 (7) | DMA CR reset value and SIZE 3 | Specification corrected to the RTL | 0.7 | OPEN | |
| INT-2 (DMA table) | DMA ID table still says 7..12 | Table corrected | 0.15 | OPEN | |
| APB-1 | The bridge's 16-pclk timeout abandons an access | To be dispositioned | 0.15 | OPEN | |
| AUD-8 | Hold against flush: matrix measured, formal not run | JasperGold | 5.7 | DONE 2026-10-14 (formal run by track B; for track A to read and sign) | Run by track B in JasperGold 2022.09p002 on 2026-10-14, on the whole core, script `flow/formal/core/pipe_ctrl_core.tcl`, result `flow/formal/core/pipe_ctrl_core.result.txt`. All nine assertions of `pipe_ctrl_sva` are proven, with the bus inputs completely free and with AHB-legal slaves, with the DSU stub and with the real DSU; that includes `a_no_gate_with_flush`, which is a property of the core and could not be shown on `pipe_ctrl` alone, and `a_h2_defers_flush_loaduse` with no assumption. With the real DSU and AHB-legal slaves all thirteen cells are reachable, the four hold-against-flush cells among them (`c_h1_vs_redirect`, `c_h2_vs_redirect`, `c_h4_vs_redirect`, `c_h5_vs_trap`): none is dead by construction, so the arbitration for those cases is live logic and `t_hold_flush_matrix` is the right test to keep. With the DSU stub the three H4 cells are unreachable, as they must be (the stub is never busy). |
| AUD-9 | DSU port names diverge from the specification | To be dispositioned | 0.15 | OPEN | |
| AUD-11 (track A rows) | Planned tests and assertions of the specifications not all written; DEBUG R-8 against D-18 | Closed block by block as each reaches the bar | 0.15, WP5, 6A | OPEN | |
| CORE-2 | Unused parameter in `garuda_core_top` and `csr_file` | To be dispositioned | 0.15 | OPEN | |
| ELEM-7 | `Docs/CORE_ELEMENT_VERIFICATION.md` cites covergroups that do not exist | To be dispositioned | 0.15 | OPEN | |
| FV-1 | IFV run not possible (no licence) | Superseded by JasperGold, run on K's machine | 5.7 | DONE 2026-10-14 in JasperGold (the IFV run stays impossible: no licence) | See AUD-8 above: the run that entry waited for, in JasperGold in place of IFV. `flow/2_static/fv_pipe_ctrl/prove.tcl` and `files.f` are the IFV setup and are superseded by `flow/formal/core/`. |
| TOOL-12 | Lockstep does not read Spike's exit status | Exit status read | 1.1 | FIXED 2026-10-11 (`c22c00e`) | `tools/lockstep.py` reads Spike's exit status. Used in the 64-test run above: 58 MATCH. |

## New entries

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **TB-A1** | `tb/soc/tb_chip.sv` in `MODE=jtag`, `rtl/debug` | OPEN, to be looked at | P3 | **`chip_jtag` times out under Verilator.** `SIM=verilator ./scripts/run_sim.sh tb_chip +MODE=jtag +TEST=sw/build/t_chip_jtag.hex +MAXUS=1500` ends in `[FAIL] TIMEOUT after 1500 us: tohost never written (385 retired, pc in EX = 0x00000000)`. The other seven chip programs pass under Verilator on the same build, and all eight passed on Xcelium on 2026-10-11 before track A's commits. Not yet known whether it is the bench (the JTAG driver and the two unrelated clocks under a two-state simulator) or the debug logic; On Xcelium after those commits (2026-10-12) `chip_jtag` passes, also with X-propagation, so the difference is between the simulators: the bench or a race it has under a two-state simulator is the first suspect. Written here by track B, which found it; the entry is track A's from here. | first Verilator run of the chip programs on Linux |
