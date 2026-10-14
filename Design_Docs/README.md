# Design_Docs — which file is the specification?

**The `.md` is normative. The `.docx` is an export.** If a `.md` and its `.docx` disagree,
the `.md` is correct and the `.docx` is a defect.

`garuda_system.yaml` (GARUDA-SYS-001) is above both. It holds the cross-block facts: block
numbers, address map, APB windows, CLIC IDs, DMA channels, clocks and pins. If a spec and the
yaml disagree, the yaml is correct. `tools/garuda_gen.py` writes the yaml into
`rtl/include/garuda_map.vh` and `sw/common/garuda_map.h`; `--check` fails if they are stale.

## Contents

| Path | What it is |
|---|---|
| `garuda_system.yaml` | System description, Rev 4.0. Normative for cross-block facts |
| `GARUDA-ADR-001.md` | Architecture decision records (ADR-0001..) |
| `GARUDA-TRM-001.md` | Technical reference manual |
| `GARUDA-<BLOCK>-SPEC-001.md` | 17 specifications: one per block or block group, and PHYS for pins and physical constraints |
| `SPEC_TEMPLATE.md` | The section layout that every block spec follows |
| `regs/*.rdl` | SystemRDL register descriptions (CLIC, clock/reset, GPIO, PWM, timers). They are written from each spec's §6 and generate the UVM register models |
| `archive/` | Rev 1.x and 2.0 documents, kept for history. Superseded |

Rulings that resolve a conflict between documents are in `Docs/DECISIONS.md`.

## Rules

1. **Edit the `.md`.** Do not edit a `.docx`. The next export overwrites it.
2. **Export before you send a document to a reviewer:** `make docs` (needs pandoc).
3. **Check before you send:** `make check_docs` fails if a `.docx` is older than its `.md`.
   It compares git commit dates, not file times, so commit the `.md` and the `.docx` together.

## Why the rule exists

The `.docx` files were first made by hand, with no generator. Two hand-kept copies drift.
That drift caused AUD-2 (`Docs/BUGS.md` §1d): one table numbered the APB windows from 0 while
the hardware numbers them from 1, and four specifications copied the error.

## Current state (2026-10-14)

All 20 `.md` files have a `.docx`. The exports were made again with pandoc 2.9.2.1 on
2026-10-14 for every document that was stale, missing or edited that day. `GARUDA-ADR-001`,
`GARUDA-AHB-SPEC-001` and `GARUDA-DSU-SPEC-001` were current and keep their earlier exports.

If nobody downstream needs Word files, delete the `.docx` files and send the `.md`. The
`.md` renders on GitHub, shows clean diffs, and cannot drift from itself.
