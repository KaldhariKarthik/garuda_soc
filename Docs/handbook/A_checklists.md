# A. Checklists

## Per fix (RTL or testbench)
- [ ] Bug in `Docs/bugs/<blk>.md` with priority; ruling recorded if it needed one
- [ ] Design note approved (major items, H0)
- [ ] Commit 1: failing test + `evidence/<ID>_before*` log + xfail row
- [ ] Commit 2: fix with `// ERRATUM <ID>` + property (+ cover) + vPlan row + spec + bug FIXED (SHA, test) + xfail removed
- [ ] Block regression unchanged otherwise; `python3 tools/check_tree.py` passes

## Per block (recipe R1-R12)
- [ ] R1 plan rows checked against the spec  - [ ] R2 register description and model
- [ ] R3 agents  - [ ] R4 reference model from the spec + one pins-only check
- [ ] R5 covergroups (four categories, H5)  - [ ] R6 bound properties
- [ ] R7 register, directed and random tests, seeds  - [ ] R8 coverage merge + waivers with proof
- [ ] R9 formal (H6 classes)  - [ ] R10 mutation (H8)
- [ ] R11 make target, plan rows, bugs  - [ ] R12 review record by the other track

## Before every push
- [ ] `make -f flow/mk/track_a_run.mk selftest_runners` after any runner/tool change
- [ ] merge-blocking set passes; no UNEXPECTED or XPASS
- [ ] The entry is in `Docs/bugs/track_a.md` (bold row); `python3 tools/check_tree.py` passes
- [ ] no tool attribution lines in commit messages; nothing backdated

## Reviewer
- [ ] read the plan rows, the model, every waiver, every BOUNDED result, every xfail row
- [ ] reran the merge-blocking set from a clean clone at the reviewed SHA
- [ ] wrote `flow/reviews/<blk>.md`
