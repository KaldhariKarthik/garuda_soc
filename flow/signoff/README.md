# 1-TOPS signoff: evidence in this repository

The 1-TOPS signoff workbook has gates G0 to G9 and keeps every row's evidence as a path in this repository at a stated commit. Karthik keeps the GARUDA version of the workbook outside the repository; this folder holds what its rows point at.

| Folder | Gate | What is in it |
|---|---|---|
| `g0/` | G0 Tools and flow | one hello-world case per tool, the commands, each tool's output |
| `g1/` | G1 Specification | trial synthesis for the gate-count budget (item 1.15) |
| `g3/` | G3 Integration | boot ROM reproducibility (3.9); the `boot_sel` path (3.12) |
| `runs/` | G4 to G6 | console output of `make gate_a`, `make gate_b` and `make regress_all`, one file per run, named by date |

## Gates and flow stages

The work is organised by the design flow in `flow/FLOW.md` (stages F0 to F16); the
gates are filled from it. New evidence goes into the folder of its stage; the folders
above stay as they are because the workbook rows already point at them.

| Gate | Flow stages |
|---|---|
| G0 | F0 tools and environment |
| G1 | F1 specification, F2 verification plan |
| G2 | F3 RTL design (core), F4 static checks (core) |
| G3 | F3 RTL design (integration), F4 static checks (chip) |
| G4 | F5 block and unit verification, F6 core sanity |
| G5 | F6 core verification, F8 core coverage |
| G6 | F7 SoC verification, F8 regression and coverage, F9 RTL freeze |
| G7 to G9 | F10 to F16, after the PDK |

The specification documents the gates point at are in `Design_Docs/`. The verification plans are in `tb/*/GARUDA_*_vplan.csv`, mapped to the 1-TOPS phases in `flow/1_vplan/1TOPS_PHASES.md`. Bugs are in `Docs/bugs/`.

## Tags (item 0.6)

Every gate that closes gets an annotated tag on the commit that holds its last piece of evidence:

    git tag -a 1tops-G0-closed -m "1-TOPS gate G0 closed: <date>, coach <name>"
    git push origin 1tops-G0-closed

The tag names are fixed in advance:

| Gate | Tag |
|---|---|
| G0 to G9 | `1tops-G0-closed` ... `1tops-G9-closed` |
| RTL frozen for synthesis (item 6.19) | `1tops-rtl-freeze` |
| The database handed to the foundry (item 9.8) | `1tops-tapeout` |

Rules:
- A gate is tagged only after the coach has approved it in the workbook.
- A tag is never moved or deleted. If a closed gate has to be reopened, the new close gets `-2`, for example `1tops-G3-closed-2`.
- Evidence paths in the workbook name a commit that is on GitHub. Push the commits before the workbook is sent to the coach.
