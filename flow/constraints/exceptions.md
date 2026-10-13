# Timing exceptions of `garuda_rtl.sdc`, each with its reason

Plan task 3.2. Every line of `flow/constraints/garuda_rtl.sdc` that takes a path out of
ordinary single-cycle analysis is listed here under the number the file gives it. A new
exception is added here first, with the reason and the check that makes it safe; an
exception without an entry here is a defect of the constraints.

Written 2026-10-14 against the RTL. There is no multicycle path and no false path
between two flops in the file.

## Exceptions

| # | Command | What it removes from analysis | Why that is right | What makes it safe |
|---|---|---|---|---|
| E1 | `set_case_analysis` on `u_clk_div/sel_act_q_reg[1:0]` | the three inputs of the hclk multiplexer that are not selected | The ratio is a mode. `sel_act_q` changes only on the falling edge of t1 that enters the interval in which all four candidates are low (CLKRST [N-7.5]), so no edge of one ratio launches a path captured by an edge of another | Properties `a_div_no_glitch` and `a_pclk_no_glitch` (`rtl/clk_div/clk_div_sva.sv`) and the ratio-change tests of the clock and reset environment (`tb/clk_div/uvm`); the four modes are each loaded by `scripts/run_sdc_check.sh 2`, `4`, `8`, `16` |
| E2 | `set_clock_groups -asynchronous`, group `tck` | every path between the debug transport (137 flops on `tck`) and the system clocks | `tck` comes from the debugger and has no relation to `refclk` | The debug request and response cross in one module, `dmi_cdc.v`, by a two-flop request and acknowledge handshake in each direction (DEBUG specification section 7, [N-7.17]); HAL's clock-domain check (`make static_cdc`) lists each crossing; the handshake proof is plan task 3.4 |
| E3 | `set_clock_groups -asynchronous`, group `io_async` (a clock that exists only in the file) | paths from and to the pins listed below | These pins have no clock in common with the chip. They are given delays against `io_async` so that no port is left unconstrained, and `io_async` is declared unrelated | per pin, below |

Pins of E3:

| Pin | Direction | Why it has no timing relation | What makes it safe |
|---|---|---|---|
| `ext_rst_n` | in | asynchronous reset from the board | asserted asynchronously, released through one two-flop synchroniser per domain (CLKRST [N-7.14], [N-7.15]); recovery and removal at the flops are still checked from the synchroniser outputs |
| `boot_sel` | in | a strap, static from before reset is released | sampled once after reset |
| `uart0_rx`, `uart1_rx`, `uart2_rx` | in | asynchronous serial line | two-flop synchroniser in the shim (`SYNC_W`); each bit is then sampled once, at its centre, by a per-bit counter (UART [N-7.1], [N-8.1]) |
| `i2c_scl`, `i2c_sda` | in, out | open-drain bus, at most 400 kHz against a pclk of 62.5 MHz or more | two-flop synchroniser on the inputs; the outputs are flop outputs that only pull low |
| `gpio0`, `gpio1` | in, out | general-purpose pins | two-flop synchroniser on the inputs; outputs are flop outputs |
| `spis_sclk`, `spis_mosi`, `spis_cs_n` | in | the external master's clock and data; the SPI slave synchronises and oversamples all three in pclk and does not use `spis_sclk` as a clock (SPIS section 7.1) | two-flop synchronisers; the master's SCLK is limited to pclk / 6 by the specification (SPIS [N-7.1a]) |
| `spis_miso` | out | read by the external master on its own clock | changes only after a synchronised SCLK edge, half an SCLK period before it is sampled |
| `uart0_tx`, `uart1_tx`, `uart2_tx` | out | asynchronous serial line | flop outputs; a bit lasts divisor + 1 pclk cycles |
| `pwm0` to `pwm3` | out | no receiver clock | flop outputs since PWM-2 (2026-10-13), so no glitch |

## Findings of `check_timing_intent` that are the design

`scripts/run_sdc_check.sh` accepts these two by name and fails on any other finding.

| # | Finding | Where | Answer |
|---|---|---|---|
| A1 | Sequential data pins driven by a clock signal | `u_clk_div/t2_q_reg/d`, `t3_q_reg/d`, `t4_q_reg/d`, `pclk_q_reg/d`, `sel_act_q_reg[0]/sena`, `sel_act_q_reg[1]/sena` | This is what a ripple divider is: each toggle flop's data is the inverse of its own output, and that output is the next stage's clock. The select flops are enabled by "t2, t3 and t4 all low". The paths are timed as ordinary paths of the clock that launches them. The 500 MHz net reaches one flop only (CLKRST [N-7.19]) |
| A2 | Timing exceptions with no effect: path group `clk_t2`, `clk_t3` or `clk_t4` | the path groups of divider stages | In a mode where a stage is not hclk it clocks at most the next stage, or nothing, so its path group can be empty. At DIV16 none is empty |

## Budgets

| Pins | Against | Outside the chip | Source of the number |
|---|---|---|---|
| `tms`, `tdi` in, `tdo` out | `tck`, 50 ns (20 MHz) | 40% of the period each way; inputs launched on the falling edge | 20 MHz is the upper limit of `tck` (DEBUG section 5, PHYS pin 3); the split is an assumption until a probe is chosen |
| `spim_sclk`, `spim_mosi`, `spim_cs_flash_n`, `spim_cs_imu_n` out, `spim_miso` in | `pclk` | 40% of a pclk period | assumption: SCLK is at most pclk / 2 (SPIM [N-6.2]); to be replaced by the flash's and the IMU's data-sheet numbers with the pad ring (task 3.8) |
| every input | – | 200 ps transition | assumption until there is a pad cell |
| every output | – | 50 fF | assumption until there is a pad cell |

Clock uncertainty before the clock tree: 5% of the period for setup, 50 ps for hold.

## Against the sketch in the physical specification

`GARUDA-PHYS-SPEC-001` section 5.2 has a sketch of these constraints written before the
ripple divider: it names two toggle flops that are not in the RTL and has no ratio other
than DIV2. This file replaces it. Its two rules hold here: hclk and pclk are synchronous
and every path between them is timed ([N-5.7]), and the 500 MHz clock reaches one flop
(`clocks.rpt`: `refclk` has 1 register), whose own path is timed at 2 ns.

## Not in the file yet

- The core's clock gate is left to the tool's own clock-gating check; when the library
  cell replaces the latch (task 3.8) the check comes from the cell.
- No constraint on the memories: they are black boxes until the wrappers of task 3.10.
- Conformal's constraint check (task 3.3) has not been run on this file.
