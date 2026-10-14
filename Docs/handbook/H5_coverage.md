# H5. Coverage: four categories, reported separately

## The flow (open tools, built 2026-10-11)
```
make -f flow/mk/track_a.mk cov_a              # every core + DSU suite with --coverage, then both reports
make -f flow/mk/track_a.mk cov_core_report    # logs/core/summary/cov_core.txt
make -f flow/mk/track_a.mk cov_dsu_report     # logs/dsu/summary/cov_dsu.txt
make -f flow/mk/track_a.mk fv_cov_unreach     # formal evidence behind the exclusions
```
- `garuda_run.py suite <m> --coverage`: Verilator `--coverage-line/-toggle/-expr/-fsm/-user`,
  one `coverage.dat` per run, outputs `<suite>.cov.*` (the normal results are untouched).
  `tb_boot` suites use `cov_flist` = `tb/soc/filelist_boot_cov.f` (bound models
  `tb/cov/garuda_cov.sv` + `garuda_cov_ext.sv`).
- `tools/cov/cov_report.py tb/<blk>/cov/cov.toml`: merges only passing runs, per
  module definition; design code (per metric per module), design functional
  (covergroup bins; illegal/ignore bins out of the target, an illegal bin hit is an
  error), testbench code (reported, not sign-off), every waiver with its reason, and
  every remaining hole with its source line. Exit 1 below target or on a waiver error.
- **Targets:** design code >= 95 % for every metric of every RTL module; design
  functional 100 % of bins; both after reviewed waivers.

## Waivers (exclusions): when and how
`tb/<blk>/cov/<blk>_waivers.toml`, one `[[waiver]]` per exclusion: id, metric, file,
match (regex on the point label), **category**, **reason**, **evidence**, reviewer.

| Category | Allowed when | Evidence |
|---|---|---|
| `constant` | a literal constant in the RTL, or a register proven constant | the RTL line, or a PROVEN property in `tb/core/formal/cov_const_sva.sv` |
| `unreachable` | the point cannot happen | PROVEN negation (fv_cov), a full `case` default, or contradictory conditions (written interval proof) |
| `not-connected` | an input tied off until a planned change | the tie-off line + the plan item (remove the waiver when it lands) |
| `ignore` | a bin the SOURCE declares `ignore_bins`, which Verilator drops (COVERIGN on `binsof`/`intersect` in cross selects) | the source line of the `ignore_bins` |
| `tool` | a simulator defect loses a point that other metrics show is exercised (e.g. TOOL-25: expression rows of an `if` whose line and branch are hit) | a TOOL-&lt;n&gt; bug with a reproducer, and the metric that shows the point is exercised. Verilator only: never exported to `flow/cov/<blk>_exclusions.tcl` (IMC measures it itself); the report fails once the point counts |

- A **reachable** hole is never waived: it gets a test. A formal proof that FAILS means
  the point is reachable (that is how BUS-E and the PC-bit-1 tests were found).
- `cov_report.py` fails on a stale waiver (matches nothing) and on a waiver that
  matches a covered point (except `ignore`), so a wrong claim cannot survive.
- Toggle waivers are generated per file with the exact uncovered points by
  `tools/cov/gen_toggle_waivers.py core|dsu` from a rule table (rule = signals, bits,
  category, reason, evidence); holes no rule explains are printed for a decision.

| Category | Shows | Measured by |
|---|---|---|
| **Requirements** | every requirement (spec `[N-x.y]` tags, vPlan rows) has a check that passes | traceability from tags and vPlan rows to evidence |
| **Design-behaviour functional** | the required scenarios happened in the design | covergroups and cover-property arrays sampled from DUT ports, RVFI and DUT state |
| **RTL code** | statements, branches, expressions, FSM states/arcs, toggles of the block's own RTL were exercised | Verilator `--coverage-line/-toggle/-expr/-fsm/-user --coverage-per-instance` (5.052 has all of these); **IMC on Xcelium is authoritative at gates** (`-covdut` + a design-only coverage file) |
| **Testbench** | stimulus generated, checkers activated, error paths exercised | stimulus covergroups, checker-activation counters, every assert's antecedent cover, TB code coverage of `tb/**` |

The four numbers are never merged into one. Sign-off uses the RTL numbers;
testbench holes are fixed, or the unused testbench code is removed or justified.

## Verilator 5.052 covergroups (measured 2026-10-11, TOOL-22)
- Covergroups compile and sample, `iff` guards included, but **`get_coverage()`
  returns 0.0 %** in every build. A bench line such as `FUNCTIONAL COVERAGE = 0.00 %`
  printed under Verilator means nothing and is never quoted.
- With `--coverage-user` each bin's hit count is written to `coverage.dat`
  (`t=covergroup`, `page=v_covergroup/<cg>`); for `tb_clic_ctrl` the counts equal
  the bench's own counters exactly. **Functional numbers from Verilator come
  from `coverage.dat` via `verilator_coverage`**, never from `get_coverage()`.
- The normal runner build has no `--coverage*` option, so bins are not recorded
  there at all; the coverage build is plan E9.
- A bench whose evidence must not depend on this (for example the strict `>`
  of `tb_clic_ctrl`, ELEM-7) also counts its key bins in plain variables and
  checks them at the end.

## Rules
- **Code coverage is not correctness.** A line can execute without its result
  being checked; observability is measured by mutation (H8).
- No artificial bins to reach 100%. Unreachable bins are listed separately, not deleted.
- No removal of meaningful RTL or testbench logic to raise a percentage: dead-code
  removal is a design decision with its own bug or decision entry.
- Design-only selection: bound SVA modules and checkers are counted as testbench,
  never as design (the CLIC/timers/PWM/GPIO/CRG environments currently count their
  bound `*_sva` as design and waive pieces of it; to be corrected in plan 4.2).

## Waivers (exclusions)
Kept in `tb/<blk>/cov/<blk>_waivers.yaml` (core) or `flow/cov/<blk>_exclusions.tcl`
(team IMC format): coverage point, reason, evidence, reviewer.

| Kind | Evidence required |
|---|---|
| Constant by design or specification (tie-off, reserved bits) | spec or decision **and** a formal proof that it is constant |
| Unreachable by construction | a PROVEN formal unreachability property (H6) |
| Fixed by a parameter in GARUDA's configuration | the parameter value and the proof under it |

Never waived: anything reachable that was simply not hit (a test gap), anything
that would hide a bug, coverage from failing runs. `waiver_check` fails on a stale,
unproven or unreviewed waiver and on any hole without one.

## Why 100% may still be missed, and what to do
| Reason | Action |
|---|---|
| Reachable, not yet hit | write the test; never waive |
| Instance vs module (address bits never toggle in the chip) | merge block + chip per module, or waive per instance with that reason |
| Only reachable with illegal stimulus | a dedicated negative test, or a waiver citing the protocol checker |
| Tool differences (Verilator vs IMC counting) | the IMC number is authoritative; every difference explained |
| Real dead code proven by formal | not a waiver: a design question for the owner |
