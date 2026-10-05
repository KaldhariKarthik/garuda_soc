# GARUDA verification: sign-off criteria

Fixed on 2026-10-04, before the block environments are written. The same list
applies to every block. A block is "closed" only when every line holds; a block
that meets all of them except formal is "closed for simulation" and says so.

| # | Criterion | Target | Where it is measured |
|---|---|---|---|
| 1 | Every feature in the block's vPlan has a check method and a passing check | 100% of features | `tb/<blk>/GARUDA_<BLK>_vplan.csv`, opened in vPlanner |
| 2 | Functional coverage of the vPlan's coverage items | 100% | IMC, covergroup report |
| 3 | Code coverage on the block's own RTL: block, expression, FSM | at least 95%, and every hole below 100% waived in writing | IMC; waivers in `flow/cov/<blk>_exclusions.tcl`, one reason per line |
| 4 | Assertions bound to the RTL | every property in the vPlan, 0 failures, each one seen to trigger at least once | simulator assertion summary |
| 5 | Open bugs against the block | zero P1, zero P2 | `Docs/BUGS.md` |
| 6 | Regression | every test passing over at least 20 seeds, no new failure in the last full run | vManager session |
| 7 | Lint and clock-domain checks | 0 errors, or each one waived in writing | HAL; `flow/2_static/hal_waivers.txt` |
| 8 | Register model | reset value, access policy and aliasing tests pass on every register | UVM register tests |
| 9 | Formal, on the features the vPlan assigns to it | proved | JasperGold. Not installed on this machine as of 2026-10-04: these items are listed and wait for the tool |

Priorities: **P1** the chip does the wrong thing or hangs; **P2** a specified
feature does not work but there is a workaround; **P3** everything else.

Check methods used in the plans: **sim** (UVM environment, constrained random or
directed), **formal**, **GLS** (gate-level simulation), **silicon** (FPGA or the
chip). A feature may list more than one.

Out of scope until there is a netlist: equivalence checking, gate-level
simulation, DFT (stage 7) and the tape-out review (stage 8).
