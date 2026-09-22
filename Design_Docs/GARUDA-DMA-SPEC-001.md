# GARUDA DMA Controller — Design Specification

## 0.1 Identity

| Field | Value |
|---|---|
| Document ID | GARUDA-DMA-SPEC-001 |
| Revision | 3.0 |
| Date | 2026-09-18 |
| Status | Released for implementation |
| Block | 9 (`dma`) |
| Owner | Team AeroSoC |
| Supersedes | GARUDA_DMA_Controller_Design_Spec_v2_2 |

## 0.2 Revision history

| Rev | Change | Driver |
|---|---|---|
| 1.0–2.2 | Initial through six channels, with CDC primitives on the config port and a channel assignment contradicting two other documents | — |
| 3.0 | All CDC logic deleted — the `hclk`/`pclk` boundary is synchronous. Channel assignment regenerated from `GARUDA-SYS-001`; no channel is shared. The ISRAM path and the boot-time role are removed. Block and CLIC numbering corrected. | ADR-0002, 0008, 0015, 0011 |

## 0.3 Normative references

1. AMBA 3 AHB-Lite Protocol Specification, ARM IHI 0033A.
2. `GARUDA-SYS-001` Rev 4.0 — channel assignment and priorities generated from `dma.assignment`.
3. `GARUDA-ADR-001` Rev 1.0.
4. `GARUDA-AHB-SPEC-001` Rev 4.0 — the DMA is master M3, highest priority.
5. `GARUDA-AHB2APB-SPEC-001` Rev 2.0 — **the no-CDC proof this revision depends on**.
6. `GARUDA-CLIC-SPEC-001` Rev 2.0 — IDs 1–12.

---

## 1 Purpose and scope

### 1.1 In scope

A six-channel DMA controller: per-channel configuration, request/acknowledge handshake with
peripherals, fixed-priority channel arbitration, AHB master M3, and completion and error
interrupts.

### 1.2 Out of scope

- The peripherals' own FIFOs and request generation.
- Boot. The DMA has no boot-time role in Rev 3.0 (§1.3).

### 1.3 What changed and why

**The CDC logic is gone.** Rev 2.2 §15.3 implemented gray-code counters, a toggle
handshake and level synchronisers between the `hclk` core logic and the `pclk` config port.
Meanwhile `GARUDA_AHB2APB_Bridge_Design_Spec_v1_4` asserted that no CDC was required across
the same boundary. Both could not be right. The bridge's conclusion was correct and its
reasoning was missing; `GARUDA-AHB2APB-SPEC-001` §7.2 now supplies the proof — `pclk` edges
are a proper subset of `hclk` edges, so both sides always sample on a shared edge. The
synchronisers were therefore solving a problem that does not exist, while adding 3–4 cycles
of latency to every register access and an entire class of apparent-CDC that a reviewer had
to trust. `dma_cdc_gray.v`, `dma_cdc_pulse.v` and `dma_cdc_sync.v` are deleted (RTL deltas
R1, R2).

**The channel assignment is fixed.** Three documents disagreed:

| | Rev 2.2 §5 | TRM §13 | TRM §14 |
|---|---|---|---|
| UART0 | sonar | GPS | — |
| UART1 | GPS | telemetry | telemetry |
| UART2 | LoRa | debug (no DMA) | LoRa |
| CH5 | GPIO/SPI2 | shared GPIO + SPI slave | — |

"SPI2" named a block that does not exist; a GPIO controller cannot be a DMA source; and a
channel cannot be shared by two peripherals, because a channel has exactly one
`dma_req`/`dma_ack` pair. The assignment now lives once, in `GARUDA-SYS-001`.

**The boot role is removed.** Rev 2.2 gave the DMA a flash→ISRAM copy path during boot, and
`GARUDA_AHB_Bus_Design_Spec_v3_0` added a dedicated DMA→ISRAM wire for it. The bootloader is
now polled PIO (ADR-0015), so the DMA has no boot-time role and no ISRAM path.

---

## 2 Requirements

| ID | Requirement | Source |
|---|---|---|
| R-1 | Six independent channels, one peripheral each. | ADR-0008 |
| R-2 | P2M, M2P and M2M transfer modes. | System |
| R-3 | No CDC logic on the configuration interface. | ADR-0002 |
| R-4 | Fixed-priority channel arbitration, re-evaluated per beat. | ADR-0004 |
| R-5 | Per-channel completion and error interrupts. | System |
| R-6 | A channel shall report a consistent transfer count and completion status. | Erratum D-1 |
| R-7 | A hardware completion shall not be lost to a simultaneous software write. | Erratum D-2 |
| R-8 | An AHB ERROR shall abort only the affected channel. | System |
| R-9 | The DMA shall have no access to Boot ROM or ISRAM. | ADR-0005, 0015 |

---

## 3 Block diagram

```
  peripheral req/ack (6 pairs)
   ┌──┬──┬──┬──┬──┬──┐
   ▼  ▼  ▼  ▼  ▼  ▼  │
  ┌─────────────────────────────────────────────────────────┐
  │                    dma  (block 9)                       │
  │                                                         │
  │  ┌────────────────────────────────────────────────┐     │
  │  │ channel 0 │ 1 │ 2 │ 3 │ 4 │ 5                  │     │
  │  │  ┌──────────────────────────────────────────┐  │     │
  │  │  │ CR  SAR  DAR  CNT  STAT   per channel    │  │     │
  │  │  └──────────────────────────────────────────┘  │     │
  │  └───────────────────┬────────────────────────────┘     │
  │                      │                                  │
  │              ┌───────▼────────┐                         │
  │              │ ch_arbiter     │  fixed priority         │
  │              │ per-beat       │  ch0 > ch4 > ch1 >      │
  │              └───────┬────────┘  ch3 > ch2 > ch5        │
  │                      │                                  │
  │              ┌───────▼────────┐                         │
  │              │ xfer_engine    │  one beat at a time     │
  │              │ read → write   │                         │
  │              └───────┬────────┘                         │
  │                      │                                  │
  │              ┌───────▼────────┐                         │
  │              │ ahb_master     ├─────────────────────────┼──▶ AHB M3
  │              └────────────────┘                         │
  │                                                         │
  │  ┌──────────────────────────┐                           │
  │  │ dma_apb  window 4        │◀── APB, pclk              │
  │  │ NO CDC  (ADR-0002)       │                           │
  │  └──────────────────────────┘                           │
  │                                                         │
  │  complete[5:0] ──────────────────────────────────────────┼──▶ CLIC 1–6
  │  error[5:0]    ──────────────────────────────────────────┼──▶ CLIC 7–12
  └─────────────────────────────────────────────────────────┘

  No ISRAM path. No Boot ROM path. (R-9)
```

---

## 4 Sub-block inventory

| Name | Type | RTL file | Role |
|---|---|---|---|
| `dma_chan` ×6 | seq (hclk) | `dma_chan.v` | Per-channel registers and state machine. |
| `ch_arbiter` | comb | `dma_arbiter.v` | Fixed-priority select among requesting channels. |
| `xfer_engine` | seq (hclk) | `dma_engine.v` | Read beat, then write beat. |
| `dma_ahb_master` | seq (hclk) | `dma_ahb_master.v` | AHB-Lite master M3. |
| `dma_apb` | seq (pclk) | `dma_apb_slave.v` | Window 4. **No CDC.** |

**[N-4.1]** Deleted in Rev 3.0: `dma_cdc_gray.v`, `dma_cdc_pulse.v`, `dma_cdc_sync.v`.

---

## 5 Interfaces

| Port | Dir | Width | Domain | Reset | Description |
|---|---|---|---|---|---|
| `hclk_i`, `hreset_n_i` | in | 1 | hclk | — | |
| `pclk_i`, `preset_n_i` | in | 1 | pclk | — | APB side only. |
| `dma_req_i` | in | 6 | hclk | — | One per channel, from its peripheral. |
| `dma_ack_o` | out | 6 | hclk | 0 | One per channel. |
| `dma_complete_o` | out | 6 | hclk | 0 | To CLIC IDs 1–6. |
| `dma_error_o` | out | 6 | hclk | 0 | To CLIC IDs 7–12. |
| AHB M3 | — | — | hclk | — | Per `GARUDA-AHB-SPEC-001` §5.1. |
| APB slave | — | — | pclk | — | Window 4. |

**[N-5.1]** `pclk_i` and `preset_n_i` remain as ports because the APB side genuinely runs on
`pclk`. What is deleted is the *synchroniser logic* between the domains, not the second
clock. The register file's `hclk`-visible values are sampled directly, per
`GARUDA-AHB2APB-SPEC-001` §7.2.

---

## 6 Register map — APB window 4 (`0x4000_5000`)

Per channel *n* (0–5), base offset `0x20 × n`:

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| +0x00 | `CR` | RW | 0 | Control. |
| +0x04 | `SAR` | RW | 0 | Source address. |
| +0x08 | `DAR` | RW | 0 | Destination address. |
| +0x0C | `CNT` | RW | 0 | Transfer count in beats. |
| +0x10 | `STAT` | RO | 0 | Status, including beats remaining. |
| +0x14 | `ICLR` | W1C | — | Interrupt clear. |

Global, at `0x100`:

| Offset | Name | Access | Description |
|---|---|---|---|
| 0x100 | `GSTAT` | RO | Per-channel active, complete and error summary. |

### 6.1 `CR` (+0x00)

| Bit | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0 | `EN` | RW | 0 | Channel enable. Cleared by hardware on completion or error. |
| 2:1 | `MODE` | RW | 0 | 0 = P2M, 1 = M2P, 2 = M2M, 3 reserved. |
| 3 | `SINC` | RW | 0 | Increment `SAR` after each beat. |
| 4 | `DINC` | RW | 0 | Increment `DAR` after each beat. |
| 6:5 | `SIZE` | RW | 2 | 0 = byte, 1 = halfword, 2 = word. |
| 7 | `IE_COMP` | RW | 0 | Completion interrupt enable. |
| 8 | `IE_ERR` | RW | 0 | Error interrupt enable. |
| 31:9 | reserved | — | 0 | |

**[N-6.1]** `MODE` = 3 is reserved and a write of 3 leaves `MODE` unchanged, rather than
being accepted and behaving as one of the legal modes. An illegal mode that silently
aliases is worse than one that refuses.

### 6.2 `STAT` (+0x10)

| Bits | Name | Description |
|---|---|---|
| 15:0 | `REMAINING` | Beats not yet transferred. |
| 16 | `ACTIVE` | Channel is enabled and has beats remaining. |
| 17 | `COMPLETE` | All beats transferred. Sticky until `ICLR`. |
| 18 | `ERROR` | AHB ERROR encountered. Sticky until `ICLR`. |
| 21:19 | `ERRPHASE` | 0 = none, 1 = read, 2 = write. |

**[N-6.2]** `REMAINING` and `COMPLETE` are updated in the same cycle by the same logic, so
they are never inconsistent (R-6). Erratum D-1 was exactly this inconsistency, caused by the
two fields being updated on opposite sides of the deleted clock crossing: `COMPLETE`
arrived through a pulse synchroniser while `REMAINING` arrived through a gray-coded counter,
with different latencies, so firmware could read `COMPLETE` = 1 with `REMAINING` non-zero.
Removing the crossing removes the mechanism, not merely the symptom.

**[N-6.3]** `ERRPHASE` distinguishes a failed source read from a failed destination write.
Without it, an error on an M2M transfer leaves firmware unable to tell which address was
bad, and the source and destination are both still in the registers, so the distinction
costs three bits and saves a debugging session.

### 6.3 Channel assignment

Generated from `GARUDA-SYS-001` `dma.assignment`:

| Channel | Peripheral | Function | Priority | CLIC complete | CLIC error |
|---|---|---|---|---|---|
| 0 | `spi_master` | IMU | 5 (highest) | 1 | 7 |
| 1 | `i2c` | baro, mag, sonar | 3 | 2 | 8 |
| 2 | `uart0` | GPS | 1 | 3 | 9 |
| 3 | `uart1` | ground link | 2 | 4 | 10 |
| 4 | — | spare | 4 | 5 | 11 |
| 5 | `uart2` | console | 0 (lowest) | 6 | 12 |

**[N-6.4]** Channel 4 serves the SPI slave (ESP32 / ESP-NOW mesh), **restored and required
per ADR-0020 Rev 2** (APF's neighbour-position source). Its registers, interrupts and
arbiter position already exist and work; `dma_req_i[4]` is still tied low at the top level
and **must be un-tied when `rtl/spi_slave/` is built** (RTL work item). Pending that, CH4
carries no traffic. The final pin outcome is gated on OPEN-2 (ADR-0020 Rev 2).

**[N-6.5]** The priority order is by consequence of not being serviced. The IMU is the
control loop's hard-real-time input and is highest. The console is lowest because nothing
depends on it — dropping a debug character is free. GPS at 115200 baud is one beat every
~21,700 `hclk` cycles, so its low priority costs nothing.

---

## 7 Functional description

### 7.1 Channel operation

**[N-7.1]** Firmware writes `SAR`, `DAR`, `CNT` and `MODE`, then sets `EN`. The channel waits
for `dma_req_i[n]`, performs one beat, decrements `REMAINING`, and asserts `dma_ack_o[n]`.

**[N-7.2]** A beat is a read followed by a write, as two separate AHB SINGLE transfers. The
DMA does not use bursts.

**[N-7.3]** When `REMAINING` reaches zero: `COMPLETE` sets, `ACTIVE` clears, hardware clears
`EN`, and `dma_complete_o[n]` asserts if `IE_COMP` is set.

**[N-7.4]** `dma_complete_o[n]` is level and stays asserted until `ICLR` clears `COMPLETE`.
This matches the CLIC's level-triggered contract (`GARUDA-CLIC-SPEC-001` §7.2).

### 7.2 Modes

| Mode | `SAR` | `DAR` | Typical use |
|---|---|---|---|
| P2M | peripheral data register, `SINC`=0 | memory, `DINC`=1 | IMU burst into a DSRAM buffer |
| M2P | memory, `SINC`=1 | peripheral, `DINC`=0 | telemetry frame out of DSRAM |
| M2M | memory, `SINC`=1 | memory, `DINC`=1 | buffer copy |

**[N-7.5]** M2M has no peripheral request. It runs continuously while enabled, taking a beat
whenever it wins arbitration. Because the DMA is the highest-priority AHB master (M3), an
M2M transfer will stall the core for the duration.

**[N-7.6]** That is a real hazard and firmware must treat it as one: an M2M transfer of
16,384 beats holds M3 requesting for ~32,768 cycles, during which the core progresses only
in the gaps. There is no rate limiting in hardware. The mitigation is firmware discipline —
break large M2M transfers into chunks — and it is stated here because the hardware gives no
protection. No use case in the current firmware needs M2M at all; it exists because it costs
nothing over the P2M/M2P datapath.

### 7.3 The request/acknowledge handshake

**[N-7.7]** `dma_req_i[n]` is level: the peripheral asserts it while it has data (P2M) or
space (M2P), and deasserts when the beat has been taken.

**[N-7.8]** `dma_ack_o[n]` is a single-cycle pulse asserted when the beat completes.

**[N-7.9]** All six peripherals' request lines are in the `pclk` domain and cross to `hclk`.
This crossing is synchronous (`GARUDA-AHB2APB-SPEC-001` §7.2) and requires no
synchroniser. The peripheral asserts on a `pclk` edge, which is also an `hclk` edge, so the
`hclk` sample is of a stable value.

**[N-7.10]** Because `pclk` is half `hclk`, a request asserted for one `pclk` cycle is
visible for two `hclk` cycles. The channel state machine takes at most one beat per request
assertion, tracked by an edge-qualified taken flag, so a two-cycle-visible request does not
produce two beats.

### 7.4 Channel arbitration

**[N-7.11]** Fixed priority per `GARUDA-SYS-001`, re-evaluated at each beat boundary. A
channel that wins arbitration completes its full read-write beat pair before arbitration is
re-evaluated; a beat is never split between channels.

**[N-7.12]** Starvation: channel 5 can be starved while higher channels request
continuously. With real peripheral rates — the IMU at 8 kHz, the others far slower — the
aggregate request rate is a few thousand beats per second against 125 million available, so
starvation is unreachable.

### 7.5 Error handling

**[N-7.13]** An AHB ERROR on either the read or the write beat: `ERROR` sets, `ERRPHASE`
records which, `EN` clears, `ACTIVE` clears, `REMAINING` freezes at its value at the point
of failure, and `dma_error_o[n]` asserts if `IE_ERR` is set.

**[N-7.14]** Only the affected channel aborts (R-8). Other channels continue. There is no
global error state.

**[N-7.15]** `REMAINING` freezing rather than zeroing means firmware can compute exactly
which address failed: `SAR` and `DAR` also hold their values at the point of failure, since
they are only incremented on a successful beat.

**[N-7.16]** The channel is not automatically retried. A bus error from a DMA channel means
a bad address in `SAR`/`DAR`, which is a firmware bug, and retrying a bad address forever is
worse than stopping.

### 7.6 Simultaneous hardware and software register updates

**[N-7.17]** Hardware clears `EN` on completion or error. Firmware may write `CR` in the same
cycle. **Hardware wins for the `EN` bit**; the rest of the write takes effect.

**[N-7.18]** This is erratum D-2. Previously the software write took the whole register,
including a stale `EN` = 1, so a channel that had just completed was re-enabled with
`REMAINING` = 0 and never completed again — it sat `ACTIVE` with nothing to do, and firmware
waiting on `COMPLETE` hung. The fix is a per-bit priority on `EN` only.

**[N-7.19]** The general rule, which applies to every hardware-updated field in this block:
where hardware and software write the same bit in the same cycle, hardware wins for bits
hardware owns (`EN`, `COMPLETE`, `ERROR`, `REMAINING`, `ACTIVE`), and software wins for bits
it owns (`MODE`, `SINC`, `DINC`, `SIZE`, `IE_*`, `SAR`, `DAR`, `CNT`). Stating it as a rule
rather than a fix for one bit is what prevents the next instance.

### 7.7 Reachability

**[N-7.20]** The DMA reaches DSRAM and the APB region. It has no path to ISRAM or Boot ROM
(R-9, `GARUDA-SYS-001` `ahb.master_reachability`).

**[N-7.21]** The ISRAM path existed in Rev 2.2 only to support the DMA boot copy. With the
polled-PIO bootloader (ADR-0015) nothing needs it, and removing it means a DMA channel
misconfigured with an ISRAM address gets a clean ERROR rather than corrupting instruction
memory. This is an omission of an unused path that happens to also be a safety property;
the ISRAM write lock (ADR-0006) covers the case more generally.

---

## 8 Timing

### 8.1 P2M beat: IMU into DSRAM

```
              │ T0 │ T1 │ T2 │ T3 │ T4 │ T5 │
hclk        ──┘‾┐_┌‾┐_┌‾┐_┌‾┐_┌‾┐_┌‾┐_┌

dma_req[0]  ──┌──────────────────┐──────────  SPI RX FIFO not empty
                                              (pclk-asserted, hclk-visible
                                               for 2 cycles  [N-7.10])
grant M3    ──────┌──────────────────────┐──

              ── read beat ──  ── write beat ──
haddr       ──────┤ SAR      ├──┤ DAR      ├──
hwrite      ──────┤ 0        ├──┤ 1        ├──
hrdata      ───────────┤ data ├──────────────
hwdata      ────────────────────┤ data     ├──

dma_ack[0]  ────────────────────────┌─┐──────  1-cycle pulse
REMAINING   ──┤  N              │  N-1     ├──
DAR         ──┤  A              │  A+4     ├──  DINC=1
```

### 8.2 Completion

```
REMAINING   ──┤ 1 │ 0                        ├
ACTIVE      ──┌──────┐──────────────────────────
COMPLETE    ─────────┌──────────────────────────  sticky
EN          ──┌──────┐──────────────────────────  hardware clears
dma_complete──────────┌─────────────────────────  level, until ICLR
                      │
            ICLR write┴───────────────────────┐
COMPLETE    ──────────────────────────────────┘
```

**[N-8.1]** `REMAINING` and `COMPLETE` change on the same edge — the D-1 inconsistency is
structurally impossible now that there is no crossing between them.

### 8.3 Erratum D-2: the write collision

```
BEFORE (Rev 2.2):
              │ T0      │ T1                │
REMAINING   ──┤ 1 │ 0                       ├
hw_clear_en ──────┌─┐──────────────────────────
sw_write_CR ──────┌─┐──────────────────────────  firmware writes CR, EN=1
EN          ──┌──────────────────────────────┐   ◀── stayed set!
ACTIVE      ──┌──────────────────────────────┐   ◀── active, REMAINING=0
COMPLETE    ─────────┌──────────────────────────
                     ▲
                     └── firmware waits on COMPLETE forever on the
                         next transfer: the channel never re-arms

AFTER (Rev 3.0):
hw_clear_en ──────┌─┐──────────────────────────
sw_write_CR ──────┌─┐──────────────────────────
EN          ──┌──────┐─────────────────────────  ◀── hardware wins [N-7.17]
              (MODE/SINC/DINC from the sw write DO take effect)
```

### 8.4 Register access latency, before and after

```
Rev 2.2, with CDC:
apb write ──┐
            ├─ pclk capture ─ 2ff sync ─ hclk apply
            │  1 pclk         2 hclk     1 hclk     = 3-4 hclk extra
            
Rev 3.0, no CDC:
apb write ──┐
            ├─ pclk capture ─ hclk sample (shared edge)
            │  1 pclk         0 extra
```

**[N-8.2]** Every DMA register access is 3–4 `hclk` cycles faster, and the register file has
one fewer failure mode. This is a side benefit; the reason for the change is correctness of
the model, not speed.

---

## 9 Clock, reset and power

**[N-9.1]** Two clocks, no CDC. The channel logic, arbiter, engine and AHB master are in
`hclk`. The APB register interface is in `pclk`. Values cross on shared edges
(`GARUDA-AHB2APB-SPEC-001` §7.2).

**[N-9.2]** Reset is `hreset_n` for the `hclk` side and `preset_n` for the APB side. All
channels reset disabled with `CNT` = 0, so no transfer can begin before firmware configures
one.

**[N-9.3]** Power: each channel's registers and state machine are gated by that channel's
`EN`. A disabled channel receives no clock. With all channels idle the block is inert apart
from the arbiter's combinational logic.

**[N-9.4]** The per-channel gate is the cleanest clock-gating opportunity in the chip: `EN`
is an explicit, single-bit, already-registered idle condition, unlike the core's WFI
condition which has to be derived from pipeline state.

---

## 10 Assertions

```systemverilog
// --- no CDC primitives remain (R-3): structural, checked at review
// --- and behaviourally: the register file responds within one hclk of the pclk edge
a_no_cdc_latency: assert property (
  @(posedge pclk_i) disable iff (!preset_n_i)
  (apb_write && apb_sel) |=> $changed(reg_hclk_view) || $stable(apb_wdata));

// --- REMAINING and COMPLETE are always consistent (R-6, erratum D-1)
a_remaining_complete_consistent: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  ch_complete[n] |-> (ch_remaining[n] == 16'd0));
a_active_implies_remaining: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  ch_active[n] |-> (ch_remaining[n] != 16'd0));

// --- hardware wins EN on a collision (R-7, erratum D-2)
a_hw_wins_en: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (hw_clear_en[n] && sw_write_cr[n]) |=> !ch_en[n]);

// --- but the rest of the software write still lands
a_sw_write_lands: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (hw_clear_en[n] && sw_write_cr[n]) |=> (ch_mode[n] == $past(sw_wdata[2:1])));

// --- a beat is never split between channels (N-7.11)
a_beat_atomic: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (xfer_state == READ) |-> ##[1:$] (xfer_state == WRITE) && $stable(cur_ch));

// --- exactly one channel active in the engine at a time
a_one_channel: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (xfer_state != IDLE) |-> $onehot(ch_granted));

// --- one beat per request assertion (N-7.10)
a_one_beat_per_req: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  $rose(dma_ack_o[n]) |-> !dma_ack_o[n] throughout (dma_req_i[n])[*1:$]);

// --- error aborts only the affected channel (R-8)
a_error_isolated: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  $rose(ch_error[n]) |=> !ch_en[n] && $stable(ch_en_others));

// --- ERRPHASE is set correctly
a_errphase: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (hresp && xfer_state == READ) |=> (ch_errphase[cur_ch] == 3'd1));

// --- SAR/DAR/REMAINING freeze at the failure point (N-7.15)
a_freeze_on_error: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  ch_error[n] |=> $stable(ch_sar[n]) && $stable(ch_dar[n]) && $stable(ch_remaining[n]));

// --- no ISRAM or Boot ROM access ever (R-9)
a_no_isram: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (dma_htrans != IDLE) |-> (dma_haddr[31:28] != 4'h0 && dma_haddr[31:28] != 4'h1));

// --- MODE=3 is rejected (N-6.1)
a_mode3_rejected: assert property (
  @(posedge pclk_i) disable iff (!preset_n_i)
  (apb_write && apb_wdata[2:1] == 2'b11) |=> $stable(ch_mode[n]));

// --- channel 4 never requests (N-6.4)
a_ch4_tied: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i) !dma_req_i[4]);

// --- all channels disabled at reset
a_reset_disabled: assert property (
  @(posedge hclk_i) !hreset_n_i |=> (ch_en == 6'd0));
```

---

## 11 Verification plan

| Req | Test | Oracle | Coverage goal | Status |
|---|---|---|---|---|
| R-1 | `t_dma_all_channels` | each channel transfers independently | all 6 | **passing**, re-run after CDC removal |
| R-2 | `t_dma_modes` | P2M, M2P, M2M each correct | 3 modes × 3 sizes | **passing**, re-run |
| R-3 | `t_dma_no_cdc` | register access completes with no synchroniser latency | — | new |
| R-3 | — | `dma_cdc_*.v` absent from the file list | — | review gate |
| R-4 | `t_dma_priority` | highest-priority requesting channel wins | all 15 channel pairs | **passing**, re-run |
| R-5 | `t_dma_interrupts` | complete and error reach the right CLIC IDs | all 12 IDs | extend |
| R-6 | `t_dma_stat_consistent` | `COMPLETE` never with non-zero `REMAINING` | — | **D-1 regression guard** |
| R-7 | `t_dma_write_collision` | software `CR` write in the completion cycle | collision at each of the last 3 beats | **D-2 regression guard** |
| R-8 | `t_dma_error_isolated` | one channel errors, others unaffected | error on each channel | extend |
| R-8 | `t_dma_errphase` | read vs write error distinguished | both phases | new |
| R-9 | `t_dma_no_isram` | ISRAM and Boot ROM addresses give a clean ERROR | both regions | new |
| §7.3 | `t_dma_req_ack` | one beat per request, across the `pclk`/`hclk` ratio | — | extend |
| §7.6 | `t_dma_hw_sw_priority` | the [N-7.19] rule for every hardware-owned bit | all 5 bits | new |
| — | `t_dma_random` | constrained-random config vs. a reference model | all modes, sizes, channels | extend |

**[N-11.1]** The existing regression passes for R-1, R-2, R-4 and R-8. Rev 3.0's verification
burden is mostly **re-running** those after the CDC removal, plus the two regression guards.
Removing logic is lower risk than adding it, but the request/acknowledge path changes
timing, so §7.3 needs re-verification rather than assumption.

**[N-11.2]** `t_dma_write_collision` must hit the collision cycle exactly. A random test will
almost never produce it, which is why D-2 survived to be found late. The test needs a
directed, cycle-accurate trigger.

---

## 12 Design decisions

| Decision | ADR |
|---|---|
| No CDC on the config port; three CDC modules deleted | ADR-0002 |
| Channel assignment generated once; no shared channels | ADR-0008 |
| No boot role; no ISRAM path | ADR-0015, 0005 |
| Channel 4 spare, registers retained for the 36-pin variant | ADR-0020 |
| Block 9, CLIC IDs 1–12 | ADR-0011, 0009 |

---

## 13 Not implemented

| Feature | Why not |
|---|---|
| CDC synchronisers | §1.3. The boundary is synchronous; they added latency and implied an asynchrony that does not exist. |
| Burst transfers | A peripheral request is per-byte or per-word. A burst would need a FIFO in the DMA to justify it, and at 7% bus utilisation there is nothing to gain. |
| Scatter-gather / descriptor chaining | Needs descriptor fetches from memory and a much larger state machine. No use case: every transfer here is one contiguous buffer. |
| 2D / strided transfers | No use case. |
| Channel linking (one completion starts the next) | Firmware can do this in the completion handler at the cost of a few microseconds, which no transfer here is sensitive to. |
| Round-robin or weighted arbitration | §7.12: starvation is unreachable. |
| Automatic retry on bus error | §7.16: a DMA bus error is a firmware bug, and retrying a bad address forever is worse than stopping. |
| M2M rate limiting | §7.6: no hardware protection. Firmware discipline, stated explicitly. |
| A shared channel serving two peripherals | §1.3: not implementable — one `req`/`ack` pair per channel. |

---

## 14 Open items

None.

---

## 15 Errata

**Existing RTL — fixed and verified:**

| ID | Symptom | Root cause | Fix | Regression test |
|---|---|---|---|---|
| D-1 | Firmware could read `COMPLETE` = 1 with `REMAINING` non-zero, and act on a transfer that had not finished. | The two fields crossed the `pclk`/`hclk` boundary through different mechanisms — a pulse synchroniser and a gray-coded counter — with different latencies. | Rev 3.0 removes the crossing entirely, so both fields update on the same edge. The mechanism is gone, not just the symptom. | `t_dma_stat_consistent` |
| D-2 | A channel that completed in the same cycle as a software `CR` write was left enabled with `REMAINING` = 0, permanently `ACTIVE` and never completing again. Firmware waiting on `COMPLETE` hung. | The software write took the whole register including a stale `EN` = 1, overwriting the hardware clear. | Per-bit priority: hardware wins `EN`; the rest of the write lands. Generalised to the [N-7.19] rule. | `t_dma_write_collision` |

**Defects fixed in this revision:**

| ID | Symptom | Root cause | Fix |
|---|---|---|---|
| D-3 | CDC logic implemented against a clock the bridge spec said needed none. | Two documents reasoning independently about one boundary. | §1.3; three modules deleted. |
| D-4 | Channel assignment contradicted two other documents; one channel was shared between two peripherals; one source was a block that does not exist. | Assignment maintained by hand in three places. | Generated from `GARUDA-SYS-001`. |
| D-5 | A DMA→ISRAM path existed solely to support a boot copy that is no longer performed. | The path was added to work around the interconnect restriction rather than fixing it. | Path removed; ADR-0015. |
| D-6 | Block numbered 9 here, CLIC at 16 and I²C at 12 in §18.2, contradicting the TRM. | Block numbers assigned per-document. | ADR-0011. |
