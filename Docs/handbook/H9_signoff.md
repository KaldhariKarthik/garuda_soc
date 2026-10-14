# H9. Regression tiers, seeds, sign-off, review records

## Regression tiers
Set from measured throughput (plan P0.11): a fast **merge-blocking** set (minutes),
a **nightly** set, and a **soak** set. No push with the track's merge-blocking set
failing. The nightly job never commits; results are committed weekly.

Measured 2026-10-11 (i9-13905H, Verilator 5.052; logs/core/evidence/P0.11_throughput.txt):
tb_boot 383 k instr/s without bus waits, 111 k with random 8-cycle waits; coverage
builds 3.3-4x slower; Spike co-simulation 140 k instr/s (no waits) to 52 k (random
waits) per job; one tb_boot build ~40 s.

| Tier | Target | Content | Time (16 jobs) |
|---|---|---|---|
| merge-blocking | `fast_a` | unit + element benches, ISA, sanity, directed, coverage programs, DSU model, trap formal (PROVEN + negative controls), runner self-tests | 2 min 43 s (measured) |
| nightly | `nightly_a` | `regress_a` (adds smokes, isa_rand, extra, RVFI, co-simulation, CSR, halt, CSR map, debug, all core formal) + riscv-arch-test, 1000-seed stress (`core_stress`), riscv-dv, DSU planted defects, DSU formal | ~1.5 h |
| soak | `soak_a` | 1e9 co-simulation-checked instructions (`core_endurance`) + `instret_report` (diversity); riscv-formal (`tools/run/rvformal.sh`) | hours |

Each tier ends in `tier_report` (or `regress_a_report`): one line per suite, exit 1
on a missing suite or any UNEXPECTED / XPASS row.

## Simulators (plan 1.3: the second-simulator list)
Verilator 5.052 is the working simulator. A second simulator is required where
Verilator's two-state model or its SVA subset cannot give the answer:

| Check | Second simulator | Why |
|---|---|---|
| DSU model bench end-of-stimulus (`tb_dsu_top_icarus`) | Icarus 12 (in `dsu_model`) | the bench's X sentinel can only be true in 4-state (TB-35) |
| Reset-X, X-propagation, `$isunknown` checks | Xcelium (Karthik) | XCELIUM-ONLY: 2-state simulation cannot show an X |
| Code coverage at gates (IMC, `-covdut`) | Xcelium/IMC (Karthik) | authoritative number; Verilator's is the working number (H5) |
| riscv-dv full test list (SV generator) | Xcelium (`make riscv_dv`) | pygen lacks sub-programs and four streams (tools/gen/garuda_dv_gen.py) |
| Cross-run of the environment at gates C and E | Xcelium (Karthik) | the plan's portability gate |
Formal (SBY) is independent of both; JasperGold re-runs the proofs when licensed.

## Seeds
Every run records its seed (H2). `logs/<blk>/history.tsv` accumulates seed,
verdict and SHA; the bar needs 500 seeds with none failing in the last two weeks.
The 1e9-instruction endurance target counts only co-simulation-checked
instructions on the candidate SHA, together with a workload-diversity report; it
is not a substitute for coverage closure.

## Sign-off
Every item of the bar is produced by a command from a clean clone at one SHA and
lands in `logs/<blk>/evidence/` (the evidence table is in the core plan). Numbers
are never typed by hand.

## Review record (`flow/reviews/<blk>.md`, written by the reviewer)
What was read (plan rows, model, coverage definitions, every waiver, every BOUNDED
result, the RTL diff), what was asked to change and how it was resolved, the commit
reviewed, name and date. A block is closed only with it.
