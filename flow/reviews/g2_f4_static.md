# Review record: G2 close, flow stage F4 (static checks)

Written by the reviewer, not the author (`flow/reviews/TEMPLATE.md`). The author filled in
only the header and the list of what to read and run, on 2026-11-10; every other entry is
the reviewer's.

| | |
|---|---|
| Block or task | 1-TOPS G2 rows 2.11 (coding rules) and 2.12 (core lint); G3 row 3.14 reopened and closed again (TOOL-A11); the F4 X-propagation record |
| Author (track) | Claude (both tracks) |
| Reviewer (track) | Karthik |
| Commit reviewed | |
| Date | |
| Verdict | |

## 1. What was read

| Item | Path | Read |
|---|---|---|
| Coding-rule record (2.11) | `flow/2_static/coding_rules.md` | |
| Core lint report (2.12) | `flow/2_static/core_lint.md` | |
| Superlint results, full-length run (3.14) | `flow/2_static/superlint/chip/RESULTS.md` | |
| X-propagation record and its open point | `flow/2_static/xprop/README.md` | |
| Bug entries | `Docs/bugs/track_a.md`: TOOL-A11, TOOL-A12 | |
| Make changes | `git diff d395563 -- flow/mk` | |
| Flow map, stage F4 | `flow/FLOW.md` | |

## 2. What was run by the reviewer

From `flow/COMMANDS.md`, "Replay by gate", rows R3.1, R3.7, R3.8 and R3.9 (R3.2 takes about
two hours and can be skipped if its report is read instead).

| Command | Result |
|---|---|
| | |

## 3. Questions asked and the answers

| # | Question | Answer | Settled |
|---|---|---|---|
| 1 | X-propagation does not reach `rtl/core/id_ex.v` (task `set_bubble`) or the register block of `rtl/debug/debug_module.v` (task `kick`). Write the two task bodies inline so the check covers them (RTL change, then `gate_a`, `gate_b`, `static_xprop`), or accept the gap in writing? | | |

## 4. Changes asked for

| # | What | Where | Done in commit |
|---|---|---|---|
| | | | |

## 6. What the reviewer did not check

## Signature
