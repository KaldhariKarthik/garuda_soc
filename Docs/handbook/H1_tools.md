# H1. Tools: pinned versions and setup

## Open-tool flow (Track A, any machine)
```
source tools/run/env.sh                     # pinned tools first on PATH; Cadence untouched
make -f flow/mk/track_a_run.mk check_tools_a    # fails on any version mismatch
```
`tools/run/env.sh` puts the pinned tools first on PATH from `$GARUDA_TOOLS`
(default `~/tools`), enables gcc-toolset-12 (Verilator `--timing` needs a C++20
compiler; Rocky 8's system GCC is 8), and points `python3` at 3.12 through an
untracked `.garuda_bin/` (Rocky 8's python3 is 3.6; the flow needs `tomllib`).
The oss-cad-suite is **not** put on PATH: it ships its own Verilator 5.053-devel
and iverilog, which would silently replace the pinned ones. Formal tools are
called as `$OSS_CAD/bin/<tool>`.

| Tool | Pinned | Where | Use |
|---|---|---|---|
| Verilator + verilator_coverage | 5.052 (2026-09-05) | `~/tools/verilator` | working simulator, code coverage |
| Icarus Verilog | 12.0 | `~/tools/iverilog` | 4-state cross-check (H2) |
| Spike | 1.1.1-dev, `609dbe0` | `~/tools/spike` (source `~/tools/src/riscv-isa-sim`) | ISA reference |
| RISC-V GCC | xPack riscv-none-elf 15.2.0 (rv32im/ilp32 multilib) | `~/tools/riscv` | firmware, ISA tests |
| riscv-tests | `bcffa2b` | `~/tools/src/riscv-tests` | ISA suite sources |
| Yosys / SBY / ABC / solvers | Yosys 0.69+190, SBY 0.69 (oss-cad-suite 2026-10-04) | `~/tools/oss-cad-suite` | formal, mutation (mcy), equivalence (eqy) |
| Python | 3.12 | system `python3.12` | flow scripts |
| dtc | 1.8.1 | `~/tools/dtc` | Spike build |
| riscv-formal | `c992aa61fdfe` (YosysHQ, main on 2026-10-11) | `~/tools/src/riscv-formal` | E4 formal ISA checks |
| riscv-arch-test | `6e8a45123f14` (riscv-non-isa, main on 2026-10-11) | `~/tools/src/riscv-arch-test` | E5 compliance suites |
| riscv-dv | `0d71c2b666de` (chipsalliance, master on 2026-10-11) | `~/tools/src/riscv-dv` (pygen) | E6 random programs |
| Sail RISC-V | release 0.15 (`sail_riscv_sim`) | `~/tools/sail` | second ISA reference (E5) |
| RISCOF / riscv-config / riscv-isac / pyvsc | 1.25.3 / 3.18.3 / 0.18.0 / 0.9.1.10086043874 | venv `~/tools/venv-a` (Python 3.12) | E5 framework, E6 constraints |

The last five rows come from `tools/run/install_tools_a.sh` (P0.6), which is
idempotent and pinned (commits, Sail release URL, pip versions); it writes
`~/tools/PINS_track_a.txt`, and `check_tools_a` compares the installed tools
against the pins above.

**Known pin note.** riscv-config 3.18.3 declares `pyyaml==5.2`, which has no
Python 3.12 build; the venv uses PyYAML 6.0.3 instead, so `pip check` prints one
conflict. Smoke test 2026-10-11: `riscof setup` and a `riscv-config` check of
the generated ISA/platform YAML both run clean. Recheck when E5 runs the real
suites.

## Cadence flow (authoritative, Karthik's machine)
`source scripts/setup_env.sh`: Xcelium 22.09, IMC/irun 15.2, vManager, JasperGold
when licensed. On the Rocky laptops Cadence scripts that test for "Red Hat"/"CentOS"
misbehave; check the Rocky causes first (unsupported-OS checks, `checkSysConf`,
missing EL8 packages) before blaming the tool.

## Version changes
A tool version changes only by a commit that updates this table, the pins in
`flow/mk/track_a_run.mk`, and reruns the runner qualification (H2). Results produced
by different tool versions are never compared without naming the change.
