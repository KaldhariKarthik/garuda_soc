# Bugs: RV32IM core (rtl/core)

Owner: Track A. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).
Priorities: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).

<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. Run `bugs.py check` before pushing. -->
| ID | Title | Status | Prio | Found-by | Found | Fixed-in | Regression test | Evidence | Formerly |
|---|---|---|---|---|---|---|---|---|---|
| T-8 | or | FIXED | P2 | RTL audit | 2026-09-19 | legacy | `t_mtip` (sanity); fails with the old term | HISTORY_2026.md L90 | - |
| C-5 | Reserved funct3 of JALR/BRANCH/LOAD/STORE, SYSTEM funct3=100 and non-architectural funct3=000 SYSTEM words decoded as... | FIXED | P2 | RTL audit | 2026-09-19 | legacy | `test_decode_control`, `test_id_stage` (models updated), ISA 63/63 | HISTORY_2026.md L91 | - |
| CORE-3 | RESET_VECTOR parameter ignored (garuda_pc_gen hard-coded it) | FIXED | P3 | RTL audit | 2026-09-19 | legacy | chip tests boot from the parameter | HISTORY_2026.md L92 | - |
| OPEN-8 | t_clic TIMEOUT was the sanity runner's 50 k-cycle budget; | CLOSED | - | re-run | 2026-09-19 | legacy | sanity 10/10 | HISTORY_2026.md L96 | - |
| ELEM-7 | That file is 74 lines and contains no covergroup and no SVA at all | IN-PROGRESS | P3 | reading the file against the doc | 2026-09-19 | - | core/elements E_clic_ctrl; flow/negctl_elem | logs/core/evidence/W6_bench_fixes.txt | - |
| C-13 | Reserved register-register encodings executed instead of trapping | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L304 | - |
| C-14 | An illegal instruction left reg_write asserted | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L305 | - |
| TB-26 | not | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L306 | - |
| SVA-1 | a_no_gate_with_flush listed ex_mem_flush, which pipe_ctrl drives from wfi_hold itself to bubble EX/MEM (P-3) | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L307 | - |
| T-9 | A trap taken while a load or store was still on the D-port lost its redirect | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L313 | - |
| T-10 | A load/store bus error did not squash the instruction behind it | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L314 | - |
| P-4 | The idle loop lost a load on wake | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L315 | - |
| P-5 | A JALR or mispredicted branch parked in EX behind a WFI redirected fetch, was flushed out of ID/EX by its own redirec... | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L316 | - |
| P-6 | A CSR instruction wrote its CSR on every cycle it sat in EX, and in the cycle it was squashed | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L317 | - |
| P-7 | A DSU operation parked in EX ran once per held cycle | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L318 | - |
| P-8 | The clock gate could close with an instruction still in MEM/WB: a load or store stretched by wait states just before ... | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L319 | - |
| C-15 | FENCE.I raced an older store | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L320 | - |
| T-11 | An interrupt taken on a WFI put the core to sleep inside the handler | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L321 | - |
| ELEM-1 | 600 soak failures on fetch_pc | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L346 | - |
| ELEM-2 | 2 492 failures and 750 a_no_overflow | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L347 | - |
| ELEM-3 | Three defects | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L348 | - |
| ELEM-4 | Nested -> inside parentheses in a constraint does not parse; | FIXED | - | - | 2026-09-19 | legacy | - | HISTORY_2026.md L349 | - |
| ELEM-5 | Never triaged before today | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L350 | - |
| ELEM-6 | Never triaged before today | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L351 | - |
| T-13 | A load or store bus error on the instruction directly before an MRET is silently dropped | FIXED | P1 | - | 2026-10-04 | 69c79ec | core/directed t_core_mret_buserr; fv_trap; Karthik t_lead1_mret_buserr | Docs/VERIFICATION_LOG_2026-10-11.md; logs/core/evidence/T-13_T-14_after.txt | - |
| T-14 | A bus error on the instruction directly before a WFI leaves the core asleep in the fault handler | FIXED | P1 | - | 2026-10-04 | 69c79ec | core/directed t_core_wfi_buserr; fv_trap; Karthik t_lead2_wfi_buserr | Docs/VERIFICATION_LOG_2026-10-11.md; logs/core/evidence/T-13_T-14_after.txt | - |
| TB-32 | tb_garuda_pc_gen checks the reset vector at 3 ns, before the first clock edge, relying on a time-zero reset edge the ... | FIXED | P3 | - | 2026-10-04 | 7769511 | core/elements tb_garuda_pc_gen | Docs/VERIFICATION_LOG_2026-10-11.md | - |
| TB-33 | The constrained-random sequences can never generate a bubble | IN-PROGRESS | P3 | - | 2026-10-04 | - | core/units U_id_stage (require: random bubbles of both kinds; seeds 1..5) | logs/core/evidence/W6_bench_fixes.txt | - |
| ELEM-8 | The soak's teardown withdraws a transfer still waiting in its address phase | IN-PROGRESS | P3 | - | 2026-10-04 | - | core/elements E_d_port_ahb_master (seeds 1..12) | logs/core/evidence/W6_bench_fixes.txt | - |
| T-12 | A second trap inside an interrupt handler leaves the interrupt level wrong | IN-PROGRESS | P1 | reading `csr_file.v` against CLIC §7.4/§8.3 while writing the CLIC feature plan | 2026-10-04 | - | core/csr t12_level_stack; fv_csr csr_prove; core/directed t_core_irq_nest(+_w2); flow/negctl_t12 | logs/core/evidence/T-12_before.txt, T-12_after.txt, T-12_program_level.txt | - |
| RDC-1 | A debugger halt resets the core at an arbitrary cycle, under a bus that is not in reset | IN-PROGRESS | P2 | reset-domain review, stage 1 | 2026-10-04 | - | core/halt t_core_hartreset_s1..s3 + _timeout; fv_rdc1 rdc1_prove | logs/core/evidence/RDC-1_before.txt, RDC-1_after.txt | - |
| T-15 | mepc bit 1 was writable | FIXED | P3 | the extended lockstep (VER-3), first new test | 2026-10-04 | legacy | - | HISTORY_2026.md L395 | - |
| C-16 | Four groups of CSRs that the privileged specification says exist are answered with an illegal-instruction trap | IN-PROGRESS | P3 | CSR sweep, after two riscv-dv programs diverged on CSR existence | 2026-10-04 | - | core/isa p-csr_readzero (lockstep); core_csr_map; fv_csr csr_prove | logs/core/evidence/C-16_before.txt, C-16_after.txt | - |
| I-1 | address | FIXED | P1 | - | legacy | legacy | - | HISTORY_2026.md L802 | - |
| D-1 | Every store wrote zero | FIXED | P1 | - | legacy | legacy | - | HISTORY_2026.md L803 | - |
| BUS-A | HBURST derived from the *current* HTRANS, so the opening beat of every burst declared SINGLE and each following beat ... | FIXED | P2 | - | legacy | legacy | - | HISTORY_2026.md L804 | - |
| BUS-B | A burst broken by a full prefetch buffer resumed with SEQ — a SEQ beat with no open burst | FIXED | P2 | - | legacy | legacy | - | HISTORY_2026.md L805 | - |
| BUS-C | AHB-Lite has no cancel | FIXED | P2 | - | legacy | legacy | - | HISTORY_2026.md L806 | - |
| BUS-D | Nothing enforced the 1 KB burst boundary | FIXED | P2 | - | legacy | legacy | - | HISTORY_2026.md L807 | - |
| CORE-1 | rtl/core/mem_wb_reg.v, ex_mem.v and if_id.v all wrote always @(posedge clk_i or negedge rst_n_i) … if (!rst_n_i \ | FIXED | P2 | - | legacy | legacy | - | HISTORY_2026.md L808 | - |
| CORE-2 | garuda_core_top and csr_file carry an unused parameter (Verilator UNUSEDPARAM) | OPEN | P3 | - | legacy | - | - | HISTORY_2026.md L809 | - |
| T-16 | An EX exception on the instruction parked behind a WFI is taken during the sleep | RULING-NEEDED | P3 | audit formal (TC-2 refuted) | 2026-10-05 | - | - | Obsidian GARUDA Audit Working Notes; local/formal core_prove tc | audit note 'T-12' |
| TB-48 | tb_mem_wb_reg a_capture relies on an asynchronous disable iff | IN-PROGRESS | P3 | Track A baseline (Verilator 5.052) | 2026-10-11 | - | core/elements E_mem_wb_reg (seeds 1..12) | logs/core/evidence/W6_bench_fixes.txt | TB-34 (Track A, renumbered 2026-10-14) |
| C-1 | (found by riscv-tests rv32mi/shamt) | FIXED | - | RTL comment | legacy | legacy | - | rtl/core/decode_control.v:203 | - |
| C-2 | - | FIXED | - | RTL comment | legacy | legacy | - | rtl/core/decode_control.v:80 | - |
| C-3 | FENCE.I redirects to the NEXT instruction. The redirect is | FIXED | - | RTL comment | legacy | legacy | - | rtl/core/branch_predict.v:44 | - |
| C-4 | (Zicntr): user-level read-only shadows of the | FIXED | - | RTL comment | legacy | legacy | - | rtl/core/csr_file.v:78 | - |
| F-1 | in id_ex.v. | FIXED | - | RTL comment | legacy | legacy | - | rtl/core/ex_stage.v:132 | - |
| P-1 | (found by riscv-tests ld_st) | FIXED | - | RTL comment | legacy | legacy | - | rtl/core/pipe_ctrl.v:151 | - |
| P-2 | (found by riscv-tests rv32mi/ma_addr) | FIXED | - | RTL comment | legacy | legacy | - | rtl/core/pipe_ctrl.v:78 | - |
| P-3 | . A JALR parked | FIXED | - | RTL comment | legacy | legacy | - | rtl/core/pipe_ctrl.v:108 | - |
| T-1 | instruction-address-misaligned (cause 0) detection. | FIXED | - | RTL comment | legacy | legacy | - | rtl/core/branch_unit.v:57 | - |
| T-2 | (found by riscv-tests rv32mi/ma_fetch) | FIXED | - | RTL comment | legacy | legacy | - | rtl/core/csr_file.v:147 | - |
| T-3 | (found by riscv-tests rv32mi/breakpoint) | FIXED | - | RTL comment | legacy | legacy | - | rtl/core/trap_ctrl.v:226 | - |
| T-4 | - | FIXED | - | RTL comment | legacy | legacy | - | rtl/core/garuda_core_top.v:346 | - |
| C-17 | A CSR read of minstret/instret lags the retired-instruction count by the instructions still in MEM and WB | RULING-NEEDED | P3 | Track A W2 (p-csr_readzero lockstep with Spike) | 2026-10-11 | - | - | logs/core/evidence/C-17_minstret_lag.txt | - |
| CORE-4 | No runtime way to disable a core feature found broken in silicon (pre-M0 item C) | IN-PROGRESS | P3 | Track A plan review (pre-M0 item C) | 2026-10-11 | - | core/directed t_core_ctl(+_w3), t_core_preempt(+_w2); fv_trap a_ctl_*; flow/negctl_preempt | logs/core/evidence/CORE-4_before.txt, CORE-4_after.txt, CORE-4_preempt_program.txt | - |
| TB-39 | tb_garuda_pc_gen a_fetch_step relies on an asynchronous disable iff (sub-cycle mid-stream re-reset) | IN-PROGRESS | P3 | Track A W6 (TB-32 fix unmasked it) | 2026-10-11 | - | core/elements E_garuda_pc_gen (seeds 1..12) | logs/core/evidence/W6_bench_fixes.txt | - |
| T-17 | An instruction access fault traps forever: the fetch-fault bit of a bubble raises cause 1 again after every redirect | IN-PROGRESS | P1 | Track A coverage closure (t_cov_fault, first test ever to take a fetch fault) | 2026-10-11 | - | core/covtests t_cov_fault(+_w3); fv_trap trap_prove a_ex_exc_needs_instr; fv_trap t17_no_fix (negative control) | logs/core/evidence/T-17_before.txt, T-17_after.txt | - |
| TB-40 | garuda_cov cg_ldst samples MEM-stage size and address under an EX-stage condition | IN-PROGRESS | P3 | Track A coverage closure (cg_ldst misaligned bins unhittable) | 2026-10-11 | - | cov_core_report cg_ldst | logs/core/summary/cov_core.txt | - |
| BUS-E | The I-port issues word fetches at misaligned addresses (HADDR not aligned to HSIZE) after a misaligned-target redirect | IN-PROGRESS | P2 | Track A coverage closure (PC bit-1 toggle hole, formal cover c_ihaddr_bit1, t_cov_misfetch) | 2026-10-11 | - | core/covtests t_cov_misfetch(+_w2,_d3); fv_trap trap_prove a_ihaddr_aligned; fv_trap buse_no_fix (negative control) | logs/core/evidence/BUS-E_before.txt, BUS-E_after.txt | - |
| T-18 | A misaligned JAL reports mtval = pc+4 instead of the target when its immediate / rd bit fields read as a not-taken branch compare | IN-PROGRESS | P2 | Track A riscv-arch-test (privilege-misalign-jal-01 signature vs Spike) | 2026-10-11 | - | core/covtests t_cov_misfetch(+_w2,_d3) case 1b; core/archtest privilege-misalign-jal-01; trap_ctrl_sva a_misfetch_tval_misaligned; fv_trap t18_no_fix (negative control) | logs/core/evidence/T-18_before.txt, T-18_after.txt, archtest_2026-10-11.txt | - |

## Details

### T-8

*From `Docs/BUGS.md` at b90b481, line 90, section "1b. Rev 4.0 migration — 2026-09-19".*

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| **T-8** | 1 core | FIXED, *proved* | medium (core sleeps forever) | `wfi_active` cleared only on a CLIC wake while `wfi_hold` released on CLIC **or** timer: after a timer-only WFI wake, clearing MTIP re-froze the pipeline. | RTL audit | `t_mtip` (sanity); fails with the old term |

### C-5

*From `Docs/BUGS.md` at b90b481, line 91, section "1b. Rev 4.0 migration — 2026-09-19".*

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| **C-5** | 1 core | FIXED | medium (undefined bus traffic) | Reserved funct3 of JALR/BRANCH/LOAD/STORE, SYSTEM funct3=100 and non-architectural funct3=000 SYSTEM words decoded as legal: silent NOPs, not-taken branches, HSIZE=64-bit on AHB. Now illegal-instruction, as Spike. | RTL audit | `test_decode_control`, `test_id_stage` (models updated), ISA 63/63 |

### CORE-3

*From `Docs/BUGS.md` at b90b481, line 92, section "1b. Rev 4.0 migration — 2026-09-19".*

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| **CORE-3** | 1 core | FIXED | low | `RESET_VECTOR` parameter ignored (`garuda_pc_gen` hard-coded it). | RTL audit | chip tests boot from the parameter |

### OPEN-8

*From `Docs/BUGS.md` at b90b481, line 96, section "1b. Rev 4.0 migration — 2026-09-19".*

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| OPEN-8 | 1 core | CLOSED — not a bug | — | `t_clic` TIMEOUT was the sanity runner's 50 k-cycle budget; the test is interrupt-bound (IRQ every 40 cycles) and needs ~60 k. `run_sanity.sh` default is now 200 k. | re-run | sanity 10/10 |

### ELEM-7

*From `Docs/BUGS.md` at b90b481, line 101, section "1b. Rev 4.0 migration — 2026-09-19".*

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| **ELEM-7** | docs | **OPEN (doc)** | low | `Docs/CORE_ELEMENT_VERIFICATION.md:157` cites covergroups `cp_lvl_vs_thresh` / `cp_lvl_vs_active` in `tb_clic_ctrl.sv` as the evidence that the strictly-greater-than threshold (test C24) was *"actually exercised rather than assumed"*. **That file is 74 lines and contains no covergroup and no SVA at all** — 9 directed vectors plus 5000 `$urandom` applications. The documented evidence does not exist. (It is also, not coincidentally, the only one of the 14 element TBs Icarus can compile, precisely because it has no SVA.) | reading the file against the doc | — |

**2026-10-11:** W6 fix: tb_clic_ctrl now has cg_clic with cp_lvl_vs_thresh / cp_lvl_vs_active (equality as its own bin), as the doc claimed, plus the same bins as counters checked at the end (Verilator get_coverage() is 0, TOOL-22). Also fixed: [PASS] was printed for every vector even when its checks failed (c_ok() returned 1); PREEMPT_DIS is now exercised (directed + random), and the bench fails on clic_ctrl_no_preempt.v (negctl_elem).

### C-13

*From `Docs/BUGS.md` at b90b481, line 304, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **C-13** | `rtl/core/decode_control.v` | FIXED | **Reserved register-register encodings executed instead of trapping.** `funct7 = 0100000` was accepted for every `funct3`; it exists only for SUB (000) and SRA (101). `0x402091b3` ran as SLL where Spike raises illegal-instruction. Same class as C-1, on OP_REG. Found by reading the decoder while chasing C-14; `reserved_funct7` in `tb_decode_control` now walks all eight `funct3` values. |

### C-14

*From `Docs/BUGS.md` at b90b481, line 305, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **C-14** | `rtl/core/decode_control.v` | FIXED | **An illegal instruction left `reg_write` asserted.** OP_IMM set `reg_write` before examining `funct7`, so a reserved shift-immediate reached EX flagged illegal with a register write still enabled. The trap squash made it harmless in practice; the decoder's own contract (C-5: "no side effects enabled") was not met. `a_illegal_inert` in `tb_decode_control` had been failing 88 times per run. The bundle is now forced inert in one place at the end of the decode. |

### TB-26

*From `Docs/BUGS.md` at b90b481, line 306, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **TB-26** | `tb/core/tb_decode_control.sv`, `tb_id_stage.sv` | FIXED | Both reference models had been written to agree with the RTL on C-13 and C-14, and `tb_id_stage` even constrained "legal ALU" stimulus to include the reserved encodings. The scoreboard therefore passed what the assertion beside it rejected. Models and constraint corrected. The inlined standalone DUT copies in those files (unused when `GARUDA_REAL_RTL` is set, which the filelists always set) are **not** updated. |

### SVA-1

*From `Docs/BUGS.md` at b90b481, line 307, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **SVA-1** | `rtl/core/pipe_ctrl_sva.sv` | FIXED (assertion) | `a_no_gate_with_flush` listed `ex_mem_flush`, which `pipe_ctrl` drives from `wfi_hold` itself to bubble EX/MEM (P-3). It therefore failed on every WFI sleep by construction — 3 times in `chip_irq`. CORE [N-11.3] defines the property over the flush *sources* (branch, trap, MRET, FENCE.I); the assertion now checks redirects and the IF/ID, ID/EX and MEM/WB flushes, and a trap squash of EX/MEM is still caught through `trap_redir_v`. RTL unchanged. |

### T-9

*From `Docs/BUGS.md` at b90b481, line 313, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **T-9** | `rtl/core/trap_ctrl.v` | FIXED | **A trap taken while a load or store was still on the D-port lost its redirect.** `trap_ctrl` had no view of H2: it entered the trap at once (mepc, mcause, mstatus written, ID/EX squashed) while `pipe_ctrl` withheld the redirect until the transfer finished, assuming the request would still be there. For an interrupt it was not, because the entry had just cleared `mstatus.MIE`; for an EX-point exception its own squash had removed it. The core ran on down the interrupted code with its CSRs saying it was in the handler. Found by `t_chip_integ` (a DMA error interrupt landing on a store: the next JALR used a stale `ra` and the chip ended in an access-fault storm with `mepc = X`), and confirmed for `sw; ecall`, `lw; illegal`, `sw; csr-illegal` and `sw; mret` by `t_hold_flush_matrix` bits 1, 2, 4, 5. This is the `c_h2_vs_redirect` cell AUD-8 said no test reached. No EX-point trap, interrupt or MRET is now taken while `mem_stall` is high. |

### T-10

*From `Docs/BUGS.md` at b90b481, line 314, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **T-10** | `rtl/core/trap_ctrl.v` | FIXED | **A load/store bus error did not squash the instruction behind it.** `trap_squash_ex_mem` covered EX-point exceptions and interrupts only. On a MEM-point fault the younger instruction in EX moved into MEM, did its own bus access and wrote its register before the handler ran: `lw a4,204(a4)` behind a faulting load overwrote its base register, then trapped as misaligned when the handler returned to it. A store in that position would have written memory after a fault. Found by `t_chip_integ` step 6. |

### P-4

*From `Docs/BUGS.md` at b90b481, line 315, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **P-4** | `rtl/core/pipe_ctrl.v` | FIXED | **The idle loop lost a load on wake.** During a WFI sleep the instruction behind the WFI is parked in ID/EX. If it was a load and the next instruction used its result, load-use fired, flush beat the H5 hold, and the load was destroyed: `wfi; lw a5,0(a4); beqz a5,...` (that is `while (!flag) wfi;`) woke up, skipped the load and branched on the stale register. `t_hold_flush_matrix` bit 12. |

### P-5

*From `Docs/BUGS.md` at b90b481, line 316, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **P-5** | `rtl/core/pipe_ctrl.v` | FIXED | A JALR or mispredicted branch parked in EX behind a WFI redirected fetch, was flushed out of ID/EX by its own redirect and never reached EX/MEM: `wfi; jalr ra,...` jumped but wrote no link register and never retired. The EX redirect is now deferred to the wake. `t_hold_flush_matrix` bit 13. |

### P-6

*From `Docs/BUGS.md` at b90b481, line 317, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **P-6** | `rtl/core/csr_file.v`, `garuda_core_top.v` | FIXED | **A CSR instruction wrote its CSR on every cycle it sat in EX, and in the cycle it was squashed.** Held behind a load/store or parked behind a WFI, `csrrw` wrote first and then returned the value it had just written, so `rd` got the new value. An interrupt taken on a `csrrw a0, mscratch, a0` swap wrote the CSR, squashed the instruction and ran it again on return, losing the old `mscratch`. The write and the read-to-clear of `dsu_ovf` now happen once, in the cycle the instruction leaves EX. `t_hold_flush_matrix` bits 7, 14. |

### P-7

*From `Docs/BUGS.md` at b90b481, line 318, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **P-7** | `rtl/core/garuda_core_top.v` | FIXED | **A DSU operation parked in EX ran once per held cycle.** A MAC behind a store (H2) or behind a WFI (H5) accumulated its product every cycle it waited. The DSU's enable is now withheld until the instruction can move. `t_hold_flush_matrix` bits 8, 15. |

### P-8

*From `Docs/BUGS.md` at b90b481, line 319, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **P-8** | `rtl/core/garuda_core_top.v` | FIXED | The clock gate could close with an instruction still in MEM/WB: a load or store stretched by wait states just before a WFI finished its data phase and the gate closed in the same cycle, leaving it unretired (and a load's register unwritten) for the whole sleep. "Idle" now also requires MEM and WB to be empty. Found by `t_hold_flush_matrix` with `+IRQ_EVERY=61 +DWAIT=2 +DRAND=1`. |

### C-15

*From `Docs/BUGS.md` at b90b481, line 320, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **C-15** | `rtl/core/garuda_core_top.v` | FIXED | **FENCE.I raced an older store.** It redirects from ID, so the refetch went out on the I-port while the store before it was still in EX or waiting on the D-port; with one wait state the core executed the word the store was replacing. FENCE.I now waits in ID until no older store is in EX or on the bus. `t_hold_flush_matrix` bit 6 with `+DWAIT=3`. |

### T-11

*From `Docs/BUGS.md` at b90b481, line 321, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **T-11** | `rtl/core/trap_ctrl.v` | FIXED | **An interrupt taken on a WFI put the core to sleep inside the handler.** When the interrupt was taken in the cycle a WFI sat in EX, the WFI was squashed but still armed the sleep latch, so the core slept on the first instruction of the handler. If the source had dropped its request, nothing woke it: the handler ran only when the next interrupt arrived, returned to the WFI, and the same happened again, so every interrupt was served one interrupt late and the program never got past the WFI. Found by sweeping `t_hold_flush_matrix` over interrupt periods and wait states (`+IRQ_EVERY=71 +DWAIT=5`); 60 further combinations now pass. |

### ELEM-1

*From `Docs/BUGS.md` at b90b481, line 346, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **ELEM-1** | `tb_garuda_pc_gen` | FIXED (testbench) | 600 soak failures on `fetch_pc`. TB-27 froze the stimulus at "issue every cycle", and the stream test before it left `fetch_issue` high across the reset, so the model started 4 behind and never re-synchronised. Not a sampling-phase problem as first recorded. RTL correct. |

### ELEM-2

*From `Docs/BUGS.md` at b90b481, line 347, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **ELEM-2** | `tb_garuda_prefetch_buffer` | FIXED (testbench) | 2 492 failures and 750 `a_no_overflow`. The write enable was meant to be gated on `ref_fifo.size() < 4`; TB-27 evaluated that once, at time 0, so the bench wrote every cycle and overfilled the FIFO. RTL correct. |

### ELEM-3

*From `Docs/BUGS.md` at b90b481, line 348, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **ELEM-3** | `tb_garuda_iport_ahb_master` | FIXED (testbench) | Three defects. `a_hburst` (382 failures) demanded SINGLE on every non-SEQ beat, the pre-BUS-A behaviour that AMBA forbids. The post-redirect NONSEQ check started looking two cycles after the transfer it was looking for. The C12 fault was armed after the fetch stream had already passed the faulting address. RTL correct. |

### ELEM-4

*From `Docs/BUGS.md` at b90b481, line 349, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| **ELEM-4** | TB | **FIXED: changed by inspection 2026-10-03, verified under Xcelium 2026-10-04 (§1h, ELEM-4)** | low | The nested implications in `tb_load_store_unit.sv`'s `constraint c_alignment` are rewritten as flat implications with a conjunction on the left: `A -> (B -> C)` and `(A && B) -> C` are the same proposition, so semantics and the stimulus distribution are unchanged, and there is no nesting left to parse. Done this way because **the tools disagree about the spelling**: Verilator accepts the parenthesised form and rejects the braced `constraint_set` form, xrun the other way round. **This is not locally verifiable and must be confirmed under xrun** — Icarus cannot parse the file at all (no concurrent-assertion support, which blocks **13 of the 14** element TBs), and Verilator parses it and then **segfaults** on 13 of 14, so its "0 errors" is not evidence either. What *is* evidence: at the parse stage Verilator reports 5 errors for the braced form and 0 for this one. | xrun; re-checked with Verilator | `make test_elements` |

| ID | Where | Status | Summary |
|---|---|---|---|
| **ELEM-4** | `tb_load_store_unit` | FIXED (testbench) | Nested `->` inside parentheses in a constraint does not parse; the bench had never compiled. Rewritten as single implications. It now runs and passes — the first execution of this testbench. The same rewrite was made independently on 2026-10-03 (ELEM-4 in the table above, then unverified); this run is its verification. |

### ELEM-5

*From `Docs/BUGS.md` at b90b481, line 350, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **ELEM-5** | `tb_garuda_if_stage_top` | FIXED (testbench) | 19 failures. `int popped_before = popped;` was a static initialiser (always 0), so the stall check failed whenever anything had ever been popped; and `expect_no_pop` was raised a full cycle before the redirect in the soak, so a legitimate pop of the old stream was reported as stale. RTL correct. **Never triaged before today.** |

### ELEM-6

*From `Docs/BUGS.md` at b90b481, line 351, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **ELEM-6** | `tb_mem_stage` | FIXED (testbench) | "SH: HWDATA on the upper half". The store was presented while the previous store was still in its data phase and checked one edge later, which reads the previous store's data. The check now follows the address phase. RTL correct. **Never triaged before today.** |

### T-13

*From `Docs/BUGS.md` at b90b481, line 366, section "1i. Independent audit on free tools — 2026-10-04/05".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **T-13** | `rtl/core/trap_ctrl.v` | OPEN | **A load or store bus error on the instruction directly before an MRET is silently dropped.** `trap_now = (exception \| any_int) & ~is_mret` (`rtl/core/trap_ctrl.v:205`) suppresses the older instruction's MEM-stage fault while the MRET sits in EX, and `mret_o` (`:213`) still pops: no trap is entered, `mepc` and `mcause` are not written, the load's write-back is squashed (`:251`) and execution continues at `mepc`. A directed test, `lw` to an erroring address followed by `mret` (`sw/tests/t_lead1_mret_buserr.S`, proposed with this entry), ends at the MRET target instead of the handler on two simulators, with and without D-port wait states, with the AHB checker reporting 0 violations and `t_buserr` passing on the same build. Realistic: trap-handler epilogues restore registers with loads immediately before `mret`. Proposed fix (5 lines together with T-14, not yet applied): take `mem_exc_valid_i` regardless of `is_mret`, and gate the MRET pop, redirect and target with `~mem_exc_valid_i`. Found by: a whole-core formal cover on `trap_ctrl` (reachable 12 cycles after reset), confirmed by directed simulation. |

**2026-10-11:** Fixed on branch a/p0-infra (W1): rtl/core/trap_ctrl.v ERRATUM T-13; properties in rtl/core/trap_ctrl_sva.sv PROVEN (fv_trap trap_prove, negative control trap_prove_unfixed FAILS on the pre-fix RTL). Becomes FIXED with the commit SHA.

**2026-10-14:** FIXED by Karthik in 69c79ec (same logic as the Track A W1 fix; his file kept on the rebase, xrun still pending per his section 1k).

### T-14

*From `Docs/BUGS.md` at b90b481, line 367, section "1i. Independent audit on free tools — 2026-10-04/05".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **T-14** | `rtl/core/trap_ctrl.v` | OPEN | **A bus error on the instruction directly before a WFI leaves the core asleep in the fault handler.** While the faulting access waits on the D-port, the WFI sits in EX and arms `wfi_active` (`rtl/core/trap_ctrl.v:168`): EX-point exceptions are gated by `~h2` (`:138`), so `wfi_squashed` is 0. When the access ends in ERROR the trap squashes the WFI, but the latch is cleared only by `wake_cond` (`:169`), so the handler is fetched and then held until an interrupt becomes pending; with none, the core hangs. A directed test, `lw` to an erroring address followed by `wfi` with interrupts disabled (`sw/tests/t_lead2_wfi_buserr.S`, proposed with this entry), times out after 6 retired instructions instead of reaching the handler on two simulators, with and without wait states; AHB checker clean, `t_buserr` passes on the same build. The T-11 symptom by another route. Proposed fix (with T-13, not yet applied): do not arm the latch while `h2` (`... & ~wfi_squashed & ~h2`). Found by: a whole-core formal cover on `trap_ctrl` (reachable 12 cycles after reset), confirmed by directed simulation. |

**2026-10-11:** Fixed on branch a/p0-infra (W1): rtl/core/trap_ctrl.v ERRATUM T-14; properties in rtl/core/trap_ctrl_sva.sv PROVEN (fv_trap trap_prove, negative control trap_prove_unfixed FAILS on the pre-fix RTL). Becomes FIXED with the commit SHA.

**2026-10-14:** FIXED by Karthik in 69c79ec (same logic as the Track A W1 fix; xrun still pending).

### TB-32

*From `Docs/BUGS.md` at b90b481, line 372, section "1i. Independent audit on free tools — 2026-10-04/05".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **TB-32** | `tb/core/tb_garuda_pc_gen.sv` | OPEN (testbench) | **`tb_garuda_pc_gen` checks the reset vector at 3 ns, before the first clock edge, relying on a time-zero reset edge the bench never makes.** `rst_n` is a `bit` (line 100), already 0, so `rst_n = 0` at line 170 is no event; the checks at lines 175-177 pass only if the simulator makes a falling edge on the DUT's 4-state `rst_n_i` net at time zero (`rtl/core/garuda_pc_gen.v:44-47`). Xcelium evidently does (the bench passes there, TB-27); under Verilator 5.052 both checks fail, expected 0x10000000, got 0x0. The rising edge at 5 ns resets the DUT anyway, and the re-reset checks after a real falling edge (lines 253-255) pass. Same class as TB-22. No confirmed RTL defect. Found by: a Verilator run of the element bench. |

**2026-10-11:** W6 fix: rst_n starts high and falls at 1 ns, so the reset vector checked at 3 ns comes from a real asynchronous reset edge. Removing the xfail exposed a second hidden failure in the same bench, logged as TB-39. Evidence logs/core/evidence/W6_bench_fixes.txt.

**2026-10-14:** FIXED by Karthik in 7769511; Track A TB-39 lines kept on top.

### TB-33

*From `Docs/BUGS.md` at b90b481, line 373, section "1i. Independent audit on free tools — 2026-10-04/05".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **TB-33** | `tb/core/tb_id_stage.sv` | OPEN | **The constrained-random sequences can never generate a bubble.** `c_defaults` forces `valid_val == 1` (line 561) while `c_op_shape` requires `valid_val == 0` for `IDK_RESET_BUBBLE` and `IDK_BUBBLE_WITH_FAULT` (575, 576), together 8 of the 110 `dist` weight (7.27%). A solver that honours the hard constraints must exclude both ops. Verilator 5.052 instead fixes `op` from the weights before solving, so 218 of 3 000 `randomize()` calls (7.27%) fail at line 769; each failed item is left as constructed (op 0, valid 0, instruction, PC and controls 0) and driven as an identical idle bubble. Either way the random mix never produces a bubble with a fault, a write-back or a load in EX; the six directed bubble cycles include one with a fault and none with the others. The bench still reports 3 067 PASS, 0 FAIL. Found by: Verilator run of `U_id_stage` (218 `[GEN] randomize() failed` errors behind a PASS summary). |

**2026-10-11:** W6 fix: c_defaults sets valid=1 only for non-bubble ops. 0 randomize() failures; seed 1 has 103 random reset bubbles (24 with a write-back and a load in EX) and 115 bubbles with a fault; the manifest now requires both.

### ELEM-8

*From `Docs/BUGS.md` at b90b481, line 374, section "1i. Independent audit on free tools — 2026-10-04/05".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **ELEM-8** | `tb/core/tb_d_port_ahb_master.sv` | OPEN (testbench) | **The soak's teardown withdraws a transfer still waiting in its address phase.** The loop re-rolls the request only while `mem_stall` is low (lines 361-367), but line 372 drops `start` at the next negedge after the 600th iteration without waiting for the access to finish. With Verilator 5.052's default seed the last access is a NONSEQ to `0xE4590028` held by HREADY low at 6255 and 6265 ns; `start` falls at 6270 ns, HTRANS returns to IDLE and `a_addr_stable` fails at 6275 ns, yet the bench prints 67 of 67 checks passed. Of seeds 1 to 12 (1 is the default) only seed 1 fails. Lines 368-369 also draw HREADY and HRESP independently, so all 17 soak ERROR responses in that run last one cycle, which AHB-Lite does not allow. HTRANS follows `start_i` combinationally, relying on the pipeline hold; no confirmed RTL defect. Found by: a Verilator run of the element bench, traced with a bound SV monitor. |

**2026-10-11:** W6 fix: the soak slave gives ERROR only in a data phase and only as the two-cycle AHB-Lite response; the teardown completes the access in flight before dropping start. Seeds 1..12 pass.

### T-12

*From `Docs/BUGS.md` at b90b481, line 390, section "1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)".*

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **T-12** | `rtl/core/csr_file.v` | **OPEN, fix needs an owner decision** | **P1** | **A second trap inside an interrupt handler leaves the interrupt level wrong.** The core keeps one saved level (`mpil`). It is pushed on an interrupt, popped on every `mret`, and no CSR lets software read or write it (`mintstatus` is read-only and `mcause` does not carry it). Two consequences, both reproduced on the unmodified RTL with a 40-line bench driving `csr_file` directly. (a) Nested interrupts: handler A at level 80 is preempted by B at level 200; after B returns the level is 80 (correct), after A returns it is **still 80** where it must be 0, so every interrupt at level 80 or below is blocked until reset. (b) An exception inside a handler (illegal instruction, bus error, or the software divide, which is an illegal-instruction trap): the exception does not push, its `mret` pops, and the level drops to **0 while still inside handler A**; if A has re-enabled interrupts, its own still-asserted source re-enters it. A handler that never re-enables `mstatus.MIE` is not affected by either, which is why no existing test saw it: CLIC §8.3 and §11 plan nesting tests to depth 3 and none was ever written (AUD-11). The standard CLIC answer is `mcause.mpil` (bits 23:16), saved and restored by the handler with `mcause`, and a push on every trap. That changes what a handler reads in `mcause`, so it is the owner's call. | reading `csr_file.v` against CLIC §7.4/§8.3 while writing the CLIC feature plan (feature F27, F28) |

**2026-10-11:** Fixed on branch a/p0-infra (W3) per DN-T12 with the recommended rulings (R1 MTI keeps mil; R2 mintstatus 0x346 = {24'b0, mil}; R3 0xFB1 = {mil, 24'b0}); Karthik to confirm. rtl/core/csr_file.v ERRATUM T-12: mcause[23:16] = mpil pushed on every trap, mret restores mil from it, hidden mpil_r removed. Properties (csr_file_sva.sv, trap_ctrl_sva.sv) PROVEN at csr_file and whole-core level; the pre-fix csr_file fails them. Open: program-level t_core_irq_nest.S (needs the P0.8 test device) and the firmware rule (handlers that re-enable MIE or can trap save/restore mcause) in crt0_chip.S/crt0.S (Karthik) and the TRM.

**2026-10-11:** Program level done (P0.8 test device): t_core_irq_nest passes (depth-3 nesting, exception and MTI inside a level-80 handler, level-30 take after unwind, plain mcause at level 0), also with IWAIT/DWAIT=2. Negative control negctl_t12: the same program with csr_file.v replaced by the T-12-reverted mutant fails with test 5 (and a_trap_pushes_mpil fires). Evidence logs/core/evidence/T-12_program_level.txt. Remaining before FIXED: Sreyesh's commit SHA; crt0/crt0_chip handler save/restore of mcause is Karthik's (firmware rule).

### RDC-1

*From `Docs/BUGS.md` at b90b481, line 393, section "1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)".*

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **RDC-1** | `rtl/core/garuda_core_top.v`, `rtl/debug` (halt by reset) | **OPEN, reproduced** | P2 | **A debugger halt resets the core at an arbitrary cycle, under a bus that is not in reset.** `hartreset` goes straight from a Debug Module flop into the core's asynchronous reset. If the core is in the waited data phase of a store (any peripheral write, about eight cycles), its write data and the address phase behind it change mid-transfer: the store in flight would complete with the wrong data and the next transfer is withdrawn, which AHB-Lite does not allow. From the reset-domain review (`flow/2_static/rdc_review.md`, crossing 5); **Reproduced on the unmodified RTL** by forcing `hartreset_n_i` low for 23 ns at 50 moments while `t_mem` runs with five data-port wait states: at 3139 ns the bus checker reports *"HWDATA changed during a wait state of its own write data phase"*; the other 49 moments fell outside a store. So the word being stored when the debugger halts the core is written with the wrong value. No existing test halts a core that is doing anything: `t_chip_jtag` halts it while it idles in the boot ROM. A permanent test is planned as `t_core_hartreset` (core plan F37); the fix is a design choice (finish the transfer in flight before the reset takes effect) and has not been made. | reset-domain review, stage 1 |

**2026-10-11:** Fixed on branch a/p0-infra (W4, DN-RDC1 option A): the Debug Module's haltreq is now a request; the core stops fetching and reports halt_safe (no address presented, no data phase on either port); the DM grants hartreset only then, or after HALT_TIMEOUT=1024 cycles with sticky haltinfo.haltforced (DMI 0x70). Proven on core + real DM (fv_rdc1); the pre-fix grant fails, and also withdraws a waited I-port address, which the original report did not name. Needs Karthik: the two nets in rtl/soc/garuda_soc_top.v, rulings on option A / HALT_TIMEOUT / the 0x70 address.

### T-15

*From `Docs/BUGS.md` at b90b481, line 395, section "1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)".*

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **T-15** | `rtl/core/csr_file.v` (mepc write) | **FIXED** | P3 | **mepc bit 1 was writable.** Only bit 0 was masked. GARUDA has no compressed instructions, so the privileged specification makes both low bits of mepc always zero. Before the fix, on the unmodified RTL: `csrw mepc` with all ones read back `0xFFFF_FFFE` (Spike: `0xFFFF_FFFC`), `0x1000_0002` read back unchanged (Spike: `0x1000_0000`), and an `mret` to an mepc with bit 1 set put a misaligned address on the instruction port: the bus checker reported *HADDR is not aligned to HSIZE* ten times while the program still ended in PASS, because the memory ignores the low address bits. A handler that adds 2 to mepc, as code written for a core with compressed instructions does, would do this. Fix: the write masks both bits. Directed test added to the ISA regression: `sw/riscv-tests/local/csr_warl.S` (`p-csr_warl`), which writes all ones, zero and misaligned values to each writable CSR, returns through a misaligned mepc, and is compared with Spike value by value. After the fix: 64 ISA tests, 12 sanity programs, 8 chip tests, the unit benches and the DSU run pass; lint unchanged. This was item 9 of AUD-12. | the extended lockstep (VER-3), first new test |

### C-16

*From `Docs/BUGS.md` at b90b481, line 398, section "1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)".*

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **C-16** | `rtl/core/csr_file.v` (CSR address decode) | **OPEN, needs an owner decision** | P3 | **Four groups of CSRs that the privileged specification says exist are answered with an illegal-instruction trap.** The core specification cites privileged v1.12. That version has `mstatush` on RV32, `mconfigptr`, `mhpmcounter3` to `31` with their high halves, and `mhpmevent3` to `31`; each may read zero, but an access must not trap. GARUDA traps on all 89 addresses. Found by reading every one of the 4,096 CSR addresses on the RTL and on Spike and comparing the two maps (`tools/csr_map.py`, `make csr_map`): GARUDA has 26 addresses, 21 of them in common with Spike; 5 only on GARUDA (CLIC registers and the DSU flag, by design); and on Spike only, besides these 89, `mcountinhibit`, the trigger registers and `time`, which are optional. Firmware written for GARUDA does not touch these registers; code that is not written for it (a library that clears the hpm counters at start, a debugger reading `mconfigptr`) takes a trap. The fix is a decode that reads zero and ignores writes, about six lines; it changes the CSR table in CORE 6.1, so it is the owner's choice between that and recording the omission in the specification. The map tool keeps the list: a new difference with no recorded reason fails `make csr_map`. | CSR sweep, after two riscv-dv programs diverged on CSR existence |

**2026-10-11:** Fixed on branch a/p0-infra (W2): rtl/core/csr_file.v ERRATUM C-16, contract Design_Docs/regs/core_csr.yaml, tools/csr_map.py now checks the RTL against the contract. Properties in rtl/core/csr_file_sva.sv PROVEN (negative control on the pre-fix RTL FAILS). Becomes FIXED with the commit SHA.

### I-1

*From `Docs/BUGS.md` at b90b481, line 802, section "4. Block 1 — RV32IM core".*

| ID | Status | Severity | One-line |
|---|---|---|---|
| I-1 | FIXED | high | A single `fetch_outstanding` flag fired one cycle early, sampling HRDATA during the **address** phase. Every instruction was paired with the previous bus cycle's data; the first fetch decoded as illegal and trapped on instruction one. AHB-Lite is pipelined — two flags are required, not one. |

### D-1

*From `Docs/BUGS.md` at b90b481, line 803, section "4. Block 1 — RV32IM core".*

| ID | Status | Severity | One-line |
|---|---|---|---|
| D-1 | FIXED | high | Same root cause on the D-port. **Every store wrote zero** (HWDATA collapsed when the pipeline advanced) and every load returned the previous bus cycle's data. |

### BUS-A

*From `Docs/BUGS.md` at b90b481, line 804, section "4. Block 1 — RV32IM core".*

| ID | Status | Severity | One-line |
|---|---|---|---|
| BUS-A | FIXED | medium | HBURST derived from the *current* HTRANS, so the opening beat of every burst declared SINGLE and each following beat declared INCR. 494 violations in one `add.hex` run. |

### BUS-B

*From `Docs/BUGS.md` at b90b481, line 805, section "4. Block 1 — RV32IM core".*

| ID | Status | Severity | One-line |
|---|---|---|---|
| BUS-B | FIXED | medium | A burst broken by a full prefetch buffer resumed with SEQ — a SEQ beat with no open burst. |

### BUS-C

*From `Docs/BUGS.md` at b90b481, line 806, section "4. Block 1 — RV32IM core".*

| ID | Status | Severity | One-line |
|---|---|---|---|
| BUS-C | FIXED | medium | On redirect the master retracted an already-presented address phase. **AHB-Lite has no cancel.** |

### BUS-D

*From `Docs/BUGS.md` at b90b481, line 807, section "4. Block 1 — RV32IM core".*

| ID | Status | Severity | One-line |
|---|---|---|---|
| BUS-D | FIXED | medium | Nothing enforced the 1 KB burst boundary. Harmless against a flat memory; a decode bug the moment a fabric exists — which it now does. |

### CORE-1

*From `Docs/BUGS.md` at b90b481, line 808, section "4. Block 1 — RV32IM core".*

| ID | Status | Severity | One-line |
|---|---|---|---|
| **CORE-1** | **FIXED** | medium (synthesis blocker) | `rtl/core/mem_wb_reg.v`, `ex_mem.v` and `if_id.v` all wrote `always @(posedge clk_i or negedge rst_n_i) … if (!rst_n_i \|\| flush_i)`. A **synchronous** signal in an **asynchronous** reset condition, not in the sensitivity list. Simulation treats `flush_i` as synchronous (correct); synthesis cannot tell, and Yosys 0.69 refused outright: `ERROR: Multiple edge sensitive events found for this signal!` on `mem_wb_reg.rd_o`. A tool that *accepts* it may infer flush as a second asynchronous reset — a functional difference in silicon, not a lint nit. **Fix:** keep the async reset, move the flush to `else if (flush_i)` with the same body. Priority is unchanged (reset, then flush, then stall). **Proven behaviour-preserving** by an old-vs-new equivalence testbench: both versions of all three registers driven from identical stimulus for 20,000 cycles, including flush and stall asserted together and async reset overlapping flush — **0 mismatches**. Unblocks full-SoC synthesis. |

### CORE-2

*From `Docs/BUGS.md` at b90b481, line 809, section "4. Block 1 — RV32IM core".*

| ID | Status | Severity | One-line |
|---|---|---|---|
| CORE-2 | OPEN | low | `garuda_core_top` and `csr_file` carry an unused parameter (Verilator `UNUSEDPARAM`). Cosmetic. |

### T-16

Found by the free-tool audit (2026-10-05) when the trap_ctrl contract TC-2 was refuted: an EX-point exception on the instruction parked behind a WFI is taken while the core sleeps; the core then waits at the handler entry for the wake. Legal (WFI may complete early) but CSR writes move earlier than a reader of the spec expects. The audit called it 'T-12', which collides with the team's T-12 (the interrupt-level stack); renumbered T-16. Ruling needed: accept and document, or hold the exception until the wake. Covered by the WFI wake matrix (plan E12).

### TB-48

*Called TB-34 in Track A evidence written before 2026-10-14. Renumbered on the rebase onto `e43672f`: Karthik's `main` uses TB-34 for a different defect (`clk_div_sva` `a_pclk_subset_hclk` at time 0, fixed in 6aa73bb; see `Docs/bugs/clkrst.md`).*

`tb/core/tb_mem_wb_reg.sv:75` `a_capture` fires once at the reset release under Verilator 5.052, which applies `disable iff` at clock edges only (IEEE 1800 16.12 makes it asynchronous; pinned by the SVA self-test, `p_async_disable`). The scoreboard passes 38/38. Fix (W6): write the property so it does not depend on the disable timing, e.g. gate on a registered reset. Until then the row is XFAIL:TB-48 on Verilator; Xcelium is the authority.

**2026-10-11:** W6 fix: the mid-stream reset is held across a clock edge (correct under both disable-iff semantics); the initial reset is now a real falling edge at 1 ns (it was the TB-32 class too, passing only because Verilator's outputs start at 0).

### C-1

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/core/decode_control.v:203`:*

```
// ERRATUM C-1 (found by riscv-tests rv32mi/shamt)
```

### C-2

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/core/decode_control.v:80`:*

```
localparam [6:0] OP_MISC_MEM= 7'b0001111;   // FENCE / FENCE.I (ERRATUM C-2)
```

### C-3

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/core/branch_predict.v:44`:*

```
// ERRATUM C-3: FENCE.I redirects to the NEXT instruction. The redirect is
```

### C-4

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/core/csr_file.v:78`:*

```
// ERRATUM C-4 (Zicntr): user-level read-only shadows of the
```

### F-1

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/core/ex_stage.v:132`:*

```
// capture across a multi-cycle stall. See ERRATUM F-1 in id_ex.v.
```

### P-1

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/core/pipe_ctrl.v:151`:*

```
// ERRATUM P-1 (found by riscv-tests ld_st)
```

### P-2

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/core/pipe_ctrl.v:78`:*

```
// ERRATUM P-2 (found by riscv-tests rv32mi/ma_addr)
```

### P-3

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/core/pipe_ctrl.v:108`:*

```
// the WFI, and EX/MEM is being fed bubbles (ERRATUM P-3). A JALR parked
```

### T-1

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/core/branch_unit.v:57`:*

```
// ERRATUM T-1: instruction-address-misaligned (cause 0) detection.
```

### T-2

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/core/csr_file.v:147`:*

```
// ERRATUM T-2 (found by riscv-tests rv32mi/ma_fetch)
```

### T-3

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/core/trap_ctrl.v:226`:*

```
// ERRATUM T-3 (found by riscv-tests rv32mi/breakpoint)
```

### T-4

*Back-filled 2026-10-11: this erratum was recorded only as an RTL comment, never in the register. First citation `rtl/core/garuda_core_top.v:346`:*

```
.idex_valid_i(xe_valid),                      // ERRATUM T-4
```

### C-17

Found 2026-10-11 while adding the C-16 read-zero test: `csrr t1, minstret` as the 839th instruction read 0x344 on GARUDA and 0x346 on Spike (the count of instructions retired before it). csr_file counts minstret at write-back (instret_i from the WB retire tag), but a CSR read happens in EX, so the up to two older instructions in MEM and WB are not yet counted. The privileged/Zicntr specification says instret counts instructions retired; software reading it sees a value that depends on pipeline occupancy. Ruling needed: (a) accept and document the lag (CORE spec 6.1, TRM), or (b) add the number of valid older instructions in MEM/WB to the value read (no extra state; the co-simulation E3 then compares minstret exactly). mcycle is not affected (no reference value exists for cycles). A directed test (t_core_minstret_read) comes with the ruling.

### CORE-4

The branch predictor, the prefetch buffer, CLIC preemption and the WFI clock gate are always on: if one of them turns out to be wrong in silicon there is nothing firmware can do. Track A W5 adds mgarudactl (CSR 0x7C0, M-mode RW, reset 0 = all features on): bit0 BP_DIS, bit1 PF_DIS, bit2 PREEMPT_DIS, bit3 CG_DIS; the bits change timing only, never architectural results (DN-CTL). Rulings pending with Karthik: the address and the bit meanings.

**2026-10-11:** Implemented on branch a/p0-infra (W5): mgarudactl at 0x7C0 (Ibex uses the same slot for its cpuctrl), bits BP_DIS/PF_DIS/PREEMPT_DIS/CG_DIS, reset 0. Architectural equivalence over all 16 settings and per-knob effect checked by t_core_ctl; properties PROVEN, per-knob mutants fail. Becomes FIXED with the commit SHA after Karthik confirms the address and bits.

**2026-10-11:** W5 test (b) done: t_core_preempt raises interrupts from the tb_boot test device at fixed points. PREEMPT_DIS=1 holds a level-200 request until the level-40 handler returns; PREEMPT_DIS=0 lets it preempt. Passes, also with IWAIT/DWAIT=2. Negative control negctl_preempt (clic_ctrl_no_preempt.v) fails with test 3 and a_ctl_preempt fires. Evidence logs/core/evidence/CORE-4_preempt_program.txt.

### TB-39

The bench's mid-stream reset is a sub-cycle pulse (falls 1 ns after a posedge, rises at the next negedge). IEEE 1800 16.12 makes disable iff asynchronous, so the a_fetch_step attempt started at the last edge is cancelled; Verilator 5.052 samples disable iff at the clock, so the attempt survives and fails at 275 ns (fetch_pc is the reset vector, not past+4). Hidden in the baseline under TB-32's xfail ('1 assertion failure(s)' next to the reset [FAIL]s). Same class as TB-48. Fix: hold the re-reset across one clock edge. No RTL defect.

### T-17

trap_ctrl.v e1 = idex_fault_i is the only EX-point exception term not qualified by idex_valid_i. After a fetch fault the trap flushes the prefetch buffer, whose empty slot 0 still presents fifo_fault[0]=1; if_id and id_ex carry it on a bubble and trap_ctrl takes cause 1 from the bubble, mepc/mtval = the old fetch PC, then flushes again. The handler never runs; the core loops until reset or the watchdog. Never seen before because no suite took an instruction access fault (i_hresp_i never toggled; cg_trap.instr_fault empty). Same class as T-4. Proposed P1 (a bad function pointer or fetch bus error hangs the core).

**2026-10-11:** Fixed in the tree: trap_ctrl e1 = idex_fault_i & idex_valid_i. t_cov_fault(+_w3) pass (12 fetch faults + 96 load/store faults, all checked); a_ex_exc_needs_instr PROVEN on the whole core, c_fetch_fault COVERED, pre-fix mutant fails it. FIXED after Sreyesh's commit SHA. Priority P1 proposed (ruling with Karthik).

### TB-40

tb/cov/garuda_cov.sv bound cg_ldst's size and offset to em_funct3 and d_haddr_o (MEM stage, the previous instruction) while sampling on xe_valid & xe_mem_read/write (EX stage). The bins mixed two instructions, and the misaligned size x offset bins (which trap in EX and never reach the bus) could not be hit. Fix: bind to xe_funct3 and ex_result (EX effective address); port names unchanged. Coverage-model defect, no design impact.

### BUS-E

A JAL or predicted-taken branch with a target that is 2 mod 4 redirects fetch from ID. If the instruction then waits in EX behind a load still in MEM (its cause-0 trap or mispredict redirect is held while H2, T-9), garuda_iport_ahb_master issues a NONSEQ word fetch at the misaligned address. AHB-Lite requires HADDR aligned to HSIZE; tb_boot's AHB-Lite checker reports 'HADDR is not aligned to HSIZE' (6 in t_cov_misfetch). No architectural effect (the fetched slots are bubbles; Spike lockstep MATCH), but a strict slave may answer ERROR or misbehave, and the address can be anywhere (peripheral). Fix: the I-port issues no fetch while fetch_pc is not word-aligned; the redirect that caused it always resolves in EX (trap, mispredict, older trap).

**2026-10-11:** Fixed in the tree: fetch_issue_o requires fetch_pc_i[1:0]==0. t_cov_misfetch(+_w2,_d3) pass with a clean AHB checker (Spike lockstep MATCH); a_ihaddr_aligned PROVEN on the whole core; pre-fix mutant fails it. FIXED after Sreyesh's commit SHA. Priority P2 proposed.

### T-18

branch_unit.v chose redirect_target = taken_r ? branch_target : pc+4 for everything that is not a JALR. For a JAL, taken_r is the branch comparator run on bit fields that are not operands: instr[14:12] (imm[14:12]) as funct3, instr[19:15] / [24:20] (imm bits) as rs1 / rs2. redirect_target does not steer a JAL (it redirects from ID; `redirect` stays low), but trap_ctrl takes it as the cause-0 mtval (T-1). So a JAL to a 2-mod-4 target reported mtval = pc+4 whenever its fields read "not taken": in riscv-arch-test privilege-misalign-jal-01 the case `j +0x22a` (0x22a0006f, read as "BEQ x0, a0" with a0 != 0) gave mtval 0x100002e0 = pc+4 against Spike's 0x10000506. t_cov_misfetch's two JALs passed only because the registers their fields name (x6, x30) held 0. Not seen by the cosim (no program took a misaligned JAL with a nonzero field register) or by riscv-formal (insn checks do not look at mtval). Proposed P2: the trap is taken correctly and mepc is right, but the handler gets a wrong faulting address.

**2026-10-11:** Fixed in the tree: redirect_target = jalr ? jalr_target : (jal | taken_r) ? branch_target : pc+4. New case 1b in t_cov_misfetch (J +6 with x6 = 0x5A5A) fails before (fail code 7, mtval 0x10000098) and passes after in all three timing variants; property a_misfetch_tval_misaligned (a cause-0 trap's mtval is never word-aligned) fails before on t_cov_misfetch and privilege-misalign-jal-01, passes after; arch-test 59/59. FIXED after Sreyesh's commit SHA.
