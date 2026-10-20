# H3. Bugs: register, fields, lifecycle, fix discipline

## Where
**Since 2026-10-15 the team register is the two-track one on `main`:** Track A's entries are in
[`Docs/bugs/track_a.md`](../bugs/track_a.md) (bold row = definition), track B's in `track_b.md`,
`Docs/BUGS.md` is history (archived 2026-10-21 as `Docs/bugs/archive/BUGS_HISTORY.md`), and `python3 tools/check_tree.py` (also run by `regress_a_report`)
fails on an ID defined twice. The per-block files and `tools/bugs/` described below were Track A's
working register before that; they stay on the Track A workstation and are not in the repository.
Working IDs were renamed when they moved (table in `track_a.md`, e.g. TB-44 -> TB-A2).

Old scheme, for reference: one file per block: [`Docs/bugs/<blk>.md`](../bugs/). [`Docs/bugs/archive/BUGS_HISTORY.md`](../bugs/archive/BUGS_HISTORY.md)
is **generated** (index, open items by priority, counts per block): never edit it
by hand. The register as it stood before the split (b90b481) is kept verbatim in
`Docs/bugs/HISTORY_2026.md`; the ID-by-ID mapping is `Docs/bugs/MIGRATION_2026-10-11.md`.
```
python3.12 tools/bugs/bugs.py check     # must pass before every push
python3.12 tools/bugs/bugs.py index     # regenerate Docs/BUGS.md
python3.12 tools/bugs/bugs.py open --prio P1
```

## Fields (one table per file, columns fixed; `bugs.py` parses it)
| Column | Rule |
|---|---|
| ID | Block prefix (T-, C-, DMA-, PWM-, ...) or cross-cutting prefix (TOOL-, VER-, AUD-, TB-). Never renumbered; a proven collision gets a new ID with the old one in Formerly. |
| Title | One line, what goes wrong (not the fix). |
| Status | OPEN, RULING-NEEDED, IN-PROGRESS, FIXED, CLOSED, WONTFIX, DUP |
| Prio | P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but has a workaround; P3 everything else (`flow/0_signoff_criteria.md`). Required while open. |
| Found-by | The check, review or person that found it. |
| Found | YYYY-MM-DD (`legacy` for migrated entries with no date). |
| Fixed-in | Commit SHA of the fix (`legacy` only for entries migrated from the pre-2026-10-11 register). |
| Regression test | The test or property that fails on the old RTL and passes on the fix. |
| Evidence | Log, record or file:line. |
| Formerly | Previous ID, if renumbered. |

Each ID also has a `### <ID>` entry under **Details** with the full write-up.

## Lifecycle
OPEN -> (RULING-NEEDED, if an owner decision is required) -> IN-PROGRESS (fix on a
branch) -> FIXED (commit SHA + regression test) -> CLOSED (only by the reviewer, for
review-tracked items). WONTFIX needs the reason and who accepted it. DUP names the
original. Every `ERRATUM <ID>` comment in `rtl/` or `tb/` must be a register ID.

## Fix discipline (every RTL or testbench fix)
1. **Commit 1, test first:** the test that fails on the current RTL, a log of it
   failing (`logs/<blk>/evidence/<ID>_before*.txt`), and an xfail row naming the bug.
2. **Commit 2, the fix:** the RTL or bench change, the property where one fits, the
   vPlan row and the specification updated, the bug set to FIXED with the commit SHA
   and the test, and the xfail row removed (a passing xfail is an error, H2).
3. The full regression of the block is unchanged otherwise.

## `bugs check` fails on
a duplicate ID; an unknown status or priority; an open item without P1..P3; a bad
Found date; FIXED without a SHA (or `legacy`) and, unless legacy, without a
regression test; an ID without a Details entry; an `ERRATUM <ID>` cited in rtl/ or
tb/ that is not in the register. Qualified by `tools/bugs/selftest_bugs.sh`.
