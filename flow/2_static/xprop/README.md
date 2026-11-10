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
It lists them at elaboration with `-xverbose`; the list is kept in `xp_elab.txt` here (the `xp_elab.log` Xcelium writes, renamed)
(51 blocks switched off; 291 blocks in a reduced mode called FOX, where the result
cannot be X by construction, for example a 2-state variable).

| Where | Why X-propagation is off | Does it matter |
|---|---|---|
| `rtl/core/id_ex.v:114`, the ID/EX pipeline register | Its reset and flush call the task `set_bubble`, which writes registers outside the task | **Yes.** This is the main register of the ID/EX stage. An X on `flush_i` or `stall_i` is not propagated here. |
| `rtl/debug/debug_module.v:159`, the debug module registers | `kick()`, which starts a system-bus access, writes registers outside the task | **Yes**, for the debug module. |
| `rtl/mem/sram_wrapper.v:80` | The behavioural memory array is too large for the default; the 28 nm macros replace it | No: the macro is a black box in the real flow |
| `rtl/dsram/dsram_top.v:72` | The testbench backdoor task, inside `ifndef SYNTHESIS` | No |
| `rtl/common/garuda_apb_shim.v:203` (8 instances) | The elaboration check inside `ifndef SYNTHESIS` | No |
| `*_sva.sv`, `dma_props_a.sv` | Assertions | No |
| `tb/` | Testbench and models | No |

## Open point

The two blocks marked "Yes" are a gap in this check, not a design error. They can be
closed by writing the task bodies inline in the always block (no change of behaviour),
after which this run covers them. Both are RTL changes to a core block and to the debug
module, so they need Karthik's ruling and a rerun of `gate_a`, `gate_b` and this target.
Until then F4 records X-propagation as done for the chip except these two blocks.
