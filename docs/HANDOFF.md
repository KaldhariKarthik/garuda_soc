# GARUDA verification — handoff

Last updated 2026-08-04. Covers the core (`rtl/core`) and the DSU (`rtl/dsu`).

---

## 1. Where things stand

Before this work, the RTL had never executed a single instruction — every test drove
pipeline-stage inputs by hand. It now boots, runs C, and passes the RISC-V ISA suite in
instruction-by-instruction lockstep against Spike.

| suite | result | command |
|---|---|---|
| ISA (rv32ui + rv32um + rv32mi), self-check **and** Spike lockstep | **63/63** | `make regress` |
| — same, with fixed AHB wait states | 63/63 | `make regress_wait` |
| — same, randomised waits 0..8 | 63/63 | `make regress_rand SEED=n` |
| Core Sanity directed tests | **9/9** | `make test_sanity` |
| DSU vs cycle-accurate golden model | **645/645** (seeds 1,2,3,5,7) | `make test_dsu` |
| Block-level unit TBs | **14,359 checks, 0 fail** | `make test_units` |
| Legacy unit smokes | 7/7 | `make test_core` |
| Boot / first C program | pass | `make test_boot` / `make test_c` |

**23 RTL bugs found and fixed** (see §4). Zero known RTL defects outstanding.

> Correction to earlier verbal counts: the authoritative number is **23** numbered
> errata, taken from the `ERRATUM` markers in the RTL. Figures of 22 or 25 quoted during
> the work were miscounts.

---

## 2. Getting a working shell

**Nothing is on `PATH` by default.** One command fixes that:

```bash
cd ~/garuda_soc
source scripts/setup_env.sh      # expect six OK lines
```

| tool | location | role |
|---|---|---|
| Xcelium 22.09 `xrun` | `/home/install/XCELIUM2209/**tools/bin**` | regression |
| Incisive 15.20 `irun` | `/home/install/INCISIVE152/tools/bin` | coverage collection only |
| Incisive 15.20 `imc` | `/home/install/INCISIVE152/bin` | coverage merge/report |
| RISC-V GCC | `/home/vivado/2025.2/Vitis/gnu/riscv/linux_toolchain/lin64/bin` | prefix `riscv64-amd-linux-gnu-` |
| Spike | `~/external/spike-inst/bin/spike` | golden ISS, built from source |
| riscv-tests | `~/external/riscv-tests` | test sources |

Licence is `5280@192.168.6.16`. Without it `xrun` compiles and elaborates fine, then dies
at simulation with `xmsim: *F,NOLICN` — a late failure that looks unrelated to licensing.

### Environment traps that masquerade as RTL bugs

Both of these cost real debugging time. Neither is a core defect.

1. **Spike's NS16550 UART is hard-wired at 0x1000_0000** — exactly GARUDA's reset vector.
   `spike -m0x10000000:0x40000` fails with `devices ... overlap`. `tools/lockstep.py`
   already passes `--disable-dtb --pc=0x10000000 --priv=m`.
2. **The Vitis GCC defaults to PIC/PIE.** `la t0, tohost` becomes a GOT load; the GOT is
   empty on bare metal, so the address loads as **zero** and the store goes to address 0.
   The core executes it perfectly — it reads exactly like a broken load unit. Use `lla`,
   never `la`, and keep `-fno-pic -no-pie -mno-relax`.

**Spike's ISA string must name every extension GARUDA implements** or the golden model
raises illegal on correct instructions and the whole test "diverges". Currently
`rv32im_zicsr_zifencei_zicntr` — `rv32im` alone does **not** imply Zicsr.

---

## 3. What exists, and where

### Testbenches
| path | what |
|---|---|
| `tb/soc/tb_boot.v` | the main TB. Loads a `+HEX` image, runs it, records a commit log, reports pass/fail via `tohost`. Also injects interrupts, bus errors and wait states. |
| `tb/dsu/tb_dsu_top.sv` | DSU unit TB, compares against `DSUModel` |
| `tb/cov/garuda_cov.sv` | 7 covergroups, `bind`-ed into the core (no RTL edits) |
| `tb/core/tb_*.sv` | six constrained-random block TBs (from a teammate) |
| `rtl/ahb/ahb_mem_slave.v` | dual-port AHB memory model — **verification only**, not silicon |

### Tools
| path | what |
|---|---|
| `tools/lockstep.py` | normalises Spike's log and ours to `(pc, rd, value)`, reports the **first** divergence |
| `tools/elf2hex.py` | binary → `$readmemh` image |
| `tools/golden/DSU_Golden.py` | `DSUModel`, cycle-accurate, the DSU's de-facto spec |
| `tools/gen/DSU_gen.py` | generates DSU stimulus + expected vectors |

### Scripts
`setup_env.sh`, `run_regression.sh`, `run_sanity.sh`, `run_coverage.sh`.
`make help` lists every target.

### Software
`sw/common/` (crt0 + linker script), `sw/tests/` (directed tests), `sw/riscv-tests/`
(two envs — see §6).

---

## 4. Errata index — 23 fixed bugs

Every one is documented in full at its fix site; search the RTL for `ERRATUM <id>`.

### Bus interface
| id | file | defect |
|---|---|---|
| **I-1** | `garuda_iport_ahb_master.v` | Sampled HRDATA during the **address** phase, so every instruction was paired with the previous cycle's data. The first fetch returned `0x00000000` and the core trapped on instruction one. **It could not execute a single instruction.** |
| **D-1** | `d_port_ahb_master.v` | Same conflation on the data side. HWDATA was driven in the address phase and collapsed to 0 before the slave sampled it — **every store wrote zero**. Loads sampled HRDATA a cycle early. |

### Pipeline control
| id | file | defect |
|---|---|---|
| **F-1** | `id_ex.v`, `ex_stage.v` | A forwarded operand was lost across a multi-cycle stall: the producer drains out of MEM/WB and EX silently reverts to the stale register-file value. |
| **P-1** | `pipe_ctrl.v` | Load-use flushed ID/EX while MEM was stalled — which **destroys the load** parked there instead of inserting a bubble behind it. |
| **P-2** | `pipe_ctrl.v` | A predicted-taken branch held in IF/ID by a load-use stall was **flushed by its own predictor's redirect**. Timing-sensitive: passed with slow memory, failed with fast. |
| **P-3** | `pipe_ctrl.v` | `dsu_busy`/`wfi_hold` held ID/EX but never bubbled EX/MEM, so the parked instruction **re-committed every cycle** — caught as an instruction executing 381 times. |

### Decode
| id | file | defect |
|---|---|---|
| **C-1** | `decode_control.v` | SLLI/SRLI/SRAI ignored all of `funct7` but bit 5, so shift-by-≥32 executed instead of trapping. |
| **C-2** | `decode_control.v` | No `OP_MISC_MEM` case at all — **FENCE trapped**, which RV32I forbids. |
| **C-3** | `decode_control.v`, `branch_predict.v`, `id_stage.v` | FENCE.I implemented as an ID redirect to PC+4; the redirect flushes the prefetch buffer, which is exactly Zifencei's requirement. |
| **C-4** | `csr_file.v` | Zicntr shadows (`cycle`/`instret`/`cycleh`/`instreth`) were unimplemented. |

### Traps and CSRs
| id | file | defect |
|---|---|---|
| **T-1** | `branch_unit.v`, `ex_stage.v` | Cause 0 (instruction-address-misaligned) **was not implemented**. Without the C extension a jump to a non-4-byte-aligned target must trap. |
| **T-2** | `csr_file.v` | `misa` treated as read-only, so `csrsi misa,4` — the standard probe for the C extension — raised illegal. It is WARL. |
| **T-3** | `trap_ctrl.v` | `mtvec` base masked to **64 bytes** instead of 4, silently relocating every handler backwards. |
| **T-4** | `trap_ctrl.v`, `garuda_core_top.v` | **Interrupt entry was not gated on a valid instruction in EX.** An interrupt arriving on a pipeline bubble latched `mepc = 0`, so `mret` jumped to address 0. Any interrupt in a branch shadow destroyed the return address. |

### DSU
| id | file | defect |
|---|---|---|
| **DSU-1** | `dsu_stall.v` | The interlock **deadlocked** — holding ID/EX re-presents the same instruction, so the stall condition sustained itself. |
| **DSU-2** | `mac_unit.v` | MACLOAD/MACCLEAR/MACSAT latched pending products from their own meaningless operand fields (FLAG-A); a stale product also survived a MACCLEAR. |
| **DSU-3** | `dsu_stall.v` | compute→readback was not interlocked (FLAG-C / FLAG-2). |
| **DSU-4** | `mac_unit.v` | **Stage 2 never self-drained.** `acc` only updated when a new instruction arrived, so the last product of any sequence sat stranded indefinitely. This — not the missing interlock — is why FLAG-2 read 0 instead of 15. |
| **DSU-5** | `barrel_shifter.v` | The arithmetic right shift was **silently logical**: Verilog takes a conditional expression's signedness from both arms, and the left-shift arm is unsigned, so `>>>` lost its signed context. |
| **DSU-6** | `dsu_decoder.v` | MACSHIFT amounts 48..63 now raise illegal (FLAG-D closed in RTL, not documentation). |
| **DSU-7** | `dsu_decoder.v` | I-type `imm[11:9]` reserved, reclaiming 7/8 of the encoding space. |
| **DSU-8** | `overflow_flag.v` | An overflow coinciding with its own clear was **lost** (FLAG-E). |
| **DSU-9** | `dsu_top.v` | `dsu_busy` was the only DSU output not gated by `dsu_en`. |

### Patterns worth internalising

Four of these (**F-1, P-1, P-2, P-3**) are the same shape: *a flush or hold whose
premise is that an instruction has already advanced, firing while a stall is holding it
in place.* If you touch `pipe_ctrl`, check that every flush term is gated against every
hold source.

**F-1, P-1 and P-3 were unreachable until D-1 was fixed** — with a one-cycle D-port
there was never a multi-cycle MEM stall to expose them. Fixing one bug made three more
reachable, which is normal and worth expecting.

---

## 5. Debugging workflow

`docs/HOWTO_RUN.md` has the full version. In short:

1. **Lockstep first.** `cat sim/regress/<test>.lockstep.txt` prints the first
   instruction where GARUDA and Spike disagree, with three instructions of context.
   Only the first divergence matters — everything after is downstream.
2. **Disassemble.** `riscv64-amd-linux-gnu-objdump -d sw/riscv-tests/build/<test>.elf`
3. **Probe.** `tb_boot` carries built-in probes, all windowed by `+DBGFROM`/`+DBGTO`:

| plusarg | shows |
|---|---|
| `+DBGBUS` | instruction fetch: bus address/data and each pipeline stage |
| `+DBGTRAP` | trap entry: cause, target, every exception source |
| `+DBGD` | data bus, address phase and data phase separately |
| `+DBGM` | MEM stage and the writeback handshake |
| `+DBGEX` | EX stage, hazard and stall signals |
| `+DBGACC` | DSU accumulators |

4. **Waveforms** with `+WAVES`, then `simvision sim/.../waves.shm`.

**Suspect the testbench too.** Several apparent RTL bugs during this work were harness
faults: a TB driving inputs *at* the clock edge (racing the DUT's flops), a trap handler
clobbering a register the test held an expected value in, a test writing over its own
far-linked code. When RTL and model disagree, the model is a suspect too.

---

## 6. Test suites

### `sw/riscv-tests/` — two environments, deliberately

| env | reports via | used for |
|---|---|---|
| `env/riscv_test.h` | direct `tohost` store | rv32ui, rv32um — keeps the trap unit **out** of base ISA tests, so a failing ADD is reported by ADD |
| `env/p/riscv_test.h` | ECALL + trap handler | rv32mi, `ma_data`, div/rem — tests that are *about* traps |

The p-env carries **three GARUDA-specific deviations** from upstream, all documented in
its header. The critical one: `trap_vector` must be **64-byte aligned** because
`trap_ctrl` masked `mtvec[5:0]`. That mask is now fixed (T-3), so the alignment is
belt-and-braces rather than load-bearing — but leave it.

The p-env also contains a **software DIV/REM emulator** (`divrem_emu.S`). GARUDA has no
hardware divider by design (Sec. 7.2); the trap handler decodes the faulting instruction
and computes the result. Misaligned load/store emulation lives in the same file.

### Still excluded, with reasons

| test | why |
|---|---|
| `breakpoint` | probes Sdtrig debug-trigger CSRs. **No debug module exists** (README: Pending). Not a bug. |
| `pmpaddr` | no PMP, by design |
| `instret_overflow` | needs a counter-overflow mechanism; confirm against Sec. 13 |

### Lockstep not applicable (still must pass their own self-check)

`p-div/divu/rem/remu` — GARUDA emulates in ~100 instructions where Spike's hardware
divider takes one; the streams cannot match. `p-csr`, `p-mcsr`, `p-ma_fetch` — `misa`
bit 23 (X, non-standard extension) is set because of the DSU, and Spike knows nothing
about it.

---

## 7. Coverage

Run: `./scripts/run_coverage.sh`. Reports in `sim/cov/`.

**Collected with `irun`, not `xrun`** — IMC here is Incisive 15.20 and cannot read an
Xcelium 22.09 database (`*E,DBERR: serialization exception`). There is no
format-downgrade option, so the fix was to move the *writer* back to a matching vintage.
Both simulators use the same filelists.

### Two IMC traps that silently produce wrong answers

1. **`-initial_model union_all` is mandatory.** The default (`primary_run`) builds the
   merged model from the first run only and **discards every run with a different top
   module** — all seven unit databases contributed nothing, with no error reported.
2. **`report -summary` shows `n/a` for functional coverage** even when covergroups are
   populated. Use `report -detail -metrics covergroup`.

### Current numbers

DUT 73.24%; 24 of 44 design modules ≥95%. Split by metric:

| metric | mean |
|---|---|
| block (statement) | **98.5%** |
| expression (branch) | **96.1%** |
| toggle | **86.0%** |

**Every module below 95% is at 100% statement coverage.** `clic_ctrl`,
`garuda_if_stage_top`, `garuda_pc_gen` and `trap_ctrl` have **zero uncovered blocks**.
The shortfall is entirely toggle — individual bits of wide buses that never change
state, not logic that never ran. Writing more tests that exercise *logic* cannot move
these numbers.

Some toggle bits are unreachable in principle: `mcycleh` needs 2³² cycles to flip its
low bit.

---

## 8. What is left

1. **`docs/COVERAGE.md` is partly stale** and committed. It lists SHV under "blocked on
   an open design decision" — that was disproven (see §9) — and carries pre-closure
   figures. Correct or delete those sections.
2. **Reconcile both `.xlsx` plans.** `Done` columns unset; the DSU plan's Open Questions
   rows 1–9 are all resolved, several of them in RTL.
3. **Decide the coverage signoff position.** A judgement call, not more testing: meet the
   bar on statement/branch, report toggle separately with per-module written waivers.
4. **Tell the teammate their coverage figures are stale.** Their TBs inlined a snapshot
   of the DUT predating the shamt and FENCE fixes, and two of their reference models were
   wrong against real RTL (both corrected here). Their ~97% needs regenerating.

---

## 9. Design questions that were answered by evidence

- **SHV vectoring.** `clic_ctrl.v`'s header flags an unresolved question: does `mtvt`
  hold jump instructions or handler pointers? **Answered: jump instructions.** SHV
  interrupts through a 4096-entry jump table work end to end. An earlier conclusion that
  SHV was broken was wrong — the `mepc = 0` symptom was **T-4**, and SHV merely hit that
  window more often because it arrives at arbitrary points in the instruction stream.
- **FLAG-2 / FLAG-C** (compute→readback). Closed as an **RTL interlock**, not a software
  ordering contract — a contract nothing in the toolchain can enforce would outlive
  everyone who knows about it. Note the interlock alone was **not sufficient**; DSU-4
  (self-draining stage 2) was the actual fix.
- **FLAG-A, FLAG-D, FLAG-E** — all closed in RTL (DSU-2, DSU-6, DSU-8).

## 10. Scope limits — state these, do not let numbers imply otherwise

Only `rtl/core/` and `rtl/dsu/` exist. `rtl/clic/`, `dma`, `debug`, `isram`, `dsram`,
`ahb2apb` and every peripheral are **empty directories**. There is no interconnect and no
TCM — `ahb_mem_slave.v` stands in for both, and its header states plainly that it
verifies nothing about arbitration, address decoding or the AHB-to-APB bridge.

A passing regression here says the **core and DSU** work. It says nothing about the SoC.
