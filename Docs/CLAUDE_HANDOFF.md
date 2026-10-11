# GARUDA — WSL / Claude Code environment handoff

**What this is.** Continuity notes for the Linux (WSL 2) EDA environment and the Claude Code
sessions that build it. It does not replace `Docs/HANDOFF.md`, which is the verification handoff
for the lab machine and stays as it is. Tool pins and install commands go in `flow/pd/TOOLS.md`
(phase B1.5); this file records state, decisions and what remains.

Every status below is one of:
- **candidate** — chosen, not installed;
- **installed** — on disk, version captured from command output;
- **validated** — passed the check named next to it.

---

## 1. Machine (measured 2026-10-11)

| Item | Value |
|---|---|
| Host | Windows 11 Home 10.0.26200, 16 logical CPUs, 15.3 GiB RAM, C: ~759 GiB free |
| WSL | Ubuntu-22.04, WSL version 2, Ubuntu 22.04.5 LTS, kernel 6.18.40.1-microsoft-standard-WSL2, systemd on |
| WSL resources | 16 CPUs, 7.4 GiB RAM, 2 GiB swap (defaults; **no `.wslconfig`**) |
| WSLg | `DISPLAY=:0`, `WAYLAND_DISPLAY=wayland-0` present; GUI not yet tested |
| Repo | `/home/aneesh/garuda_soc`, `main` at `9c5a308`, clean |

**Decision (user, 2026-10-11):** keep the default WSL resources. No `.wslconfig` is created
unless a build fails or shows memory pressure, and then only the smallest change the logs justify.

## 2. Phase B1 status

| Step | Status |
|---|---|
| B1.0 orientation | done 2026-10-11 |
| B1.2 `.wslconfig` | **deferred by decision** (see §1) |
| B1.4a ORFS | **done 2026-10-12**: base + common installs and local build passed (§4) |
| B1.4b–h other tools | not started |
| B1.5 `flow/pd/TOOLS.md` | written 2026-10-12 (uncommitted) |
| B1.6 ASAP7 gcd gate | **passed as a toolchain gate, 2026-10-12.** Batch run: exit 0, all stages, GDS/ODB, LEC identical, 0 router DRC violations. **Setup timing NOT met**: WNS −41.07 ps, TNS −117.98 ps, 5 violations at the design's 310 ps clock (period_min 329.16 ps); hold met. GUI: OpenROAD `gui_final` showed the routed layout and KLayout showed `6_final.gds` (both confirmed by the user, both exit 0). Details and caveats in `flow/pd/TOOLS.md` §5 |
| B1.7, B2, B3 | **not started**: each needs the user's explicit approval |

**B1 caveats to carry forward.**
- The gcd run proves the toolchain, not GARUDA.
- Setup timing is not met at 310 ps. ORFS 3451ca1 has no reference-limits file for asap7/gcd, so
  whether −41 ps matches upstream is unknown.
- "0 DRC" is OpenROAD's detailed-router check only. No KLayout or foundry DRC deck ran.
- `yosys -m slang` fails by design: slang is built in, use `yosys -p slang_version`.
- B1.4b–h (Icarus, Verilator, Spike, riscv-tests, RISC-V GCC, z3) are not installed, so the
  environment does not yet reproduce the Phase A simulations. The apt RISC-V GCC (binutils 2.35.1)
  is unsuitable; the xPack 15.2.0-1 candidate is not yet checked against `sw/Makefile`.
- `scripts/run_sim.sh` and `scripts/run_synth.sh` are still mode 100644 (run with `bash …`).

## 3. Tool pins

| Tool | Pin | Status |
|---|---|---|
| OpenROAD-flow-scripts | `3451ca1f56902a49baf50bb8eba345eb709cf9c8` at `~/tools/OpenROAD-flow-scripts`, all submodules at recorded commits (none `-`/`+`) | **validated** (gcd gate) |
| ↳ OpenROAD submodule | `91e5f5ff2f198fd130e8915c8ad4408b56987fa4` (26Q4-110), built with Bazel 9.1.1 via bazelisk 1.28.1 | **validated** (`26Q4-110-g91e5f5ff2f`; gcd flow and GUI) |
| ↳ Yosys submodule | `a5af9d690a43744bf6b2cc3dea2717c16b54621c` (`yosys_ver = "0.68"`), slang built in | **validated** (`Yosys 0.68+ (git sha1 a5af9d690)`; gcd synthesis) |
| ↳ kepler-formal submodule | `f70c2e38592d704c8cccf68433b091e82c8118f0` | **validated** (gcd LEC) |
| ↳ KLayout | 0.30.12, Ubuntu-22 .deb, md5 `6dfffa50f385881768dee30bdc759608` | **validated** (`KLayout 0.30.12`; GDS merge and GUI) |
| Icarus Verilog | `v12_0` = `d61ab44c8a62d10dc80c3ae219387de04b7217c7` | candidate |
| Verilator | `v5.052` | candidate |
| SymbiYosys | tag `v0.68` (tag object `5c9bfbe0`, commit `b1a1e98cba941ec8433f8dc27f416cd7bb7f14be`, which also carries `v0.69`, so it reports `SBY v0.69`), built by ORFS `-common` with Yosys 0.68 (git sha1 38e001a6f) and eqy v0.68, in `~/tools/OpenROAD-flow-scripts/dependencies` | **installed**, not yet exercised |
| Spike | `17e8a69fb75546dea445cfc0fb78769d2510f339` (master, 2026-10-11) | candidate |
| riscv-tests | `7b68f7b91f827f8d94cc1c57ff123752c5c8f704` (master, 2026-10-11) | candidate |
| RISC-V GCC | not apt (10.2.0 / binutils 2.35.1, too old). xPack `riscv-none-elf-gcc` v15.2.0-1, sha256 `aaaa8060…a33758`, under review | candidate |

The physical-design toolchain (ORFS, OpenROAD, Yosys, kepler-formal, KLayout) is pinned and
recorded in `flow/pd/TOOLS.md` from command output. The candidate rows are not; the simulation
and firmware toolchain is not reproducible until they are installed and recorded.

## 4. What ORFS `setup.sh` does at `3451ca1` (read 2026-10-11)

Not in the original runbook, and needing the user's decision:
- **It installs Docker.** If `docker` is absent, ORFS's `_installUbuntuPackages` adds Docker's apt
  repository and GPG key (`/etc/apt/sources.list.d/docker.list`, `/etc/apt/keyrings/docker.asc`) and
  installs `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`. With
  systemd on, the daemon is enabled at boot. The local (`--local`) build does not use it.
- **It installs bazelisk** to `/usr/local/bin`; OpenROAD is built with Bazel (`--config=release`,
  ThinLTO), which downloads its own LLVM toolchain and Qt prebuilts into `~/.cache/bazel`.
- **`-common` compiles with `nproc` = 16 threads** unless `-threads=N` is given (`setup.sh` does not
  pass it): CMake (binary), bison, flex, PCRE, SWIG, Boost 1.89, Eigen, CUDD, LEMON, spdlog, gtest,
  or-tools 9.14 (prebuilt), Abseil, Yosys/eqy/sby v0.68 — all under `dependencies/`.
- **pip:** as the normal user, `pip install --user` upgrades pip and installs the hashed
  `etc/requirements-common_lock.txt` into `~/.local`.
- **`apt-get autoclean` and `apt-get autoremove -y` run twice** (OpenROAD's installer and ORFS's).
  Simulated 2026-10-11 before any install: autoremove would remove **0 packages**.

**apt simulation, 2026-10-11** (after `apt-get update` run as root with the user's approval; every
other command `apt-get -s`, no root). All apt lists from both installers, the B1.4b prerequisites and
the RISC-V GCC together: **338 new packages, 27 upgrades of installed packages, 0 removals**, ~302 MiB
download, ~1.5 GiB installed. The upgrades are jammy security/point updates pulled in as dependencies
(libc6 3.13→3.15, libssl3, perl, python3.10, glib, ncurses, util-linux libs, libxml2, curl, wget,
tzdata, and a few more). On 22.04 the OpenROAD installer's `libtcl` resolves to `libtcl8.6`, and
`libpython3.8` matches no installable package and is silently skipped (apt reads the `.` as a regex).
KLayout 0.30.12 .deb: md5 matches, 63 MiB, ~219 MiB installed, needs only jammy Qt5/ruby/python libs.
Docker (if installed): ~84 MiB download, ~343 MiB installed (docker-ce 29.9.0, containerd.io 2.4.1).
Apt's RISC-V cross-compiler: `gcc-riscv64-unknown-elf` **10.2.0**, `binutils-riscv64-unknown-elf`
**2.35.1**. That binutils is older than the 2.39 that `-Wl,--no-warn-rwx-segments` needs, so
`make sw` is expected to fail with it.

**Decisions (user, 2026-10-11):** no Docker and no Docker apt repository; B1.4b prerequisites and
RISC-V GCC deferred until after the first ORFS build; the apt RISC-V GCC (10.2.0 / binutils 2.35.1)
is not to be installed, and the xPack toolchain is to be checked against `sw/Makefile` first.

**Docker is not needed for the local build.** `build_openroad.sh` uses Docker only when `--local` is
absent *and* `docker` is on PATH (line 526); with `--local` it always builds locally. No file in
`flow/Makefile`, `flow/scripts/`, `flow/platforms/asap7/*.mk`, `flow/designs/asap7/gcd/`, `env.sh` or
`dev_env.sh` mentions Docker.

**Base-installer apt set without Docker** (simulated): 323 new packages, **27 upgrades**, 0 removals.
All 27 upgrades come from jammy-security / jammy-updates: libperl5.34, perl, perl-base,
perl-modules-5.34 (5.34.0-3ubuntu1.5 → 1.9); libc6 (2.35-0ubuntu3.13 → 3.15); libbz2-1.0
(1.0.8-5build1 → 5ubuntu0.1); libexpat1 (2.4.7-1ubuntu0.7 → 0.9); libpython3.10, python3.10,
libpython3.10-stdlib, python3.10-minimal, libpython3.10-minimal (3.10.12-1~22.04.15 → .18); libssl3
(3.0.2-0ubuntu1.21 → 1.30); liblzma5 (5.2.5-2ubuntu1 → 1.1); libncurses6, libncursesw6, libtinfo6
(6.3-2ubuntu0.1 → 0.3); libuuid1, libblkid1, libmount1 (2.37.2-4ubuntu3.4 → 3.6); libglib2.0-0,
libglib2.0-bin (2.72.4-0ubuntu2.9 → 2.10); libxml2 (2.9.13+dfsg-1ubuntu0.11 → 0.14); tzdata
(2025b → 2026c); wget (1.21.2-2ubuntu1.1 → 1.5); curl, libcurl4 (7.81.0-1ubuntu1.22 → 1.29).

**Method proposed for skipping Docker:** run, unmodified and in order, the same commands ORFS's
`-base` path runs, except its Docker block (`etc/DependencyInstaller.sh` lines 282–309): OpenROAD's
installer with `-eqy -threads=6 -base -bazel -yosys-ver=v0.68`; ORFS's apt list (lines 197–229);
KLayout 0.30.12 .deb with the md5 check (lines 264–276); then `apt-get autoclean` / `autoremove`
(lines 177–180). Then the ORFS script itself, unmodified, as the normal user for `-common`.

**Base step run, 2026-10-12 00:00–00:01** (approved; as root via `wsl -u root`, script
`~/tools/logs/b14a_base_root.sh`, log `~/tools/logs/b14a_base.log`, exit 0). Both guarded autoremove
simulations predicted 0 and the real autoremoves removed nothing. From `/var/log/dpkg.log` for this
window: **27 upgrades, identical to the approved list; 324 new packages (323 + klayout); 0 removals**.
No Docker, no extra apt source. Installed: KLayout 0.30.12 (md5 OK), bazelisk v1.28.1
(`/usr/local/bin`), gcc 11.4.0, GNU Make 4.3, clang 14.0.0. `SUDO_USER=aneesh` was set so the
OpenROAD installer's deps-prefix file is user-owned; no root-owned file is left in the ORFS tree.

**Common step run, 2026-10-12 00:02–00:16** (normal user, unmodified ORFS script,
`-common -prefix=$HOME/tools/OpenROAD-flow-scripts/dependencies -threads=6`, log
`~/tools/logs/b14a_common.log`): **exit 0**, wall time 13 min 50 s. Installed into `dependencies/`
(768 MB): CMake 3.31.9, Bison 3.8.2, Flex 2.6.4, PCRE 10.42, SWIG 4.3.0, Boost 1.89, Eigen 3.4,
CUDD 3.0.0, CUSP, LEMON 1.3.1, spdlog 1.15.0, gtest 1.17.0, **Yosys 0.68 (git sha1 38e001a6f)**,
eqy v0.68, **sby v0.68** (with `yosys-smtbmc`), or-tools 9.14.6206 (Abseil 20250512 bundled). pip
25.2 and 50 hashed packages into `~/.local` (241 MB). Memory, sampled every 15 s: peak 3.7 GiB used,
never under 3.6 GiB available, 0 swap, kernel memory-pressure stall 0.00 %; largest single process
1.1 GiB. Warnings only: `~/.local/bin` not on PATH (pip scripts), and pip could not parse the Debian
version string of `devscripts` (cosmetic).

**ORFS local build, 2026-10-12 00:19:50–01:19** (`./build_openroad.sh --local --threads 6`, normal
user, log `~/tools/logs/b14a_build.log`, ORFS's own `build_openroad.log`): **exit 0**, wall time
59 min 27 s, 0 error lines. Installed under `tools/install/`:
- **OpenROAD `26Q4-110-g91e5f5ff2f`** (Bazel 9.1.1, `--config=release`, GUI platform), 142 MB.
  Bazel fetched many actions from OpenROAD's public remote cache; `~/.cache/bazel` is 3.0 GB.
- **Yosys `0.68+ (git sha1 a5af9d690)`** from the ORFS submodule, 74 MB. `read_slang` is
  **built in** (sv-elab `3dddccd4`, slang `8acc660a`); there is no `slang.so`, so the runbook's
  `yosys -m slang -p slang_version` fails, while `yosys -p slang_version` works. ORFS 3451ca1's
  `synth_preamble.tcl` says the same ("read_slang is built into Yosys (>=0.67); no plugin load
  needed"), and only uses slang when `SYNTH_HDL_FRONTEND=slang`.
- kepler-formal, 66 MB. KLayout 0.30.12 at `/usr/bin/klayout`. No standalone `sta` (OpenSTA is
  inside `openroad`).

Memory, every 15 s: peak 5.8 GiB used, never under 1.3 GiB available, peak swap 1.06 GiB, swap-in
and swap-out rates 0 when checked at the peak (00:55), largest single process 1.4 GiB (Bazel's JVM
and the link). No OOM. Warnings: compiler warnings in third-party code (ABC/kissat
"changes meaning", deprecated comma subscripts, one ABC `gzprintf` stub `#warning`) and GCC's
"using serial compilation of N LTRANS jobs" notes. Disk after build: 23 GB used, 934 GB free.
ORFS tree clean; submodules unchanged.

## 5. Boundaries for Claude sessions

- GARUDA work only in `/home/aneesh/garuda_soc`; never touch the Windows checkout.
- No RTL changes, commits, pushes or history rewrites without explicit approval; files are left
  uncommitted for the user.
- Every `sudo` command is explained and run by the user.
- Tools live under `~/tools/<tool>` and `~/external/<tool>`; removal is one directory each.
- The ASAP7 gcd run proves the toolchain, not GARUDA.
