# Bugs: Clock divider + reset controller

Owner: Track B. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).
Priorities: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).

<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. Run `bugs.py check` before pushing. -->
| ID | Title | Status | Prio | Found-by | Found | Fixed-in | Regression test | Evidence | Formerly |
|---|---|---|---|---|---|---|---|---|---|
| CRG-2 | Rev 2.0 reset_ctrl drove an async clear from combinational logic | FIXED | P2 | RTL audit | 2026-09-19 | legacy | `tb_crg` 43/43 | HISTORY_2026.md L93 | - |
| CRG-3 | Three behaviours of the reset controller that the specification does not state, or states differently | RULING-NEEDED | P3 | 1` does not change the ratio, and a plain `RSTCTL = 1` does not clear it. In a b | 2026-10-04 | - | - | HISTORY_2026.md L403 | - |
| SIM-1 | RTL simulation and silicon disagree by one hclk cycle on every register that pclk captures from hclk | RULING-NEEDED | P3 | the timers scoreboard, first run | 2026-10-04 | - | - | HISTORY_2026.md L405 | - |
| CRG-1 | a one-cycle watchdog pulse asserts the whole-chip reset for 5 ns | FIXED | P2 | - | 2026-09-16 | legacy | - | HISTORY_2026.md L587 | - |
| TB-16 | the clock-alignment monitor raced the clock it was monitoring | FIXED | P2 | - | legacy | legacy | - | HISTORY_2026.md L976 | - |
| TB-17 | a reset check written as absolute-time modulo | FIXED | P3 | - | legacy | legacy | - | HISTORY_2026.md L992 | - |
| TB-18 | the watchdog test armed its wait after the event | FIXED | P1 | - | legacy | legacy | - | HISTORY_2026.md L1002 | - |
| TB-34 | clk_div_sva a_pclk_subset_hclk fired at time 0 under a two-state simulator | FIXED | P3 | Karthik (Verilator) | 2026-10-11 | 6aa73bb | clk_div_sva under Verilator (VERIFICATION_LOG) | Docs/VERIFICATION_LOG_2026-10-11.md | - |

## Details

### CRG-2

*From `Docs/BUGS.md` at b90b481, line 93, section "1b. Rev 4.0 migration — 2026-09-19".*

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| **CRG-2** | 22 reset | FIXED | medium (glitch on an async clear) | Rev 2.0 `reset_ctrl` drove an async clear from combinational logic. Rewritten: every async clear comes from a flop. | RTL audit | `tb_crg` 43/43 |

### CRG-3

*From `Docs/BUGS.md` at b90b481, line 403, section "1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)".*

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **CRG-3** | `rtl/reset_ctrl/reset_ctrl.v`, `rtl/reset_ctrl/reset_ctrl_apb.v`, GARUDA-CLKRST-SPEC-001 | **OPEN, needs an owner decision** | P3 | **Three behaviours of the reset controller that the specification does not state, or states differently.** Each is exercised by the directed test of the new environment, with the value the RTL gives written as the expectation. (1) **The cause register is rewritten in every cycle a request is up, so of two requests that overlap, the one that ends last is recorded.** Requests in the same cycle are taken watchdog, then software, then debugger (the specification is silent, plan F26); but the watchdog's request lasts two or three cycles and the debugger's `ndmreset` is a level that can last much longer. If the debugger asserts `ndmreset` within those cycles of a watchdog expiry, RSTREASON reads NDM and the firmware's watchdog-recovery path is not taken, although the watchdog fired first and caused the reset. Reproduced: a one-cycle watchdog request with a six-cycle debugger request gives 0x4. A rare coincidence under a debugger; capturing the first cause until the counter runs out would remove it. (2) **A RSTCTL write that sets SWRST never completes in the chip,** because the reset it causes reaches the bridge before the end of the access. Its BOOTFAIL bit is taken (it is seen during the access); its DIVSEL bits are not. So `RSTCTL = (ratio << 8) | 1` does not change the ratio, and a plain `RSTCTL = 1` does not clear it. In a bench whose APB master is not reset with the bus, the DIVSEL bits do land: `tb_crg` and the first version of the shared UVM driver both behaved that way, which is not the chip's behaviour. The driver now drops PSEL at once on reset, as the bridge does. (3) **[N-7.16] justifies releasing the divider's reset unsynchronised "because the divider is a single toggle flop".** It is now seven flops on four clocks. The argument still holds, for a longer reason that should be written down: every one of them, and every flop of the reset controller released by the same pin, either is a free-running divider (any state is a legal state) or has its reset value at its input for the first two cycles. Also written into the plan from the RTL: BOOTFAIL is set by RSTCTL bit 4; a write to CLKSTAT is ignored without an error (AUD-13); the stretch is 1024 cycles of the always-on clock, which is 2048 reference cycles. | writing the clock and reset environment |

### SIM-1

*From `Docs/BUGS.md` at b90b481, line 405, section "1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)".*

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **SIM-1** | `rtl/clk_div/clk_div.v` line 118 (the pclk divider), seen through `rtl/timers/timers_apb.v` | **OPEN, needs an owner decision** | P3 | **RTL simulation and silicon disagree by one hclk cycle on every register that pclk captures from hclk.** pclk is made by a toggle flop on hclk written with a non-blocking assignment, so in simulation the pclk edge arrives one step *after* every hclk flop has already taken its new value. A pclk flop therefore captures the value an hclk flop launched on that same edge. On silicon the two clock trees are balanced and the pclk flop captures the value from before the edge (the 4 ns path the header of `timers_apb.v` describes). **Measured:** the timers UVM bench first used the same divider style and the reference model, which follows the specification, disagreed with the RTL on every live `WDTVAL` read by exactly one count (8 of 8 mismatches); with both clocks made in one process the model and the RTL agree on 20,449 reads. **Does anything functional depend on it?** A copy of the tree with the divider flop made blocking was run through the 15 block benches, the 8 chip tests and the 12 sanity programs: everything passes except `tb_crg`'s own `a_pclk_phase` monitor (277 reports), which samples `pclk_phase` in a way that depends on the old ordering. So today the only visible effect is that the chip simulation reads `WDTVAL` one count lower than the chip will; the bridge's hclk-to-pclk handshake is a toggle with a stable payload and does not care. The risk is for later code: a one-hclk pulse sent from hclk logic to a pclk register would be caught in simulation and missed on silicon, or the reverse, and no RTL test could tell. The usual fix is a blocking assignment in the divider flop, with `pclk_phase_o` moved to its own non-blocking flop and the `tb_crg` monitor corrected; it needs one lint waiver. Not made: it is the clock generator and the choice is the owner's. Other hclk-to-pclk captures known from the block-alone lint runs: `dma_top.u_apb.prdata_q` and the bridge's request toggle. | the timers scoreboard, first run |

### CRG-1

*From `Docs/BUGS.md` at b90b481, line 587, section "CRG-1 — a one-cycle watchdog pulse asserts the whole-chip reset for 5 ns · `SPEC` / `FIXED IN RTL` · **Severity: medium**".*

#### CRG-1 — a one-cycle watchdog pulse asserts the whole-chip reset for 5 ns · `SPEC` / `FIXED IN RTL` · **Severity: medium**

- **Where:** CRG spec §7.1; RTL `rtl/reset_ctrl/reset_ctrl.v`.
- **The defect:** §7.1 combines the sources as a bare term — `rst_n_qual` low
  when `por_n_i` is low **or** `wdt_reset_i` is high. Taken literally with the
  one-cycle watchdog pulse Block 19 produces, the entire chip's reset asserts
  for exactly one hclk period (5 ns) and then releases.
- **Failure mode:** too narrow to rely on. Reset is distributed through a
  buffered tree across a 1.45 mm die; a 5 ns pulse can arrive degraded or, after
  tree insertion-delay skew, fail to overlap at every leaf. The result is a
  *partial* reset — some flops cleared, some not — which is indistinguishable
  from corrupted state and would be blamed on anything but the reset controller.
- **Fix:** the watchdog request is stretched to `WDT_STRETCH` (default 16) hclk
  cycles. POR is untouched and remains fully asynchronous with no minimum width,
  because it arrives from outside and is already wide. The stretch counter is
  reset by `por_n_i` **only**, never by its own output — a counter cleared by
  the reset it generates would truncate its own pulse.
- **Test:** `tb/clk_div/tb_crg.sv` T9 — drives a single-cycle `wdt_reset_i` and
  requires the reset to be held materially longer than one cycle, then requires
  the chip to leave reset rather than latch in it.
- **Spec action:** §7.1 should specify a minimum assertion width.

### TB-16

*From `Docs/BUGS.md` at b90b481, line 976, section "TB-16 — the clock-alignment monitor raced the clock it was monitoring  ·  `FIXED` · **Severity: medium (falsely alarming)**".*

#### TB-16 — the clock-alignment monitor raced the clock it was monitoring  ·  `FIXED` · **Severity: medium (falsely alarming)**

- **Where:** `tb/clk_div/tb_crg.sv`, edge-alignment monitor.
- **Symptom:** three failures against a divider that was behaving perfectly,
  all in fallback mode.
- **Root cause:** the check asked "was the last hclk rise at the same `$time` as
  this pclk rise?", comparing a timestamp written by one `always @(posedge)`
  block from inside another. Two always blocks woken by the same edge run in an
  arbitrary order, so the hclk block had often not written its timestamp yet.
  In **fallback that is guaranteed**, because hclk and pclk are then literally
  the same net and both blocks wake on the identical event.
- **Fix:** sample the hclk *level* 10 ps after the pclk edge instead. No
  ordering dependency: if the edges coincide, hclk is high, in both modes.
- **Lesson:** an event-ordering comparison between two always blocks is not a
  measurement, it is a race. Sample a level at a defined offset.

### TB-17

*From `Docs/BUGS.md` at b90b481, line 992, section "TB-17 — a reset check written as absolute-time modulo  ·  `FIXED` · **Severity: low**".*

#### TB-17 — a reset check written as absolute-time modulo  ·  `FIXED` · **Severity: low**

- **Where:** `tb/clk_div/tb_crg.sv` T8.
- **Root cause:** "hreset_n de-asserts on an hclk edge" was checked as
  `($time % hclk_period) == 0`. That assumes clock edges fall on exact multiples
  of absolute zero, so any earlier test that offsets time by a sub-period amount
  (T7 did, by 100 ps) breaks it for the rest of the run.
- **Fix:** check the property that actually matters — that release is *delayed*
  by the synchroniser depth, at least two hclk edges after the source released.

### TB-18

*From `Docs/BUGS.md` at b90b481, line 1002, section "TB-18 — the watchdog test armed its wait after the event  ·  `FIXED` · **Severity: high (test hung)**".*

#### TB-18 — the watchdog test armed its wait after the event  ·  `FIXED` · **Severity: high (test hung)**

- **Where:** `tb/clk_div/tb_crg.sv` T9. Symptom: the whole testbench **hung** and
  hit its 50 µs timeout.
- **Root cause:** `wdt_reset` was driven, and only *then* did the test
  `@(negedge hreset_n)`. But `hreset_n` drops combinationally the instant
  `wdt_reset_i` rises, so the edge had already happened; the wait then blocked
  forever on a second falling edge that never came.
- **Fix:** `fork` the wait so it is armed before the stimulus is driven.
- **Lesson:** for any signal that responds combinationally to stimulus, arm the
  wait first. "Drive, then wait" only works across a clock edge.

### TB-34

Karthik's entry (Docs/BUGS.md section 1k on main, efea71e): rtl/clk_div/clk_div_sva.sv a_pclk_subset_hclk fired at time 0 under a two-state simulator, which gives pclk_q its initial value as a change. Fixed in 6aa73bb. Not the Track A TB-34 (now TB-48, core).
