# Bugs: UART (rtl/uart + vendored PULP)

Owner: Track B. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).
Priorities: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).

<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. Run `bugs.py check` before pushing. -->
| ID | Title | Status | Prio | Found-by | Found | Fixed-in | Regression test | Evidence | Formerly |
|---|---|---|---|---|---|---|---|---|---|
| UART-1 | high | FIXED | P1 | `tb_uart` RX mismatch | 2026-09-22 | legacy | `t_uart_rxidle`, and the loopback tests that failed without it | HISTORY_2026.md L118 | - |
| UART-2 | MCR (0x10), MSR (0x18) and SCR (0x1C) are not implemented upstream at all — no write case, no read case, they fall to... | FIXED | P3 | `tb_uart` | 2026-09-22 | legacy | `t_uart_wordmap` asserts they read 0 | HISTORY_2026.md L122 | - |
| TB-36 | same module-level loop index | FIXED | - | the tests themselves | 2026-09-22 | legacy | all three now pass | HISTORY_2026.md L125 | TB-16 |
| UART-3 | The baud counter compares for equality | FIXED | P3 | - | 2026-10-04 | 658683a | Karthik BMC + Yosys (VERIFICATION_LOG) | Docs/VERIFICATION_LOG_2026-10-11.md | - |
| UART-4 | One byte of the vendored UART register array is not reset inside an asynchronous-reset block | FIXED | P3 | - | 2026-10-04 | 658683a | Karthik BMC + Yosys (VERIFICATION_LOG) | Docs/VERIFICATION_LOG_2026-10-11.md | - |

## Details

### UART-1

*From `Docs/BUGS.md` at b90b481, line 118, section "1c. Peripherals — vendored IP and wrappers, 2026-09-22/23".*

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| **UART-1** | 16/17/18 | FIXED | **high** (every read off by one byte, for ever) | `garuda_apb_shim`'s pad synchronisers reset to 0. An idle serial line is **high**, so out of reset the receiver saw a start bit, framed a garbage byte, and left it at the head of the RX FIFO — after which every `RBR` read returned the previous byte. Shim gained `SYNC_RESET`; the UART passes 1. | `tb_uart` RX mismatch | `t_uart_rxidle`, and the loopback tests that failed without it |

### UART-2

*From `Docs/BUGS.md` at b90b481, line 122, section "1c. Peripherals — vendored IP and wrappers, 2026-09-22/23".*

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| **UART-2** | 16/17/18 | DOCUMENTED | low | `MCR` (0x10), `MSR` (0x18) and `SCR` (0x1C) are not implemented upstream at all — no write case, no read case, they fall to `default`. They decode without `PSLVERR` and read 0. `SCR` in particular is not a usable scratch register. | `tb_uart` | `t_uart_wordmap` asserts they read 0 |

### TB-36

*From `Docs/BUGS.md` at b90b481, line 125, section "1c. Peripherals — vendored IP and wrappers, 2026-09-22/23".*

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| **TB-16** | TB | FIXED | — (lost time) | Three testbench defects of the same family, all of which first looked like RTL bugs. (a) `tb_uart` ran both `fork` branches over the **same module-level loop index**, so the back-to-back test compared nonsense and reported "index 16" of a 16-iteration loop. (b) `tb_pwm` read `width[]` in the same delta its monitor wrote it, so every check saw the *previous* pulse. (c) `tb_i2c`'s SDA-stability checker flagged legal traffic because it asked "did SDA move during the high phase" instead of the actual I2C rule, "is the value at the rising edge still there at the falling edge". Recorded because in each case the first instinct was to go and change working RTL. | the tests themselves | all three now pass |

### UART-3

*From `Docs/BUGS.md` at b90b481, line 338, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **UART-3** | `rtl/third_party/pulp/apb_uart_sv/src/uart_tx.sv` | OPEN (vendored) | The baud counter compares for equality. A smaller divisor written while a frame is in flight leaves it counting to the 16-bit wrap: the line stalls for up to 65 536 `pclk` with TEMT low. Firmware must wait for `LSR.TEMT` before writing DLL/DLM. A `>=` compare is a one-line vendor patch. Found when the UART bench changed the divisor under a frame. |

**2026-10-14:** FIXED by Karthik in 658683a (vendor patch).

### UART-4

*From `Docs/BUGS.md` at b90b481, line 370, section "1i. Independent audit on free tools — 2026-10-04/05".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **UART-4** | `rtl/third_party/pulp/apb_uart_sv/src/apb_uart.sv` | OPEN (vendored) | **One byte of the vendored UART register array is not reset inside an asynchronous-reset block.** `regs_q` is `logic [9:0][7:0]` (`apb_uart.sv:42`); the reset branch of `always_ff @(posedge CLK, negedge RSTN)` (`:328-342`) assigns nine entries (IER, IIR, LCR, MCR, LSR, MSR, SCR, DLL+8, DLM+8) but not index 0, so that byte holds its value through reset. Yosys reports `Async reset value ... is not constant`; synthesis must build it as a flop with RSTN acting as a data enable (a reset-in-data-path lint item), and the byte powers up undefined. Benign if firmware never reads it before writing it. A one-line vendor patch adds it to the reset branch. Found by: Yosys whole-chip synthesis. |

**2026-10-14:** FIXED by Karthik in 658683a (vendor patch).
