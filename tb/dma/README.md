# DMA verification (Track A, Karthik's task 6A.4)

Verification of `rtl/dma` (6-channel AHB master + APB register file) to Karthik's
block bar: functional coverage 100 %, code coverage 100 % after proven waivers,
every property PROVEN or BOUNDED with its depth, 500 random seeds, a planted-defect
run, and a review record. Plan and log: Obsidian `process/GARUDA DMA Plan - Track A (C).md`.

All testbench, checker, model, coverage and formal code is SystemVerilog. Python,
TOML and Make are flow glue; C is firmware for the chip programs.

## What is here

| Path | What it is |
|---|---|
| `tb_dma_top.sv` | the team's directed bench (64 checks), `dma_sva` bound |
| `tb_dma_probe.sv` | reproducers of the open defects DMA-9/10/11/13/14 (`+CASE=`) |
| `tb_dma_regs.sv` | register tests from `Design_Docs/regs/dma_a.rdl` (87 checks) |
| `units/` | each sub-module on its own: `tb_dma_apb_slave_unit` (map, strobes, PSLVERR, read mux), `tb_dma_chan_unit` (cycle model of the channel rules, 200k cycles), `tb_dma_engine_unit` (AHB slave model; per-beat read/write, lanes, errors, R-9, ack, ENG-1); 7 negative controls |
| `env/` | the environment: `dma_env_top.sv` (tests), `dma_env_pkg.sv` (transfer class, reference model + scoreboard), `dma_beat_check.sv` (pin-level beat checker, R4), `dma_req_agent.sv` (D-21 peripherals), `dma_cov.sv` (functional coverage, bound in every DMA bench), `dma_regs_pkg.sv` (generated) |
| `../ahb/agent/` | AHB-Lite slave with waits, address stalls, ERROR, FIFO regions (reused by the AHB/bridge work) |
| `../../rtl/dma/dma_props_a.sv` | 89 asserts, 78 covers, bound in every DMA bench and in `tb_chip` |
| `formal/` | SBY harnesses and tasks: `dma.toml` (proof, BMC, covers, defect finders, mutants), `dma_2clk.toml` (real pclk), `arb.toml` (five priority maps), `cov_unreach.toml` (evidence for the coverage waivers); assumptions in `formal/ASSUMPTIONS.md` |
| `cov/` | `cov.toml` (what is design / testbench / functional), `dma_waivers.toml` (every exclusion with its evidence) |
| `mut/` | generated mutants (planted defects) |
| `run/` | suite manifests for `tools/run/garuda_run.py`, `xfail.tsv` (every expected failure with its bug ID) |
| `vplan_trace.toml` | maps each vPlan row (F01-F51) to what implements it |

## Running it (from the repository root)

```
make -f flow/mk/track_a_run.mk dma_block      # tb_dma_top
make -f flow/mk/track_a_run.mk dma_probe      # defect reproducers (XFAIL with their IDs)
make -f flow/mk/track_a_run.mk dma_regs       # register tests + negative control
make -f flow/mk/track_a_run.mk dma_units      # sub-module benches + negative controls
make -f flow/mk/track_a_run.mk dma_env        # environment: smoke qual coll reset arb req matrix edge bits rand + 7 negative controls
make -f flow/mk/track_a_run.mk dma_seeds      # 100 random seeds (base = day of year x 100)
make -f flow/mk/track_a_run.mk dma_chip       # chip programs on tb_chip: traffic, subword, uart, rearm (DMA-11)
make -f flow/mk/track_a_run.mk dma_mut        # planted defects; evidence in logs/dma/evidence/dma_mut_<date>.txt
make -f flow/mk/track_a_run.mk fv_dma_quick   # formal, fast part (~2 min); fv_dma = everything (~16 min)
make -f flow/mk/track_a_run.mk cov_dma cov_dma_report   # coverage, design and testbench reported separately
make -f flow/mk/track_a_run.mk cov_dma_imc    # regenerate the toggle waivers and flow/cov/dma_exclusions.tcl
python3 tools/run/vplan_trace.py dma      # logs/dma/summary/vplan_trace.txt
```

One test by hand, with its seed:

```
source tools/run/env.sh
$PYTHON tools/run/garuda_run.py suite tb/dma/run/env.toml --only env_edge --seed 7
```

Each run writes `logs/dma/raw/<suite>/sim_<test>_s<seed>.log` (with the exact
command to reproduce it) and a summary `logs/dma/summary/<suite>.tsv`. A test
passes only with its pass marker, zero `[FAIL]` lines and zero assertion failures;
an expected failure must fail for the reason in `run/xfail.tsv`.

Tiers: `fast_a` runs block, probe, regs and env; `regress_a` adds the chip
programs and `fv_dma_quick` (with the coverage-waiver proofs); `nightly_a` adds
`fv_dma`, 100 seeds and the planted-defect run.

## Open defects (rulings pending, see Docs/bugs/dma.md)

DMA-9 (restart vs resume), DMA-10 (source read before a DAR refusal), DMA-11
(re-arm while a beat is in flight; reachable from firmware), DMA-12 (ACK_CYCLES
guard), DMA-13 (unaligned SAR/DAR), DMA-14 (SIZE changed inside a beat), DMA-15
(ack on M2M beats). Each has a reproducer that fails for its named detector; the
detectors are left out of the proof tasks and kept in a `*_find` task that must fail.

## XCELIUM-ONLY (for Karthik; the open flow cannot produce these)

Run through NCLaunch (`tcsh`, `source ~/cadence/cshrc`, VPN up). On the Rocky 8.10
laptop check the Rocky causes first (Obsidian `Rocky Linux and Cadence (C).md`).

1. **irun / xrun simulation, 20 seeds** of the environment (R7). The environment
   compiles and elaborates with 0 errors on Xcelium (2026-10-12); simulation needs
   the licence (-39 today).
2. **IMC merge** of those runs with `flow/cov/dma_exclusions.tcl`. The IMC number is
   the authoritative coverage. Three lines in that file are marked "complete in
   IMC" (the engine's `default` arm and two covergroup exclusions): IMC numbers
   blocks and bins itself.
3. **X-propagation and reset-X**: Verilator is 2-state.
4. **JasperGold re-proof** of `dma_props_a.sv` and of the coverage-waiver properties
   (`formal/dma_cov_sva.sv`), once licensed.
