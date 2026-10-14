# Bugs: Timers + watchdog (rtl/timers)

Owner: Track B. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).
Priorities: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).

<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. Run `bugs.py check` before pushing. -->
| ID | Title | Status | Prio | Found-by | Found | Fixed-in | Regression test | Evidence | Formerly |
|---|---|---|---|---|---|---|---|---|---|
| TB-38 | timers_sva a_mtimecmp_reset relies on a time-zero reset edge that 2-state simulation never produces | OPEN | P3 | Track A W4 chip check (Verilator) | 2026-10-11 | - | debug/chip_diag (known line) | logs/debug/raw/chip_diag/ | - |

## Details

### TB-38

`rtl/timers/timers_sva.sv:64` checks `!hreset_n_i |-> cmp_q == all-ones && !mtip_o` at every clock edge during reset. In the chip, hreset_n comes from reset_ctrl and is 0 from time zero; in 2-state Verilator it never has a falling edge, so the timer's asynchronous reset never runs and cmp_q is 0 when the assertion samples it (fires once at 51 ns in every tb_chip run). In 4-state Xcelium the X->0 transition is a falling edge and the reset runs. Same family as TB-30/TB-32. Owner Karthik: either sample the property only after the first reset release, or make the bench give the internal resets a real edge. Until then it is a declared known line in Track A's chip_diag suite.
