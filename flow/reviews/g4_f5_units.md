# Review record: G4, flow stages F5 and F6 at unit level (core units, hazards, mutants)

Written by the reviewer, not the author (`flow/reviews/TEMPLATE.md`). The author filled in
only the header and the list of what to read and run, on 2026-11-10; every other entry is
the reviewer's.

| | |
|---|---|
| Block or task | 1-TOPS G4 rows 4.1 to 4.9, 4.11 to 4.16; the F5 exit table by block; mutation results for every block with a mutant set |
| Author (track) | Claude (both tracks) |
| Reviewer (track) | Karthik |
| Commit reviewed | |
| Date | |
| Verdict | |

## 1. What was read

| Item | Path | Read |
|---|---|---|
| Row-by-row record, unit coverage, core covergroups | `flow/3_unit/core_units.md` | |
| Seed sweep | `flow/3_unit/seeds_2026-11-10.txt` | |
| Hazard program | `sw/tests/t_hazard.S` | |
| New forwarding-unit bench | `tb/core/tb_forward_unit.sv` | |
| Bench changes | `git diff 45aef55 -- tb/core tb/cov tb/debug tb/mem tb/common` | |
| Exit table by block | `flow/FLOW.md`, stage F5 | |
| Mutation results | `flow/mutation/README.md`, `flow/mutation/results/` | |
| Equivalent-mutant proof | `flow/formal/mem/dsram_bank_fpv.tcl`, `.result.txt` | |
| Bug entries | `Docs/bugs/track_a.md` TOOL-A13; `Docs/bugs/track_b.md` TB-B4 | |

## 2. What was run by the reviewer

From `flow/COMMANDS.md`, "Replay by gate", rows R4.1 to R4.7.

| Command | Result |
|---|---|
| | |

## 3. Questions asked and the answers

| # | Question | Answer | Settled |
|---|---|---|---|
| | | | |

## 4. Changes asked for

| # | What | Where | Done in commit |
|---|---|---|---|
| | | | |

## 6. What the reviewer did not check

## Signature
