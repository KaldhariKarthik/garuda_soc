# GARUDA Verification — Work Log and Plan

Date: 2026-07-29 · Commit on `main`: `5e22971 "Completed Booting"` (pushed, 22 files,
1651 insertions, zero build artifacts)

---

# PART 1 — WHAT WAS DONE

## 1.1 Starting state

The repo had RTL for the full RV32IM core plus the DSU, seven unit testbenches, and two
detailed verification plans in `.xlsx`. What it did **not** have was any testbench that
ran a real instruction stream. `rtl/ahb/` and `tb/soc/` were empty directories — no bus
fabric, no memory model, no way to boot. Every prior test drove stage inputs by hand.

## 1.2 Environment discovery — and why it mattered

Nothing needed was on `PATH`. Each of these was found by inspection, and two of them
caused failures that look exactly like RTL bugs.

| Tool | Location | Why needed / what it cost |
|---|---|---|
| Xcelium `xrun` 22.09 | `/home/install/XCELIUM2209/**tools/bin**` | Simulator. Note `tools/bin`, not `bin` — the obvious path is wrong. |
| License | `LM_LICENSE_FILE=5280@192.168.6.16` (from `/home/install/cshrc`) | Without it xrun compiles and elaborates fine, then dies at `xmsim: *F,NOLICN`. Silent until simulation. |
| RISC-V GCC | `/home/vivado/2025.2/Vitis/gnu/riscv/linux_toolchain/lin64/bin`, prefix `riscv64-amd-linux-gnu-` | A *Linux* toolchain, but it has an `rv32imac/ilp32` multilib, so `-march=rv32im -mabi=ilp32` works for bare metal. Verified before relying on it. |
| Spike | built from source → `~/external/spike-inst` | No package available. Built with the host `g++` 8.5 + `dtc` from the Vivado tree. ~4 min. |
| riscv-tests | cloned → `~/external/riscv-tests` | 42 rv32ui + 8 rv32um sources. |
| `imc` / `iccr` | `/home/install/INCISIVE152/bin/imc`, `/home/install/XCELIUM2209/tools.lnx86/iccr` | Coverage reporting. Initially reported as absent — that was wrong, it is simply not in `tools/bin`. |
| `openpyxl` | system python3 | To read the two `.xlsx` verification plans. |

### Two environment traps that mimic RTL bugs

**Spike's NS16550 UART is hard-wired at 0x1000_0000** — exactly GARUDA's reset vector.
`spike -m0x10000000:0x40000` fails with `devices ... overlap`. Working invocation:
`--disable-dtb --pc=0x10000000`. Side effect: HTIF can no longer terminate on the tohost
write, so spike runs into the post-tohost spin loop — handled in `lockstep.py` by
truncating both logs at the terminal self-branch.

**The Vitis GCC defaults to PIC and PIE.** `la t0, tohost` silently became
`auipc; lw` through the GOT, which is never populated on bare metal, so the address
loaded as **zero** and the pass/fail store went to address 0. The core executed it
perfectly. This cost real debugging time and reads exactly like a broken load unit.
Fix needed all three: `lla` instead of `la`, `-fno-pic`, `-no-pie -static`.

## 1.3 Files created

| File | What it is | Why it exists |
|---|---|---|
| `rtl/ahb/ahb_mem_slave.v` (206 lines) | Dual-ported AHB-Lite memory model | There is no arbiter or address decoder in the tree, so faking a fabric would have been fiction. Both masters attach directly to one image. Header states explicitly what this therefore does **not** verify (arbitration, decode, bridge CDC). Supports per-port wait-state injection and the two-cycle ERROR response. |
| `tb/soc/tb_boot.v` (274 lines) | The boot testbench | First TB in the project to run real instructions. `+HEX` image load, tohost pass/fail, `+IWAIT`/`+DWAIT`, and a commit-log probe. |
| `tb/soc/filelist_boot.f` | Filelist | Pulls `filelist_core_dsu.f` (real DSU, not the stub) plus the memory model and TB. |
| `sw/common/crt0.S` | C runtime startup | Stack, `.bss` zeroing, `main()`, tohost handshake. |
| `sw/common/link.ld` | Linker script | Memory map at 0x1000_0000 matching `garuda_pc_gen.v:42`. |
| `sw/tests/boot6.S` | 6-instruction boot smoke | Smallest program proving fetch + decode + ALU + forwarding + store. Instruction 3 (`add x3,x1,x2`) needs **both** EX forwards — a core with broken forwarding produces 0 and still "runs". |
| `sw/tests/ctest1.c` | First C test | 10 checks: `.data` survival, sign/zero-extending loads, `.bss` zeroing, all three store widths, calls/stack/loops, M-extension including negative multiply. Returns the failing check number so a failure names itself. |
| `sw/tests/dsu_flag2.S` | FLAG-2 probe | Contrasts an immediate compute→read against one spaced by 3 instructions. |
| `sw/Makefile`, `sw/riscv-tests/Makefile` | Software builds | Produce `.elf` and `.hex` from the **same link**, so RTL and golden model cannot execute different images — the precondition for lockstep meaning anything. |
| `sw/riscv-tests/env/riscv_test.h` | GARUDA env for riscv-tests | Upstream's `p` env links at 0x8000_0000 and reports via ECALL into a trap handler. This env reports by direct tohost store, so an ADD failure is reported by ADD, not by the trap unit. |
| `tools/elf2hex.py` | Binary → `$readmemh` image | Emits explicit `00000000` for uncovered words rather than leaving holes — a hole that reads as `x` becomes a decode error thirty cycles later that looks nothing like its cause. |
| `tools/lockstep.py` (176 lines) | Spike log normalizer + comparator | Reduces both logs to `(pc, rd, value)`. Without it the first run is thousands of formatting mismatches with the real bug invisible inside. Reports only the **first** divergence — everything after is downstream of it. |
| `scripts/run_regression.sh` | Regression driver | Elaborates **once** into a snapshot, then `-R` per test. Two independent verdicts per test (tohost self-check **and** Spike lockstep) because a test can pass its own check and still diverge. |

## 1.4 The four RTL bugs — how each was found and fixed

### ERRATUM I-1 — `garuda_iport_ahb_master.v`
**Symptom:** 0 instructions retired in 2000 cycles. Core redirected to 0x00000000 on
instruction one and spun forever.

**How found:** Added a `+DBGBUS` fetch-path probe to `tb_boot`, then `+DBGTRAP`. Trap
cause 2 (illegal instruction) with `id_illegal=1`. The decoder's `OP_IMM` case is
complete and correct, so the instruction word itself was suspect — printed it and found
IF/ID holding `pc=0x10000000` with `instr=0x00000000` while the real instruction arrived
that same cycle.

**Root cause:** `fetch_outstanding` was set on the same edge that drove `i_haddr_o`, so
`data_phase_done = fetch_outstanding & i_hready_i` fired during the **address** phase.
Every instruction was paired with the previous bus cycle's HRDATA.

**Fix:** AHB-Lite is pipelined; one flag cannot express it. Split into `addr_outstanding`
and `data_outstanding`, with a `drop_cnt[1:0]` replacing `drop_pending` because up to two
transfers can now be in flight across a redirect. FIFO reservation extended to count both.

### ERRATUM D-1 — `d_port_ahb_master.v`
**Symptom:** After I-1, the commit log matched the hand-written golden reference exactly
— but tohost never fired.

**How found:** `+DBGD` D-port probe. The store reached the bus correctly
(`addr=1000f000 wdata=00000001`) — but that was the address phase.

**Root cause:** The same conflation. `d_hwdata_o` was driven from the same combinational
block as HADDR/HTRANS, so once the address phase completed the pipeline advanced,
`start_i` fell, and HWDATA collapsed to 0 in the cycle the slave samples it. **Every
store wrote zero.** Loads had the mirror defect: `ok_done_o`/`mem_stall_o` released on
the address phase, so `load_formatter` sampled HRDATA a cycle early.

**Fix:** Two-state FSM (`S_ADDR` → `S_DATA`). HWDATA registered at address-phase
acceptance and held across wait states. Completion is now a data-phase event. A D-port
access is inherently two cycles over AHB-Lite with no write buffer — not a regression
that can be optimised away.

### ERRATUM F-1 — `id_ex.v` (+ `ex_stage.v`, `garuda_core_top.v`)
**Symptom:** After D-1, 39/44 riscv-tests passed. All five failures were stores.

**How found:** `lockstep.py` pointed at one instruction: a load returned `0x00000617`,
which is the *instruction word* at 0x10000230 — the pre-`addi` value of `a2`. D-port
trace confirmed the load's address was 0x10000230, not 0x10000540.

**Root cause:** Forwarding is re-evaluated combinationally every cycle, but its sources
drain away while EX is held: `pipe_ctrl` bubbles MEM/WB on every D-port wait-state cycle,
`memwb_reg_write` falls, `forward_unit` reverts to `FWD_NONE`, and EX falls back to the
stale register-file value read in ID. The store (1 instruction behind the producer) got
the right address; the load (2 behind) got the stale one.

**Fix:** Expose the post-forward operands from `ex_stage` and have `id_ex` **capture**
them while held. Idempotent: on the first held cycle the producer is still visible; on
later cycles the select is already `FWD_NONE` so the mux returns the now-correct value.

### ERRATUM P-1 — `pipe_ctrl.v`
**Symptom:** One test left (`ld_st`): a load never retired, a later read returned `X`,
and one PC retired twice.

**How found:** `+DBGM` MEM-stage probe. At c15 the store stalls MEM; at c17 MEM contains
a bubble and the load at 0x10000014 has vanished from the pipeline entirely.

**Root cause:** The load-use interlock bubbles ID/EX so a gap opens *behind* a load that
has already advanced into EX/MEM. During a D-port wait that premise is false — EX/MEM is
held — so flushing ID/EX **destroys the load parked there**. Flush outranks stall inside
`id_ex.v`, so the hold does not save it.

**Fix:** Gate `load_use_stall_i` by `~mem_stall_i` — exactly as redirects were already
gated on line 24 of the same file. A one-term fix that took a full debug cycle to locate.

> **F-1 and P-1 were latent behind D-1.** With the old one-cycle D-port there was never a
> multi-cycle MEM stall, so neither could be reached. Any wait-stated memory would have
> triggered both in silicon.

## 1.5 Also fixed

`Makefile` — the `xrun` leg `cd`-ed into `sim/<workdir>` and then passed repo-relative
filelist paths, so it could never resolve them (`*F,BDARGF`). Only the `xsim` leg worked,
because its `sed` rewrites paths absolute. Now runs from the repo root with outputs
redirected. New targets: `sw`, `isa_tests`, `test_boot`, `test_c`, `test_flag2`,
`regress`, `regress_wait`.

## 1.6 Results

| Check | Result |
|---|---|
| `boot6` — 6-instruction smoke | PASS, commit log matches hand-written golden exactly |
| `ctest1` — first C program | PASS, 98 instructions, all 10 checks |
| rv32ui + rv32um vs Spike lockstep | **44/44**, zero divergence |
| Same, `+IWAIT=2 +DWAIT=3` | **44/44** |
| 7 pre-existing unit smokes | all still pass — no regression from 5 modified RTL files |

## 1.7 Corrections to earlier statements

**"The DSU never computes."** Wrong. `tools/golden/DSU_Golden.py` already documents the
real behaviour: a product issued in cycle K reaches `acc` only on the next cycle
asserting `write_en` for that accumulator, so the final product of a sequence is
**stranded** in `sum_reg`/`carry_reg`. The repro (`MACCLEAR, MAC_SEL, MACRD_LO`, nothing
else touching acc0) hits precisely that. This is **FLAG-C**, already confirmed in the DSU
plan, and `DSU_gen.py --no-drain` exists specifically to provoke it. FLAG-2 is the
decision it was originally framed as — not a bigger defect.

**"IMC is not present."** Wrong. It is at `/home/install/INCISIVE152/bin/imc`, with
`iccr` under `/home/install/XCELIUM2209/tools.lnx86`. Coverage is not blocked.

Still open and **unconfirmed**: a suspected `dsu_stall` deadlock (`dsu_busy` latching
high permanently, same PC retiring repeatedly). Not in FLAG-A..E. Must be validated
against `DSUModel` before any RTL change — it may be an artefact of the repro.

---

# PART 2 — THE PLAN

Seven deliverables. Items 1, 2 and most of 7 are already done. All three scope choices
were taken at maximum (full Phase-2 Core Sanity TB, implement the FLAG-C interlock, cut
nothing), which makes this **~10-11 working days, not 5**. Ordered so that if the
calendar wins, days 1-6 alone close items 1, 2, 3, 5, 6, 7 and leave only coverage depth.

### Status against the mentor's list

| # | Deliverable | Status |
|---|---|---|
| 1 | Booting | ✅ done |
| 2 | C verification | ✅ done (basic); extend with more C tests |
| 3 | Core verification | 🟡 ISA lockstep done; Phase-2 Core Sanity TB (22 P0 rows) outstanding |
| 4 | Coverage (code + functional) | ⬜ not started, unblocked |
| 5 | DSU verification | 🟡 golden model + generator exist; `tb_dsu_top.sv` missing; FLAG-A/C fixes outstanding |
| 6 | Memory test | 🟡 covered indirectly by riscv-tests; directed tests outstanding |
| 7 | Instruction test | 🟡 rv32ui/um done; `div/rem`, `ma_data`, `fence_i`, CSR/system, Custom-0 outstanding |

### Two orderings that are load-bearing

- **Trap env first.** Traps, `div/rem` (illegal by design, Sec. 7.2), `ma_data`,
  ECALL/EBREAK and bus-error tests all need one handler. Built once, it unblocks parts of
  items 3, 6 and 7 simultaneously.
- **All RTL changes before coverage.** FLAG-A and FLAG-C are RTL fixes. Coverage
  collected on RTL that is about to change is wasted compute.

### Day 1 — trap-handler env (unblocks 3, 6, 7)
Create `sw/riscv-tests/env/p/riscv_test.h` **alongside** the existing tohost env, not
replacing it — keeping the trap unit out of the first ISA test is a property worth
keeping. Add `.text.trap` to `link.ld` for an aligned `mtvec`. Re-enable `div/divu/rem/
remu` (via software Newton-Raphson emulation in the handler), `ma_data`, and add `rv32mi`.

### Day 2-3 — Phase-2 Core Sanity TB (item 3)
Work the 22 P0 rows of the `2 Core Sanity TB` sheet. **Extend `tb_boot.v`, do not write a
second TB** — rows 1, 2, 3, 5, 6, 10, 11, 12 are already satisfied. New capability
needed: CLIC interrupt injection (row 18 wants many offsets into a loop), bus-error
injection in the memory model (row 17), seeded random per-access wait states 0..8 (row
21). Directed programs under `sw/tests/sanity/`. **Row 22 (flush + outstanding fetch with
I-port wait states) is the highest-value row** — it targets the `drop_cnt` logic rewritten
under I-1, which is new and currently only proven by the wait-state regression passing.
Expect bugs; traps, CLIC and WFI have never seen a real instruction stream.

### Day 4 — bug fixing + memory test (item 6)
Fallout from days 2-3, plus directed tests: alignment matrix at every width and offset,
byte-enable correctness for SB/SH at all lane positions, back-to-back load/store to the
same address (the F-1/P-1 pattern), AHB error on both ports, TCM boundary addresses,
random wait-state sweep.

### Day 5-6 — DSU verification (item 5)
- **`tb/dsu/tb_dsu_top.sv`** — reads `dsu_stim.mem` (4 words/test) and `dsu_expected.mem`
  (8 words/test) in the format `DSU_gen.py` already documents. This is the missing piece
  named in the DSU plan Infrastructure row 4.
- **FLAG-A** (`mac_unit.v`) — MACLOAD/MACCLEAR/MACSAT assert `write_en` and latch
  `sum_reg`/`carry_reg` with products of their own meaningless operand fields, which the
  next accumulate adds in. Gate the write to compute ops only.
- **FLAG-C** (`dsu_stall.v`) — extend `cur_is_2cycle` to the compute ops (`MAC_SEL`,
  `MACSUB`, `MACABS`, `MACDOT`) so compute→readback interlocks. **This is the FLAG-2
  decision, taken as an RTL interlock.** Costs one cycle on readback.
- **Suspected deadlock** — confirm against `DSUModel` before changing anything.
- **`DSU_gen.py`** — migrate off `ArchDSU` to `DSUModel`, drop the `settle` op now that
  the interlock makes compute→read safe (Infrastructure row 3).
- **DSU through the pipeline** — extend `dsu_flag2.S` into a Custom-0 suite run through
  `tb_boot` (Core Sanity rows 9 and 13); re-run the FLAG-2 repro to confirm closure.

### Day 7-8 — coverage (item 4)
**Verify Incisive 15.2 `imc` can read Xcelium 22.09 databases first** — version skew is
the main risk, `iccr` from the Xcelium tree is the fallback. `xrun -coverage all
-covoverwrite` across the regression and every unit TB. Functional covergroups via
SystemVerilog `bind` onto the Verilog RTL: 8 core groups (decode, load/store, ALU,
hazards, traps, CLIC, AHB protocol) and 7 DSU groups (instruction × accumulator = 30
legal combinations, operand corners, accumulator range, shift space, illegal space,
pipeline sequences, flush/reset). Merge with the 7 unit-TB databases. Target ≥95%
statement/branch/toggle with **every exclusion justified in writing** — core plan
Coverage rows 9 and 10 make written waiver rationale part of signoff.

> Known gap to state explicitly in the write-up: `filelist_clic_ctrl.f` points at a
> `tb_clic_ctrl.v` that was never written, and `tb_id_stage.sv` / `tb_mem_stage.sv` have
> no filelists or make targets. A coverage number that silently excludes the interrupt
> controller is worse than no number.

### Day 9-10 — buffer, write-up, plan reconciliation
Update both `.xlsx` `Done` columns; correct DSU plan row 31 (Open Questions row 5 already
records it as wrong vs RTL). Errata document covering I-1, D-1, F-1, P-1 and the FLAG-A/C
resolutions. Coverage write-up with waiver justifications.

## Files

**Create:** `sw/riscv-tests/env/p/riscv_test.h`, `sw/tests/sanity/t*.S`,
`tb/dsu/tb_dsu_top.sv`, `tb/dsu/filelist_dsu_top.f`, `scripts/run_coverage.sh`,
covergroup bind files under `tb/cov/`.

**Modify:** `tb/soc/tb_boot.v`, `rtl/ahb/ahb_mem_slave.v`, `rtl/dsu/mac_unit.v`,
`rtl/dsu/dsu_stall.v`, `tools/gen/DSU_gen.py`, `sw/common/link.ld`,
`sw/riscv-tests/Makefile`, `scripts/run_regression.sh`, both `.xlsx` plans.

**Reuse, do not rewrite:** `tools/golden/DSU_Golden.py` (`DSUModel` is validated against
RTL as of 2026-07-20), `tools/lockstep.py`, `tools/elf2hex.py`, `rtl/ahb/ahb_mem_slave.v`.

## Verification

- `make regress` and `make regress_wait` stay at 100% after **every** RTL change — this
  is the gate for the DSU fixes in particular.
- `make test_core` (7 unit smokes) after every core RTL change.
- New: `make test_sanity`, `make test_dsu`, `make coverage`.
- Every DSU RTL change re-validated against `DSUModel`. The RTL wins over the document,
  but `DSUModel` is validated against the RTL — so a divergence is a real bug in one of
  them, not a formatting difference.

## Note on the pushed commit

`5e22971` on `main` is clean: 22 source files, zero build artifacts, `.gitignore`
correctly excluding `sw/build/` and `sw/riscv-tests/build/`. One thing now in public
history on `github.com/KaldhariKarthik/garuda_soc`: the license-server address
`5280@192.168.6.16` and absolute paths under `/home/install` and `/home/vivado`, as
defaults in `scripts/run_regression.sh`. They are env-overridable and the IP is RFC1918,
so this is a judgement call rather than a leak — but rewriting history later is far more
expensive than deciding now.
