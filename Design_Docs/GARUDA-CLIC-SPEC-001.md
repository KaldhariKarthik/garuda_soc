# GARUDA CLIC Interrupt Controller — Design Specification

## 0.1 Identity

| Field | Value |
|---|---|
| Document ID | GARUDA-CLIC-SPEC-001 |
| Revision | 2.0 |
| Date | 2026-09-18 |
| Status | Released for implementation |
| Block | 10 (`clic`) |
| Owner | Team AeroSoC |
| Supersedes | GARUDA_CLIC_Design_Spec_v1_1 |

## 0.2 Revision history

| Rev | Change | Driver |
|---|---|---|
| 1.0–1.1 | Initial. ID 13 carried `mtip`; trigger type configurable; ID map partly provisional | — |
| 2.0 | ID 13 freed — `mtip` no longer routes through the CLIC. Trigger type fixed in hardware. ID 0 becomes a permanently unassigned sentinel. ID 14 freed by the SPI-slave removal. ID map now generated from `GARUDA-SYS-001`. `mintthresh` interface clarified. | ADR-0009, 0010, 0020 |

## 0.3 Normative references

1. RISC-V Privileged Architecture v1.12, Machine-level ISA.
2. RISC-V CLIC specification, draft (the subset implemented is enumerated in §13).
3. `GARUDA-SYS-001` Rev 4.0 — the ID map is generated from `clic.map`.
4. `GARUDA-ADR-001` Rev 1.0.
5. `GARUDA-CORE-SPEC-001` Rev 3.0 — `clic_ctrl` lives inside the core; this block is the aggregator.
6. `GARUDA-TIMERS-SPEC-001` Rev 2.0 — for why `mtip` bypasses this block.

---

## 1 Purpose and scope

### 1.1 Division of responsibility

This is worth stating first, because the split is unusual and Rev 1.1 was vague about it.

| Function | Where it lives |
|---|---|
| Collecting peripheral and DMA interrupt lines | **this block** (10) |
| Per-ID enable, pending and level registers | **this block** |
| Selecting the highest-level pending enabled ID | **this block** |
| The take decision against `mstatus.MIE`, `mintthresh` and `mintstatus.mil` | `clic_ctrl` **inside the core** |
| Vectoring, `mcause` writeback, `mnxti` | core |

**[N-1.1]** `clic_ctrl` is already implemented and verified inside `garuda_core_top`. This
block supplies it with a single winning ID and its level; it does not duplicate the take
logic. Splitting it this way keeps the take decision in the same timing cone as the CSRs it
reads.

### 1.2 In scope

Interrupt aggregation, the per-ID register file, level-based selection, and the APB
configuration interface on window 10.

### 1.3 Out of scope

- The trap entry sequence and `mcause` (core).
- The machine timer interrupt, which does not pass through here at all (§7.6).

---

## 2 Requirements

| ID | Requirement | Source |
|---|---|---|
| R-1 | Aggregate 32 interrupt sources into a single winning ID and level for the core. | System |
| R-2 | Per-ID enable, pending, and 8-bit level. | CLIC |
| R-3 | All sources shall be level-triggered, fixed in hardware. | ADR-0009 |
| R-4 | All interrupts disabled at reset. | Safety |
| R-5 | ID 0 shall never be assigned to any source. | ADR-0009 |
| R-6 | The machine timer shall not consume a CLIC ID. | ADR-0010 |
| R-7 | Selection shall complete in one cycle and add no latency to the core's take decision. | Timing |
| R-8 | An ID's level shall be changeable while that ID is pending, without losing the pending state. | Firmware |

---

## 3 Block diagram

```
  DMA complete[5:0] ──┐
  DMA error[5:0]    ──┤
  spi_master_irq    ──┤      ┌─────────────────────────────────┐
  i2c_irq           ──┤      │          clic (block 10)        │
  uart0_irq         ──┼─────▶│                                 │
  uart1_irq         ──┤      │  ┌───────────────────────────┐  │
  uart2_irq         ──┤      │  │ pending[31:0]             │  │
  gpio_irq          ──┤      │  │  (level-sensitive,        │  │
  pwm_fault_irq     ──┤      │  │   combinational from src) │  │
  wdt_warn_irq      ──┘      │  └────────────┬──────────────┘  │
                             │               │                 │
                             │  ┌────────────▼──────────────┐  │
                             │  │ enable[31:0]  (APB)       │  │
                             │  │ level[31:0][7:0] (APB)    │  │
                             │  └────────────┬──────────────┘  │
                             │               │                 │
                             │  ┌────────────▼──────────────┐  │
                             │  │  level_select             │  │
                             │  │  max level, lowest ID     │  │
                             │  │  wins ties                │  │
                             │  └────────────┬──────────────┘  │
                             │               │                 │
                             └───────────────┼─────────────────┘
                                             │ clic_irq_id[4:0]
                                             │ clic_irq_level[7:0]
                                             │ clic_irq_valid
                                             ▼
                              ┌──────────────────────────────┐
                              │ clic_ctrl  (inside the core) │
                              │ take = valid & MIE           │
                              │      & level > mintthresh    │
                              │      & level > mintstatus.mil│
                              └──────────────────────────────┘

  mtip ──────────────────────▶ core mip.MTIP directly.  NOT through here.
                               (ADR-0010, §7.6)
```

---

## 4 Sub-block inventory

| Name | Type | RTL file | Role |
|---|---|---|---|
| `irq_capture` | comb | `clic_top.v` | Maps source lines to ID positions. Pure wiring, no state. |
| `clic_regfile` | seq | `clic_regfile.v` | `enable`, `level` per ID. APB-writable. |
| `level_select` | comb | `clic_select.v` | Two-stage comparison tree over 32 IDs. |
| `clic_apb` | seq (pclk) | `clic_apb.v` | Window 10 register interface. |

---

## 5 Interfaces

| Port | Dir | Width | Domain | Reset | Description |
|---|---|---|---|---|---|
| `hclk_i`, `hreset_n_i` | in | 1 | hclk | — | |
| `irq_src_i` | in | 32 | hclk | — | Source lines, positioned per the ID map. Unassigned positions tied low. |
| `clic_irq_id_o` | out | 5 | hclk | 0 | Winning ID. |
| `clic_irq_level_o` | out | 8 | hclk | 0 | Winning level. |
| `clic_irq_valid_o` | out | 1 | hclk | 0 | At least one enabled source is pending. |
| APB slave | — | — | pclk | — | Window 10. |

**[N-5.1]** There is no `mintthresh` input to this block. Rev 1.1 implied one, and the core
RTL exposes a `clic_mintthresh_o` port that no consumer reads. The threshold comparison is
part of the take decision and belongs in `clic_ctrl` with the other CSR reads; performing it
here would mean shipping the threshold out of the core and the result back, adding a round
trip to a path that is already in the core's critical cone. **The orphan
`clic_mintthresh_o` port shall be removed from the core** (RTL delta R7).

**[N-5.2]** `irq_src_i` is a flat 32-bit vector, positioned by the ID map. The top level does
the mapping, so this block contains no per-peripheral knowledge and the ID map exists in
exactly one place.

---

## 6 Register map — APB window 10 (`0x4000_A000`)

*(Window number corrected 2026-09-26: was stated as 9, inherited from the
0-based table in GARUDA-AHB2APB-SPEC-001. The hardware decodes window *n* at
`0x4000_0000 + 0x1000 x n` (`haddr[15:12]`), so the base address quoted here was
always right and only the index was wrong.)*

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | `CLICINFO` | RO | see §6.1 | Implementation parameters. |
| 0x004 | `CLICIE` | RW | 0x0000_0000 | Per-ID enable, bit *n* = ID *n*. |
| 0x008 | `CLICIP` | RO | — | Per-ID pending, read-only. |
| 0x100+4n | `CLICINTCFG[n]` | RW | 0x00 | 8-bit level for ID *n*. n = 0..31. |

### 6.1 `CLICINFO` (0x000)

| Bits | Name | Value | Description |
|---|---|---|---|
| 12:0 | `num_interrupt` | 32 | Number of IDs. |
| 20:13 | `version` | 1 | |
| 24:21 | `CLICINTCTLBITS` | 8 | Level bits implemented. |
| 31:25 | reserved | 0 | |

### 6.2 `CLICIE` (0x004)

**[N-6.1]** Reset value is zero: every interrupt is disabled at reset. Firmware enables
sources explicitly after configuring the peripherals that drive them. A source enabled
before its peripheral is configured can fire on a spurious level and trap into a handler
whose state is not yet initialised.

**[N-6.2]** Bit 0 is hardwired to zero and ignores writes. ID 0 is never assigned (§7.5).

**[N-6.3]** Bits 13 and 14 are hardwired to zero and ignore writes: ID 13 is reserved by
ADR-0010 and ID 14 by ADR-0020. Reserved-and-unwritable rather than merely unassigned,
so an enable of an ID with no source cannot produce a permanently-clear pending bit that a
debugging engineer then spends an afternoon on.

### 6.3 `CLICIP` (0x008)

**[N-6.4]** Read-only, and combinational from the source lines. There is no write path,
no set register and no clear register.

**[N-6.5]** This follows from level triggering: a pending bit that firmware could clear
while the source is still asserted would immediately re-assert, and firmware that expected
the clear to work would spin. Clearing an interrupt means clearing the condition in the
peripheral, which is what its own register map provides.

### 6.4 `CLICINTCFG[n]` (0x100 + 4n)

| Bits | Name | Description |
|---|---|---|
| 7:0 | `level` | Interrupt level. 0 = never taken. |

**[N-6.6]** All 8 bits are implemented, giving 255 usable levels. A level of 0 means the
interrupt is never taken even when enabled and pending, because the take condition requires
`level > mintthresh` and `mintthresh` is at minimum 0.

**[N-6.7]** Writing `CLICINTCFG[n]` while ID *n* is pending changes the level without
disturbing the pending state, since pending is combinational from the source (R-8).
Changing the level of an interrupt that is currently *being serviced* changes the
`mintstatus.mil` comparison for nested interrupts and is firmware's responsibility.

**[N-6.8]** `CLICINTCFG` for IDs 0, 13, 14 and 23–31 is writable but has no effect, as those
IDs can never be enabled.

### 6.5 ID map

Generated from `GARUDA-SYS-001` `clic.map`:

| ID | Source | Block |
|---|---|---|
| 0 | **permanently unassigned sentinel** | — |
| 1–6 | DMA channel 0–5 complete | 9 |
| 7–12 | DMA channel 0–5 error | 9 |
| 13 | reserved (freed by ADR-0010) | — |
| 14 | reserved (freed by ADR-0020) | — |
| 15 | `spi_master` | 13 |
| 16 | `i2c` | 15 |
| 17 | `uart0` (GPS) | 16 |
| 18 | `uart1` (ground link) | 17 |
| 19 | `uart2` (console) | 18 |
| 20 | `gpio` aggregate | 19 |
| 21 | `pwm` fault | 20 |
| 22 | watchdog early warning | 11 |
| 23–31 | reserved | — |

---

## 7 Functional description

### 7.1 Pending

**[N-7.1]** `pending[n]` is combinational: `pending[n] = irq_src_i[n]`. No capture, no
latch, no synchroniser. Every source is already in the `hclk` domain — the peripherals'
interrupt outputs cross from `pclk` to `hclk`, and that crossing is synchronous
(`GARUDA-AHB2APB-SPEC-001` §7.2), so no CDC is needed.

### 7.2 Level triggering, fixed in hardware

**[N-7.2]** Every source is level-triggered. There is no edge-detect logic and no
configuration bit to select trigger type.

**[N-7.3]** Rationale: trigger type is a property of the source's hardware, not a firmware
preference. Every source in this chip holds its line asserted until its condition is
cleared in the peripheral — a UART's receive-FIFO-not-empty, a DMA channel's complete flag,
the watchdog's warning threshold. Making trigger type configurable would only create a way
to configure it wrongly, and an edge-triggered configuration on a level source loses
interrupts that arrive while the handler is running.

**[N-7.4]** The firmware consequence, which must be understood: a handler must clear the
condition in the peripheral before returning. `mret` with the source still asserted
re-enters the handler immediately. This is the standard level-triggered contract and it is
stated here because Rev 1.1's configurable trigger type left it ambiguous.

### 7.3 Selection

**[N-7.5]** `level_select` finds the enabled pending ID with the highest `level`. Ties are
broken by the **lowest ID**.

**[N-7.6]** Implemented as a two-stage tree: eight 4-input comparators, then one 8-input
comparator. Each comparison carries `{level, ~id}` so that a single magnitude comparison
resolves both the level and the tie-break, and the tree is 5 levels of logic deep at 32
inputs.

**[N-7.7]** The lowest-ID tie-break puts the DMA channels (IDs 1–12) ahead of the
peripherals at equal level, which matches the priority reasoning in
`GARUDA-SYS-001` `dma.priority_note` — a DMA channel not serviced loses data, a peripheral
interrupt merely waits.

**[N-7.8]** `clic_irq_valid_o` is the OR of `enable & pending`. It is presented to
`clic_ctrl` in the same cycle, and `clic_ctrl` performs the take decision. This block adds
one combinational tree to that path and no register stage (R-7).

### 7.4 The take decision (informative — implemented in the core)

**[N-7.9]** For completeness, since this document's output feeds it directly:

```
take = clic_irq_valid
     & mstatus.MIE
     & (clic_irq_level >  mintthresh)
     & (clic_irq_level >  mintstatus.mil)
```

**[N-7.10]** Both comparisons are **strictly greater**. An interrupt at exactly the current
level does not preempt. Equal-level preemption would allow a handler to be interrupted by
another instance of its own level, which recurses and overflows the stack.

**[N-7.11]** `mintstatus.mil` is the level of the interrupt currently being serviced, so the
second comparison is what implements nesting.

### 7.5 ID 0 as a sentinel

**[N-7.12]** ID 0 is never assigned to any source, `CLICIE[0]` is hardwired low, and
`irq_src_i[0]` is tied low at the top level.

**[N-7.13]** Rationale: `clic_irq_id_o` reads 0 when nothing is pending. If ID 0 were also a
real source, an engineer at bring-up could not distinguish "no interrupt" from "source 0
fired", and an uninitialised or stuck-at-zero ID path would look like normal operation.
Reserving it means a trap with `mcause` ID 0 is unambiguously a bug, visible the first time
it happens. This costs one of 32 IDs, of which nine are already spare.

### 7.6 The machine timer does not come through here

**[N-7.14]** `mtip` reaches the core as a single wire into `mip.MTIP`, generated by the
timers block (`GARUDA-TIMERS-SPEC-001` §7). It does not occupy a CLIC ID.

**[N-7.15]** Rev 1.1 assigned it ID 13, while the core already implemented `mip.MTIP`
directly and that path was verified. Two mechanisms existed for one interrupt. The core's
path is kept because it works and is tested; ID 13 is freed.

**[N-7.16]** The consequence, stated honestly: the machine timer cannot be level-prioritised
against CLIC sources, and cannot preempt or be preempted by them under the level scheme. It
is the RISC-V architectural timer driving a 1 kHz control loop; it does not need to
participate in the level hierarchy. Firmware controls its priority relative to everything
else through `mstatus.MIE` in the timer handler.

### 7.7 Spurious and vestigial cases

**[N-7.17]** If the winning source deasserts between `clic_irq_valid_o` asserting and the
core taking the trap, `clic_ctrl` may enter a handler for a condition that is no longer
present. The handler must tolerate this by checking the peripheral's own status register
before acting. This is inherent to level triggering with a pipelined take decision and
cannot be removed by this block.

**[N-7.18]** If the winning ID *changes* between valid asserting and the take, the core
takes the new winner. `mcause` is written from the ID present at the take cycle, not the one
that first caused valid to assert, so `mcause` is always consistent with the handler that
runs.

---

## 8 Timing

### 8.1 Single interrupt taken

```
              │ T0 │ T1 │ T2 │ T3 │
hclk        ──┘‾┐_┌‾┐_┌‾┐_┌‾┐_┌

irq_src[17] ──────┌──────────────────  UART0 RX FIFO not empty
pending[17] ──────┌──────────────────  combinational  [N-7.1]
enable[17]  ──┌──────────────────────  set earlier by firmware

irq_valid   ──────┌──────────────────
irq_id      ──────┤  17  ├───────────
irq_level   ──────┤  80  ├───────────

(in core)
take        ──────────┌──┐───────────  clic_ctrl, same cycle + 1
mcause      ──────────────┤ 17 ├─────
pc          ──────────────┤ vector ├─
```

### 8.2 Tie-break: equal level, lowest ID wins

```
irq_src[3]  ──┌──────────  DMA ch2 complete, level 100
irq_src[18] ──┌──────────  UART1,           level 100

irq_id      ──┤  3  ├────  lowest ID wins the tie  [N-7.5]
irq_level   ──┤ 100 ├────
```

### 8.3 Nesting: higher level preempts

```
              │ T0        │ T1          │ T2        │
irq_src[17]  ─┌──────────────────────────────────────  level 80
irq_src[15]  ────────────────┌────────────────────────  level 200

mintstatus   ─┤ 0 ├─┤   80    ├─┤   200    ├─┤  80  ├
  .mil
                    ▲          ▲            ▲
                    │          │            └── mret: back to 80
                    │          └── 200 > 80, preempts
                    └── handler 17 entered

irq_id       ─┤17├──┤   17    ├─┤   15     ├─┤  17  ├
```

### 8.4 Equal level does NOT preempt

```
irq_src[17]  ─┌──────────────────────────  level 80, being serviced
irq_src[18]  ────────────┌────────────────  level 80

mintstatus   ─┤   80                     ├  unchanged
  .mil
take         ──────────────────────────────  never asserts  [N-7.10]
                         ▲
                         └── ID 18 waits until mret
```

---

## 9 Clock, reset and power

**[N-9.1]** The interrupt path — sources, pending, enable, level, selection — is entirely in
`hclk`. The APB register interface is in `pclk`. Register values cross `pclk`→`hclk`
synchronously, no CDC.

**[N-9.2]** `CLICIE` resets to zero (R-4). `CLICINTCFG` resets to zero, so an interrupt that
is enabled before its level is set is still never taken (level 0). Both defaults fail safe.

**[N-9.3]** Power: `level_select` is combinational and re-evaluates whenever any source or
configuration changes. With all interrupts idle its inputs are static and it consumes
nothing. No clock gating is applied; the register file is small and must respond to a source
asserting at any time.

**[N-9.4]** An enabled, pending interrupt must be able to wake the core from WFI. The
`clic_irq_valid_o` term feeds the core's wake condition directly and is not gated by
`mstatus.MIE`, so WFI wakes on a pending enabled interrupt even with interrupts globally
disabled, as the privileged specification requires. This block therefore cannot be clock
gated on "core asleep".

---

## 10 Assertions

```systemverilog
// --- ID 0 is never a winner and never enableable (R-5, N-7.12)
a_id0_never_enabled: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i) !clic_ie[0]);
a_id0_never_wins: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  clic_irq_valid_o |-> (clic_irq_id_o != 5'd0));

// --- reserved IDs can never be enabled (N-6.3)
a_reserved_ids: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (clic_ie[13] == 1'b0) && (clic_ie[14] == 1'b0) && (clic_ie[31:23] == 9'd0));

// --- valid is exactly the OR of enable & pending
a_valid_correct: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  clic_irq_valid_o == |(clic_ie & clic_ip));

// --- the winner really is enabled and pending
a_winner_legit: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  clic_irq_valid_o |-> (clic_ie[clic_irq_id_o] && clic_ip[clic_irq_id_o]));

// --- the winner has the maximum level among enabled pending IDs
a_winner_max_level: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  clic_irq_valid_o |-> (clic_irq_level_o == max_enabled_pending_level));

// --- tie-break is lowest ID (N-7.5)
a_tiebreak_lowest_id: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  clic_irq_valid_o |->
    !$isunknown(clic_irq_id_o) &&
    (!(|(clic_ie & clic_ip & lower_id_mask(clic_irq_id_o) & same_level_mask(clic_irq_level_o)))));

// --- pending is purely combinational from the source (N-7.1)
a_pending_comb: assert property (
  @(posedge hclk_i) clic_ip == irq_src_i);

// --- no pending set/clear path exists: CLICIP is unaffected by writes
a_clicip_ro: assert property (
  @(posedge pclk_i) disable iff (!preset_n_i)
  (apb_write && apb_addr == 12'h008) |=> (clic_ip == irq_src_i));

// --- level change while pending does not disturb pending (R-8)
a_level_change_safe: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (clic_ip[17] && $changed(clic_level[17])) |-> clic_ip[17]);

// --- everything disabled at reset (R-4)
a_reset_disabled: assert property (
  @(posedge hclk_i) !hreset_n_i |=> (clic_ie == 32'd0 && clic_irq_valid_o == 1'b0));

// --- no CLIC ID is ever asserted for the machine timer (R-6, N-7.14)
a_no_mtip_id: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i) !irq_src_i[13]);

// --- selection adds no register stage (R-7)
a_no_latency: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  $rose(|(clic_ie & clic_ip)) |-> clic_irq_valid_o);
```

---

## 11 Verification plan

| Req | Test | Oracle | Coverage goal | Status |
|---|---|---|---|---|
| R-1 | `t_clic_single` | each source individually reaches the core with the right ID | all 20 assigned IDs | new |
| R-2 | `t_clic_regs` | enable, pending, level read/write behaviour | all 32 `CLICINTCFG` | new |
| R-3 | `t_clic_level_trig` | source held → handler re-enters after `mret` | — | new |
| R-3 | `t_clic_no_edge` | a pulse shorter than the take latency may be missed; a held source never is | — | new |
| R-4 | `t_clic_reset` | all disabled after reset; no spurious take | — | new |
| R-5 | `t_clic_id0` | `CLICIE[0]` unwritable; ID 0 never wins | — | new |
| R-6 | `t_clic_no_mtip` | timer interrupt arrives via `mip.MTIP`, no CLIC ID involved | — | new |
| R-7 | `t_clic_latency` | valid in the same cycle as enable & pending | — | new |
| R-8 | `t_clic_level_change` | level write while pending, pending preserved | — | new |
| §7.3 | `t_clic_tiebreak` | equal level → lowest ID | all adjacent ID pairs | new |
| §7.4 | `t_clic_nest` | higher level preempts; equal does not | 8 level pairs | new |
| §7.4 | `t_clic_thresh` | `mintthresh` blocks levels at or below it | boundary values | extend |
| §7.7 | `t_clic_spurious` | source deasserts before the take; handler tolerates | — | new |
| §9.4 | `t_clic_wfi_wake` | pending enabled interrupt wakes WFI with `MIE` clear | — | new |
| — | `t_clic_random` | constrained-random source assertion vs. a reference model | all 20 IDs, nesting depth ≥3 | new |

**[N-11.1]** **`t_clic` currently times out and the cause is not diagnosed.** The existing
sanity suite is 8 of 9 passing, with `t_clic` the failure. It must be diagnosed before any
of this block's RTL is written: the failure is in the CLIC path, the take logic in
`clic_ctrl` is what this block feeds, and building an aggregator on top of an unexplained
hang in the consumer would make the resulting bug very hard to localise. The same symptom
class produced the T-4 fault-loop erratum in the core, so it should not be assumed benign.

**[N-11.2]** `t_clic_nest` should be reachable by formal for depth 2–3, which is worth doing:
nesting bugs depend on the interleaving of take and `mret`, and directed tests cover only
the interleavings someone thought of.

---

## 12 Design decisions

| Decision | ADR |
|---|---|
| IDs assigned once in `GARUDA-SYS-001`; level-triggered fixed in hardware; ID 0 sentinel | ADR-0009 |
| `mtip` does not consume a CLIC ID; ID 13 freed | ADR-0010 |
| ID 14 freed with the SPI slave | ADR-0020 |
| Take decision stays in `clic_ctrl` inside the core; no `mintthresh` port on this block | ADR-0009, §5.1 |

---

## 13 Not implemented

| CLIC feature | Why not |
|---|---|
| Edge-triggered mode and per-ID trigger configuration | §7.2: trigger type is a hardware property; configurability only permits misconfiguration. |
| `CLICIP` write, set or clear registers | §6.3: meaningless under level triggering. |
| Supervisor or user mode CLIC | M-mode only chip. |
| `mnxti` | Not implemented in the core; its CSR address reads 0. Interrupt-tail-chaining is a performance optimisation for high interrupt rates that this workload does not have. |
| Selective hardware vectoring (`CLICINTATTR.shv`) | All interrupts use the same vectored entry. A per-ID vector table would need a base register and a memory read in the trap path. |
| More than 32 IDs | 20 assigned, 9 spare, 3 reserved. No growth pressure. |
| Fewer than 8 level bits | 8 bits is what the core's `mintthresh` and `mintstatus.mil` already carry; narrowing would save a handful of flops and create a mismatch. |
| Software-triggerable interrupts | No use case; firmware can call the handler directly. |

---

## 14 Open items

**OPEN-8 (carried, not closed here):** the `t_clic` timeout. This is a debug task, not a
design decision, and it is a prerequisite for this block's RTL. See [N-11.1].

---

## 15 Errata

No RTL for this block yet. `clic_ctrl` inside the core is implemented; its errata are in
`GARUDA-CORE-SPEC-001` §15.

**Defects fixed in this revision:**

| ID | Symptom | Root cause | Fix |
|---|---|---|---|
| CL-1 | Two mechanisms for one interrupt: ID 13 in three documents, `mip.MTIP` in the core RTL. | Timer routing decided independently in the CLIC, Timers and Core specs. | ADR-0010; ID 13 reserved; §7.6. |
| CL-2 | A configurable trigger type permitted an edge configuration on level sources, losing interrupts. | Configurability added without asking whether any source needed it. | §7.2, fixed in hardware. |
| CL-3 | ID 0 assignable, making "no interrupt" indistinguishable from "source 0" at bring-up. | No sentinel convention. | §7.5. |
| CL-4 | An orphan `clic_mintthresh_o` port on the core with no consumer, implying this block performed the threshold comparison. | Take logic's location left ambiguous between two documents. | §5.1; port removed (RTL delta R7). |
| CL-5 | Six IDs marked Provisional; the DMA spec assigned CLIC to block 16 while the TRM said 10. | ID and block numbers maintained by hand in three documents. | Generated from `GARUDA-SYS-001`. |
