# GARUDA SoC: bug register, track B

Peripherals, clocks and resets, the chip top, software, FPGA and the flow. Kept by the
owner of track B. `Docs/BUGS.md` is the register up to 2026-10-05 and is history: it gets
no new entries. Track A's entries are in `Docs/bugs/track_a.md`.

## How entries are numbered

| Kind of entry | ID | Next free on 2026-10-11 |
|---|---|---|
| A block of this track | the block's own prefix, continuing the numbers of `Docs/BUGS.md` | CLIC-2, CRG-4, GPIO-3, INT-4, PWM-5, SPIM-3, SPIS-8, UART-5; I2C-1 and TMR-1 are new |
| Anything that is not one block (tools, benches, audits, lint, simulation, verification runs) | the old prefix with the track letter | TOOL-B1, TB-B1, AUD-B1, LINT-B1, SIM-B1, VER-B1 |

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
| AUD-13 (timers) | A write to the read-only WDTVAL answers PSLVERR | A write to a read-only register is ignored; PSLVERR only for an offset that is not a register | 0.8 | OPEN | |
| AUD-13 (shim) | An offset that is not a register inside an IP range answers without an error | The shim gets a per-word map | 0.9 | OPEN | |
| GPIO-2 | GPIO specification and vendored block disagree in five places | Type `11` reserved; GPIOEN text corrected; non-registers answer PSLVERR through the shim's map | 0.9 | OPEN | |
| CRG-3 | Cause register records the request that ends last; SWRST write; divider release text | First cause held until the stretch ends; specification text for the other two | 0.10 | OPEN | |
| SIM-1 | pclk edge arrives one simulation step after hclk | Divider flop written so pclk is in the same step as hclk; `pclk_phase` from its own flop | 0.11 | OPEN | |
| PWM-2 | PWM pins driven combinationally | Register the four outputs; "low" takes effect one clock later | 0.12 | OPEN | |
| PWM-3 | Read-mux loop variable inferred as a latch | Remove the latched loop variable | 0.12 | OPEN | |
| UART-4 | One byte of the vendored UART register array is not reset | Recorded patch to the vendored file | 0.13 | OPEN | |
| TB-30 | `tb_chip` never gives the reset pin a falling edge | The bench makes a real falling edge | 0.13 | OPEN | |
| AUD-12 (4) | Watchdog warning: specification says one cycle, RTL holds it (D-17) | Specification corrected to the RTL | 0.14 | OPEN | |
| AUD-12 (5) | Specifications name `spec/regs/<block>.yaml`, which does not exist | Specification corrected; final form in task 2.5 | 0.14 | OPEN | |
| AUD-12 (8) | CLIC ID map, [N-6.3], four assertions and [N-7.6] describe the map before INT-2 and INT-3 | Specification corrected to the RTL | 0.14 | OPEN | |
| INT-2 | CLIC, DMA and TRM ID tables still say 7..12 | Tables corrected (CLIC and TRM here, DMA in track A) | 0.14, 0.15 | OPEN | |
| AUD-4 | The SDC sketch in PHYS section 5 does not elaborate and misses the ratios and `aon_clk` | Replaced by real constraints | 3.2 | OPEN | |
| SPIM-2 | Vendored SPI master: state `MODE` has no exit | To be dispositioned | 0.15 | OPEN | |
| UART-3 | Vendored UART: baud counter compares for equality | To be dispositioned | 0.15 | OPEN | |
| AUD-11 (track B rows) | Planned tests and assertions of the specifications not all written | Closed block by block as each reaches the bar | 0.15, 4.2, 6B | OPEN | |
| TOOL-13 | Simulation macros and the Icarus runner never use the exit status | Pass or fail from exit status and log | 1.1 | OPEN | |
| TOOL-14 | `scripts/run_coverage.sh` cannot fail because a test failed | Same | 1.1 | OPEN | |
| TOOL-15 | `scripts/expand_filelist.py` drops `-define` lines | Same | 1.1 | OPEN | |
| TOOL-16 | irun 15.2 prints `*E,IMPDLL` on every UVM run | Worked around; goes away if coverage moves to Xcelium | 1.8 | OPEN | |
| LINT-1 | Five HAL errors left, all dispositioned | Lint on three tools | 3.1 | OPEN | |

## New entries

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
