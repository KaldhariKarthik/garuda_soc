# GARUDA physical-design toolchain (WSL 2, Ubuntu 22.04)

**What this is.** The pinned, open-source Linux toolchain for GARUDA physical-design work: what was
installed, from which commit, by which command, how to check it, and how to remove it. Every version
and hash below was captured from command output on 2026-10-12; none is typed from memory.
Session history and decisions are in `Docs/CLAUDE_HANDOFF.md`.

**Status words.**
- **validated**: installed, and passed the check named in the row.
- **installed**: on disk, with the version captured; not yet exercised by a real flow.
- **proposed**: chosen but not installed.

**This toolchain proves nothing about GARUDA.** The ASAP7 `gcd` run in §5 shows that the tools work.
It says nothing about GARUDA's RTL, timing or tapeout readiness.

---

## 1. Machine

| Item | Value (command) |
|---|---|
| Host | Windows 11 Home 10.0.26200, 16 logical CPUs, 15.3 GiB RAM |
| WSL | WSL 2, distribution `Ubuntu-22.04` (`wsl -l -v`) |
| OS | Ubuntu 22.04.5 LTS (`lsb_release -ds`), kernel `6.18.40.1-microsoft-standard-WSL2` |
| Resources | 16 CPUs, 7584 MiB RAM, 2048 MiB swap (`nproc`, `free -m`); **WSL defaults, no `.wslconfig`** |
| GUI | WSLg (`DISPLAY=:0`, `WAYLAND_DISPLAY=wayland-0`) |

There is deliberately no `.wslconfig`. It would be created only if a run fails or swaps heavily, and
only with the smallest change the logs justify. The 59-minute ORFS build ran within the defaults.

## 2. Tools

### 2a. OpenROAD-flow-scripts and the tools it builds

| Tool | Source pin | Version reported | Location | Status |
|---|---|---|---|---|
| OpenROAD-flow-scripts | `3451ca1f56902a49baf50bb8eba345eb709cf9c8` (master, 2026-10-10) | — | `~/tools/OpenROAD-flow-scripts` | **validated** (§5) |
| OpenROAD (incl. OpenSTA) | submodule `91e5f5ff2f198fd130e8915c8ad4408b56987fa4` | `26Q4-110-g91e5f5ff2f` | `tools/install/OpenROAD/bin/openroad` | **validated** (§5: flow and GUI) |
| Yosys (ORFS submodule) | submodule `a5af9d690a43744bf6b2cc3dea2717c16b54621c` | `Yosys 0.68+ (git sha1 a5af9d690, Release, GNU /usr/bin/c++ 11.4.0)` | `tools/install/yosys/bin/yosys` | **validated** (§5: synthesis) |
| ↳ slang frontend | built in; no plugin file | `sv-elab revision 3dddccd478618d68f8a5e160fb4b5783c4da35d4` | `read_slang` command | installed (not used by gcd) |
| kepler-formal | submodule `f70c2e38592d704c8cccf68433b091e82c8118f0` | has no `--version` option | `tools/install/kepler-formal/bin/kepler-formal` | **validated** (§5: LEC) |
| KLayout | Ubuntu-22 `.deb`, md5 `6dfffa50f385881768dee30bdc759608` | `KLayout 0.30.12` (dpkg `0.30.12-1`) | `/usr/bin/klayout` | **validated** (§5: GDS merge and GUI) |
| Bazel | `tools/OpenROAD/.bazelversion` | `9.1.1`, fetched by bazelisk `v1.28.1` | `/usr/local/bin/bazelisk`, `~/.cache/bazel` | installed (build only) |

OpenSTA has no standalone `sta` binary here. It is inside `openroad`.

### 2b. Dependencies built by ORFS `-common`

These are in `~/tools/OpenROAD-flow-scripts/dependencies`:

| Tool | Version reported | Status |
|---|---|---|
| CMake | `cmake version 3.31.9` | installed (build only) |
| SWIG | `SWIG Version 4.3.0` | installed (build only) |
| Bison, Flex | `bison (GNU Bison) 3.8.2`, `flex 2.6.4` | installed (build only) |
| Boost, Eigen, CUDD, LEMON, spdlog, gtest, PCRE, CUSP | 1.89, 3.4, 3.0.0, 1.3.1, 1.15.0, 1.17.0, 10.42, (unversioned) — from the installer summary | installed (build only) |
| or-tools | 9.14.6206 (Abseil 20250512 inside it) — from the installer summary | installed (build only) |
| Yosys (YosysHQ release, for formal) | `Yosys 0.68 (git sha1 38e001a6f, Release, GNU /usr/bin/c++ 11.4.0)` | installed |
| SymbiYosys | tag `v0.68`, commit `b1a1e98cba941ec8433f8dc27f416cd7bb7f14be`; reports `SBY v0.69` because that commit carries both tags | **validated** with z3: `pipe_ctrl.sby` 6/6 PASS |
| eqy | `EQY v0.68` | installed |
| Python packages | pip `25.2` and ORFS's hashed `etc/requirements-common_lock.txt`, in `~/.local` | installed |

### 2c. System packages

| Item | Version reported | Status |
|---|---|---|
| gcc / g++ | `gcc (Ubuntu 11.4.0-1ubuntu1~22.04.3) 11.4.0` | installed |
| make | `GNU Make 4.3` | installed |
| clang | `Ubuntu clang version 14.0.0-1ubuntu1.1` | installed |
| python3 | `Python 3.10.12` | installed (Ubuntu) |
| libc6 | `2.35-0ubuntu3.15` | upgraded by the install, from 3.13 |
| z3 | `Z3 version 4.8.12 - 64 bit` (dpkg `4.8.12-1`), installed 2026-10-12 with `apt-get install -y --no-install-recommends z3` (1 new package, 0 upgraded, 0 removed) | **validated**: `pipe_ctrl.sby` 6/6 PASS (`Docs/VERIFICATION_LOG_2026-10-12.md`) |

### 2d. Proposed, not installed

| Tool | Proposed pin | Notes |
|---|---|---|
| Icarus Verilog | `v12_0` = `d61ab44c8a62d10dc80c3ae219387de04b7217c7` | `~/tools/iverilog`; deferred until after the gcd gate |
| Verilator | `v5.052` (newest release tag on 2026-10-11) | `~/tools/verilator`; the Windows 5.053-devel crashed on `pwm_sva.sv` |
| Spike | `17e8a69fb75546dea445cfc0fb78769d2510f339` (master, 2026-10-11; no release since v1.1.0) | `~/external/spike-inst`, the Makefile's `SPIKE` default |
| riscv-tests | `7b68f7b91f827f8d94cc1c57ff123752c5c8f704` (master, 2026-10-11) | `~/external/riscv-tests`; for ISA builds only |
| RISC-V GCC | **not** apt's `gcc-riscv64-unknown-elf` 10.2.0 / binutils 2.35.1 (binutils older than the 2.39 `-Wl,--no-warn-rwx-segments` needs). Candidate: xPack `riscv-none-elf-gcc` `v15.2.0-1`, `xpack-riscv-none-elf-gcc-15.2.0-1-linux-x64.tar.gz`, sha256 `aaaa8060c914851a3e5ee1ba82cc3d6f80972f90638a05c6e823a37557a33758` | Being checked against `sw/Makefile`. Prefix `riscv-none-elf-`. `sw/riscv-tests/Makefile` hard-codes `riscv64-amd-linux-gnu-`, so override `CC=`/`OBJCOPY=` on the command line |

## 3. Install commands, in the order run

All of these ran on 2026-10-11/12. The logs are in `~/tools/logs/`.

```bash
# 3.1 Clone ORFS at the pin (normal user)
mkdir -p ~/tools && cd ~/tools
git clone https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts
cd OpenROAD-flow-scripts
git checkout --detach 3451ca1f56902a49baf50bb8eba345eb709cf9c8
git submodule update --init --recursive

# 3.2 Refresh package lists (root)
wsl -d Ubuntu-22.04 -u root -- apt-get update

# 3.3 System packages (root): ~/tools/logs/b14a_base_root.sh, log b14a_base.log.
#     These are ORFS's own `etc/DependencyInstaller.sh -base` commands in its order, minus its
#     Docker block (lines 282-309). No upstream file was modified. SUDO_USER=aneesh is set so that
#     files the installer writes in the ORFS tree are owned by the normal user, as under sudo.
#  a) ./tools/OpenROAD/etc/DependencyInstaller.sh -eqy -threads=6 -base -bazel -yosys-ver=v0.68
#  b) apt-get -y update && apt-get -y install --no-install-recommends <ORFS list, lines 197-229>
#  c) KLayout 0.30.12 .deb: wget, md5sum -c 6dfffa50f385881768dee30bdc759608, dpkg -i
#  d) apt-get autoclean -y && apt-get autoremove -y   (simulated first; 0 to remove)
#  Result: 324 packages installed, 27 upgraded (jammy-security/updates), 0 removed.

# 3.4 Build dependencies (normal user), log b14a_common.log: exit 0, 13 min 50 s
./etc/DependencyInstaller.sh -common -prefix=$HOME/tools/OpenROAD-flow-scripts/dependencies -threads=6

# 3.5 Build OpenROAD, Yosys and kepler-formal (normal user), log b14a_build.log: exit 0, 59 min 27 s
./build_openroad.sh --local --threads 6
```

**Docker is not installed.** `build_openroad.sh --local` never uses it. Nothing in `flow/`, `env.sh`
or `dev_env.sh` refers to it.

**Resource use.** The build ran on WSL defaults, with memory sampled every 15 s:
- `-common`: peak 3.7 GiB used, 0 swap.
- Build: peak 5.8 GiB used, never under 1.3 GiB available, swap peaked at 1.06 GiB with swap-in
  and swap-out rates 0 at that moment. No OOM.

## 4. Using it, and checking it

```bash
cd ~/tools/OpenROAD-flow-scripts && source ./env.sh
openroad -version          # expect 26Q4-110-g91e5f5ff2f
yosys -V                   # expect Yosys 0.68+ (git sha1 a5af9d690 ...)
yosys -p slang_version     # slang is built in. NOTE: `yosys -m slang` fails (no slang.so); expected
klayout -v                 # expect KLayout 0.30.12
git -C ~/tools/OpenROAD-flow-scripts rev-parse HEAD   # expect 3451ca1f...
git -C ~/tools/OpenROAD-flow-scripts submodule status # no leading '+' or '-'
```

ORFS's `flow/scripts/synth_preamble.tcl` states that `read_slang` is built into Yosys from 0.67
and needs no plugin load. The default flow reads Verilog with `read_verilog`, and uses slang only
when `SYNTH_HDL_FRONTEND=slang`.

## 5. Acceptance gate (B1.6)

```bash
cd ~/tools/OpenROAD-flow-scripts/flow && source ../env.sh
/usr/bin/time -v make DESIGN_CONFIG=./designs/asap7/gcd/config.mk   # log ~/tools/logs/gcd_asap7_run.log
```

Run on 2026-10-12, 01:21:33 to 01:22:14. Outputs are in `flow/{logs,results,reports}/asap7/gcd/base/`
under the ORFS tree.

| Check | Result (source) |
|---|---|
| Exit status, time | `make` exit 0. 40.8 s wall, 51.8 s user, 7.3 s system. Largest process 743 MiB RSS (`time -v`, `gcd_asap7_run.log`) |
| Stage logs | All present: `1_synth`, `2_1`–`2_4` floorplan, `3_1`–`3_5` place, `4_1_cts`, `5_1_grt`, `5_2_route`, `5_3_fillcell`, `6_1_fill`, `6_1_merge`, `6_report`. No `[ERROR` lines |
| Final outputs | `6_final.gds` 681,294 B; `6_final.odb` 1,349,429 B; `6_final.v`, `.sdc`, `.def`, `.spef` present |
| Logic equivalence (kepler-formal) | `4_rsz_lec_check.log` and `6_final_lec_check.log`: "SAT solver finished: UNSAT", "Circuits are IDENTICAL" |
| Clock | `core_clock`, period 310 ps (`designs/asap7/gcd/constraint.sdc`) |
| Setup timing | **Not met.** WNS −41.07 ps, TNS −117.98 ps, 5 setup violations; worst slack −41.07 ps; `core_clock period_min = 329.16`, fmax 3.04 GHz (`reports/.../6_finish.rpt`, `logs/.../6_report.json`). `RSZ-0062` "Unable to repair all setup violations" ×3 |
| Hold timing | Met. Worst hold slack +41.06 ps, TNS 0, 0 violations (`6_report.json`) |
| Routing DRC | Detailed router: `[INFO DRT-0199] Number of violations = 0` (`logs/.../5_2_route.log`); `reports/.../5_route_drc.rpt` is empty (0 B). Antenna checks: 0 net, 0 pin violations. **Only OpenROAD's router check ran. No KLayout/foundry DRC deck ran, so this is not a signoff DRC result** |
| Design | Core area 61.31 µm², std-cell area 45.48 µm², utilisation 74.2 %, 29 rows; total power 1.37 mW; worst IR drop 5.7 mV on VDD |
| Warnings | GUI-0010 ×10 (image file extension renamed to `.webp.png`), STA-0450 ×4 (virtual clock not propagated), RSZ-0062 ×4, PDN-1051 ×2 (no macros for the macro grid), GRT-0246 ×2 (no antenna diode cell in the ASAP7 LEF), GPL-0302 ×2 (target density 0.35 too low), EST-0027 ×2 (wire-load models before parasitics exist), IFP-0028 ×1 (core corner snapped to 0.540), GUI-0076 ×1 (Qt "wayland" platform plugin not found, in headless `6_report`), FLW-0010 ×1 (two clocks, SDC update skipped). Yosys: 0 warnings |
| GUI: `make DESIGN_CONFIG=./designs/asap7/gcd/config.mk gui_final` | **Passed** (user confirmed 2026-10-12): the window opened through WSLg and showed the routed gcd layout. The log shows `6_final.odb`, `.sdc` and `.spef` loaded and timing computed. Open 01:26–01:30:54, closed by the user, exit 0 (`~/tools/logs/gui_openroad.log`). Messages: `qt.qpa.plugin: Could not find the Qt platform plugin "wayland"` (the window opened anyway, presumably over X11), and STA-0450 |
| GUI: `klayout results/asap7/gcd/base/6_final.gds` | **Passed** (user confirmed 2026-10-12): KLayout opened and displayed `6_final.gds`. Open 01:26:11–01:32:26, exit 0 (`~/tools/logs/gui_klayout.log`). One WSLg graphics-driver message: `Dropped Escape call with ulEscapeCode : 0x03007703` |

**Gate status.** Every stage ran and produced the final GDS and ODB. Both equivalence checks
passed, and the router reports 0 DRC violations. The tools therefore run end to end. Setup timing
is **not met** at ORFS's 310 ps clock for this design. ORFS 3451ca1 ships no reference-limits file
for `asap7/gcd`, so this run cannot say whether −41 ps matches upstream's own result.

The OpenROAD, Yosys, kepler-formal and KLayout rows in §2a are **validated** by this gate: batch
flow execution, and the OpenROAD and KLayout GUIs under WSLg. The gate checks that the toolchain
works. It is not a timing or signoff result.

To launch a GUI, run it in the foreground of a live shell, or as a job that keeps the WSL session
open. A `setsid nohup … &` launch from a `wsl --` one-shot command was killed when the call
returned, before the GUI started.

## 6. Removal

| Scope | Command | Notes |
|---|---|---|
| ORFS and every tool it built | `rm -rf ~/tools/OpenROAD-flow-scripts ~/.cache/bazel` | Also delete `~/tools/logs` if the logs are no longer wanted |
| Python packages | `rm -rf ~/.local/lib/python3.10 ~/.local/bin` | Only ORFS put anything there |
| KLayout, bazelisk | `sudo dpkg -r klayout`; `sudo rm /usr/local/bin/bazelisk` | |
| apt packages | Not removed one by one. The 27 upgrades are ordinary Ubuntu security updates | |
| Everything Linux | `wsl --unregister Ubuntu-22.04` (PowerShell) | **Irreversible.** Deletes the whole Linux disk: every tool, the WSL clone of this repo and any uncommitted work there. The user's decision only |
| WSL itself | `wsl --uninstall`; remove the VS Code WSL extension | Optional. Nothing else on Windows was touched |

There is no `.wslconfig` to delete.
