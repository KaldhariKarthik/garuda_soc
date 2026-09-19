# GARUDA Block Design Specification — Template

**GARUDA-DOC-001 Rev 1.0.** Every block spec in this project has exactly these sections,
in this order, with these numbers. A reviewer, a new engineer and a script all know where
to look, and a missing section is visible as a gap rather than hidden in prose.

## Rules that apply to every spec

1. **No cross-block facts are written by hand.** Frequencies, addresses, block numbers,
   CLIC IDs, DMA channels, pins and APB windows come from `GARUDA-SYS-001` via
   `{{include: gen/tables.md#T-n}}`. If a value appears literally in a spec's prose, that
   is a defect, and `tools/check_specs.py` fails on it.
2. **No edit history in the body.** No "(was 200 MHz)", no "corrected from". History lives
   in §0.2 and in the ADR that made the change. The body states only what is true now.
3. **Every normative statement is numbered and testable.** `[N-3.2]` style. Section 11's
   verification matrix references those numbers, so an untested requirement is visible.
4. **Every design choice points at an ADR.** If a choice has no ADR, either it is not a
   choice (it follows from a requirement) or the ADR is missing.
5. **Timing is drawn, not described.** Any multi-cycle protocol needs a waveform. Blocks
   whose specs described handshakes in prose instead of waveforms are where I-1 and D-1
   came from.
6. **Assertions are in the spec, in SVA.** §10 holds the assertions that the testbench
   binds. The spec is the source; the testbench imports it.

## Section structure

| § | Title | Content |
|---|---|---|
| 0.1 | Identity | Doc ID, revision, date, status, owner, block number (generated) |
| 0.2 | Revision history | One row per revision: what changed and which ADR drove it |
| 0.3 | Normative references | With revisions. `GARUDA-SYS-001` is always first |
| 1 | Purpose and scope | What the block does, what it explicitly does not |
| 2 | Requirements | `[R-n]` numbered. Where each comes from (system need, protocol, ADR) |
| 3 | Block diagram | Boundary, sub-blocks, every port on the boundary |
| 4 | Sub-block inventory | Table: name, seq/comb, RTL file, one-line role |
| 5 | Interfaces | Every port: name, direction, width, domain, reset value, description |
| 6 | Register map | Offset, name, width, access, reset value, field-by-field. Machine-readable source in `spec/regs/<block>.yaml` |
| 7 | Functional description | `[N-n]` normative statements. State machines as explicit state tables |
| 8 | Timing | Waveforms for every protocol phase, wait state, back-to-back and error case |
| 9 | Clock, reset and power | Domains, CDC (or a statement that there is none and why), reset domain, reset values |
| 10 | Assertions | SVA the testbench binds. Each maps to a `[N-n]` |
| 11 | Verification plan | Matrix: requirement → test name → oracle → coverage goal → status |
| 12 | Design decisions | Table of ADR references. No rationale restated, only the pointer |
| 13 | Not implemented | What was considered and excluded, with why. Prevents re-litigation |
| 14 | Open items | `OPEN-n` with owner and what unblocks it. Empty is a valid section |
| 15 | Errata | Fixed bugs: symptom, root cause, fix, test that catches a regression |

## Machine readability

Each spec ships three machine-readable companions, and the prose is generated from or
checked against them:

- `spec/regs/<block>.yaml` — the register map. Generates the §6 table, the RTL register
  bank's field decode, `sw/common/<block>_regs.h`, and a UVM-style register model for the
  testbench. A register that exists in RTL but not here fails CI.
- `spec/ports/<block>.yaml` — the port list. Generates the §5 table and an instantiation
  template, and is checked against the RTL module header, which is how the `dma_top`
  naming mismatch and the `clic_mintthresh_o` ghost port would have been caught.
- `spec/verif/<block>.yaml` — the §11 matrix. Test names are checked to exist in the
  Makefile, so a requirement cannot silently have no test.

## Human readability

- A reader who needs one fact reads one table. A reader who needs the design reads §1, §3,
  §7 in order and nothing else.
- Rationale is in §12 by pointer, never inline. The old specs buried decisions in
  paragraphs of narrative, which is why the same decision got made three different ways in
  three documents.
- No section exceeds two screens without a table or a waveform breaking it up.
