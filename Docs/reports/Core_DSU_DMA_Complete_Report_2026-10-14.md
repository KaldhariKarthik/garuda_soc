# Core, DSU and DMA: complete report (Track A)

Part of [[MOC - Garuda SoC (C)]] · sources: [[Core and DSU Verification Status (C)]], [[Core and DSU Coverage Report (C)]], [[DMA Verification Status (C)]], [[Karthik - Track A RTL changes and rulings (C)]], [[Bug Register Handoff for Karthik (C)]] · written 2026-10-14

Author of the work: Sreyesh (Track A, verification). Evidence is in `logs/<blk>/evidence/` of `~/garuda_track_a`. Numbers come from the open-tool flow (Verilator 5.052, SymbiYosys, Spike) unless a line says Cadence.

---

## 1. At a glance

| Block | Verification state | Bugs found | RTL changed | Waiting on |
|---|---|---|---|---|
| **Core** (RV32IM) | Done on the open flow: Spike co-simulation, arch-test 59/59, riscv-formal 48/48, 1.08 billion instructions compared, coverage 100 % after reviewed exclusions | 11 new (T-12, T-13, T-14, T-16, T-17, T-18, BUS-E, C-16, C-17, CORE-4, RDC-1) | 7 fixes in `rtl/core`, `rtl/debug` and 2 nets in `rtl/soc` | Karthik's rulings; signing off T-12, T-17, T-18, BUS-E, RDC-1, C-16, CORE-4 |
| **DSU** (MAC coprocessor) | Done on the open flow: 18 properties proven, 8/8 planted defects killed, coverage 100 % | DSU-14 to DSU-18 (all need a ruling) plus bench problems TB-41, TB-42, TB-43, TB-45 | None. The disagreements are spec versus RTL. | Karthik: which side is right |
| **DMA** | Done on the open flow except the rulings: functional 442/442, code 100 % after 27 waivers, 24/24 planted defects killed | DMA-9 to DMA-18 (all RULING-NEEDED) | AUD-13 only (`dma_apb_slave.v`) | Karthik's rulings DMA-9 to DMA-18 |
| **AHB / AHB2APB** (support work) | 62 properties proven, 20/20 planted defects killed, coverage 100 % after 298 waivers | AHB-6, AHB-7, APB-1, APB-2, APB-3 | APB-2 (one line in the bridge) | Karthik: AHB-7, APB-1 |

Three things limit today's picture:
1. **Simulation licences are blocked** (`NOLICN`, flag -42). Compile and elaboration work in Cadence; running tests does not. So there are **no Cadence/IMC coverage numbers from this session**. Every coverage number here is from Verilator.
2. **The RISC-V toolchain and Spike are not installed on the Cadence laptop**, so the ISA and co-simulation runs happen on the other machine.
3. **Several items are fixed in the RTL but not signed off** in the register (see section 5).

---

## 2. Method: what was run and how

| Technique | What it does | Where it found bugs |
|---|---|---|
| **Spike co-simulation** | Every retired instruction of the RTL compared with the Spike ISS (via an RVFI port added to the core) | C-17 (minstret lag), T-18 (via arch-test), many core corner cases |
| **riscv-arch-test 3.10.0** | 59 standard tests, signatures compared with Spike | T-18 (misaligned JAL mtval) |
| **riscv-dv random programs** | 85 random programs through co-simulation | none new; 141,669 instructions, 110 traps |
| **riscv-formal** | Bounded model checks of the core | none new; 48/48 pass |
| **SVA and formal properties** (SymbiYosys) | Properties bound into the RTL | BUS-E (`a_iport_pc_aligned`), T-12, T-17 via coverage tests |
| **Stress and endurance** | 1000 seeds; 1,084,831,114 instructions each compared with Spike | none new, T-17 and BUS-E were already fixed |
| **Coverage closure** | Tests written for every reachable hole | T-17 (`t_cov_fault`), BUS-E (`t_cov_misfetch`), TB-40, TB-41 |
| **Planted-defect (mutant) runs** | Inject known bugs and check a named check kills each | DSU-14, TB-42 (three mutants survived the block bench) |
| **Benches written from the spec** | Independent reference written from the document, not from the RTL | DSU-17, DSU-18, DMA-9 to DMA-15 |
| **vPlan trace** | Maps every vPlan row to a property, test or covergroup | DSU-15 (`a_macsat` had no implementation), uncovered vPlan items |
| **External plan review** | Cross-check of a second team's plan against the RTL | DMA-16, DMA-17, DMA-18, APB-2 |

---

## 3. Runs and results

### 3.1 Core

| Item | Result |
|---|---|
| RVFI port | 87/87 programs, 652,930 records identical to the commit-log probe |
| Spike co-simulation | All suites pass, 0 mismatches. 6 negative controls (rd, store, pc, trap, dropped interrupt, extra interrupt) all caught |
| riscv-arch-test | 59/59. 44 identical; 15 privilege tests identical except the trap-signature header word (ARCH-DEV-1: `mtvec.MODE` is hardwired to 3 for the CLIC. No RTL change.) |
| riscv-dv | 85/85 programs pass, 0 mismatches. 15 of 100 not generated |
| riscv-formal | 48/48 pass |
| Stress, 1000 seeds | 1000/1000 pass (690 co-simulated runs of 13 self-checking programs) |
| Endurance | 1,084,831,114 instructions, each compared with Spike (2092 passing runs, 9,375 traps) |
| T-13 and T-14 | Fail before the fix, pass after. `tb_trap_ctrl`: 47 checks, 4 fail before; 64 checks, 6 fail before; all pass with both fixes |
| pipe_ctrl formal | First time in formal. The nine [N-11.3] properties are bounded at depth 30 |
| Block regression (Verilator) | tb_ahb_ic 802, tb_dma 63, tb_debug 93, tb_clic 17, tb_mem 18 and others pass, identical to HEAD |
| Closing regression | `nightly_a` PASS, 0 unexpected rows. `fast_a` PASS in 2 min 43 s |
| Throughput | tb_boot 383 k instructions/s without waits, 111 k with random waits |

### 3.2 DSU

| Item | Result |
|---|---|
| Properties | 18 PROVEN, covers COVERED |
| Planted-defect run | 8/8 mutants killed by a named check (5 block scoreboard, 2 core-level, 1 formal) |
| Sub-block benches | 7 ported benches pass. The other 6 (TB-43) have new spec-written benches: overflow_flag 20k checks, shifter 6.9k, decoder 20k, stall 840/840, mac_unit and mac_cluster 6000 bursts each. 6/6 negative controls caught |
| Overflow walks | 65,544 tests each: every accumulator overflowed by MAC, MACSUB and MACDOT in both directions |
| Clock-gate test | `t_dsu_gate`: 2937 cycles gated |

### 3.3 DMA

| Checklist item | Status |
|---|---|
| Functional coverage | 442/442 after 3 waived bins (raw 99.3 %). IMC number pending |
| Code coverage | 100 % line, branch, expression, toggle after 27 waivers (raw: line 96.7, branch 100, expression 98.2, toggle 80.1) |
| Properties | PROVEN, except the 7 open-defect detectors; `a_ack_one_pclk_edge` proven with a real pclk |
| Planted defects | 24/24 killed by a named check; M12 proven EQUIVALENT |
| Seeds | 100 distinct seeds, all pass. The target is 500 with none failing for 2 weeks: not yet met, and the clock restarts at every RTL fix |
| Sub-modules on their own | apb_slave 6,657 checks, chan 200k cycles against a cycle model, engine 178k checks. 7 negative controls caught |
| vPlan trace F01 to F51 | All 82 CHK/COV/TC rows trace to a property, covergroup item, test or rule |
| Testbench coverage | Line 87.5 %, branch 68.4 % (reported separately; the uncovered lines are mostly failure paths) |
| Open P1/P2 | Not zero: DMA-9, DMA-11, DMA-14 (P2) and several P3 wait for rulings |

### 3.4 Coverage (open flow, Verilator 5.052)

| Block | Line | Branch | Expression | Toggle | Functional | Verdict |
|---|---|---|---|---|---|---|
| Core, after reviewed exclusions | 100 % (196/196) | 100 % (176/176) | 100 % (548/548) | 100 % (18082/18082) | 100 % (1167/1167) | PASS |
| Core, raw | 98.5 % | 100 % | 98.9 % | 94.0 % | 93.8 % | |
| DSU, after reviewed exclusions | 100 % (42/42) | 100 % (28/28) | 100 % (228/228) | 100 % (7272/7272) | 100 % (47/47) | PASS |
| DSU, raw | 100 % | 100 % | 100 % | 96.6 % | 100 % | |
| DMA, after waivers | 100 % | 100 % | 100 % | 100 % | 442/442 | met |

Testbench coverage is reported separately and is not the sign-off number: core line 82.0 %, branch 73.8 %, expression 89.4 %, toggle 64.6 %; DSU line 81.2 %, branch 50.0 %, expression 48.0 %, toggle 96.8 %.

**Older Cadence-measured numbers** (2026-10-04, irun 15.2 + IMC, 119 runs, all passing, in `Docs/COVERAGE.md`): `garuda_core_top` 88.79 %, `dsu_top` 99.74 %, `mac_unit` 97.57 %, `dma_top` 55.45 %, `ahb_interconnect` 68.41 %. These are IMC module averages before the Track A coverage tests, so they are lower.

---

## 4. Bugs found

Priority: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 the rest. Statuses are as in the register.

### 4.1 Core

| ID | Prio | What | Found by | Status |
|---|---|---|---|---|
| T-13 | P1 | A load/store bus error on the instruction before an MRET was silently dropped | Review of trap_ctrl | **FIXED** (69c79ec) |
| T-14 | P1 | A bus error on the instruction before a WFI left the core asleep in the fault handler | Review of trap_ctrl | **FIXED** (69c79ec) |
| T-17 | P1 | An instruction access fault traps forever: the fetch-fault bit of a bubble raises cause 1 again after every redirect | Coverage test `t_cov_fault` (first test ever to take a fetch fault) | Fixed in RTL (one line in `trap_ctrl.v`), property PROVEN; register says IN-PROGRESS |
| T-12 | P1 | A second trap inside an interrupt handler leaves the interrupt level wrong | CLIC feature plan | Fixed in RTL (`mcause[23:16]` = mpil); 9 checks failed before; IN-PROGRESS |
| BUS-E | P2 | The I-port issues word fetches at misaligned addresses after a misaligned redirect (AHB-Lite violation) | `t_cov_misfetch`, formal cover | Fixed in RTL; `a_iport_pc_aligned` PROVEN; IN-PROGRESS |
| T-18 | P2 | A misaligned JAL reports mtval = pc+4 instead of the target | riscv-arch-test vs Spike | Fixed in RTL (`branch_unit.v`); arch-test 59/59; IN-PROGRESS |
| RDC-1 | P2 | A debugger halt resets the core at an arbitrary cycle under a bus that is not in reset | Reset-domain review | Fixed in RTL (halt waits for the bus to drain); IN-PROGRESS |
| C-16 | P3 | Four CSR groups that exist in the spec trap as illegal | CSR sweep | Fixed in RTL; CSR map test 116/116; IN-PROGRESS |
| CORE-4 | P3 | No runtime way to disable a core feature found broken in silicon | Plan review | New `mgarudactl` CSR 0x7C0 (BP_DIS / PF_DIS / PREEMPT_DIS / CG_DIS); IN-PROGRESS |
| C-17 | P3 | A minstret read lags the retired count by the instructions in MEM and WB | Spike lockstep | RULING-NEEDED |
| T-16 | P3 | An EX exception on the instruction behind a WFI is taken during the sleep | Audit formal | RULING-NEEDED |
| ARCH-DEV-1 | - | arch-test trap-signature header differs from Spike because `mtvec.MODE` is hardwired to 3 | arch-test | Deviation, no RTL change |

### 4.2 DSU (spec versus RTL: Karthik rules which side is right)

| ID | Prio | What |
|---|---|---|
| DSU-14 | P2 | `csrr dsu_ovf` right after the overflowing instruction reads the old flag (0). The overflow folds one cycle later and the CSR read is not interlocked. Found by the planted-defect run. |
| DSU-15 | P2 | MACSAT writes no rd and clamps to int32 (±2.0); the spec says rd = Q1.15 saturated (±1.0). Found by the vPlan trace. Test `t_dsu_macsat_rd` is an expected failure. |
| DSU-17 | P2 | MACSHIFT is not the specified instruction: the spec has `acc >>>= rs1[4:0]`; the RTL shifts by an immediate 0..47 into rd and leaves the accumulator unchanged. |
| DSU-16 | P3 | The spec says MACDOT puts its two products into two accumulators; RTL and models add both into one (a real dot product). Spec fix proposed. |
| DSU-18 | P3 | An overflowing accumulate followed at once by MACCLEAR/MACLOAD of the same accumulator never sets the sticky flag. Test `tb_dsu_top_ovf_b2b` is an expected failure. |
| D0 items | - | Saturate vs wrap; MACSHIFT 48..63 and reserved immediate bits; `dsu_idle` gate; interlock narrowing after MACRD/MACSAT |

### 4.3 DMA (all waiting for rulings)

| ID | Prio | What |
|---|---|---|
| DMA-9 | P2 | Setting EN again after a software stop restarts from CNT instead of continuing; SAR/DAR keep their advanced values, so the restarted transfer writes past the buffer |
| DMA-11 | P2 | Re-arming a channel while a beat of the previous transfer is in flight lets that beat land in the new transfer |
| DMA-14 | P2 | Stopping a channel with CR = 0 (which writes SIZE = byte) while a beat is in flight changes that beat's size. Found by formal and replayed in simulation |
| DMA-17 | P2 | `garuda_system.yaml` (normative) lets the DMA reach ISRAM; DMA spec R-9 and `dma_engine.v` refuse it. Recommendation: change the YAML to `dma: [dsram, apb]` |
| DMA-10 | P3 | A forbidden destination (ISRAM / Boot ROM) is refused only after the source has been read, so a peripheral FIFO loses one entry |
| DMA-12 | P3 | ACK_CYCLES outside 1..4 silently gives the wrong ack width |
| DMA-13 | P3 | A halfword or word channel with an unaligned SAR/DAR puts a misaligned transfer on the AHB bus; the spec is silent |
| DMA-15 | P3 | Every M2M beat pulses `dma_ack` although no peripheral requested it |
| DMA-16 | P3 | A P2M beat whose destination write gets an AHB ERROR has already popped its source FIFO; the item is lost. Recommendation: document it as a limitation |
| DMA-18 | P3 | Arming a non-zero transfer clears STAT.COMPLETE, while the spec calls it sticky until ICLR. Recommendation: change the spec text |
| AUD-13 | - | PSLVERR only for the specified illegal accesses. **Fixed.** `tb_dma_regs` 87/87 |
| Earlier, fixed | - | DMA-1 (SR snapshot across the clock domain), DMA-2, DMA-3, DMA-7, DMA-8. DMA-4, DMA-5, DMA-6 are WONTFIX |

### 4.4 AHB and AHB2APB (found while building the DMA environment)

| ID | What | Status |
|---|---|---|
| APB-2 | `win_ok` did not check `HADDR[27:16] == 0`, so 0x4001_5000 and 0x4FFF_5000 completed OKAY on window 5 (the DMA's own registers) instead of an ERROR | **Fixed** (one line in `ahb2apb_bridge.v`) |
| AHB-7 (P3) | The AHB-2 response hold can capture an ERROR, giving two or more cycles of HREADY low + ERROR if the grant moves during ERROR cycle 1 | Needs a decision |
| APB-1 | The bridge timeout drops PSEL with PREADY still low | Accept and state it in the spec |
| AHB-6, APB-3, AUD-14 | Documentation fixes: 4 masters, twelve windows, ID map | Comment/doc only |

### 4.5 Test-bench and tool findings

| ID | What |
|---|---|
| TB-45 (P2) | The DSU reference models defer to the RTL ("where this file and the RTL disagree, the RTL wins"), so they cannot catch spec deviations. DSU-15 slipped past both models. |
| TB-42 | `tb_dsu_top` cannot see timing or flag-history defects (one instruction per vector). Three mutants survived the block bench. |
| TB-43 | 6 of the 13 DSU sub-block benches disagree with the RTL (3 need D0 rulings, 3 are stale or wrong). |
| TB-41, TB-40 | Coverage groups with wrong layout or sampling conditions; bins can never be hit |
| TB-39, TB-48, TB-33, ELEM-8 | Async-reset and random-sequence weaknesses in the checkers |
| TB-46 | `tb_ahb2apb.sv`: reset declared 1 before being driven 0, so `clk_div_sva` fired at time 0 while the bench printed PASS |
| TB-47 | `ahb_lite_sram.v`: HRESP was ERROR through the wait states before an ERROR, an illegal slave response; `tb_ahb_interconnect` still printed 802/0 |
| TB-44 | DMA bench pclk race |
| TOOL-12 | The Spike lockstep ignored Spike's exit status. **Fixed.** |
| TOOL-23, 24, 25 | Verilator 5.052 problems: class covergroup through a virtual interface, `$past` part-select, expression coverage. Covergroups are compiled out under Verilator only. |

---

## 5. RTL changes made

Each change is marked `// ERRATUM <ID>` at the changed lines. Each went in test first: a failing test or property, then the fix, then the full regression.

| ID | File(s) | Change |
|---|---|---|
| T-12 | `rtl/core/csr_file.v` | `mcause[23:16]` = mpil |
| C-16 | `rtl/core/csr_file.v` | CSR map matches `Design_Docs/regs/core_csr.yaml` |
| CORE-4 | `csr_file.v`, `branch_predict.v`, `clic_ctrl.v`, `garuda_iport_ahb_master.v`, `id_stage.v`, `garuda_if_stage_top.v`, `garuda_core_top.v` | New `mgarudactl` CSR 0x7C0 with BP_DIS, PF_DIS, PREEMPT_DIS, CG_DIS |
| RDC-1 | `rtl/debug/debug_module.v`, `debug_top.v`, `garuda_core_top.v`, `garuda_iport_ahb_master.v`, plus 2 nets in `rtl/soc/garuda_soc_top.v` | Debug halt/reset waits for the bus to drain (request, drain, grant) |
| T-17 | `rtl/core/trap_ctrl.v` | One line: `e1 = idex_fault_i & idex_valid_i` |
| T-18 | `rtl/core/branch_unit.v` | Misaligned-JAL `mtval` |
| BUS-E | `rtl/core/garuda_iport_ahb_master.v` | No word fetch from a misaligned `fetch_pc` |
| AUD-13 | `rtl/dma/dma_apb_slave.v` | PSLVERR only for the specified illegal accesses |
| APB-2 | `rtl/ahb2apb/ahb2apb_bridge.v` | One line: `win_ok` also needs `HADDR[27:16] == 0` |

**Verification-only files** (never synthesised, behind the `SYNTHESIS` define): `rtl/core/*_sva.sv` (5 files), `rtl/dsu/dsu_sva.sv`, `rtl/dma/dma_sva.sv`, `rtl/ahb/ahb_interconnect_sva.sv` (62 properties), `rtl/ahb2apb/ahb2apb_sva.sv`, and `rtl/core/garuda_rvfi.v` (behind `GARUDA_RVFI`).

Size of the core/DSU RTL change (commit 2 of branch `a/core-dsu`): 22 files, +1,129 / -41 lines; most of the added lines are the properties and the RVFI port.

---

## 6. RTL changes still needed (decisions, not yet made)

| Item | Needed decision | Our recommendation |
|---|---|---|
| DSU-14 | Interlock the CSR read, or document the one-cycle delay | Options A/B/C in the Gate 0 message |
| DSU-15, DSU-17 | Follow the spec (Q1.15 into rd; in-place MACSHIFT) or change the spec to match the RTL | Karthik rules; DSU-17 is a different instruction, so likely an RTL change |
| DSU-16 | Fix the spec text (one accumulator) | Spec fix |
| DSU-18 | Set the overflow flag before MACCLEAR/MACLOAD | RTL fix |
| DMA-9, DMA-11, DMA-14 (P2) | Define stop, re-arm and in-flight behaviour | RTL fixes, one at a time with the two-commit discipline |
| DMA-17 | ISRAM reachable by the DMA or not | Change the YAML (keeps the ISRAM lock story simple) |
| DMA-10, 12, 13, 15, 16, 18 | Fix or document | DMA-16 and DMA-18: document; the rest as in the Gate 0 message §11 |
| C-17, T-16 | Count-lag and WFI-exception behaviour | Rulings |
| misa M vs Zmmul | Which one the chip reports | Ruling |
| AHB-7, APB-1 | Accept or fix | APB-1: accept and state it in the spec |
| D5 / [N-9.3] | "A disabled channel receives no clock" vs no clock gate in the RTL | Change the spec to "clock enable" |
| T-17, BUS-E, T-18 priorities | Agree the P1/P2 ratings | Karthik |
| W8 clock-gate test enable | Blocked on Karthik's DFT spec | - |

After each DMA ruling: fix, rerun, restart the 500-seed clock. Tests that encode today's behaviour (`tb_dma_top` steps 10/13, `env_r9`, the probe expected-failures) change with their fix.

---

## 7. Where the work lives (git)

| What | Where |
|---|---|
| Bug findings, section 1m of `Docs/BUGS.md` (17 core/DSU findings) | **On GitHub `main`**, commit 868118a, pushed 2026-10-14 |
| Core and DSU work (3 commits: infrastructure, core RTL fixes, verification) | Local branch `a/core-dsu` (72bb6f6). It was pushed once and then the remote branch was deleted. Push again with `git push -u origin a/core-dsu`. |
| Per-block bug register (`Docs/bugs/`, `tools/bugs/bugs.py`) | Only on `a/core-dsu`. Merging it into `main` conflicts on `Docs/BUGS.md` and needs the TOOL-18..21 ID decision (see the handoff note). |
| DMA, AHB, AHB2APB work, Cadence coverage scripts (`flow/cov/<blk>_cadence.sh`) | **Uncommitted** in the working tree and in the stash `leftover recovered` (commit e2b4ea8). Commit it to a branch before anything else. |

---

## 8. Not done, blocked, or limited

- **Cadence simulation:** blocked by the C2S licence (`NOLICN`, flag -42). The coverage scripts compile and elaborate cleanly (79 instances, 103 assertions, 37 covergroups); runs need the licence.
- **IMC cross-check** of the coverage numbers, **Xcelium** runs, and **JasperGold** re-proofs (for example `pc_fwd` deeper than 16): all need the licence. They are packaged in `tb/dma/README.md` under "XCELIUM-ONLY".
- **Verilator on the Cadence laptop:** not installed, so `make local_lint` cannot run there. HAL lint (`make static_lint`) needs the licence too.
- **RISC-V gcc, Spike, riscv-tests:** not installed on the Cadence laptop.
- **DMA 500-seed bar:** 100 seeds so far.
- **Karthik's review records** (`flow/reviews/core.md`, `flow/reviews/dma.md`).
- **TB-42, TB-43 rewrites** and the requirements coverage of the spec tags (`vplan_trace`, sign-off row 1).
- **Chip-level simulation of the P2 chip-top change** is pending (needs the lab `xrun`).

---

## 9. Commands for the meeting

Environment (tcsh):
```
nmcli connection up cvrc2s
tcsh
source ~/cadence/cshrc
cd ~/garuda_track_a
setenv GARUDA_ROOT $PWD
setenv PATH /home/install/INCISIVE152/tools/bin:${PATH}
```
Open-flow results:
```
make -f flow/mk/track_a.mk fast_a
make -f flow/mk/track_a.mk nightly_a JOBS=16
make -f flow/mk/track_a.mk cov_a
```
Cadence coverage (needs the licence):
```
bash flow/cov/core_cadence.sh
imc -exec flow/cov/core_report.tcl
imc -load sim/cov_core/cov_work/scope/all &
```
In the IMC window: File, Load, pick the run. The Metrics page shows the overall grade and the Verification Hierarchy. The Analysis menu opens Block, Expression and Toggle analysis pages. The Report button writes an HTML report. (From the IMC User Guide in `/home/install/INCISIVE152/doc/imcuser/`.)

Bugs:
```
less Docs/BUGS.md
```
Section 1m on `main` lists the core and DSU findings.

---

## 10. Honest limits to say out loud

1. Coverage of 100 % is **after reviewed exclusions**, measured with Verilator. The raw figures are listed beside it, and every exclusion carries a reason.
2. The Cadence/IMC measurement of these numbers has not been done in this licence period.
3. "Fixed in RTL" for T-12, T-17, T-18, BUS-E, RDC-1, C-16 and CORE-4 means the change is made and tested, but the register still says IN-PROGRESS until Karthik reviews.
4. Every DSU and DMA entry marked RULING-NEEDED is a disagreement between the spec and the RTL. None of them is proven to be an RTL defect yet.
5. The DMA 500-seed bar is not met.
