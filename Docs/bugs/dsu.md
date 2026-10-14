# Bugs: DSU coprocessor (rtl/dsu)

Owner: Track A. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).
Priorities: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).

<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. Run `bugs.py check` before pushing. -->
| ID | Title | Status | Prio | Found-by | Found | Fixed-in | Regression test | Evidence | Formerly |
|---|---|---|---|---|---|---|---|---|---|
| OVF-1 | 48-bit carry-save path dropped maj[47]; | FIXED | P1 | ArchDSU oracle sweep | 2026-09-19 | legacy | `test_dsu` + clamp walk 33 168/0; oracle sweep 0/2000 at every magnitude (was 84 | HISTORY_2026.md L89 | - |
| DSU-13 | A trap flush discarded a committed accumulate: the pending product belongs to a MAC that has already left EX, but flu... | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L322 | - |
| DSU-11 | One accumulator was corrupted by an instruction for another | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L323 | - |
| DSU-12 | MACSAT behind a MAC on the same accumulator is held one cycle by the DSU interlock, but the saturate ran in the held ... | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L324 | - |
| DSU-10 | The four casts were semantic no-ops | FIXED | P2 | - | legacy | legacy | - | HISTORY_2026.md L822 | - |
| TB-35 | tb_dsu_top ends its stimulus on an X sentinel that 2-state simulators never see | FIXED | P3 | audit F-09; Track A baseline | 2026-10-04 | 145ac53 | dsu/model (tb_dsu_top) | Docs/VERIFICATION_LOG_2026-10-11.md | audit F-09 |
| DSU-1 | still applies, so this | FIXED | - | RTL comment | legacy | legacy | - | rtl/dsu/dsu_stall.v:46 | - |
| DSU-2 | (FLAG-A) changed which values reach the | FIXED | - | RTL comment | legacy | legacy | - | rtl/dsu/barrel_shifter.v:37 | - |
| DSU-3 | (FLAG-C / FLAG-2) -- compute -> readback was not interlocked | FIXED | - | RTL comment | legacy | legacy | - | rtl/dsu/dsu_stall.v:23 | - |
| DSU-4 | the second pipeline stage did not self-drain | FIXED | - | RTL comment | legacy | legacy | - | rtl/dsu/mac_unit.v:209 | - |
| DSU-5 | the arithmetic right shift was actually LOGICAL | FIXED | - | RTL comment | legacy | legacy | - | rtl/dsu/barrel_shifter.v:17 | - |
| DSU-6 | (FLAG-D) -- MACSHIFT amount out of range | FIXED | - | RTL comment | legacy | legacy | - | rtl/dsu/dsu_decoder.v:73 | - |
| DSU-7 | reserved I-type immediate bits | FIXED | - | RTL comment | legacy | legacy | - | rtl/dsu/dsu_decoder.v:88 | - |
| DSU-8 | (FLAG-E) -- an overflow coinciding with its own clear | FIXED | - | RTL comment | legacy | legacy | - | rtl/dsu/overflow_flag.v:21 | - |
| DSU-9 | dsu_busy was the ONE DSU output not gated by | FIXED | - | RTL comment | legacy | legacy | - | rtl/dsu/dsu_top.v:161 | - |
| TB-41 | garuda_cov cg_dsu decodes MACSHIFT with the R-type layout, so its bins can never be hit | IN-PROGRESS | P3 | Track A coverage closure (cg_dsu macshift bins never hit although t_cov_dsu executes MACSHIFT on every accumulator) | 2026-10-11 | - | cov_dsu_report cg_dsu | logs/dsu/summary/cov_dsu.txt | - |
| DSU-14 | A `csrr dsu_ovf` directly after the instruction that overflows reads the old flag (0): the overflow folds one cycle later and the CSR read is not interlocked | RULING-NEEDED | P2 | Track A planted-defect run (5.11: a back-to-back overflow + CSR read written to kill the ovf_clear_drops_set mutant) | 2026-10-11 | - | core/covtests t_dsu_ovf_raw (xfail DSU-14) | logs/dsu/evidence/DSU-14_before.txt | - |
| DSU-15 | MACSAT writes no rd and clamps the accumulator to int32 (+-2.0), where the spec defines rd = the accumulator saturated to Q1.15 (+-1.0) in rd[15:0] | RULING-NEEDED | P2 | Track A wrap-up: vPlan trace of DSU F06 (a_macsat had no implementation) | 2026-10-12 | - | core/covtests t_dsu_macsat_rd (xfail DSU-15) | logs/dsu/evidence/DSU-15_before.txt | - |
| TB-45 | The DSU reference models defer to the RTL by their own rule ("where this file and the RTL disagree, the RTL wins"), so model compare cannot find a deviation from the specification | OPEN | P2 | Track A wrap-up (DSU-15 slipped past both oracles) | 2026-10-12 | - | - | tools/golden/DSU_Golden.py header; logs/dsu/evidence/DSU-15_before.txt | - |
| DSU-16 | The spec says MACDOT puts its two products into two accumulators; the RTL (and both models) add both products into the one selected accumulator, which is what a 2-element dot product needs | RULING-NEEDED | P3 | Track A wrap-up (DSU vPlan coverage, cg_dsu_ovf walk) | 2026-10-12 | - | - | rtl/dsu/operand_router.v:29-30 (rs1[31:16] x rs2[31:16] into the same mac_unit); GARUDA-DSU-SPEC-001 section 7 table and [N-7.2] | - |
| DSU-17 | MACSHIFT is not the specified instruction: the spec has `acc >>>= rs1[4:0]` (in place, arithmetic, amount from a register, no rd); the RTL shifts by an immediate 0..47, left or right, into rd, and leaves the accumulator unchanged | RULING-NEEDED | P2 | Track A wrap-up (DSU sub-unit benches written from the spec) | 2026-10-12 | - | - | rtl/dsu/dsu_decoder.v (I-type, imm = {rsvd[11:9], left[8], acc[7:6], amt[5:0]}, writes_regfile); GARUDA-DSU-SPEC-001 section 7 table | - |
| DSU-18 | An accumulate that overflows, followed at once by MACCLEAR or MACLOAD of the same accumulator, never sets the sticky overflow flag | RULING-NEEDED | P3 | Track A wrap-up: tb_dsu_mac_unit_spec (sequential reference) | 2026-10-12 | - | dsu/units_spec tb_dsu_top_ovf_b2b (xfail DSU-18) | logs/dsu/evidence/DSU-18_before.txt | - |
| TB-42 | tb_dsu_top cannot see DSU timing or flag-history defects: one instruction per vector with idle cycles, so no read directly behind its MAC and no overflow flag carried across instructions | OPEN | P3 | Track A planted-defect run (mutants no_interlock, ovf_not_sticky, ovf_clear_drops_set survive the block bench) | 2026-10-11 | - | dsu_mut (core-level rows); fv_dsu dsu_mut_* | logs/dsu/evidence/dsu_mut_2026-10-11.txt | - |
| TB-43 | 6 of the 13 dsu-verification sub-block benches disagree with the current DSU RTL once their pasted DUT copies are removed (none is an RTL correctness defect; 3 need D0 rulings, 3 are stale or wrong benches) | RULING-NEEDED | P3 | Track A D1 triage (tools/gen/port_dsu_benches.py, 2026-10-11) | 2026-10-11 | - | dsu/units (7 pass; 6 xfail TB-43) | logs/dsu/evidence/D1_dsu_units_2026-10-11.txt | - |

## Details

### OVF-1

*From `Docs/BUGS.md` at b90b481, line 89, section "1b. Rev 4.0 migration — 2026-09-19".*

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| **OVF-1** | 2 DSU | FIXED | high (wrong overflow flag, top quarter of range) | 48-bit carry-save path dropped `maj[47]`; the adder's bit 48 carried no sign. Path widened to 49 bits, operands sign-extended before compression; `DSUModel` updated. Was open since `Docs/ORACLES.md` found it and missing from this register. Closes OPEN-9. | ArchDSU oracle sweep | `test_dsu` + clamp walk 33 168/0; oracle sweep 0/2000 at every magnitude (was 845–1023/2000) |

### DSU-13

*From `Docs/BUGS.md` at b90b481, line 322, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **DSU-13** | `rtl/dsu/mac_unit.v` | FIXED | A trap flush discarded a committed accumulate: the pending product belongs to a MAC that has already left EX, but `flush` cleared it. A MAC followed by an instruction that trapped, or on which an interrupt was taken, lost its product silently. `t_hold_flush_matrix` bits 9, 10. |

### DSU-11

*From `Docs/BUGS.md` at b90b481, line 323, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **DSU-11** | `rtl/dsu/mac_unit.v` | FIXED | **One accumulator was corrupted by an instruction for another.** `load`/`clear` are cluster-wide decodes; the accumulator mux used them without checking the instruction addressed this unit. `MAC acc0; MACCLEAR acc1` set acc0 to 0, and `MAC acc0; MACLOAD acc1` loaded acc0 with the other instruction's operand. `tb_dsu_top` could not see it because it inserts an idle cycle after every instruction. `t_dsu_b2b` bits 0, 1. |

### DSU-12

*From `Docs/BUGS.md` at b90b481, line 324, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **DSU-12** | `rtl/dsu/dsu_top.v` | FIXED | MACSAT behind a MAC on the same accumulator is held one cycle by the DSU interlock, but the saturate ran in the held cycle anyway: it clamped the stale accumulator, its write-back beat the pending fold, the product was lost and the sticky overflow flag was raised for a value that never existed. `t_dsu_b2b` bit 2. |

### DSU-10

*From `Docs/BUGS.md` at b90b481, line 822, section "5. Block 2 — DSU".*

| ID | Status | Severity | One-line |
|---|---|---|---|
| **DSU-10** | **FIXED** | medium (synthesis blocker) | `rtl/dsu/mac_unit.v:43–44` connected `$signed(a0)` / `$signed(b0)` to `mult_16x16`'s ports. Yosys 0.69 aborted with an internal assertion: `Assert 'arg->is_signed == sig.as_wire()->is_signed' failed` (genrtlil.cc:2145). **The four casts were semantic no-ops** — `mult_16x16` already declares `input wire signed [15:0] a, b`, and a port connection's signedness is governed by the *formal*, not the actual, so the multiply was already signed with or without them. **Fix:** delete them. Icarus and Verilator both accept the casts, which is why this stayed invisible until the first full-SoC synthesis run. DSU block TB re-run after the change: 90/90 tests, 0 mismatches. Unblocks full-SoC synthesis. |

### TB-35

`tb/dsu/tb_dsu_top.sv:138` counts tests until `stim[...] !== 32'hxxxx_xxxx`. Under 2-state Verilator the sentinel never matches, so the bench reads past the 445 records (40960 compared, 162060 mismatches, all from test 445 on). On Icarus (4-state) it is 445/0. Fix (D2/E7): size the run from the generator's record count (+NTESTS) instead of a sentinel.

**2026-10-11:** Fixed for the coverage work: the bench counts the data words of both vector files ($fscanf/$fgets, comments skipped) and fails if they are inconsistent (checked with a truncated expected file). Verilator now 445 compared / 0 mismatches, same as Icarus; xfail removed.

**2026-10-14:** FIXED by Karthik in 145ac53 (same defect); his count_words kept on the rebase, Track A version dropped.

### DSU-1

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/dsu/dsu_stall.v:46`:*

```
// purposes. The one-shot guard from ERRATUM DSU-1 still applies, so this
```

### DSU-2

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/dsu/barrel_shifter.v:37`:*

```
// clear/load, and ERRATUM DSU-2 (FLAG-A) changed which values reach the
```

### DSU-3

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/dsu/dsu_stall.v:23`:*

```
// ERRATUM DSU-3 (FLAG-C / FLAG-2) -- compute -> readback was not interlocked
```

### DSU-4

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/dsu/mac_unit.v:209`:*

```
// ERRATUM DSU-4 -- the second pipeline stage did not self-drain
```

### DSU-5

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/dsu/barrel_shifter.v:17`:*

```
// ERRATUM DSU-5 -- the arithmetic right shift was actually LOGICAL
```

### DSU-6

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/dsu/dsu_decoder.v:73`:*

```
// ERRATUM DSU-6 (FLAG-D) -- MACSHIFT amount out of range
```

### DSU-7

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/dsu/dsu_decoder.v:88`:*

```
// ERRATUM DSU-7 -- reserved I-type immediate bits
```

### DSU-8

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/dsu/overflow_flag.v:21`:*

```
// ERRATUM DSU-8 (FLAG-E) -- an overflow coinciding with its own clear
```

### DSU-9

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/dsu/dsu_top.v:161`:*

```
// ERRATUM DSU-9 -- dsu_busy was the ONE DSU output not gated by
```

### TB-41

MACSHIFT is I-type: funct3 = 001, imm = {left, acc_sel, amt}, so acc_sel is instr[27:26] and instr[31:27] is not a funct5. tb/cov/garuda_cov.sv took funct5 = instr[31:27] and acc = instr[26:25] for every DSU op: the macshift bin (funct5 9) and its three accumulator crosses were unhittable, and MACSHIFTs were credited to MAC_SEL..MACDOT / wrong accumulators. Fix: decode MACSHIFT by funct3 and take its accumulator from instr[27:26]. Coverage-model defect, no design impact.

### DSU-14

The accumulate's overflow is detected in its stage-2 fold, the cycle after the MAC leaves EX (`mac_unit` overflow = accum_ovf & pending & is_accum). The read-to-clear CSR dsu_ovf (0xBC0) reads the flag register in EX with no interlock, so in `MACDOT (overflows); csrr t0, 0xBC0` the read returns 0. The flag is not lost: the fold sets it in the very cycle the read clears it, set beats clear ([N-6.9] / a_ovf_set_beats_clear), so the next read returns 1. Architecturally (sequential semantics; ArchDSU, the Spike extension) the first read must return 1 and the second 0. Firmware following [N-6.9] ("check it after a computation") with the natural `MAC; csrr; branch` misses the overflow of that computation and reports it one check late, against the next computation. Found by t_dsu_ovf_raw: TOHOST=0x13 (fail code 9, dsu_ovf mismatch), commit log 0x100007a0 csrr -> t0 = 0. The spec's RAW interlock (§7.3, [N-7.6]-[N-7.8]) covers accumulator reads only; the overflow flag has the same one-cycle latency and no rule.

Options for the ruling: (A) extend the interlock: `csrr` of 0xBC0 in EX while any accumulate fold is pending holds one cycle (dsu_busy), so the read sees the folded flag and the clear lands after the set (smallest change, one stall cycle, only in this pattern); (B) forward the folding overflow into the CSR read value and let that read's clear also clear the forwarded set (no stall; changes the set-beats-clear rule for the CSR clear); (C) document a one-instruction latency for dsu_ovf in the TRM and DSU spec (firmware puts one instruction between). (A) is recommended. Until the ruling, t_dsu_ovf_raw is an xfail naming DSU-14.

### DSU-15

**MACSAT does not do what the specification says.** GARUDA-DSU-SPEC-001 section 7 lists `MACSAT rd` as "rd = acc saturated to Q1.15 in rd[15:0]", writing rd, and [N-7.3] calls it "the normal way a result re-enters the RV32IM datapath". The RTL never writes rd for MACSAT (`dsu_decoder.v:133`, `writes_regfile` = MACRD_LO | MACRD_HI | MACSHIFT) and instead clamps the selected accumulator **in place** to the int32 range, i.e. +-2.0 in Q18.30 (`saturation_unit.v`), not +-1.0. Firmware written to the spec reads a stale register; a value between 1.0 and 2.0 is not saturated at all. Neither existing oracle could see it: `tools/golden/DSU_Golden.py` mirrors `saturation_unit.v` line by line, and the ArchDSU checker of `t_cov_dsu` follows the RTL. Found when the vPlan row a_macsat (F06) had nothing behind it. Reproducer `sw/tests/t_dsu_macsat_rd.S` (0.5, +1.5, -1.5): all three cases fail, code 7. **Ruling needed:** (A) RTL: MACSAT writes rd = clamp(acc, +-1.0) as Q1.15 (acc[30:15] when in range), with or without the in-place clamp; or (B) spec: MACSAT is an in-place int32 clamp, firmware reads with MACRD_LO and converts. The vPlan text (F06) follows the spec. Either way `DSU_Golden.py` and ArchDSU change with it.

### TB-45

`tools/golden/DSU_Golden.py` states its rule in its header: "RTL source of truth: rtl/dsu ... Where this file and the RTL disagree, the RTL wins and this file is the bug". Both of its models (the cycle-accurate DSUModel, and ArchDSU for the expected values of t_cov_dsu) therefore follow the RTL, including where the RTL departs from GARUDA-DSU-SPEC-001. That is how DSU-15 (MACSAT) stayed invisible to every DSU test. It breaks the plan's independence rule (models from the specification and the rulings, never from the RTL). Mitigation today: the DSU vPlan rows are traced (`tools/run/vplan_trace.py dsu`) and each spec item has a directed check (t_dsu_macsat_rd, t_dsu_gate) or a ruling entry. **Fix:** in the D2 DSU environment (with TB-42), an ArchDSU written from the specification; until then, every DSU ruling must be applied to both models by hand.

### DSU-16

GARUDA-DSU-SPEC-001 section 7 lists `MACDOT rs1, rs2` as "Two products into two accumulators", and [N-7.2] says it "issues two 16x16 products into two different accumulators in one instruction, which is what makes a 2-element dot product one cycle rather than two". The RTL feeds rs1[15:0] x rs2[15:0] and rs1[31:16] x rs2[31:16] into the SAME mac_unit (`operand_router.v:29-30`, `dot_active`), so MACDOT adds both products into the one selected accumulator: acc += lo*lo + hi*hi. That is the dot product the sentence itself motivates; "two different accumulators" contradicts it. Both models (DSUModel, ArchDSU) and every test follow the RTL. **Proposed ruling:** the specification text is wrong; reword both places to "acc += rs1.lo x rs2.lo + rs1.hi x rs2.hi into the selected accumulator". No RTL change.

### DSU-17

GARUDA-DSU-SPEC-001 section 7 lists `MACSHIFT rs1` as `acc >>>= rs1[4:0]`, arithmetic: the accumulator is shifted in place by an amount from a register and nothing is written to rd. Section 7.16 relies on exactly that ("`MACSHIFT` used to renormalise between blocks", block floating-point in firmware). The RTL implements a different instruction: I-type (funct3 001), immediate = {reserved[11:9], left[8], acc_sel[7:6], amount[5:0]}, amounts 0..47 (48..63 illegal, DSU-6), left or arithmetic right, the low 32 bits of the shifted value written to rd, the accumulator unchanged. Firmware cannot renormalise an accumulator in place: it can read a shifted copy, but MACLOAD only reloads 32 bits. Both models, t_cov_dsu and the decoder benches follow the RTL. Related open D0 items (amount 48..63, reserved immediate bits) only exist in the RTL's form. **Ruling needed:** (A) RTL becomes the specified in-place shift, or (B) the spec documents the I-type read-shifted form and drops the renormalisation claim of 7.16 (or adds a write-back variant).

### DSU-18

An accumulate's overflow is detected in its stage-2 fold, the cycle after it leaves EX. A MACCLEAR, MACLOAD (or saturate write-back) of the same accumulator in that next cycle replaces the accumulator and discards the pending product (`mac_unit.v` pend_clr), which is right for the value (the younger op wins) but also discards its overflow: the sticky flag is never set, although the MAC retired and overflowed ([N-6.7], [N-6.9]; sequential semantics, ArchDSU). In dsu_top the saturate case is protected by the interlock (MACSAT reads the accumulator, so it is held one cycle: DSU-12); MACCLEAR and MACLOAD are not readers, so `MAC (overflows); MACCLEAR` and `MAC (overflows); MACLOAD` lose the overflow at top level. Reproducer `tb/dsu/units_spec/tb_dsu_top_ovf_b2b.sv`: overflow then idle / then MAC set the flag (controls); then MACCLEAR / MACLOAD at once leave it clear. No existing DSU stimulus could see it: every vector set drains one idle cycle between instructions, and t_dsu_b2b has no overflow. Impact: low (the overwritten result is discarded anyway), but the flag is the only overflow report firmware has. **Ruling:** (A) let the fold's overflow be recorded even when the product is discarded (one gate), or (B) document that a clear/load straight after an accumulate drops that accumulate's overflow.

### TB-42

tb_dsu_top replays one decoded instruction per stimulus vector and compares results per vector, with idle cycles in between. It therefore never issues an accumulator read in the cycle after the MAC that writes it (the interlock case) and never carries the overflow flag across instructions. The planted-defect run (tools/gen/gen_dsu_mutants.py) shows it: no_interlock (dsu_busy tied low), ovf_not_sticky and ovf_clear_drops_set pass the block bench (5 of 8 mutants killed there). The first two are killed at core level by t_cov_dsu (ArchDSU-checked program; the bound DSU properties fire), the third by formal (a_ovf_set_beats_clear, fv_dsu dsu_mut_ovf_clear_drops_set). Fix (plan D2): the DSU environment drives back-to-back instruction streams with flush injection and checks the flag history.

### TB-43

The dsu-verification branch (391e8e0, 13 single-file sub-block benches, 2026-08-30) carried a pasted copy of every module it tested, so it verified the copies. tools/gen/port_dsu_benches.py removes the copies and compiles each bench against rtl/dsu (class covergroups compiled out under Verilator only, TOOL-23). 7 pass on the real RTL (csa_3to2, kogge_stone_49, mult_16x16, operand_router, readback_mux, result_selector, saturation_unit) and join the DSU regression (dsu_units). The other 6, first failure each, classified against GARUDA-DSU-SPEC-001:
- barrel_shifter (315/1888): arithmetic right shift by 48..63 of a negative accumulator: bench expects 0, RTL sign-fills (0xFFFF_FFFF). Amounts 48..63 are undefined in the spec (FLAG-D): D0 ruling "MACSHIFT width".
- decoder (355/3597): MACSHIFT with reserved immediate bits [11:9] set (0x2000100B): bench expects a legal shift, RTL flags it illegal. The spec is silent on reserved bits: D0 ruling.
- mac_unit (1158/1185), mac_cluster (1501/1530): mismatches from the first idle cycle; the benches model the accumulate as single-stage, the RTL folds in a second stage (DSU-12/DSU-13 fixes, after the benches were written). Stale benches: rewrite against the spec timing (plan D2 environment).
- overflow_flag (237/1532, + its own SVA a_clear_wins_next_cycle): the bench requires clear-beats-set; the spec says set beats a same-cycle clear ([N-6.9]) and the RTL does that (a_ovf_set_beats_clear PROVEN). Bench wrong.
- dsu_stall (105/4543): "FINDING1": after a MACRD / MACSAT the RTL interlocks a read of the same accumulator; the bench expects no stall (the RTL counts MACRD_LO/HI/MACSAT as two-cycle). One extra stall cycle, no wrong result: performance only; ruling whether the interlock should be narrowed.
