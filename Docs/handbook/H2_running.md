# H2. Running: verdicts, xfail, shims, seeds, logs

## One way to run
Every Track A run goes through `tools/run/garuda_run.py` with a manifest
(`tb/<blk>/run/*.toml`) and a make target in `flow/mk/track_a_run.mk`:
```
make -f flow/mk/track_a_run.mk help
make -f flow/mk/track_a_run.mk core_isa SEED=7
python3.12 tools/run/garuda_run.py suite tb/core/run/isa.toml --only add --seed 7
```
A manifest names the block, the suite, the bench(es) and the tests. `kind = "sim"`
builds one bench per test; `kind = "prog"` builds one bench (e.g. `tb_boot`) and
runs many programs on it, with optional Spike lockstep.

## Verdict of one test
**PASS** only if all hold:
1. the bench was built fresh in this run (old builds are deleted first);
2. the simulator exit status is 0 and the run did not time out;
3. the pass marker is present;
4. zero `[FAIL]`/`[SVA-FAIL]` lines, zero assertion failures, zero other `%Error` lines;
5. every `require` regex is present, no `forbid` regex is present, every `count` is exact;
6. Spike lockstep is MATCH when the test is lockstepped.

**FAIL**: anything else that ran. **BLOCKED**: the bench could not be built (tool
limit or source error), never PASS or FAIL.

Why so strict (measured, not assumed):
- With `+verilator+error+limit` raised, Verilator **exits 0 after assertion
  failures**: failures are counted from the log.
- **A process keeps executing after `$finish` until it yields** (Verilator 5.052,
  found 2026-10-11): a bench must skip its pass line by control flow, never by an
  earlier `$finish`.
- The repo Makefile macros run `xrun ...; grep ...` and ignore the exit status (TOOL-13).

## Classification (the xfail list)
Each suite names an xfail file (`tb/<blk>/run/xfail.tsv`): one row per **expected**
non-pass, each with a bug ID: `suite  test  FAIL|BLOCKED  <bug>  reason`.

| Class | Meaning | Suite result |
|---|---|---|
| OK | PASS, not listed | fine |
| XFAIL:<bug> / XBLOCK:<bug> | the listed failure happened as expected | fine |
| XPASS:<bug> | listed but PASSED: the list is stale | **error** |
| UNEXPECTED | FAIL or BLOCKED, not listed | **error** |

An xfail row is removed in the same commit as the fix (H3, fix discipline).

## Shims (declared Verilator-only deviations)
When a repo file cannot be compiled by the open tools, the manifest declares a
shim: a regex rewrite applied to a **generated copy** (never the repo file), with
the exact number of changed lines and a `shim:<ID>` marker on each. The run aborts
if the copy differs in any other way. Shims in use: `SHIM-SHM` (Cadence-only
`$shm_*` calls in `tb_boot.v`, 2 lines; removed by P0.8) and `SHIM-SB-SUMMARY`
(Verilator 5.052 front-end crash on `sb.summary(<cg>.get_coverage())`, 1 line per
element bench; removed by E7). Every log header lists the shims used.

## Simulators
`sim = "icarus"` in a test runs Icarus 12 (4-state) instead of Verilator. Used
where a bench depends on X (e.g. `tb_dsu_top`, TB-35). XCELIUM-ONLY items (H0) are
never claimed from either open simulator.

## Seeds
`SEED=<n>` (default 1) is passed as `+verilator+seed+<n>`; a bench that takes
`+SEED` gets it in its plusargs. Every log and history row records the seed, and
every log has a reproduce line. Measured 2026-10-11: on Verilator `tb_boot`'s
`+SEED` does vary the random wait states (three seeds, three traces); Xcelium to be
checked by Karthik.

## Log convention (all blocks)
| Path | What | In git |
|---|---|---|
| `logs/<blk>/summary/<suite>.tsv`, `.txt` | one row per test of the last full suite run | yes |
| `logs/<blk>/evidence/` | only logs and records cited by sign-off; 1 MB cap per file | yes |
| `logs/<blk>/history.tsv` | one row per test run, appended | yes |
| `logs/<blk>/raw/` | per-run logs, builds, commit/Spike logs, waves, coverage databases | no |

Log names: `<kind>_<name>[_s<seed>].log`, kind in sim, build, fv, cov, mut, lint,
regr, cosim, arch. Every log starts with a header (runner version, date, block,
suite, test, design SHA with an `rtl/` dirty flag and the count of uncommitted
paths, tool and version, seed, shims, command, reproduce line) and ends with a
footer (exit code, counts, verdict and the reason).

## Qualifying the runner (Gate A, and after any runner or tool change)
`make -f flow/mk/track_a_run.mk selftest_runners` must pass:
- planted outcomes: `[FAIL]` line, assertion failure (exit 0), `$error`, missing
  marker, `$fatal`, hang (timeout), missing `require`, present `forbid` must each
  FAIL; a source error must be BLOCKED; a clean run must PASS;
- a stale xfail entry must make its suite fail;
- SVA liveness (`tb/core/selftest/sva_selftest.sv`): every SVA form fires exactly
  as designed; Verilator deviations are pinned (`p_async_disable` fires once:
  `disable iff` is not asynchronous; `p_isunknown` never fires: 2-state);
- lockstep oracle controls (`lockstep_negctl.py`): N0 match; N1 an `add`->`sub`
  image FAILs; N2 a flipped value DIVERGEs; N3 a short RTL log and N4 a short Spike
  log MISMATCH; N5 Spike exiting non-zero after a full log fails (TOOL-12);

A control that "passes" proves nothing until it is shown to change the outcome:
two controls were too weak on first try (N4 cut a Spike log that runs on into the
spin loop; N1 corrupted a prologue `add` with zero operands) and were fixed before
being trusted.
