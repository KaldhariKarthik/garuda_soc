# GARUDA verification handbook

How verification is done on GARUDA: who owns what, how a run is judged, how a
bug is recorded, how coverage and formal results are counted, and what sign-off
needs. Written for both tracks. A chapter states a rule only where the rule is
already in force; a chapter whose subject has not landed yet says so.

| Chapter | Subject | State |
|---|---|---|
| [H0](H0_roles.md) | Roles, ownership, authorities, design notes, gates | in force |
| [H1](H1_tools.md) | Tools: pinned versions, setup, Rocky notes | in force (open tools) |
| [H2](H2_running.md) | Running: verdicts, xfail, shims, seeds, logs, qualification | in force |
| [H3](H3_bugs.md) | Bugs: register, fields, lifecycle, fix discipline | in force |
| [H4](H4_coding.md) | Coding standards for RTL fixes and verification code | in force |
| [H5](H5_coverage.md) | Coverage: four categories, waivers | rules in force; flow lands with E8/E9 |
| [H6](H6_formal.md) | Formal: result classes, assumptions, replay | rules in force; flow lands with P0.9 |
| [H7](H7_core_env.md) | Core environment and co-simulation | lands with E1-E3 |
| [H8](H8_mutation.md) | Mutation and planted defects | rules in force; flow lands with E11 |
| [H9](H9_signoff.md) | Regression tiers, seeds, sign-off, review records | rules in force |
| [A](A_checklists.md) | Checklists: per fix, per block, pre-push, reviewer | in force |

Source of the rules: the approved Track A plan (Obsidian `GARUDA Core Plan (C)`,
2026-10-11) and `flow/0_signoff_criteria.md`. Where this handbook and
`0_signoff_criteria.md` differ, the stricter rule applies until the two are
reconciled (plan change 5).
