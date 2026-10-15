# GARUDA — WSL / Claude Code environment handoff

**Status at 2026-10-14.** `main` at `b8b0f5a` plus the documentation sync of 2026-10-14.

This file records the state of the Linux (WSL 2) environment and of the Claude Code work on it.
It does not replace `Docs/HANDOFF.md`, which is the verification handoff for the lab machine.

- Tool versions, install commands and removal: `flow/pd/TOOLS.md`.
- Physical-design runs: `Docs/PD_LOG_<date>.md`.
- Defects: `Docs/BUGS.md` (physical design: §1l, IDs PD-n and TOOL-n).
- Owner rulings: `Docs/DECISIONS.md` (D-26 and later for physical design).

Keep this file, `flow/pd/TOOLS.md`, `BUGS.md` and `DECISIONS.md` in step. Record a finding or a
ruling in its home file in the same session that finds it.

---

## 1. Rules for Claude sessions

1. Work only in `/home/aneesh/garuda_soc`. Do not touch the Windows checkout.
2. Do not change RTL without the owner's approval. Do not commit, push or rewrite history
   unless the owner asks.
3. The owner runs every `sudo` command. Explain each one before the owner runs it.
4. Install tools under `~/tools/<tool>` or `~/external/<tool>` only. One directory removes one tool.
5. An ASAP7 result is exploratory (D-26). Do not report it as timing closure or as a 28 nm result.

## 2. Machine

| Item | Value |
|---|---|
| Host | Windows 11 Home 10.0.26200, 16 logical CPUs, 15.3 GiB RAM |
| WSL | Ubuntu 22.04.5 LTS, WSL 2, kernel 6.18.40.1-microsoft-standard-WSL2, systemd on |
| WSL resources now | WSL defaults: 16 CPUs, 7.4 GiB RAM, 2 GiB swap. There is no `.wslconfig` |
| Repo | `/home/aneesh/garuda_soc` |

**Caution — detailed routing needs more memory than the defaults.** pnr_r5 was OOM-killed in
detailed route at 16 threads (TOOL-21). For pnr_r6 and pnr_r7 the owner set this
`C:\Users\gover\.wslconfig` (D-30):

```
[wsl2]
memory=12GB
swap=8GB
processors=8
```

The owner deleted the file on 2026-10-14. Before the next full place-and-route run, ask the
owner to create it again, then run `wsl --shutdown`. Peak use in pnr_r7 was 8.65 GiB at
`NUM_CORES=8`.

## 3. Phase status

| Phase | Status |
|---|---|
| B1 — toolchain | **Done.** ORFS `3451ca1` built locally (no Docker). The ASAP7 `gcd` gate passed as a toolchain check (2026-10-12). z3 installed; the `pipe_ctrl` SymbiYosys proof passes 6/6 (`Docs/VERIFICATION_LOG_2026-10-12.md`) |
| B2 — clocks, SDC, RTL hooks | **Done.** `flow/constraints/garuda.sdc` (28 nm draft, rev 2) and `flow/constraints/asap7/` (four DIVSEL scenarios). P1, P2, P3 applied and committed (D-28) |
| B3 — first exploratory P&R | **Done to GDS.** Reference result: pnr_r7 (`Docs/PD_LOG_2026-10-14.md`) |
| Simulation toolchain on Linux | **Not installed** (§5) |

### 3.1 B3 reference result (pnr_r7, ASAP7, exploratory)

- Die 320 × 300 µm, mock memories (D-29), 61 % utilisation.
- Detailed-route DRC 0, antenna 0. LEC `4_rsz` and `6_final`: identical.
- Post-route, extracted, FF corner: setup and hold met in all four DIVSEL modes. Worst hold
  +1.79 ps (thin, no hold uncertainty). Both reset-release paths met.
- Outputs: `~/tools/garuda_pd/` (`results/asap7/garuda/pnr_r7/6_final.gds`).
- Flow steps beyond ORFS (multi-mode hold repair, per-scenario STA, clock reports, the run driver, run summaries): `make pd_*`, `flow/pd/asap7/scripts/README.md`; `make pd_runs` gives every run side by side. The next run is `make pd_pnr V=pnr_r8 PD_FROM=pnr_r7` or a full one without `PD_FROM`.

These figures prove the flow, the constraints and the RTL hooks. They do not prove timing,
area or power at 28 nm.

### 3.2 Open items for physical design

| Item | What is open |
|---|---|
| P2 chip simulation | `make test_chip` on the lab xrun after the top split (D-28) |
| PD-1 | `GARUDA_SRAM_BLACKBOX` folds read data to 0; Genus cell counts may be low. Needs an RTL change |
| TOOL-18 | OpenROAD crashes (signal 11) in CTS hold repair with about 1700 violations |
| D2, D6 (28 nm) | Derived-clock uncertainty is a provisional 150 ps; the 28 nm ICG cell and object names need the foundry library |
| DFT | Not in scope until the mentors decide (D-26) |
| 28 nm | No library or memory compiler is available |

## 4. Tool pins (summary)

| Tool | Pin | Status |
|---|---|---|
| OpenROAD-flow-scripts | `3451ca1f56902a49baf50bb8eba345eb709cf9c8` | validated |
| OpenROAD | `26Q4-110-g91e5f5ff2f` | validated |
| Yosys (ORFS) | `0.68+ (git sha1 a5af9d690)`, slang built in | validated |
| Yosys / SymbiYosys / eqy (YosysHQ, for formal) | Yosys 0.68 `38e001a6f`, SBY v0.68 (reports v0.69) | validated with z3 |
| z3 | 4.8.12 (apt) | validated |
| kepler-formal, KLayout 0.30.12 | see `flow/pd/TOOLS.md` | validated |

Use `yosys -p slang_version`. `yosys -m slang` fails because slang is built in.

## 5. Not installed on Linux

Icarus `v12_0`, Verilator `v5.052`, Spike, riscv-tests and a RISC-V GCC are proposed only.
Do not use apt's RISC-V GCC 10.2.0: its binutils 2.35.1 is older than the 2.39 that
`sw/Makefile` needs. The candidate is xPack `riscv-none-elf-gcc` 15.2.0-1, not yet checked.

Until these are installed, the following do not run on Linux: `make local_sim`,
`make local_lint`, `make sw`, the T-13 and T-14 core tests, the ISA and Spike lockstep
regression, and TB-33 and ELEM-8. The full xrun regression runs at the lab only.

## 6. Document inconsistencies

Fixed on 2026-10-14 (`Docs/BUGS.md` DOC-1): the PHYS §5.2 SDC sketch, the yaml stretch clock
and pclk ratios (PD-5), the CLIC ID map after INT-2, the APB window numbering, and the
clock/reset description after D-14.
