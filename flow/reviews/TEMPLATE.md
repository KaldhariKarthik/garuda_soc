# Review record: <block or task>

Written by the reviewer, not the author. Copy this file to `flow/reviews/<blk>.md`
(a block) or `flow/reviews/<task>.md` (a change that is not a block, for example
`wp0_track_b.md`), fill every section, and commit it yourself. A block is closed only
when this record is on `main`. Nothing in it is backdated: the date is the day of the
review, and a later re-review is a new section below the first, not an edit of it.

| | |
|---|---|
| Block or task | |
| Author (track) | |
| Reviewer (track) | |
| Commit reviewed | the full hash on `main` |
| Date | |
| Verdict | accepted / accepted with the changes below / not accepted |

## 1. What was read

Tick each one that was read in full, and write the path. Anything not read is said so.

| Item | Path | Read |
|---|---|---|
| Plan rows against the specification | `tb/<blk>/GARUDA_<BLK>_vplan.csv` | |
| Specification sections the change touches | `Design_Docs/...` | |
| Reference model | | |
| Coverage definitions | | |
| Properties | `rtl/<blk>/<blk>_sva.sv` | |
| Every waiver | `flow/cov/<blk>_exclusions.tcl` | |
| The RTL diff | `git diff <base>..<commit> -- rtl/<blk>` | |
| The test that fails before the fix (for a fix) | | |
| Bug entries | `Docs/bugs/track_<x>.md` | |

## 2. What was run by the reviewer

The commands, typed by the reviewer on the reviewer's machine, and what they printed.
"Not run" with the reason is an acceptable entry; a result copied from the author is not.

| Command | Result |
|---|---|
| | |

## 3. Questions asked and the answers

| # | Question | Answer | Settled |
|---|---|---|---|
| | | | |

## 4. Changes asked for

| # | What | Where | Done in commit |
|---|---|---|---|
| | | | |

## 5. Against the bar (blocks only)

| Criterion | Evidence | Met |
|---|---|---|
| Functional coverage 100% | | |
| Code coverage 100% after written waivers | | |
| Each unreachable waiver confirmed by the unreachability run | | |
| Every bound property proven, or bounded with the depth stated | | |
| 500 seeds accumulated, none failing in the last two weeks | | |
| Planted-defect run | | |

## 6. What the reviewer did not check

Said plainly, so that nobody reads the signature as covering it.

## Signature

Name, track, date.
