# GARUDA Core: Micro-architecture

## 0.1 Identity

| Field | Value |
|---|---|
| Document | GARUDA-CORE-UARCH-001 |
| Revision | 1.0, 2026-11-03 |
| Block | 1 (core), with block 2 (DSU) where it sits in EX |
| Companion | `GARUDA-CORE-SPEC-001` (requirements, CSRs, the hold and flush table §7.6, timing §8) |
| Source of truth | the RTL in `rtl/core/`; where this document and the RTL differ, the RTL is right and this document is wrong |
| Written for | 1-TOPS item 1.13: per-stage datapath, control signals, hazard and forwarding logic, memory interface protocol |

The CORE spec says *what* the core must do. This document says *how* the RTL does it, stage by stage, file by file.

---

## 1 The pipeline at a glance

```
            IF                 ID                 EX                  MEM                WB
  ┌───────────────────┐ ┌────────────────┐ ┌──────────────────┐ ┌─────────────────┐ ┌──────────┐
  │ pc_gen            │ │ decode_control │ │ fwd muxes A/B    │ │ load_store_unit │ │ wb_stage │
  │ iport_ahb_master ─┼─┤ imm_gen        │ │ alu              │ │ d_port_ahb_     │ │  → regfile│
  │ prefetch_buffer(4)│ │ regfile (read) │ │ mul32 (1 cycle)  │ │   master        │ │   write  │
  │                   │ │ branch_predict │ │ branch_unit      │ │ load_formatter  │ │          │
  │                   │ │ hazard_fwd_unit│ │ csr_rw           │ │ wb_data mux     │ │          │
  │                   │ │  (load-use)    │ │ dsu_top (block 2)│ │                 │ │          │
  └────────┬──────────┘ └───────┬────────┘ └────────┬─────────┘ └────────┬────────┘ └────┬─────┘
           │      if_id         │      id_ex        │      ex_mem        │     mem_wb     │
           ▼   (pipeline reg)   ▼  (pipeline reg)   ▼  (pipeline reg)    ▼ (pipeline reg) ▼
       I-port (AHB M0)                                              D-port (AHB M1)

  CONTROL (beside the pipeline): pipe_ctrl · trap_ctrl · clic_ctrl · csr_file · core_clk_gate
```

- Five stages, in order, single issue. Every stage has its own module, and every pipeline register is a separate module instantiated at the core top (`garuda_core_top.v`). A register belongs to neither the stage before nor the stage after it.
- Every core flop runs on `gclk`, the output of `core_clk_gate` (§8.4).
- Best-case throughput is one instruction per cycle. The cycles lost are listed in §7.

---

## 2 IF: instruction fetch

Files: `garuda_if_stage_top.v` (wiring only), `garuda_pc_gen.v`, `garuda_iport_ahb_master.v`, `garuda_prefetch_buffer.v`.

### 2.1 Datapath

| Element | What it holds or does |
|---|---|
| `pc_gen.fetch_pc_o` | The address the I-port fetches next. It advances by 4 each time the I-port's address phase is accepted, so it runs up to four words ahead of the pipeline. |
| `pc_gen.pc_o` | The address of the instruction entering ID: the PC tag of the popped entry, plus 4. |
| `prefetch_buffer` | A 4-entry circular FIFO. Each entry holds `{instr[31:0], pc[31:0], fault}`. `fault` is set when the I-port got an AHB ERROR for that word. The reset contents are NOPs (`addi x0,x0,0`). |
| `iport_ahb_master` | Issues fetches only while (buffered + outstanding) < 4 can hold another word, so the FIFO can never overflow. |

### 2.2 Control

| Signal | Source | Effect |
|---|---|---|
| `redirect_i`, `redirect_pc_i` | `pipe_ctrl` redirect mux (§8.1) | Both PCs load the target in the same cycle. The whole FIFO is emptied in one cycle (pointers reset, not entry by entry). |
| `drop_pending` (inside the I-port) | the I-port itself | A fetch still on the bus when a redirect happens is discarded when its data arrives, even if that is a cycle after the redirect. |
| `stall_i` | `pipe_ctrl` (PC hold) | No pop from the FIFO. Fetching continues until the FIFO is full. |
| `fetch_stop_i` | Debug Module `halt_req_i` (RDC-1) | No new address phase starts. One already presented stays until accepted (AHB-Lite does not allow it to be withdrawn). |
| `pf_dis_i` | `mgarudactl.PF_DIS` (CORE-4) | At most one fetch buffered or in flight. This changes timing only, never results. |

### 2.3 I-port protocol (AHB-Lite master M0)

| Signal | Value |
|---|---|
| `HSIZE` | word (`3'b010`), always |
| `HBURST` | `INCR`, always: one undefined-length burst per run of sequential fetches (BUS-A to BUS-D) |
| `HTRANS` | `NONSEQ` for the first beat after a start or a redirect; `SEQ` for the next sequential word; `IDLE` when the FIFO has no room or fetching is stopped |
| `HWRITE`, `HWDATA` | 0: read only |
| `HPROT` | fixed |
| Pipelining | address and data phases overlap; one address phase can be presented while the previous data phase completes |
| Error | `HRESP` = ERROR on a fetch sets `fault` on that entry. The trap is taken only if that entry reaches EX as a real instruction (cause 1, T-17). |

---

## 3 IF/ID register (`if_id.v`)

Fields: `instr`, `pc`, `fault`, `valid`. It is held by `pipe_ctrl` (PC/IF-ID hold) and flushed (valid ← 0) by any redirect. The exception is an ID redirect while ID is held: that one leaves IF/ID alone (erratum P-2 in `pipe_ctrl.v`), so the branch is not destroyed.

---

## 4 ID: decode and register read

Files: `id_stage.v` (wiring), `decode_control.v`, `imm_gen.v`, `regfile.v`, `branch_predict.v`, `hazard_forward_unit.v`.

### 4.1 Datapath

| Element | What it does |
|---|---|
| `regfile` | 31 × 32-bit registers (x0 is not stored and reads 0). Two read ports, combinational. One write port, written on the clock edge from WB. **Write-then-read bypass:** a read of the register WB is writing in the same cycle returns the new value. **No reset:** a register reads X in simulation until something writes it. |
| `imm_gen` | The I, S, B, U and J immediates, sign-extended. |
| `decode_control` | Turns the opcode, funct3 and funct7 into the control bundle below. Raises `illegal` for every encoding outside RV32IM + Zicsr + Zifencei + the DSU's custom-0 space. DIV, DIVU, REM and REMU are deliberately illegal: they are done in software (CORE §7.2). |
| `branch_predict` | Static backward-taken, forward-not-taken. **JAL always redirects from ID.** A backward conditional branch is predicted taken and redirects from ID. FENCE.I redirects to pc+4, which empties the prefetch buffer (C-3). `mgarudactl.BP_DIS` predicts every branch not taken. The prediction bit travels down `id_ex` so EX can check it. |
| `hazard_forward_unit` | Load-use detection only (§7.1). |

### 4.2 Control bundle produced in ID

| Signal | Meaning |
|---|---|
| `reg_write` | the instruction writes `rd` |
| `mem_read`, `mem_write` | load, store |
| `mem_to_reg` | WB value comes from memory, not from EX |
| `alu_src` | ALU operand B is the immediate (else `rs2`) |
| `alu_a_pc` | ALU operand A is the PC (AUIPC, JAL link) |
| `alu_op[3:0]` | the ALU operation |
| `branch`, `jal`, `jalr` | control-transfer kind |
| `mul_en` | MUL, MULH, MULHSU, MULHU |
| `dsu_en` | a DSU custom-0 instruction |
| `csr_en`, `csr_op`, `csr_imm` | a CSR instruction and its kind |
| `is_system` | ECALL, EBREAK, MRET, WFI |
| `illegal` | raises cause 2 in EX |
| `predict_taken` | the ID prediction, checked in EX |

---

## 5 ID/EX register (`id_ex.v`)

Fields: the control bundle of §4.2, `pc`, `instr`, `rs1_data`, `rs2_data`, `imm`, `rs1_idx`, `rs2_idx`, `rd`, `funct3`, `fault`, `valid`, and a retire tag for `minstret`.

During a hold it captures the **forwarded** operands from EX, not the stale register-file values (erratum F-1). A held instruction whose producer moves on during the hold therefore keeps the right value.

---

## 6 EX: execute

Files: `ex_stage.v` (combinational, except the DSU's state), `alu.v`, `mul32.v`, `branch_unit.v`, `csr_rw.v`, `forward_unit.v`, and `rtl/dsu/dsu_top.v` (block 2).

### 6.1 Datapath

| Element | What it does |
|---|---|
| Operand muxes A and B | For each source, select the register-file value, the EX/MEM result, or the MEM/WB value (§7.2). Then A may be replaced by the PC (`alu_a_pc`) and B by the immediate (`alu_src`). |
| `alu` | Add, sub, logic, shifts (amount masked to 5 bits), SLT, SLTU. |
| `mul32` | One shared signed 33 × 33 multiplier, **single cycle**. Both operands are sign- or zero-extended to 33 bits by funct3. MUL takes `product[31:0]`; MULH, MULHSU and MULHU take `product[63:32]`. It is written with the `*` operator, and synthesis builds the tree. This multiplier in series with the EX result mux is the core's critical path (CORE §7.9). |
| `branch_unit` | Resolves all six conditional branches. Computes `branch_target`, `jalr_target` (`(rs1 + imm) & ~1`) and the link `pc + 4`. Raises `mispredict` when the outcome differs from `predict_taken`, and `redirect` for a mispredict or any JALR. Checks the target's alignment (cause 0, T-1; a JAL reports the target in `mtval`, T-18). |
| `csr_rw` | The new CSR value for CSRRW/S/C and their immediate forms. The write itself happens in `csr_file` only when the instruction commits (`commit_i`), so a squashed CSR instruction writes nothing. |
| `dsu_top` | The DSU MAC coprocessor (`GARUDA-DSU-SPEC-001`). A multi-cycle operation raises `dsu_busy`, a **registered** output that holds PC, IF/ID and ID/EX in the same cycle (§7.3). |
| Misalignment check | Load and store address alignment is checked in EX, before the D-port starts an address phase (causes 4 and 6). A misaligned access never reaches the bus. |

**EX result mux, in priority order:** CSR read value (`csr_en`) > DSU result (`dsu_rd_valid`) > multiplier > ALU or link.

### 6.2 What EX sends on

| To | What |
|---|---|
| `ex_mem` | `ex_result`, `store_data` (rs2 after forwarding), `rd`, `funct3`, `pc`, the memory and write-back controls, `valid` |
| `pipe_ctrl` | `redirect` and `redirect_target` (mispredict, JALR), `dsu_busy` |
| `trap_ctrl` | the exception terms of the instruction in EX: fault, illegal (decode, DSU, CSR), EBREAK, ECALL, MRET, WFI, misaligned fetch, load or store target |

---

## 7 Hazards and forwarding

### 7.1 Load-use (the only data-hazard stall)

`hazard_forward_unit`: the instruction in EX is a load (`mem_read`) with `rd ≠ x0`, and `rd` equals the `rs1` or `rs2` index of the instruction in ID. The check does not look at whether the ID instruction actually uses that field, so a LUI with a matching field index also stalls. That is conservative and always safe.

Effect: PC and IF/ID are held and ID/EX is flushed. That is **one bubble**. Next cycle the load is in MEM; the cycle after, its data is in MEM/WB and is forwarded into EX.

### 7.2 Forwarding (`forward_unit.v`, muxes in `ex_stage.v`)

For each of `rs1` and `rs2` of the instruction in EX:

| Priority | Source | When |
|---|---|---|
| 1 | EX/MEM `ex_result` | EX/MEM writes a register, its `rd ≠ x0`, and its `rd` is this source |
| 2 | MEM/WB `wb_data` (after load formatting) | same rule, on MEM/WB |
| 3 | register file | otherwise; the register file's own write-then-read bypass covers a producer in WB |

EX/MEM never holds load data (its `ex_result` for a load is the address). That is safe because a load followed at once by its consumer is always split by the load-use bubble.

### 7.3 Structural and control hazards

| Hazard | How it is handled | Cost |
|---|---|---|
| D-port wait state (H2) | PC, IF/ID, ID/EX and EX/MEM held; a bubble goes into WB | 1 cycle per wait state, plus 1 for every load or store (§9) |
| DSU busy | PC, IF/ID and ID/EX held; `id_ex` keeps the DSU op | the DSU's extra cycles |
| JAL, predicted-taken branch (ID redirect) | IF flushed | 1 bubble |
| Mispredict, JALR (EX redirect) | IF and ID flushed; the redirecting instruction itself is kept | 2 bubbles |
| Trap or MRET | IF, ID and the faulting instruction's downstream register flushed | 2 bubbles |
| FENCE.I | held in ID like a load-use until no older store is in EX or MEM, then redirects to pc+4 | the wait plus the buffer refill |
| WAR, WAW | cannot happen: in order, one write port, written only in WB | 0 |

The full composition of holds and flushes is CORE §7.6 (20 cells), as implemented in `pipe_ctrl.v`.

---

## 8 Control blocks

### 8.1 `pipe_ctrl.v`: holds, flushes, redirect mux

- **Redirect priority:** trap or MRET > EX (JALR, mispredict) > ID (JAL, predicted taken).
- **Holds are ORed, not prioritised:**
  - PC and IF/ID are held by D-port wait | DSU busy | load-use | WFI (H5);
  - ID/EX by D-port wait | DSU busy | WFI;
  - EX/MEM by D-port wait.
  - FENCE.I's wait for an older store enters as a load-use-style hold (`load_use_stall_i = load_use | fencei_wait` at the core top), so it holds PC and IF/ID and flushes ID/EX.
- **A flush wins over a hold** on the same register.
- Redirects are applied only when no D-port transfer is in a wait state. The source stays asserted and fires the cycle the wait clears (H2, T-9).
- **`quiescent`**: the pipeline is held by WFI and nothing is in flight on either port, in the DSU or in MEM. It is the only definition of "idle" in the design, and it drives the clock gate.

### 8.2 `trap_ctrl.v`

Collects the exceptions of the instruction in EX and the interrupt takes. It applies the priority in CORE [N-7.18a], drives the trap redirect to `mtvec` BASE (or to `mepc` for MRET), and tells `csr_file` what to write. A trap is taken only on a valid instruction in EX (T-2, T-4, T-17), and never while a D-port transfer is waiting (T-9).

### 8.3 `clic_ctrl.v` and `csr_file.v`

- **`clic_ctrl`:** takes a CLIC interrupt when `valid & MIE & level > mintthresh & level > mil`. `mgarudactl.PREEMPT_DIS` allows a take only at level 0.
- **`csr_file`:** holds every CSR in CORE §6.1, reads combinationally, writes only on commit. On trap entry it saves `mepc`, `mcause` (with `mpil`) and `mtval`. On MRET it restores `MIE` and `mil`.

### 8.4 `core_clk_gate.v`

The core's root clock gate: a latch-based ICG model, replaced by the library ICG cell at synthesis. Enable = `~quiescent` (CORE §7.7). `CLK_GATE = 0` or `mgarudactl.CG_DIS` keeps it open. `test_en_i` is the scan-mode bypass and is tied to 0 until the DFT work of G7.

---

## 9 MEM: memory access

Files: `mem_stage.v` (wiring and the write-back mux), `load_store_unit.v`, `d_port_ahb_master.v`, `load_formatter.v`.

### 9.1 Datapath

| Element | What it does |
|---|---|
| `load_store_unit` | `HSIZE` from funct3 (byte, half, word). Store data is shifted onto the byte lane given by `addr[1:0]`. |
| `d_port_ahb_master` | Two-state FSM: `S_ADDR` (idle, or presenting an address) and `S_DATA` (data phase). |
| `load_formatter` | Picks the addressed lane of `HRDATA`, then sign-extends (LB, LH) or zero-extends (LBU, LHU); LW passes through. |
| write-back mux | Chooses formatted load data (`mem_to_reg`) or `ex_result`. `wb_data` leaves MEM already final. |

### 9.2 D-port protocol (AHB-Lite master M1)

| Item | Value |
|---|---|
| Transfers | `SINGLE` only, `NONSEQ`, **one outstanding transfer**, no pipelined back-to-back addresses |
| Address and control | taken straight from `ex_mem`. They stay stable for the whole access because the pipeline is held (§7.3). |
| Timing | Cycle 1: address phase; MEM holds the pipeline (`mem_stall`). Cycle 2: data phase; it completes when `HREADY = 1`, and every wait state adds a cycle. **Every load or store therefore spends at least two cycles in MEM.** |
| OKAY | `ok_done`: the load data is formatted and captured into `mem_wb`. |
| ERROR | The two-cycle AHB ERROR; `err_pulse` in the cycle it is sampled. `trap_ctrl` raises cause 5 (load) or 7 (store), with `mepc` = this instruction (precise). |
| Byte strobes | none on AHB-Lite: the slave uses `HSIZE` and `HADDR[1:0]` |
| Halt (RDC-1) | `halt_safe_o` says neither port presents an address or owns a data phase, so a debugger reset breaks no transfer. |

---

## 10 MEM/WB and WB

- **`mem_wb_reg.v`:** fields `wb_data`, `rd`, `reg_write`, and the retire tag. It takes a bubble during every D-port wait cycle.
- **`wb_stage.v`:** passes `reg_write`, `rd` and `wb_data` to the register file's write port. `minstret` counts the retire tag here (C-17: a read of `minstret` does not yet include the instructions in MEM and WB).

---

## 11 Verification-only logic

`garuda_rvfi.v`: the RISC-V Formal Interface, built only with `GARUDA_RVFI`. It reports every retired instruction to riscv-formal and to the Spike co-simulation. It is never synthesised.

---

## 12 File map

| Stage | Files in `rtl/core/` |
|---|---|
| top | `garuda_core_top.v` |
| IF | `garuda_if_stage_top.v`, `garuda_pc_gen.v`, `garuda_iport_ahb_master.v`, `garuda_prefetch_buffer.v` |
| IF/ID | `if_id.v` |
| ID | `id_stage.v`, `decode_control.v`, `imm_gen.v`, `regfile.v`, `branch_predict.v`, `hazard_forward_unit.v` |
| ID/EX | `id_ex.v` |
| EX | `ex_stage.v`, `alu.v`, `mul32.v`, `branch_unit.v`, `csr_rw.v`, `forward_unit.v`, `core_ex_defs.vh`; DSU in `rtl/dsu/` |
| EX/MEM | `ex_mem.v` |
| MEM | `mem_stage.v`, `load_store_unit.v`, `d_port_ahb_master.v`, `load_formatter.v` |
| MEM/WB | `mem_wb_reg.v` |
| WB | `wb_stage.v` |
| control | `pipe_ctrl.v`, `trap_ctrl.v`, `clic_ctrl.v`, `csr_file.v`, `core_clk_gate.v` |
| verification only | `garuda_rvfi.v`; properties in `*_sva.sv`, `*_props_a.sv` |
