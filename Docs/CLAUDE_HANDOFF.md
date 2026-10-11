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
| B1.4a ORFS | cloned at pinned commit; `sudo ./setup.sh` **awaiting approval** |
| B1.4b–h other tools | not started |
| B1.5 `flow/pd/TOOLS.md` | not started |
| B1.6 ASAP7 gcd gate | not started |
| B1.7, B2, B3 | gated on explicit approval after B1.6 |

## 3. Tool pins

| Tool | Pin | Status |
|---|---|---|
| OpenROAD-flow-scripts | `3451ca1f56902a49baf50bb8eba345eb709cf9c8` | cloned (not built) |
| Icarus Verilog | `v12_0` = `d61ab44c8a62d10dc80c3ae219387de04b7217c7` | candidate |
| Verilator | `v5.052` | candidate |
| SymbiYosys | tag matching ORFS's Yosys, chosen after B1.4a | candidate |
| Spike | `17e8a69fb75546dea445cfc0fb78769d2510f339` (master, 2026-10-11) | candidate |
| riscv-tests | `7b68f7b91f827f8d94cc1c57ff123752c5c8f704` (master, 2026-10-11) | candidate |
| RISC-V GCC | apt `gcc-riscv64-unknown-elf` first; version unknown until `apt-get update` | candidate |

The environment is **not reproducible** until every row is installed and its hash/version is
recorded in `flow/pd/TOOLS.md` from command output.

## 4. Boundaries for Claude sessions

- GARUDA work only in `/home/aneesh/garuda_soc`; never touch the Windows checkout.
- No RTL changes, commits, pushes or history rewrites without explicit approval; files are left
  uncommitted for the user.
- Every `sudo` command is explained and run by the user.
- Tools live under `~/tools/<tool>` and `~/external/<tool>`; removal is one directory each.
- The ASAP7 gcd run proves the toolchain, not GARUDA.
