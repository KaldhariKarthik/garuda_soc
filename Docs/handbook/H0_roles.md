# H0. Roles, ownership, authorities, gates

## Tracks and ownership
| Track | Person | Owns (edits) | Signs |
|---|---|---|---|
| A | Sreyesh (verification) | `rtl/core`, `rtl/dsu`, `rtl/ahb`, `rtl/ahb2apb`, `rtl/dma`, `rtl/debug`, `rtl/mem`, `tb/uvm/ahb`, `tools/lockstep.py`, `tools/cosim`, `tools/csr_map.py`, `tools/run`, `tools/bugs`, `tb/core/*`, `tb/dsu/*`, `sw/riscv-tests`, `sw/tests`, `tb/soc/tb_boot*`, `flow/mk/track_a.mk` | Track A evidence |
| B | Karthik (team lead) | `Makefile`, `flow/` (except reviews A signs and `flow/mk/track_a.mk`), `scripts/`, `rtl/common`, `rtl/soc`, `rtl/clk_div`, `rtl/reset_ctrl`, `rtl/timers`, `rtl/clic`, `rtl/pwm`, `rtl/gpio`, `rtl/uart`, `rtl/i2c`, `rtl/spi_*`, `rtl/dft`, `rtl/tech`, `fpga/`, `sw/hal`, `sw/chip` | milestones |

A change in the other track's files is asked for, except an obvious one-line fix,
which is noted in the status sheet. Shared infrastructure (log convention,
`tools/bugs`, handbook) is drafted by A and reviewed by both.

## Authorities, in this order
1. **Architectural**: RISC-V unprivileged and privileged specifications; CLIC as adopted.
2. **Approved GARUDA contracts**: the specifications, `Docs/DECISIONS.md`, approved design notes.
3. **Implementation details.**

A disagreement between the RTL and a model is never resolved by changing the
model to match the RTL. An architectural deviation needs a written ruling in
`Docs/DECISIONS.md`. Only implementation-detail text may be corrected to follow the RTL.

## Design notes (plan before code)
Every major item (an RTL fix in the core, a verification environment, co-simulation,
a formal harness) starts with a design note of at most two pages: problem, options,
decision, contract, how it is verified, rulings needed. No code before the note is
approved by the track owner; rulings are Karthik's. Small items (a script bug, a
one-line bench fix, an already-validated patch) go ahead after saying what will be done.

## Independence
- Reference models are written from the authorities, never from the RTL.
- The reviewer of a block is not its author; the review record (`flow/reviews/<blk>.md`) is written by the reviewer.
- Every checker has a negative control shown to fail (H2, "Qualifying the runner").

## Gates (evidence, not dates)
| Gate | Passed when |
|---|---|
| 0 Ownership | Both agree the ownership table, shared files and rulings list |
| A Baseline reproducible | Baseline SHA recorded; every existing check classified; runner, oracle and bug check qualified; portability probe and throughput measured |
| B Core fixes verified | Each WP0 core fix: failing-before, passing-after, regression unchanged, properties PROVEN, xfail removed, bug FIXED with SHA and test |
| C Environment trusted | RVFI lockstep equals commit-log lockstep; co-simulation negative controls all caught; reference models qualified; Xcelium cross-run passes |
| D Core + DSU mature | Coverage (four categories) reviewed; formal table has no UNRESOLVED critical property; mutation survivors analysed |
| E Release candidate | Every sign-off row regenerated from a clean clone at one SHA; Xcelium/IMC cross-check; 500 seeds, none failing in the last 2 weeks; review record |

## Simulator authority
Verilator 5.052 is the working simulator. **Xcelium is the authoritative commercial
check** at every gate. Checks that need 4-state behaviour (X-propagation, reset-X,
`$isunknown`) or Cadence coverage are **XCELIUM-ONLY** and are never reported as
passed from a Verilator run.

## Commits
Track A: Claude edits in `~/garuda_track_a` on a branch per item (`a/<id>-<slug>`);
Sreyesh reviews, commits and pushes. Commit messages carry no tool attribution lines.
Nothing is backdated. No PDK, library or licence file is committed.
