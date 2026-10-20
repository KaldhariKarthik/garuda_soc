# GARUDA project documents

This folder holds the project records: defects, rulings, handoffs, guides and dated logs.
The specifications are in `Design_Docs/`. Write each new document to
`Docs/DOC_STANDARD.md`.

## Folder map

| Path | What goes in it | Who adds to it |
|---|---|---|
| `Docs/DOC_STANDARD.md` | The writing standard (based on ASD-STE100) | Change only by team agreement |
| `Docs/DECISIONS.md` | Rulings, one for each section (D-n) | The person who records the ruling |
| `Docs/COVERAGE.md` | The coverage summary of the chip | Track B (coverage chart) |
| `Docs/THIRD_PARTY_NOTICES.md` | Licences of the third-party RTL | The person who adds the IP |
| `Docs/bugs/track_a.md` | Defects of track A: core, DSU, AHB, bridge, DMA, debug, memories, physical design | Owner of track A |
| `Docs/bugs/track_b.md` | Defects of track B: peripherals, clocks and resets, chip top, software, FPGA, flow | Owner of track B |
| `Docs/bugs/archive/BUGS_HISTORY.md` | The old register (was `Docs/BUGS.md`), closed 2026-10-21 | Nobody. Do not add to it |
| `Docs/coverage/` | Coverage by block, applicability matrix, findings | Track B (generated) |
| `Docs/guides/` | How-to documents: running the flow, oracles, element verification, meeting notes | Any track |
| `Docs/handoff/` | Handoff notes between people and sessions | The person who hands over |
| `Docs/logs/pd/` | Physical-design logs, `PD_LOG_<YYYY-MM-DD>.md` | The person who ran the flow |
| `Docs/logs/verification/` | Verification logs, `VERIFICATION_LOG_<YYYY-MM-DD>.md` | The person who ran the checks |
| `Docs/logs/rtl/` | RTL logs of the early blocks | History |
| `Docs/logs/fpga/` | FPGA bring-up logs | The person who ran the FPGA |
| `Docs/logs/ENGINEERING_LOG.md` | The general engineering log | Any track |

## Rules

1. Put a defect in its track register. Do not add to the archive.
2. Do not put a new file in the `Docs/` root.
3. Name a dated log `<AREA>_LOG_<YYYY-MM-DD>.md` and put it in `Docs/logs/<area>/`.
4. Write a path from the repository root.
5. Run `make check_tree` before you push. It checks the bug IDs and this folder layout.

## Where the files were before 2026-10-21

Old paths in commits before 2026-10-21 changed as follows.

| Old path | New path |
|---|---|
| `Docs/BUGS.md` | `Docs/bugs/archive/BUGS_HISTORY.md` |
| `Docs/HANDOFF.md`, `Docs/CLAUDE_HANDOFF.md` | `Docs/handoff/` |
| `Docs/HOWTO_RUN.md`, `Docs/MEETING_CHEATSHEET.md`, `Docs/ORACLES.md`, `Docs/CORE_ELEMENT_VERIFICATION.md` | `Docs/guides/` |
| `Docs/PD_LOG_*.md` | `Docs/logs/pd/` |
| `Docs/VERIFICATION_LOG_*.md` | `Docs/logs/verification/` |
| `Docs/RTL_LOG_2026-09-16.md`, `Docs/SOC_RTL_LOG.md`, `Docs/DMA_RTL_LOG.md` | `Docs/logs/rtl/` |
| `Docs/FPGA_BRINGUP_LOG.md` | `Docs/logs/fpga/` |
| `Docs/ENGINEERING_LOG.md` | `Docs/logs/` |
