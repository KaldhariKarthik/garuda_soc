# GARUDA RV32IM Core — Design Specification

## 0.1 Identity

| Field | Value |
|---|---|
| Document ID | GARUDA-CORE-SPEC-001 |
| Revision | 3.0 |
| Date | 2026-09-18 |
| Status | Released for implementation |
| Block | 1 (`core`) |
| Owner | Team AeroSoC |
| Supersedes | GARUDA_Core_Design_Spec_v2_1 |

## 0.2 Revision history

| Rev | Change | Driver |
|---|---|---|
| 1.0–2.1 | Initial through the 27-erratum fix set. RTL implemented and verified: 63/63 lockstep against Spike | — |
| 3.0 | `mtime`/`mtimecmp` 64-bit ports replaced by a single `mtip_i`. `hartreset_n_i` added for debug. WFI root clock gate added. Orphan `clic_mintthresh_o` removed. The hold/flush composition made a single authoritative table (§7.6). Frequency target and timing-closure fallback stated. | ADR-0010, 0012, 0001, 0009 |

## 0.3 Normative references

1. RISC-V Unprivileged ISA v2.2 — RV32I, M extension.
2. RISC-V Privileged Architecture v1.12 — Machine-level ISA.
3. RISC-V CLIC specification, draft — the implemented subset is in `GARUDA-CLIC-SPEC-001` §13.
4. `GARUDA-SYS-001` Rev 4.0.
5. `GARUDA-ADR-001` Rev 1.0.
6. `GARUDA-DSU-SPEC-001` Rev 3.0 — the Custom-0 extension in EX.
7. `GARUDA-TIMERS-SPEC-001` Rev 2.0 — `mtip_i`.
8. `GARUDA-CLKRST-SPEC-001` Rev 2.0 — `core_rst_n` and `hartreset`.

---

## 1 Purpose and scope

### 1.1 What this is

A single-hart RV32IM core, M-mode only, five-stage in-order pipeline, no cache. It runs the
1 kHz flight loop: APF collision avoidance, a 9-state EKF, and PID output to the motors.

### 1.2 Status

**This block is implemented and verified.** 63 of 63 lockstep tests pass against Spike, and
27 errata have been found and fixed. Rev 3.0 is a set of interface changes plus one new
document section; it is not a redesign, and it deliberately touches as little of the
verified logic as possible.

### 1.3 What Rev 3.0 changes, and what it protects

| Change | Logic touched | Risk |
|---|---|---|
| `mtip_i` replaces two 64-bit ports | deletes a 64-bit comparator | low — removal only |
| `hartreset_n_i` added | one reset term | low |
| WFI root clock gate | **the hold/flush logic** | **the one to watch** |
| `clic_mintthresh_o` removed | deletes an unused output | low |

**[N-1.1]** The WFI clock gate is the only Rev 3.0 change that touches the pipeline control
logic, and the pipeline control logic is where 4 of the 27 errata came from. §7.7 specifies
it as a consumer of the existing quiescence term rather than a new decode of the WFI
instruction, precisely so that it cannot become a fifth.

---

## 2 Requirements

| ID | Requirement | Source |
|---|---|---|
| R-1 | RV32I base plus M extension. No A, F, D, C. | System |
| R-2 | M-mode only. No U or S mode, no PMP. | System |
| R-3 | Five-stage in-order pipeline, single issue. | System |
| R-4 | All synchronous exceptions precise. | Priv spec |
| R-5 | CLIC-mode interrupts, `mtvec.MODE` = 3. | ADR-0009 |
| R-6 | The machine timer shall arrive as a single `mtip_i` wire. | ADR-0010 |
| R-7 | A debug-controlled reset shall stop the core without disturbing the bus. | ADR-0012 |
| R-8 | WFI shall stop the core's clock and wake on a pending enabled interrupt. | Power |
| R-9 | The DSU shall be an in-pipeline EX extension, not a bus peripheral. | System |
| R-10 | Target 250 MHz, with a documented fallback if closure fails. | ADR-0001 |

---

## 3 Block diagram

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │                          core  (block 1)                            │
  │                                                                     │
  │   IF          ID           EX            MEM          WB            │
  │ ┌──────┐   ┌──────┐   ┌──────────┐   ┌────────┐   ┌────────┐        │
  │ │ pc   │──▶│decode│──▶│   ALU    │──▶│ lsu    │──▶│ regfile│        │
  │ │ gen  │   │      │   │   mul    │   │ align  │   │ write  │        │
  │ │      │   │regfile│  │   ┌────┐ │   │        │   │        │        │
  │ │prefch│   │ read │   │   │DSU │ │   │        │   │        │        │
  │ │ buf  │   │      │   │   │(2) │ │   │        │   │        │        │
  │ └───┬──┘   └──────┘   │   └────┘ │   └────────┘   └────────┘        │
  │     │                 └──────────┘                                  │
  │     │ I-port (M0)          │  forwarding  ◀──────────┘              │
  │     ▼                      ▼                                        │
  │  ┌───────────────────────────────────────────────┐                  │
  │  │              pipe_ctrl                        │                  │
  │  │  hold / flush / trap / quiescent   (§7.6)     │                  │
  │  │      │                                        │                  │
  │  │      └──▶ quiescent ──▶ WFI clock gate (§7.7) │                  │
  │  └───────────────────────────────────────────────┘                  │
  │                            │                                        │
  │  ┌─────────────────────────▼─────────────────────┐                  │
  │  │  csr_file  │  trap_ctrl  │  clic_ctrl         │                  │
  │  │            │             │  take decision     │                  │
  │  └────────────────────────────────────────────────┘                 │
  │        ▲                          ▲                                 │
  │        │ mtip_i (1 wire)          │ clic_irq_{id,level,valid}       │
  │        │                          │                                 │
  │   D-port (M1) ──────────────────────────────────────────────────────┼──▶ AHB
  └─────────────────────────────────────────────────────────────────────┘

  Deleted in Rev 3.0:  mtime_i[63:0], mtimecmp_i[63:0], clic_mintthresh_o[7:0]
  Added in Rev 3.0:    mtip_i, hartreset_n_i
```

---

## 4 Sub-block inventory

| Name | Type | RTL file | Role | Rev 3.0 |
|---|---|---|---|---|
| `garuda_pc_gen` | seq | `garuda_pc_gen.v` | PC, prefetch buffer, I-port master. | — |
| `garuda_decode` | comb | `garuda_decode.v` | Instruction decode, hazard detect. | — |
| `garuda_regfile` | seq | `garuda_regfile.v` | 31×32 GPRs, 2R1W, x0 hardwired. | — |
| `garuda_alu` | comb | `garuda_alu.v` | Arithmetic, logic, shift, compare. | — |
| `garuda_mul` | comb | `garuda_mul.v` | 33×33 signed multiplier, one cycle. | — |
| `garuda_dsu` | seq | `dsu/*.v` | Custom-0 MAC unit. Block 2. | — |
| `garuda_lsu` | seq | `garuda_lsu.v` | Load/store, D-port master, alignment. | — |
| `pipe_ctrl` | comb+seq | `pipe_ctrl.v` | **Hold, flush, trap, quiescence.** | `quiescent` output |
| `csr_file` | seq | `csr_file.v` | CSRs. | `mtip_i`; port removed |
| `trap_ctrl` | comb+seq | `trap_ctrl.v` | Exception and interrupt entry. | — |
| `clic_ctrl` | comb | `clic_ctrl.v` | CLIC take decision. | — |
| `core_clk_gate` | seq | `core_clk_gate.v` | **New.** WFI root gate. | new |

---

## 5 Interfaces

| Port | Dir | Width | Domain | Reset | Description | Rev 3.0 |
|---|---|---|---|---|---|---|
| `hclk_i` | in | 1 | hclk | — | Ungated root clock. | |
| `core_rst_n_i` | in | 1 | hclk | — | From `reset_ctrl`. Asserts for every system reset. | |
| `hartreset_n_i` | in | 1 | hclk | — | Debug core-only reset. | **new** |
| `mtip_i` | in | 1 | hclk | — | Machine timer interrupt, into `mip.MTIP`. | **new** |
| `clic_irq_id_i` | in | 5 | hclk | — | From the CLIC. | |
| `clic_irq_level_i` | in | 8 | hclk | — | | |
| `clic_irq_valid_i` | in | 1 | hclk | — | | |
| `dsu_acc_o` | out | 48×3 | hclk | 0 | Live accumulator taps for Debug. | |
| `dsu_ovf_o` | out | 3 | hclk | 0 | Sticky overflow taps. | |
| I-port (M0) | — | — | hclk | — | AHB-Lite, read only, INCR permitted. | |
| D-port (M1) | — | — | hclk | — | AHB-Lite, read/write, SINGLE. | |

**[N-5.1]** **Deleted:** `mtime_i[63:0]` and `mtimecmp_i[63:0]`. 128 signals and the
comparator they fed (`garuda_core_top.v:126`) are removed; the comparison now happens in
block 11 (ADR-0010). This takes a 64-bit comparator out of a timing cone that already
contains the 33×33 multiplier.

**[N-5.2]** **Deleted:** `clic_mintthresh_o[7:0]`. No consumer ever read it. It implied that
the CLIC block performed the threshold comparison, which it does not — that comparison is
in `clic_ctrl`, inside this core, alongside the CSRs it reads. Removing the port removes the
ambiguity.

**[N-5.3]** `core_rst_n_i` and `hartreset_n_i` are separate ports, not ORed outside. The core
ORs them internally so that both produce identical internal reset behaviour, while
`reset_ctrl` and the Debug Module can drive them independently — `hartreset` leaves the bus,
memories and peripherals running, which is what SBA needs (`GARUDA-DEBUG-SPEC-001` §7.13).

---

## 6 Register map — CSRs

### 6.1 Implemented

| Address | Name | Access | Notes |
|---|---|---|---|
| 0x300 | `mstatus` | RW | Only `MIE` (3) and `MPIE` (7) implemented. |
| 0x301 | `misa` | RO | `0x4000_1100` — RV32IM. |
| 0x304 | `mie` | RW | `MTIE` (7) only. CLIC enables live in the CLIC block. |
| 0x305 | `mtvec` | RW | `MODE` hardwired to 3 (CLIC). |
| 0x340 | `mscratch` | RW | |
| 0x341 | `mepc` | RW | Bit 0 hardwired 0. |
| 0x342 | `mcause` | RW | |
| 0x343 | `mtval` | RW | |
| 0x344 | `mip` | RO | `MTIP` (7) from `mtip_i`. |
| 0x345 | `mnxti` | RO | **Reads 0, not implemented.** See §13. |
| 0x346 | `mintstatus` | RO | `mil` (7:0) — current interrupt level. |
| 0x347 | `mintthresh` | RW | Interrupt level threshold. |
| 0xB00 | `mcycle` | RW | Cycle counter. |
| 0xB02 | `minstret` | RW | Instructions retired. |
| 0xB80 | `mcycleh` | RW | |
| 0xB82 | `minstreth` | RW | |
| 0xF14 | `mhartid` | RO | 0. |

**[N-6.1]** `mip.MTIP` is read-only and reflects `mtip_i` combinationally. Firmware clears the
timer interrupt by advancing `mtimecmp` in block 11, not by writing `mip` — which is what
the privileged specification requires, and which the three-step sequence of
`GARUDA-TIMERS-SPEC-001` §7.4 implements.

**[N-6.2]** `mcycle` and `minstret` are the measurement instruments for the loop duty cycle
that no document asserts a figure for. Firmware reads `mcycle` around each loop stage. Until
that measurement exists, no spec in this project states an idle percentage.

**[N-6.3]** Debug CSRs — `dcsr` (0x7B0), `dpc` (0x7B1), `dscratch0/1` (0x7B2/3) — are **not
implemented** and raise an illegal-instruction exception. This is the deliberate consequence
of ADR-0012: the debug subsystem is System Bus Access only and needs none of them. See
`GARUDA-DEBUG-SPEC-001` §1.3 for what that costs and §13 for the v2 path.

---

## 7 Functional description

### 7.1 Pipeline

**[N-7.1]** IF → ID → EX → MEM → WB, in-order, single issue, no branch prediction.

**[N-7.2]** Branches and jumps resolve in EX and flush IF and ID: a 2-cycle penalty on a
taken branch. No predictor. At 250,000 cycles per loop iteration against a few thousand
branches, a predictor would save well under 1% of the budget for a significant area and
verification cost.

**[N-7.3]** The prefetch buffer holds up to 4 instructions and issues undefined-length INCR
bursts on the I-port. It absorbs arbitration latency, which is why the I-port is the
lowest-priority AHB master.

### 7.2 Multiply and divide

**[N-7.4]** `MUL`, `MULH`, `MULHU`, `MULHSU` use one shared 33×33 signed multiplier in EX,
single cycle. The 33-bit width handles the signed/unsigned combinations with one datapath.

**[N-7.5]** This multiplier is the critical path. In series with the EX result multiplexer,
and with the DSU in the same cone, it is what makes 250 MHz (4 ns) a real question rather
than a formality.

**[N-7.6]** `DIV`, `DIVU`, `REM`, `REMU` **trap to a software handler.** There is no divider.

**[N-7.7]** Rationale, and why this stays: a Newton-Raphson software routine costs roughly
150–250 cycles including trap overhead. The EKF performs a handful of divisions per
iteration, so the total is a few thousand cycles of 250,000. A multi-cycle hardware divider
would cost area, a new stall condition in the pipeline control logic — the most
erratum-prone part of the design — and re-verification, to save under 1% of the cycle
budget. The trap handler is also already written and verified.

**[N-7.8]** The consequence for firmware: division is expensive and must not appear in the
innermost APF loop. The handler must be installed before any division executes, which means
before `main()`.

### 7.3 DSU integration

**[N-7.9]** The DSU decodes the Custom-0 opcode space from the raw instruction word in EX. It
is in the pipeline, not on the bus, so a multiply-accumulate is one instruction rather than a
bus round trip. `GARUDA-DSU-SPEC-001` specifies it.

**[N-7.10]** The DSU asserts `dsu_busy` for a same-accumulator RAW hazard, which `pipe_ctrl`
treats as an ordinary hold. It is not a special case in the hold logic — see §7.6.

**[N-7.11]** The DSU sits in the EX timing cone alongside the multiplier. Both are part of
the 250 MHz question.

### 7.4 Exceptions

**[N-7.12]** All nine synchronous causes are implemented and precise:

| Cause | Name | `mtval` |
|---|---|---|
| 0 | Instruction address misaligned | address |
| 1 | Instruction access fault | address |
| 2 | Illegal instruction | instruction word |
| 3 | Breakpoint | address |
| 4 | Load address misaligned | address |
| 5 | Load access fault | address |
| 6 | Store address misaligned | address |
| 7 | Store access fault | address |
| 11 | Environment call (ECALL) | 0 |

**[N-7.13]** Precise means: `mepc` is the address of the faulting instruction, every earlier
instruction has retired, and no later instruction has changed architectural state. This is
what makes a bus ERROR diagnosable — `mepc` points at the exact load or store.

**[N-7.14]** `mepc` bit 0 is hardwired to zero. With no C extension all instructions are
4-byte aligned.

### 7.5 Interrupts

**[N-7.15]** CLIC mode only, `mtvec.MODE` = 3. `clic_ctrl` computes:

```
take = clic_irq_valid_i
     & mstatus.MIE
     & (clic_irq_level_i >  mintthresh)
     & (clic_irq_level_i >  mintstatus.mil)
```

**[N-7.16]** Both comparisons strictly greater; equal level never preempts
(`GARUDA-CLIC-SPEC-001` §7.4).

**[N-7.17]** `mtip` is separate: it enters `mip.MTIP` and is taken via `mstatus.MIE &
mie.MTIE`, the classic CLINT path, not through the CLIC level hierarchy. Two mechanisms
coexist deliberately (ADR-0010) — the CLIC path for the 20 peripheral and DMA sources, the
`mip` path for the architectural timer. The consequence is that the timer cannot be
level-prioritised against CLIC sources; firmware controls its relative priority with
`mstatus.MIE` inside the timer handler.

**[N-7.18]** An interrupt is taken only when a real instruction is in EX. This is erratum
T-2's fix: taking an interrupt on an empty EX stage wrote a meaningless `mepc`, so the
handler returned to nowhere.

### 7.6 Hold and flush composition — authoritative

**[N-7.19]** This section is normative and is the **only** place in the project where these
interactions are specified. No other document, and no RTL comment, may re-derive them.

**[N-7.20]** Rationale for stating it this way: 4 of this core's 27 errata came from the
interaction of hold and flush conditions, not from either in isolation. They were found by
directed tests, which means they were found by someone thinking of the case. The cross
product is small enough to enumerate, so it is enumerated.

**Hold sources** — a stage stalls, state is preserved:

| Source | Stalls | Cause |
|---|---|---|
| `H1` load-use | IF, ID | A load's result is needed by the next instruction. |
| `H2` D-port not ready | IF, ID, EX | `hready` low on a load or store. |
| `H3` I-port empty | IF | Prefetch buffer underrun. |
| `H4` `dsu_busy` | IF, ID | Same-accumulator DSU RAW hazard. |
| `H5` WFI | IF, ID, EX | WFI in EX with no wake condition. |

**Flush sources** — instructions are discarded, state is not preserved:

| Source | Flushes | Cause |
|---|---|---|
| `F1` taken branch/jump | IF, ID | Resolved in EX. |
| `F2` trap entry | IF, ID, EX | Exception or interrupt. |
| `F3` `mret` | IF, ID | Return from handler. |
| `F4` FENCE.I | IF, ID | Prefetch buffer invalidation. |

**[N-7.21]** **Flush always beats hold.** If any `F` and any `H` are asserted in the same
cycle, the flush takes effect and the hold is ignored for the flushed stages.

**[N-7.22]** The reason, which is the crux of the erratum class: a hold preserves state so an
instruction can complete later. A flush says that instruction must never complete. Honouring
a hold during a flush keeps an instruction alive that the flush has already logically
killed — and the classic symptom is `mepc` or a register write from an instruction that
should not have existed.

**[N-7.23]** The full cross product, all 20 combinations:

| | `F1` branch | `F2` trap | `F3` mret | `F4` FENCE.I |
|---|---|---|---|---|
| `H1` load-use | flush wins; the load in MEM still completes | flush wins; the load in MEM still completes | flush wins | flush wins |
| `H2` D-port | **hold wins** — see [N-7.24] | **hold wins** — see [N-7.24] | hold wins | hold wins |
| `H3` I-port | flush wins; the buffer is refilled from the new PC | flush wins | flush wins | flush wins |
| `H4` `dsu_busy` | flush wins; the DSU op in EX is discarded | flush wins | flush wins | flush wins |
| `H5` WFI | flush wins; WFI is abandoned | flush wins; this is the normal WFI wake path | n/a | n/a |

**[N-7.24]** `H2` is the one exception to [N-7.21], and it is not a policy choice: AHB-Lite
has no mechanism to abort a transfer whose address phase has been accepted. The data phase
must complete. So a flush concurrent with an outstanding D-port transfer is *deferred* until
`hready`, then applied. The instruction in MEM completes its bus transfer and its writeback;
the flush discards IF, ID and EX as normal. Erratum T-7 was a flush applied immediately here,
which left the bus mid-transfer and the core's LSU state machine desynchronised from the
fabric.

**[N-7.25]** A load or store already in MEM always completes its writeback, even under `F1`
or `F2`. Its bus transfer has been committed and its result is architecturally required —
the instruction has passed the point at which it could be discarded.

**[N-7.26]** Multiple simultaneous flushes: `F2` (trap) beats all others. A trap on the same
cycle as a taken branch means the branch never architecturally happened, and `mepc` must be
the branch's address, not its target. Erratum T-4 (the fault loop) was this priority
inverted.

### 7.7 WFI and the clock gate

**[N-7.27]** WFI in EX asserts `H5`, holding the pipeline. The core wakes when
`clic_irq_valid_i` (with that source enabled) or `mtip_i` is asserted — **regardless of
`mstatus.MIE`**, as the privileged specification requires. If `MIE` is clear the core resumes
at the instruction after WFI without taking a trap.

**[N-7.28]** `pipe_ctrl` exports a single `quiescent` signal, asserted when the pipeline is
held by `H5` and no bus transfer is outstanding. `core_clk_gate` uses exactly this signal,
through a standard ICG, to gate `hclk` to the core and DSU.

**[N-7.29]** **The gate's enable is `quiescent` from `pipe_ctrl`, not a separate decode of the
WFI instruction.** This is normative and it is the whole reason §7.6 is written as a single
table. A second piece of logic deciding "the core is idle" would be a second opinion about
pipeline state, and the first time the two disagreed — a flush arriving during WFI, a bus
transfer completing in the wake cycle — the core would be clocked or not clocked contrary to
what the pipeline believed. That is precisely the erratum class of §7.20, and it would be a
fifth instance.

**[N-7.30]** Wake takes one cycle to ungate the clock. Total WFI wake latency is 2 cycles: one
to ungate, one to resume fetch. At 4 ns that is 8 ns against a 4 ms loop period.

**[N-7.31]** The wake condition is combinational from `clic_irq_valid_i` and `mtip_i`, which
are outside the gated domain. A gated clock cannot be woken by logic inside the gated domain,
so the wake term is deliberately outside it.

**[N-7.32]** Power: firmware's loop is compute-then-WFI, so the core and DSU clock trees are
off for most of each iteration. This is the largest single power saving in the chip, since
the core and DSU hold the majority of the design's flops. The actual duty cycle is a firmware
measurement ([N-6.2]) and is not asserted here.

### 7.8 Reset and the reset vector

**[N-7.33]** `core_rst_n_i` and `hartreset_n_i` are ORed internally. Either produces a full
core and DSU reset.

**[N-7.34]** On reset the PC is `BOOTROM_BASE` (`0x1000_0000`), from the generated header.
The prefetch buffer is empty, all CSRs take their reset values, and `mtvec` is
**uninitialised** — which is why the bootloader installs a trap handler before touching the
SPI (`GARUDA-MEM-SPEC-001` §8.6).

**[N-7.35]** `hartreset` does not reset the bus, memories or peripherals, so the Debug
Module's SBA keeps working while the core is held. Resume is release of `hartreset`, and the
core restarts from the reset vector — it does not continue from where it was
(`GARUDA-DEBUG-SPEC-001` [N-7.9]).

### 7.9 Timing closure

**[N-7.36]** Target 250 MHz (4 ns) at DIV=2. The critical path is the 33×33 multiplier in
series with the EX result multiplexer, with the DSU in the same cone.

**[N-7.37]** **Closure is not asserted by this document.** If synthesis and place-and-route
show it does not close, the recovery is `DIVSEL` = 1 (DIV=4, 125 MHz) per ADR-0001 —
a parameter change in `clk_div`, with no change to this core. At 125 MHz the loop budget is
125,000 cycles, still far more than the workload needs.

**[N-7.38]** Stating the fallback in advance is deliberate: a timing miss discovered after
the GDSII handoff is a schedule problem only if the recovery has to be invented then.

---

## 8 Timing

### 8.1 Load-use hold (`H1`)

```
            │ T0 │ T1 │ T2 │ T3 │ T4 │
IF        ──┤ i2 │ i2 │ i3 │ i4 │ i5 ├   held one cycle
ID        ──┤ i1 │ i1 │ i2 │ i3 │ i4 ├   held one cycle
EX        ──┤ i0 │ -- │ i1 │ i2 │ i3 ├   bubble inserted
MEM       ──┤ -- │ i0 │ -- │ i1 │ i2 ├   i0 = lw
WB        ──┤ -- │ -- │ i0 │ -- │ i1 ├
                        ▲
                        └── i0's result forwarded to i1 in EX
```

### 8.2 Flush beats hold: branch during `dsu_busy` (`F1` vs `H4`)

```
            │ T0 │ T1 │ T2 │ T3 │
dsu_busy  ──┌─────────┐──────────
branch_   ──────┌─┐──────────────  resolved in EX
  taken

IF        ──┤ i3 │ tgt│tgt+4├────  flushed, refetched from target
ID        ──┤ i2 │ -- │ tgt ├────  flushed
EX        ──┤ i1 │ -- │ --  ├────  the DSU op in EX is discarded
                  ▲
                  └── flush wins; the hold is ignored  [N-7.21]
```

### 8.3 The exception: flush deferred by an outstanding bus transfer (`H2`)

```
            │ T0 │ T1 │ T2 │ T3 │ T4 │
hready    ──┌─┐       ┌──────────────  low for 2 cycles (APB access)
             └───────┘
trap_req  ──────┌──────────────────────  exception raised

EX        ──┤ i2 │ i2 │ i2 │ -- │ --├  held, THEN flushed
MEM       ──┤ i1 │ i1 │ i1 │ i1 │ --├  i1 = store, must complete
                            ▲     ▲
                            │     └── flush applied here
                            └── hready; i1's data phase completes

  The trap is deferred, not lost. mepc = i2's address. [N-7.24]
  Applying the flush at T1 would leave the bus mid-transfer: erratum T-7.
```

### 8.4 WFI, clock gate, and wake

```
            │ T0 │ T1 │ T2 │ T3 │ T4 │ T5 │
hclk_i    ──┘‾┐_┌‾┐_┌‾┐_┌‾┐_┌‾┐_┌‾┐_┌   (root, always running)

EX        ──┤wfi │wfi │wfi │wfi │ i+1│ i+2├
H5        ──────┌───────────────┐────────
quiescent ──────┌───────────────┐────────  from pipe_ctrl  [N-7.28]

core_clk  ──┘‾┐_┌‾┐________________┌‾┐_┌‾  gated off
                    (no edges)
                                 ▲
mtip_i    ───────────────────────┌────────  wake  [N-7.31]
                                 │
                                 └── ungate: 1 cycle, then resume
                                     total wake latency 2 cycles
```

---

## 9 Clock, reset and power

**[N-9.1]** One clock domain: `hclk`. No CDC anywhere in this core.

**[N-9.2]** Two reset inputs, ORed internally ([N-7.33]).

**[N-9.3]** Clock gating: one root gate on core + DSU, enabled by `quiescent` (§7.7). No
other gating in the core — finer-grained gating would need per-stage idle conditions derived
from the same pipeline state, which is the duplication [N-7.29] forbids.

**[N-9.4]** The CSR file is inside the gated domain. `mcycle` therefore stops during WFI,
which is correct — it counts cycles the core executed. `mtime` in block 11 keeps running, so
wall-clock time is unaffected. Firmware measuring duty cycle should use `mtime` for elapsed
time and `mcycle` for active cycles; the ratio is the duty cycle directly.

---

## 10 Assertions

Existing assertions are retained. New and changed for Rev 3.0:

```systemverilog
// --- mtip path (R-6)
a_mtip_to_mip: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n) mip_q[7] == mtip_i);

// --- no 64-bit timer port remains: structural, integration review

// --- hartreset produces a full core reset (R-7)
a_hartreset_resets: assert property (
  @(posedge hclk_i) !hartreset_n_i |=> (pc_q == `GARUDA_RESET_VECTOR));

// --- THE Rev 3.0 property: the clock gate uses pipe_ctrl's quiescent, nothing else
a_gate_enable_is_quiescent: assert property (
  @(posedge hclk_i) core_clk_en == !quiescent);

// --- the core is never gated with a bus transfer outstanding
a_no_gate_with_bus: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n)
  (dport_htrans != IDLE || iport_htrans != IDLE) |-> core_clk_en);

// --- the core is never gated while any flush is pending
a_no_gate_with_flush: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n)
  (f1_branch || f2_trap || f3_mret || f4_fencei) |-> core_clk_en);

// --- WFI wakes regardless of MIE (N-7.27)
a_wfi_wake_mie_clear: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n)
  (h5_wfi && !mstatus_q[3] && (clic_irq_valid_i || mtip_i)) |-> ##[1:3] !h5_wfi);

// --- wake latency is bounded at 2 cycles (N-7.30)
a_wake_latency: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n)
  (h5_wfi && (clic_irq_valid_i || mtip_i)) |-> ##[1:2] core_clk_en);

// --- flush beats hold, for every combination except H2 (N-7.21, N-7.23)
a_flush_beats_hold: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n)
  ((f1_branch || f2_trap || f3_mret || f4_fencei) && (h1_loaduse || h3_iport || h4_dsu || h5_wfi))
    |-> flush_applied);

// --- the H2 exception: flush deferred until hready (N-7.24)
a_h2_defers_flush: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n)
  ((f1_branch || f2_trap) && h2_dport) |-> !flush_applied until_with dport_hready);

// --- a committed load/store always writes back (N-7.25)
a_mem_completes: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n)
  (mem_valid && mem_is_load) |-> ##[1:$] wb_valid);

// --- trap beats every other flush (N-7.26)
a_trap_beats_branch: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n)
  (f2_trap && f1_branch) |=> (mepc_q == $past(ex_pc)));

// --- debug CSRs raise illegal instruction (N-6.3)
a_debug_csr_illegal: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n)
  (csr_access && csr_addr inside {12'h7B0, 12'h7B1, 12'h7B2, 12'h7B3})
    |-> illegal_instruction);

// --- mnxti reads zero, never traps (N-13.1)
a_mnxti_zero: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n)
  (csr_read && csr_addr == 12'h345) |-> (csr_rdata == 32'h0));
```

---

## 11 Verification plan

**[N-11.1]** The existing suite — 63/63 lockstep against Spike, plus the 27 errata
regression tests — is retained and must continue to pass. Rev 3.0's additions:

| Req | Test | Oracle | Coverage goal | Status |
|---|---|---|---|---|
| R-6 | `t_core_mtip` | `mtip_i` → `mip.MTIP` → trap | — | new |
| R-6 | — | 64-bit timer ports absent | — | review gate |
| R-7 | `t_core_hartreset` | core resets; bus and peripherals unaffected | — | new |
| R-8 | `t_core_wfi_gate` | clock stops during WFI, restarts on wake | — | new |
| R-8 | `t_core_wfi_mie` | wake with `MIE` set (traps) and clear (resumes) | both | extend |
| R-8 | `t_core_wfi_latency` | wake within 2 cycles | — | new |
| §7.6 | `t_core_hold_flush_matrix` | **all 20 combinations of [N-7.23]** | 20/20 | **new — the priority test** |
| §7.6 | `t_core_h2_defer` | flush deferred by an outstanding transfer, at each wait-state count | 1–4 waits | extend (T-7 guard) |
| §7.7 | `t_core_gate_safety` | never gated with a bus transfer or flush pending | — | new |
| §7.2 | `t_core_div_trap` | all four M-extension divide instructions trap and return correctly | 4 instructions × edge operands | extend |
| §6 | `t_core_debug_csr` | `dcsr`/`dpc`/`dscratch` raise illegal instruction | 4 CSRs | new |

**[N-11.2]** **`t_core_hold_flush_matrix` is the most valuable new test in this project.**
Four errata came from this cross product and all four were found by someone thinking of the
case. The matrix is 20 entries; enumerating it exhaustively costs a day and closes the
class.

**[N-11.3]** **Formal is strongly recommended for `pipe_ctrl`.** The hold/flush composition
is a small, bounded, purely combinational-plus-one-register property set, and it is the
highest-probability location for a remaining silicon bug in the whole chip. The properties
`a_flush_beats_hold`, `a_h2_defers_flush`, `a_trap_beats_branch`,
`a_no_gate_with_bus` and `a_no_gate_with_flush` are all formal-tractable. If there is time
for formal on exactly one block, it is this one.

**[N-11.4]** The WFI gate must be verified at gate level after synthesis, not only in RTL.
An ICG's enable timing and the resulting clock waveform are not visible in RTL simulation,
and a gate that opens a cycle late or produces a runt pulse is a silicon-only failure.

---

## 12 Design decisions

| Decision | ADR |
|---|---|
| 250 MHz target, DIV=4 fallback, no PLL | ADR-0001 |
| `mtip` as a single wire; 64-bit ports and in-core comparator deleted | ADR-0010 |
| `hartreset` for debug; no debug CSRs, no program buffer | ADR-0012 |
| `clic_mintthresh_o` removed; take decision stays in `clic_ctrl` | ADR-0009 |
| Universal AHB reachability for both ports | ADR-0005 |

---

## 13 Not implemented

| Feature | Why not |
|---|---|
| Hardware divider | §7.7: a few thousand cycles of 250,000, against area plus a new stall condition in the most erratum-prone logic. |
| C, A, F, D extensions | No compressed code pressure, no atomics needed on one hart, EKF is fixed-point. F would change the whole datapath. |
| U mode, S mode, PMP | M-mode only. **The honest cost: no memory protection, so a wild pointer can write any peripheral register including PWM.** The ISRAM lock (ADR-0006) covers instruction memory only. This is the weakest safety property in the chip. |
| Branch prediction | §7.2: under 1% of the cycle budget. |
| Instruction or data cache | All memory is single-cycle on-chip SRAM. |
| `mnxti` | Interrupt tail-chaining, a throughput optimisation for high interrupt rates this workload does not have. Reads 0. |
| Debug CSRs, program buffer, breakpoints, single-step | ADR-0012, `GARUDA-DEBUG-SPEC-001` §1.3. **v2 path:** add `dcsr`/`dpc`/`dscratch0/1` and a halt-drain sequence to `pipe_ctrl` as a fifth hold source, extending the §7.23 matrix. SBA remains the firmware-load path. |
| Multi-hart | One hart. `mhartid` = 0. |
| Performance counters beyond `mcycle`/`minstret` | Those two are enough to measure the loop duty cycle, which is the one measurement the project needs. |

---

## 14 Open items

**OPEN-9 (carried):** verify the DSU overflow guard width in `mac_unit.v` against
`GARUDA-DSU-SPEC-001`. A 15-minute RTL read, not a design decision.

**OPEN-10 (carried):** measure the loop duty cycle with `mcycle` and `mtime`. No document
asserts a figure until this exists ([N-6.2], [N-9.4]).

---

## 15 Errata

All 27 errata from Rev 2.1 are fixed and carry regression tests. The four in the hold/flush
class are reproduced here because §7.6 exists to prevent a fifth:

| ID | Symptom | Root cause | Fix | Test |
|---|---|---|---|---|
| T-2 | `mepc` meaningless after an interrupt; handler returned to nowhere. | An interrupt was taken with an empty EX stage. | Take only with a real instruction in EX ([N-7.18]). | `t_trap_bubble` |
| T-4 | Fault loop: a trap concurrent with a taken branch wrote the branch target as `mepc`, so the handler returned into the branch and re-faulted. | Flush priority inverted: branch beat trap. | Trap beats every other flush ([N-7.26]). | `t_trap_branch` |
| T-7 | LSU state machine desynchronised from the AHB fabric after a trap during a wait-stated access. | A flush was applied immediately while a D-port data phase was outstanding. | Flush deferred until `hready` ([N-7.24]). | `t_trap_wait` |
| T-5 | Trap vector computed with a 64-byte alignment mask rather than 4-byte, so handlers landed at the wrong offset. | Mask width wrong. RTL comment at `trap_ctrl.v:187` indicates 4-byte is now correct; **verify which is intended against the priv spec before release** (OPEN-9 adjacent). | 4-byte alignment. | `t_trap_vector` |

**Interface changes in Rev 3.0 (not errata):**

| Change | RTL delta |
|---|---|
| `mtime_i`/`mtimecmp_i` and the in-core comparator removed | R4 |
| `hartreset_n_i` added | R5 |
| `clic_mintthresh_o` removed | R7 |
| `core_clk_gate` added, enabled by `pipe_ctrl.quiescent` | R11 |
