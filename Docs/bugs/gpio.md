# Bugs: GPIO (rtl/gpio)

Owner: Track B. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).
Priorities: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).

<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. Run `bugs.py check` before pushing. -->
| ID | Title | Status | Prio | Found-by | Found | Fixed-in | Regression test | Evidence | Formerly |
|---|---|---|---|---|---|---|---|---|---|
| GPIO-1 | level | FIXED | P3 | s_is_int_all`, a combinational edge detect); `INTSTATUS` is the separate per-pin | 2026-09-22 | legacy | `t_gpio_irq` failing | HISTORY_2026.md L124 | - |
| GPIO-2 | The GPIO specification and the vendored block disagree in five places | RULING-NEEDED | P2 | writing the GPIO reference model from the specification | 2026-10-04 | - | - | HISTORY_2026.md L401 | - |

## Details

### GPIO-1

*From `Docs/BUGS.md` at b90b481, line 124, section "1c. Peripherals — vendored IP and wrappers, 2026-09-22/23".*

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| **GPIO-1** | 19 GPIO | SPEC CORRECTED | low | The first draft of GARUDA-GPIO-SPEC-001 said upstream's `interrupt` was a read-to-clear **level**, so clearing `IRQSTAT` alone would not drop the line. It is a one-cycle **pulse** (`assign interrupt = \|s_is_int_all`, a combinational edge detect); `INTSTATUS` is the separate per-pin sticky record. The sticky tail is therefore doing real work — without it a GPIO interrupt would be one `pclk` wide and the CLIC would miss it. Spec and test corrected to match the RTL. | `t_gpio_irq` failing | `t_gpio_irq`, `t_gpio_irq_cause` |

### GPIO-2

*From `Docs/BUGS.md` at b90b481, line 401, section "1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)".*

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **GPIO-2** | `rtl/third_party/pulp/apb_gpio/src/apb_gpio.sv`, `rtl/gpio/garuda_gpio_top.v`, GARUDA-GPIO-SPEC-001 | **OPEN, needs an owner decision** | P2 | **The GPIO specification and the vendored block disagree in five places.** Each is exercised by the directed test of the new environment; its reference model follows the block and says so at each line. (1) **The "level" interrupt type does not exist.** The register table gives INTTYPE `11` as level. The block decodes `00` falling, `01` rising and `10` either edge, and for `11` raises nothing, on either pin, for a rising edge, a falling edge or a steady level. Firmware that selects it waits for an interrupt that never comes. (2) **GPIOEN is not per pin.** [N-6.1] says bit n enables pin n's input path. The block runs the input flops of both pins when either bit is set (it gates in groups of four pins), so with only GPIOEN[0] set PADIN[1] is live; with both clear PADIN holds its last value instead of reading 0; and a pad that moves while the path is stopped is delivered as an edge, with its interrupt, when the path is started again. (3) **Offsets the register table does not list answer without an error:** 0x20 and 0x2C to 0x7C are inside the vendored register file (the wrapper passes everything below 0x80), read 0 and ignore writes. (4) **[N-6.2] says only bits 1:0 of each register mean something;** INTTYPE uses 3:0 (two bits per pin) and PADCFG0 7:0. (5) **An INTSTATUS read in the cycle a new event arrives does not clear:** the bits already set stay set and the new one is added; nothing is lost, but a handler can see a pin it has already served. Only (1) can cost an interrupt. The choice for each is to correct the specification or to change the wrapper (the block itself is vendored); none was changed here. Also corrected in the plan: a pad reaches PADIN after five clock cycles (two flops in the shim, three in the block), not two. | writing the GPIO reference model from the specification |
