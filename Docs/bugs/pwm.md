# Bugs: PWM (rtl/pwm)

Owner: Track B. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).
Priorities: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).

<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. Run `bugs.py check` before pushing. -->
| ID | Title | Status | Prio | Found-by | Found | Fixed-in | Regression test | Evidence | Formerly |
|---|---|---|---|---|---|---|---|---|---|
| PWM-1 | HAL ULRELE: (cnt_q + 16'd1) >= period_i is evaluated in 16 bits and would wrap at cnt_q = 0xFFFF | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L309 | - |
| TB-28 | Two new checks were mis-sequenced: the PWM clamp-release check read a pulse width before one whole pulse at the new d... | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L339 | - |
| PWM-2 | The PWM pins are driven combinationally, so an output can glitch when two of its inputs change on the same edge; seve... | RULING-NEEDED | P2 | - | 2026-10-04 | - | - | HISTORY_2026.md L368 | - |
| PWM-3 | The read-mux loop variable k is inferred as a latch and then optimised away | FIXED | P3 | - | 2026-10-04 | c6843f2 | Karthik formal equivalence (VERIFICATION_LOG) | Docs/VERIFICATION_LOG_2026-10-11.md | - |
| PWM-4 | Lowering PRESCALE while running froze the outputs for up to 65,536 clock cycles | FIXED | P2 | PWM UVM environment, random test, first run | 2026-10-04 | legacy | - | HISTORY_2026.md L397 | - |

## Details

### PWM-1

*From `Docs/BUGS.md` at b90b481, line 309, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **PWM-1** | `rtl/pwm/garuda_pwm_core.v` | FIXED (hardening) | HAL `ULRELE`: `(cnt_q + 16'd1) >= period_i` is evaluated in 16 bits and would wrap at `cnt_q = 0xFFFF`. That value is unreachable today (the counter wraps at `period - 1`), so no behaviour changes; the compare is now 17 bits so it stays correct if the counter is ever preloaded. |

### TB-28

*From `Docs/BUGS.md` at b90b481, line 339, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **TB-28** | `tb/pwm/tb_pwm.sv`, `tb/uart/tb_uart.sv` | FIXED | Two new checks were mis-sequenced: the PWM clamp-release check read a pulse width before one whole pulse at the new duty had completed, and the UART line-status checks changed the divisor under a frame still being sent (UART-3). |

### PWM-2

*From `Docs/BUGS.md` at b90b481, line 368, section "1i. Independent audit on free tools — 2026-10-04/05".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **PWM-2** | `rtl/pwm/garuda_pwm_core.v` | OPEN (owner to rule) | **The PWM pins are driven combinationally, so an output can glitch when two of its inputs change on the same edge; severity depends on the minimum pulse width the ESC input can register.** `pwm_o[c] = en_i & ch_en_i[c] & (cnt_q < duty_s[c])` (`rtl/pwm/garuda_pwm_core.v:101`) has no output register. A CTRL write `0x0F0` to `0x051` turns EN on and channel 1 off on the same `pclk` edge; a 4-state event-driven run shows a zero-width pulse on channel 1 and `tb_pwm` reports 2 [FAIL] for [N-6.1] (`4 1 4 1`, `5 violations`), while simulators that settle both updates first pass (58/0). In silicon the two flops have different clock-to-Q, and the magnitude comparator can also glitch while `cnt_q` changes. GARUDA-PWM-SPEC-001 §1.1/§1.3: these pins drive ESCs, and the block is in-house so that no register combination can glitch an output. Proposed (not applied): register the compare and keep the enables as an AND on the output, which keeps the [N-7.5] immediate stop. Found by: Icarus run of `tb_pwm`. |

### PWM-3

*From `Docs/BUGS.md` at b90b481, line 369, section "1i. Independent audit on free tools — 2026-10-04/05".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **PWM-3** | `rtl/pwm/garuda_pwm_top.v` | OPEN (hardening) | **The read-mux loop variable `k` is inferred as a latch and then optimised away.** `integer k` (`rtl/pwm/garuda_pwm_top.v:65`) is assigned only inside the `default:` branch of the combinational read mux (`:114-122`), so Yosys `proc_dlatch` infers latches for `k` (three warnings in the whole-chip synthesis log); they have no fanout and are removed, and the final latch list holds only `core_clk_gate`. Harmless today; other tools may report it. A loop variable local to the block avoids it. Found by: Yosys whole-chip synthesis (`scripts/run_synth.sh`). |

**2026-10-14:** FIXED by Karthik in c6843f2.

### PWM-4

*From `Docs/BUGS.md` at b90b481, line 397, section "1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)".*

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **PWM-4** | `rtl/pwm/garuda_pwm_core.v` (prescaler compare) | **FIXED** | P2 | **Lowering PRESCALE while running froze the outputs for up to 65,536 clock cycles.** The tick was `prescaler == PRESCALE`. A PRESCALE written below the running count is never matched: the prescaler counts on to 0xFFFF and round, and until then there is no tick, the frame counter stands still and every pin stays as it was. A pin that was high stayed high for up to 0.52 ms at 125 MHz, on an output whose whole pulse is 1 to 2 ms. Reproduced on the unmodified RTL: PRESCALE 7, PERIOD 10, duty 6 on four channels, PRESCALE written to 2 with the pins high: all four still high 163 cycles later, where a frame is 80. PWM [N-7.1a] tells firmware to stop the block before changing PRESCALE, so this needs a firmware mistake; but a stretched pulse on a motor output is the one thing the block's design note says no register write can produce. The cycle-by-cycle model did not see it, because it was written with the same equality; the check that did is measured on the pins alone (`sb_no_stuck_high`: no pin with a duty below the period stays high for more than two frames). Fix: `>=`, the same hardening the period compare got in PWM-1; the tick in progress now ends in the next cycle. Added: property `a_tick_no_stall`, and the directed case that lowers PRESCALE at each count of the prescaler (`pwm_directed_test`, F17). After the fix: PWM UVM 22 of 22, `tb_pwm` 58 checks, 8 chip tests. | PWM UVM environment, random test, first run |
