# ASAP7 physical-design steps

The GARUDA ASAP7 flow is ORFS (`flow/pd/asap7/config.mk`) plus a few steps that ORFS does not have:
a multi-mode hold repair, STA of all four DIVSEL scenarios, and the clock checks that the B2/B3 runs
needed. These scripts are those steps. Until 2026-10-15 they lived outside the repository
(`~/tools/logs/b2_*`, `b3_*`), with the paths of one machine typed in. Here they share one environment
script and run from `make`.

**Exploratory.** ASAP7 is a predictive 7 nm teaching PDK. No timing, area or power number from these
runs carries over to the 28 nm target (`config.mk`, `Docs/DECISIONS.md` D-27).

## Use

From the repository root, with ORFS built (`flow/pd/TOOLS.md`):

| Command | What it does | Output |
|---|---|---|
| `make pd_pnr V=pnr_r8` | One whole run: ORFS to CTS, multi-mode hold repair, route to GDS under a memory guard, STA of every scenario | `~/tools/garuda_pd/{results,logs,reports}/asap7/garuda/pnr_r8/` |
| `make pd_pnr V=pnr_r8 PD_FROM=pnr_r7` | The same, starting from `pnr_r7`'s results up to CTS | as above |
| `make pd_pnr_dry V=pnr_r8` | Print the steps `pd_pnr` would run | terminal |
| `make pd_mmhold V=<run>` | Multi-mode hold repair of `4_cts.odb` (PD-9) | `4_cts.odb`, ORFS's original kept as `4_cts_div2only.odb`; log `4_2_mmhold.log` |
| `make pd_sta V=<run> [PD_STAGE=cts]` | STA of DIV2, DIV4, DIV8 and DIV16; routed database with SPEF by default | `analysis/<run>_sta_<stage>/sta_div*.log`, `summary.txt` |
| `make pd_skew V=<run>` | Clock insertion delay and skew after CTS (PD-7) | `analysis/<run>_cts_skew.log` |
| `make pd_phase V=<run>` | The launch and capture edges STA uses for every crossing between the derived clocks (PD-6) | `analysis/<run>_phase/phase_div*.log` |
| `make pd_shot V=<run> [PD_VIEW=routing]` | PNG of `6_final.gds`: all layers, M3..M7, or a list of GDS layers | `analysis/shots/<run>_gds_<view>.png` |
| `make pd_qor V=<run>` | One page: how far the run got and why it stopped, final timing, every DIVSEL scenario, the hold repair, area, power, DRC, run time and memory per stage. Reads files only | `analysis/<run>_qor.md` |
| `make pd_runs` | Every run side by side: outcome, setup and hold WNS, worst hold over all modes, DRC, cells, hold buffers, run time, peak memory | `analysis/qor_compare.md` |
| `make pd_check` | Parse every script here; needs no PD tool | terminal |

`PD_MODES="div2 div8"` limits the scenarios of `pd_mmhold`, `pd_sta` and `pd_phase`. `ORFS_HOME` and
`PD_WORK` move the ORFS tree and the work area from their defaults (`~/tools/OpenROAD-flow-scripts`,
`~/tools/garuda_pd`); `PD_ANALYSIS` moves the analysis directory alone.

## Before a full run under WSL

Detailed route needs about 9 GiB at 8 threads (pnr_r6/r7). The WSL default of 7.4 GiB is not enough:
pnr_r5 was OOM-killed (BUGS TOOL-21). Create `.wslconfig` again with the owner's approval
(`flow/pd/TOOLS.md` §1, D-30), then `wsl --shutdown`. `run_pnr.sh` stops the route when available memory
falls below 700 MiB while more than 4000 MiB of swap is in use, and restarts it once with 6 threads
(`GUARD_AVAIL_MIB`, `GUARD_SWAP_MIB`, `PD_FALLBACK_CORES`).

## Files

| File | Role |
|---|---|
| `pd_env.sh` | Sourced by every driver: paths, ORFS's `env.sh`, and `LIB_FILES`, `ADDITIONAL_LIBS`, `PLATFORM_DIR` and `DONT_USE_CELLS` exactly as ORFS resolves them for the run (`make print-<VAR>`) |
| `pd_common.tcl` | Tcl shared by the steps: liberty list (each file once), one STA mode and scene per DIVSEL scenario, the per-scene slack table |
| `run_pnr.sh` | The run driver (was `b3_r7.sh`) |
| `run_mm_hold.sh`, `mm_hold.tcl` | Multi-mode hold repair (was `b3_mm_hold.tcl`) |
| `run_sta.sh`, `sta_post.tcl` | Per-scenario STA with the reset-release paths (was `b3_sta_post.*`) |
| `run_skew.sh`, `cts_skew.tcl` | Clock-tree report (was `b3_skew.*`) |
| `run_phase.sh`, `phase_check.tcl` | Clock-edge pairing (was `b2_phase_check.tcl`, on a pre-layout netlist; now any stage's database) |
| `run_gds_shot.sh`, `gds_shot.py` | KLayout render (was `b3_gds_shot.py`) |
| `qor.py` | Run summaries and the run-history table (new; standard-library Python, starts no tool) |

## Changes from the scripts in `~/tools/logs`

- **The per-scene table of the hold repair printed nothing.** `b3_mm_hold.tcl` named each scene with
  `[$s name]`; scene objects have no methods, so every pnr_r7 summary line was
  `summ: Invalid method` and only the all-scene worst slack survived. `pd_scene_summary` uses
  `sta::scene_property $s name` and prints setup and hold WNS/TNS per scenario.
- **Each memory liberty was read twice.** ORFS's `LIB_FILES` already contains `ADDITIONAL_LIBS`, so the
  concatenation gave `STA-1140 library ... already exists` three times per step. `pd_libs` keeps each file
  once.
- **Paths are not typed in.** `/home/aneesh/...` and the `pnr_r6`/`pnr_r7` names are replaced by the
  variant argument and `pd_env.sh`.
