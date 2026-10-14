# Bug register split, 2026-10-11

Source: `Docs/BUGS.md` at b90b481 (archived as `HISTORY_2026.md`). 188 IDs. Made by `tools/bugs/migrate_2026.py`.

Rules: status normalised to OPEN / RULING-NEEDED / IN-PROGRESS / FIXED / CLOSED / WONTFIX / DUP (WAIVED -> WONTFIX; MOOT, not a bug, dispositioned -> CLOSED); priority from the Priority column, else Severity high/medium/low -> P1/P2/P3; fixed entries carry Fixed-in `legacy` (no SHA was recorded).

Collisions renumbered: TOOL-18 (formerly the one at line 971), TOOL-19 (formerly the one at line 126), TOOL-20 (formerly the one at line 198), TB-36 (formerly the one at line 125). Same-defect duplicates merged: AUD-8, ELEM-4, TB-15.

**Needs review (18):** AUD-4, AUD-9, SPIM-2, UART-3, AUD-11, FV-1, T-13, T-14, PWM-2, PWM-3, UART-4, TB-30, TB-32, TB-33, ELEM-8, TOOL-13, TOOL-14, TOOL-15

| ID | Block | Status as written | Status | Prio | Formerly | Note |
|---|---|---|---|---|---|---|
| OVF-1 | dsu | FIXED | FIXED | P1 | - |  |
| T-8 | core | FIXED, *proved* | FIXED | P2 | - |  |
| C-5 | core | FIXED | FIXED | P2 | - |  |
| CORE-3 | core | FIXED | FIXED | P3 | - |  |
| CRG-2 | clkrst | FIXED | FIXED | P2 | - |  |
| DMA-7 | dma | FIXED (by design) | FIXED | P2 | - |  |
| ENG-1 | dma | FIXED | FIXED | P2 | - |  |
| OPEN-8 | core | CLOSED — not a bug | CLOSED | - | - |  |
| ELEM-7 | core | **OPEN (doc)** | OPEN | P3 | - |  |
| SPIM-1 | spi_master | FIXED | FIXED | P1 | - |  |
| UART-1 | uart | FIXED | FIXED | P1 | - |  |
| UART-2 | uart | DOCUMENTED | FIXED | P3 | - |  |
| GPIO-1 | gpio | SPEC CORRECTED | FIXED | P3 | - |  |
| TB-36 | uart | FIXED | FIXED | - | TB-16 |  |
| TOOL-19 | flow | FIXED | FIXED | P3 | TOOL-5 |  |
| AUD-1 | spec | FIXED | FIXED | - | - |  |
| AUD-2 | spec | FIXED | FIXED | - | - |  |
| AUD-3 | spec | **FIXED 2026-09-26** | FIXED | - | - |  |
| AUD-4 | spec | **OPEN** ([N-5.3]) | OPEN | P3 | - | proposed |
| AUD-5 | spec | FIXED | FIXED | - | - |  |
| AUD-6 | spec | FIXED | FIXED | - | - |  |
| AUD-7 | spec | FIXED | FIXED | - | - |  |
| AUD-9 | spec | **OPEN** | OPEN | P3 | - | proposed |
| AUD-10 | spec | PROCESS FIXED | FIXED | - | - |  |
| SPIS-1 | spi_slave | — | CLOSED | - | - | status set by hand: design decision |
| SPIS-2 | spi_slave | MEASURED, caveated | CLOSED | - | - | status set by hand: 'MEASURED, caveated': a stated measurement, not a defect |
| SPIS-3 | spi_slave | ACCEPTED, bounded | WONTFIX | - | - | status set by hand: 'ACCEPTED, bounded' |
| TOOL-20 | flow | FIXED | FIXED | - | TOOL-6 |  |
| TB-22 | flow | **FIXED** | FIXED | P1 | - |  |
| TOOL-7 | flow | **FIXED** | FIXED | P1 | - |  |
| TOOL-8 | flow | **FIXED** | FIXED | P2 | - |  |
| TOOL-9 | flow | **FIXED** | FIXED | P2 | - |  |
| TOOL-10 | flow | **FIXED** | FIXED | P2 | - |  |
| RTL-C1 | soc | **FIXED** | FIXED | P3 | - |  |
| APB-1 | ahb2apb | **OPEN — needs an owner ruling, not an RTL change** | RULING-NEEDED | P3 | - |  |
| TB-24 | flow | **FIXED** | FIXED | P2 | - |  |
| TOOL-11 | flow | FIXED | FIXED | - | - |  |
| C-13 | core | FIXED | FIXED | - | - |  |
| C-14 | core | FIXED | FIXED | - | - |  |
| TB-26 | core | FIXED | FIXED | - | - |  |
| SVA-1 | core | FIXED (assertion) | FIXED | - | - |  |
| PWM-1 | pwm | FIXED (hardening) | FIXED | - | - |  |
| LINT-1 | flow | 5 errors left, all dispositioned | CLOSED | - | - |  |
| SPIM-2 | spi_master | OPEN (vendored) | OPEN | P3 | - | proposed (vendored) |
| CDC-1 | debug | REVIEWED | CLOSED | - | - |  |
| T-9 | core | FIXED | FIXED | - | - |  |
| T-10 | core | FIXED | FIXED | - | - |  |
| P-4 | core | FIXED | FIXED | - | - |  |
| P-5 | core | FIXED | FIXED | - | - |  |
| P-6 | core | FIXED | FIXED | - | - |  |
| P-7 | core | FIXED | FIXED | - | - |  |
| P-8 | core | FIXED | FIXED | - | - |  |
| C-15 | core | FIXED | FIXED | - | - |  |
| T-11 | core | FIXED | FIXED | - | - |  |
| DSU-13 | dsu | FIXED | FIXED | - | - |  |
| DSU-11 | dsu | FIXED | FIXED | - | - |  |
| DSU-12 | dsu | FIXED | FIXED | - | - |  |
| INT-1 | soc | FIXED | FIXED | - | - |  |
| INT-2 | soc | FIXED, **owner to confirm** | FIXED | - | - |  |
| INT-3 | soc | FIXED | FIXED | - | - |  |
| SPIS-4 | spi_slave | FIXED | FIXED | - | - |  |
| SPIS-5 | spi_slave | FIXED | FIXED | - | - |  |
| SPIS-6 | spi_slave | FIXED | FIXED | - | - |  |
| SPIS-7 | spi_slave | FIXED | FIXED | - | - |  |
| DMA-8 | dma | FIXED | FIXED | - | - |  |
| DBG-1 | debug | FIXED | FIXED | - | - |  |
| DBG-2 | debug | FIXED | FIXED | - | - |  |
| DBG-3 | debug | FIXED | FIXED | - | - |  |
| UART-3 | uart | OPEN (vendored) | OPEN | P3 | - | proposed (vendored) |
| TB-28 | pwm | FIXED | FIXED | - | - |  |
| TB-29 | ahb | FIXED | FIXED | - | - |  |
| AUD-8 | spec | **CLOSED in simulation** | CLOSED | - | - |  |
| AUD-11 | spec | OPEN | OPEN | P3 | - | proposed |
| VIP-1 | spi_master | RUN, no defect attributed to GARUDA | CLOSED | - | - |  |
| FV-1 | flow | NOT RUN (no licence) | OPEN | P3 | - | proposed: superseded by the SBY flow (plan P0.9), close when it lands |
| TB-27 | flow | FIXED | FIXED | - | - |  |
| ELEM-1 | core | FIXED (testbench) | FIXED | - | - |  |
| ELEM-2 | core | FIXED (testbench) | FIXED | - | - |  |
| ELEM-3 | core | FIXED (testbench) | FIXED | - | - |  |
| ELEM-4 | core | FIXED (testbench) | FIXED | - | - |  |
| ELEM-5 | core | FIXED (testbench) | FIXED | - | - |  |
| ELEM-6 | core | FIXED (testbench) | FIXED | - | - |  |
| T-13 | core | OPEN | OPEN | P1 | - | proposed: a precise fault is lost |
| T-14 | core | OPEN | OPEN | P1 | - | proposed: the core can sleep in the handler |
| PWM-2 | pwm | OPEN (owner to rule) | RULING-NEEDED | P2 | - | proposed: an ESC input can see a glitch (owner K rules) |
| PWM-3 | pwm | OPEN (hardening) | OPEN | P3 | - | proposed |
| UART-4 | uart | OPEN (vendored) | OPEN | P3 | - | proposed (vendored) |
| TB-30 | soc | OPEN (testbench) | OPEN | P3 | - | proposed |
| TB-32 | core | OPEN (testbench) | OPEN | P3 | - | proposed |
| TB-33 | core | OPEN | OPEN | P3 | - | proposed |
| ELEM-8 | core | OPEN (testbench) | OPEN | P3 | - | proposed |
| TOOL-12 | flow | OPEN | IN-PROGRESS | P2 | - | fix on branch a/p0-infra (Spike exit status), lands with its commit |
| TOOL-13 | flow | OPEN | OPEN | P2 | - | proposed: a failing simulation can be reported as passing |
| TOOL-14 | flow | OPEN | OPEN | P2 | - | proposed: coverage merges failing runs and cannot fail |
| TOOL-15 | flow | OPEN | OPEN | P3 | - | proposed |
| T-12 | core | **OPEN, fix needs an owner decision** | RULING-NEEDED | P1 | - |  |
| TOOL-16 | flow | OPEN (tool, worked around) | OPEN | P3 | - |  |
| VER-1 | flow | DONE | FIXED | - | - |  |
| RDC-1 | core | **OPEN, reproduced** | OPEN | P2 | - |  |
| AUD-12 | spec | **OPEN, each needs a ruling** | RULING-NEEDED | P2 | - |  |
| T-15 | core | **FIXED** | FIXED | P3 | - |  |
| VER-3 | soc | DONE | FIXED | - | - |  |
| PWM-4 | pwm | **FIXED** | FIXED | P2 | - |  |
| C-16 | core | **OPEN, needs an owner decision** | RULING-NEEDED | P3 | - |  |
| AUD-13 | spec | **OPEN, needs a ruling** | RULING-NEEDED | P3 | - |  |
| VER-4 | flow | DONE | FIXED | - | - |  |
| GPIO-2 | gpio | **OPEN, needs an owner decision** | RULING-NEEDED | P2 | - |  |
| VER-5 | flow | DONE | FIXED | - | - |  |
| CRG-3 | clkrst | **OPEN, needs an owner decision** | RULING-NEEDED | P3 | - |  |
| VER-6 | flow | DONE | FIXED | - | - |  |
| SIM-1 | clkrst | **OPEN, needs an owner decision** | RULING-NEEDED | P3 | - |  |
| VER-2 | flow | DONE | FIXED | - | - |  |
| AHB-1 | ahb | SPEC / FIXED | FIXED | P1 | - |  |
| AHB-2 | ahb | SPEC / FIXED | FIXED | P1 | - |  |
| AHB-3 | ahb | SPEC / FIXED | FIXED | P2 | - |  |
| AHB-4 | ahb | SPEC / FIXED | FIXED | P1 | - |  |
| AHB-5 | ahb | SPEC / RESOLVED (documentation) | FIXED | P3 | - |  |
| BRG-1 | ahb2apb | SPEC / FIXED IN RTL | FIXED | P1 | - |  |
| CRG-1 | clkrst | SPEC / FIXED IN RTL | FIXED | P2 | - |  |
| CLIC-1 | clic | FIXED | FIXED | P3 | - |  |
| DMA-1 | dma | FIXED | FIXED | P1 | - |  |
| DMA-2 | dma | FIXED | FIXED | P1 | - |  |
| DMA-3 | dma | FIXED | FIXED | P2 | - |  |
| DMA-3a | dma |  | FIXED | - | - | status set by hand: part of the DMA-3 fix |
| DMA-4 | dma | WAIVED | WONTFIX | P3 | - |  |
| DMA-5 | dma | WAIVED | WONTFIX | P2 | - |  |
| DMA-6 | dma | WAIVED | WONTFIX | P2 | - |  |
| SPEC-1 | dma | contradiction | FIXED | - | - | status set by hand: 'each resolved on the record in docs/DMA_RTL_LOG.md 9.4' |
| SPEC-2 | dma | contradiction | FIXED | - | - | status set by hand: 'each resolved on the record in docs/DMA_RTL_LOG.md 9.4' |
| SPEC-3 | dma | contradiction | FIXED | - | - | status set by hand: 'each resolved on the record in docs/DMA_RTL_LOG.md 9.4' |
| SPEC-4 | dma | contradiction | FIXED | - | - | status set by hand: 'each resolved on the record in docs/DMA_RTL_LOG.md 9.4' |
| SPEC-5 | dma | **ambiguity with a latent hang** | FIXED | - | - | status set by hand: 'each resolved on the record in docs/DMA_RTL_LOG.md 9.4' |
| SPEC-6 | dma | gap | FIXED | - | - | status set by hand: 'each resolved on the record in docs/DMA_RTL_LOG.md 9.4' |
| SPEC-7 | dma | gap | FIXED | - | - | status set by hand: 'each resolved on the record in docs/DMA_RTL_LOG.md 9.4' |
| SPEC-8 | dma | gap | FIXED | - | - | status set by hand: 'each resolved on the record in docs/DMA_RTL_LOG.md 9.4' |
| SPEC-9 | dma | gap | FIXED | - | - | status set by hand: 'each resolved on the record in docs/DMA_RTL_LOG.md 9.4' |
| SPEC-10 | dma | **integration risk** | FIXED | - | - | status set by hand: 'each resolved on the record in docs/DMA_RTL_LOG.md 9.4' |
| SPEC-11 | dma | doc erratum | FIXED | - | - | status set by hand: 'each resolved on the record in docs/DMA_RTL_LOG.md 9.4' |
| SPEC-12 | dma | doc erratum | FIXED | - | - | status set by hand: 'each resolved on the record in docs/DMA_RTL_LOG.md 9.4' |
| I-1 | core | FIXED | FIXED | P1 | - |  |
| D-1 | core | FIXED | FIXED | P1 | - |  |
| BUS-A | core | FIXED | FIXED | P2 | - |  |
| BUS-B | core | FIXED | FIXED | P2 | - |  |
| BUS-C | core | FIXED | FIXED | P2 | - |  |
| BUS-D | core | FIXED | FIXED | P2 | - |  |
| CORE-1 | core | **FIXED** | FIXED | P2 | - |  |
| CORE-2 | core | OPEN | OPEN | P3 | - |  |
| DSU-10 | dsu | **FIXED** | FIXED | P2 | - |  |
| TOOL-4 | flow | FIXED | FIXED | P1 | - |  |
| TB-11 | flow | FIXED | FIXED | P1 | - |  |
| TB-12 | flow | FIXED | FIXED | P2 | - |  |
| TB-13 | ahb | FIXED | FIXED | P2 | - |  |
| TB-14 | ahb | FIXED | FIXED | P2 | - |  |
| TB-15 | dma | FIXED 2026-10-03 | FIXED | P3 | - |  |
| TB-23 | ahb | FIXED 2026-10-03 | FIXED | P3 | - |  |
| TB-1 | dma |  | FIXED | - | - | status set by hand: DMA bring-up testbench fixes ('every such check was converted') |
| TB-2 | dma |  | FIXED | - | - | status set by hand: DMA bring-up testbench fixes ('every such check was converted') |
| TB-3 | dma |  | FIXED | - | - | status set by hand: DMA bring-up testbench fixes ('every such check was converted') |
| TB-4 | dma |  | FIXED | - | - | status set by hand: DMA bring-up testbench fixes ('every such check was converted') |
| TB-5 | dma |  | FIXED | - | - | status set by hand: DMA bring-up testbench fixes ('every such check was converted') |
| TB-6 | dma |  | FIXED | - | - | status set by hand: DMA bring-up testbench fixes ('every such check was converted') |
| TB-7 | dma |  | FIXED | - | - | status set by hand: DMA bring-up testbench fixes ('every such check was converted') |
| TB-8 | dma |  | FIXED | - | - | status set by hand: DMA bring-up testbench fixes ('every such check was converted') |
| TOOL-1 | flow |  | CLOSED | - | - | status set by hand: Windows-session environment note, superseded |
| TOOL-2 | flow |  | CLOSED | - | - | status set by hand: Windows-session environment note, superseded |
| TOOL-3 | flow |  | CLOSED | - | - | status set by hand: Windows-session environment note, superseded |
| TOOL-18 | flow |  | CLOSED | - | TOOL-5 | status set by hand: environment note (no Cadence tools), superseded |
| TOOL-6 | flow |  | CLOSED | - | - | status set by hand: environment note (no RISC-V toolchain), superseded |
| TB-16 | clkrst | FIXED | FIXED | P2 | - |  |
| TB-17 | clkrst | FIXED | FIXED | P3 | - |  |
| TB-18 | clkrst | FIXED | FIXED | P1 | - |  |
| TB-19 | ahb2apb | FIXED | FIXED | P2 | - |  |
| TB-20 | clic | FIXED | FIXED | P2 | - |  |
| TB-21 | soc | FIXED | FIXED | P2 | - |  |
| TOOL-5 | flow | FIXED | FIXED | P1 | - |  |
| MUT-1 | flow | **8 failures**, all T14 | CLOSED | - | - | status set by hand: mutation record, not a defect |
| MUT-2 | flow | **1 failure**, T12 — DMA starved | CLOSED | - | - | status set by hand: mutation record, not a defect |
| MUT-3 | flow | **39 failures**, T13 and the soak | CLOSED | - | - | status set by hand: mutation record, not a defect |
| MUT-4 | flow | slave-side checker: **79** `SEQ following a SINGLE burst` | CLOSED | - | - | status set by hand: mutation record, not a defect |
| MUT-5 | flow | **394 failures** across T1, T13, T16 | CLOSED | - | - | status set by hand: mutation record, not a defect |
| MUT-6 | flow | **10 failures**, T18 and T19 | CLOSED | - | - | status set by hand: mutation record, not a defect |
| MUT-7 | flow | **1 failure**, T20a | CLOSED | - | - | status set by hand: mutation record, not a defect |
| MUT-8a | flow | **PASSES — uncovered, and known to be redundant.** See DMA-3 | CLOSED | - | - | status set by hand: mutation record, not a defect |
| MUT-8b | flow | **1 failure**, T20a | CLOSED | - | - | status set by hand: mutation record, not a defect |
| MUT-9 | flow | **1 failure**, T20b | CLOSED | - | - | status set by hand: mutation record, not a defect |
| T-16 | core | (new 2026-10-11) | RULING-NEEDED | P3 | audit note 'T-12' | added |
| TB-34 | core | (new 2026-10-11) | OPEN | P3 | - | added |
| TB-35 | dsu | (new 2026-10-11) | OPEN | P3 | audit F-09 | added |
