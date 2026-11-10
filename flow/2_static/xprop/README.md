# X-propagation on the chip programs (flow stage F4)

Written 2026-11-10. This is the X-propagation record that `flow/FLOW.md` asks for at the
end of F4. The workbook has no row of its own for it; G2 row 2.11 (coding rules) and
the register-file rows of G2 rely on it.

## What was run

`make static_xprop` (`flow/mk/track_b.mk`): every chip program on `tb_chip` with Xcelium
X-propagation in forward mode (`xrun -xprop F`). In this mode an X on a condition, a case
select or an index sends X forward into everything it controls, as real silicon would give
an unknown value. Normal simulation picks one branch and hides the X. A program that still
passes shows that no X from an unreset flop or an undriven net reaches a register whose
value the program checks.

Run from the repository root in tcsh:

    source /home/install/cshrc
    make static_xprop

On 2026-11-10, commit d395563 plus this change, Xcelium 22.09-s003:

| Program | What it exercises | Result |
|---|---|---|
| chip_basic | the first program on the chip, entered from the boot ROM recovery mailbox | PASS |
| chip_irq | the interrupt path end to end: DMA completion, CLIC, core trap, clear | PASS |
| chip_wdt | a real watchdog reset of the whole chip | PASS |
| chip_jtag | halt, load ISRAM over JTAG system-bus access, resume, run | PASS |
| chip_flash | boot from SPI flash | PASS |
| chip_uart | the three UARTs from the core, through the fabric | PASS |
| chip_periph | all seven peripherals from the core, through the fabric | PASS |
| chip_integ | every wire between two blocks, from the core | PASS |
| chip_swirq | the software interrupt end to end (added to the target on 2026-11-10; it was missing) | PASS |

PASS means `RESULT: PASSED` in the log and no `*E` or `*F` message. The logs are
`sim/xprop/chip_<program>.log`. The whole run takes about 25 seconds.

## Where X-propagation is switched off

Xcelium cannot apply X-propagation to some blocks and runs them with normal semantics.
It lists them at elaboration with `-xverbose`; the list is kept in `xp_elab.txt` here (the
`xp_elab.log` Xcelium writes, renamed). After the change below: 49 blocks switched off, and
292 blocks in a reduced mode called FOX, where the result cannot be X by construction (for
example a 2-state variable).

| Where | Why X-propagation is off | Does it matter |
|---|---|---|
| `rtl/mem/sram_wrapper.v:80` | The behavioural memory array is too large for the default; the 28 nm macros replace it | No: the macro is a black box in the real flow |
| `rtl/dsram/dsram_top.v:72` | The testbench backdoor task, inside `ifndef SYNTHESIS` | No |
| `rtl/common/garuda_apb_shim.v:203` (8 instances) | The elaboration check inside `ifndef SYNTHESIS` | No |
| `*_sva.sv`, `dma_props_a.sv` | Assertions | No |
| `tb/` | Testbench and models | No |

No block of synthesised design logic is left out.

## Two blocks brought in (ruling 2026-11-10)

The first run listed 51 blocks, among them two of design logic:

- `rtl/core/id_ex.v`, the ID/EX pipeline register: its reset and flush called the task
  `set_bubble`;
- `rtl/debug/debug_module.v`, the debug module registers: three places called `kick()`,
  which starts a system-bus access.

Xcelium switches X-propagation off for a block that calls a task writing registers outside
the task. Karthik ruled to write the task bodies inline. Both are now inline, and the
comment at each place says why.

How the change was checked:

- Conformal LEC, the old file (commit aeecf3c) against the new one, module by module
  (`lec -lpgxl`): `id_ex` 404 of 404 points equivalent; `debug_module` 281 of 281
  equivalent, with the same 96 unreachable flops on both sides. Dofiles and logs:
  `lec_id_ex.do`, `lec_debug_module.do` and the `.txt` logs here; each dofile reads the old
  file from `sim/lec_inline/<module>_old.v`, made with
  `git show aeecf3c:rtl/core/id_ex.v > sim/lec_inline/id_ex_old.v` (and the same for
  `rtl/debug/debug_module.v`).
- `make static_xprop`: 9 of 9 pass, now with X-propagation in both blocks.
- `make static_lint`: HAL 745 findings, one fewer than before. The inline check writes the
  alignment literal sized (`2'b00`); the task wrote `0`.
- `make gate_a`, `make gate_b`: pass (`flow/signoff/runs/`).
