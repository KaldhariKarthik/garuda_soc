# GARUDA SoC: bug register, track A

Core, DSU, AHB interconnect, AHB2APB bridge, DMA, debug and memories. Kept by the owner
of track A. `Docs/BUGS.md` is the register up to 2026-10-05 and is history: it gets no new
entries. Track B's entries are in `Docs/bugs/track_b.md`.

## How entries are numbered

| Kind of entry | ID | Next free on 2026-10-11 |
|---|---|---|
| A block of this track | the block's own prefix, continuing the numbers of `Docs/BUGS.md` | T-16, C-17, CORE-4, DSU-14, AHB-6, BRG-2, APB-2, DMA-9, DBG-4, RDC-2; MEM-1 is new |
| Anything that is not one block (tools, benches, audits, lint, simulation, verification runs) | the old prefix with the track letter | TOOL-A1, TB-A1, ELEM-A1, AUD-A1, VER-A1, FV-A1 |

A block prefix belongs to the block's track, and a prefix that is not a block carries the
track letter, so the two tracks cannot take the same ID. An ID is never reused or
renumbered. `make check_tree` fails when an ID is defined twice.

Status words are those of `Docs/BUGS.md`: `OPEN`, `FIXED`, `WAIVED`, `SPEC`, `DONE`.
Priority: P1 wrong behaviour in the field, P2 wrong behaviour that needs an unusual
condition or a verification hole that could hide one, P3 everything else.
An entry marked FIXED names the test that fails without the fix.

## Carried over from `Docs/BUGS.md`

Entries of this track that were open when the register was split. The full text of each
is in `Docs/BUGS.md` under its ID; this table says what was decided and what was done.
Task numbers are those of the plan of 2026-10-10.

| ID | Subject | Ruling | Task | State | What was done |
|---|---|---|---|---|---|
| T-12 | A second trap inside an interrupt handler leaves the interrupt level wrong | Previous level in `mcause[23:16]`, pushed on every trap, popped by `mret` | 0.1 | OPEN | |
| T-13 | A bus error on the instruction before an MRET is dropped | The audit's test and fix | 0.2 | OPEN | |
| T-14 | A bus error on the instruction before a WFI leaves the core asleep | The audit's test and fix | 0.2 | OPEN | |
| RDC-1 | A debugger halt resets the core under a bus that is not in reset | The core reset waits, bounded, for the core's bus transfers to end | 0.3 | OPEN | |
| C-16 | Four groups of CSRs trap where v1.12 says they exist | Read 0, ignore writes | 0.4 | OPEN | |
| AUD-13 (rule, DMA) | PSLVERR decided block by block | One rule in the bridge specification; DMA stops raising PSLVERR on a read-only write | 0.5 | OPEN | |
| TB-32 | `tb_garuda_pc_gen` relies on a time-zero reset edge | Fixed as the entry says | 0.6 | OPEN | |
| TB-33 | `tb_id_stage` can never generate a bubble | Fixed as the entry says | 0.6 | OPEN | |
| ELEM-8 | `tb_d_port_ahb_master` withdraws a waiting transfer | Fixed as the entry says | 0.6 | OPEN | |
| AUD-12 (1) | DMA reach: yaml and AHB specification against DMA R-9 and the RTL | Specification corrected to the RTL | 0.7 | OPEN | |
| AUD-12 (2) | Clock gates in DMA and DSU that do not exist | Specification corrected to the RTL | 0.7 | OPEN | |
| AUD-12 (3) | Branch prediction: specification says none, RTL has a static predictor | Specification corrected to the RTL | 0.7 | OPEN | |
| AUD-12 (5) | Specifications name `spec/regs/<block>.yaml`, which does not exist | Specification corrected; final form in task 2.5 | 0.7 | OPEN | |
| AUD-12 (6) | Window numbers in AHB2APB and MEM | Specification corrected to the RTL | 0.7 | OPEN | |
| AUD-12 (7) | DMA CR reset value and SIZE 3 | Specification corrected to the RTL | 0.7 | OPEN | |
| INT-2 (DMA table) | DMA ID table still says 7..12 | Table corrected | 0.15 | OPEN | |
| APB-1 | The bridge's 16-pclk timeout abandons an access | To be dispositioned | 0.15 | OPEN | |
| AUD-8 | Hold against flush: matrix measured, formal not run | JasperGold | 5.7 | OPEN | |
| AUD-9 | DSU port names diverge from the specification | To be dispositioned | 0.15 | OPEN | |
| AUD-11 (track A rows) | Planned tests and assertions of the specifications not all written; DEBUG R-8 against D-18 | Closed block by block as each reaches the bar | 0.15, WP5, 6A | OPEN | |
| CORE-2 | Unused parameter in `garuda_core_top` and `csr_file` | To be dispositioned | 0.15 | OPEN | |
| ELEM-7 | `Docs/CORE_ELEMENT_VERIFICATION.md` cites covergroups that do not exist | To be dispositioned | 0.15 | OPEN | |
| FV-1 | IFV run not possible (no licence) | Superseded by JasperGold, run on K's machine | 5.7 | OPEN | |
| TOOL-12 | Lockstep does not read Spike's exit status | Exit status read | 1.1 | OPEN | |

## New entries

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
