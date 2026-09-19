# GARUDA AHB-Lite Interconnect — Design Specification

## 0.1 Identity

| Field | Value |
|---|---|
| Document ID | GARUDA-AHB-SPEC-001 |
| Revision | 4.0 |
| Date | 2026-09-18 |
| Status | Released for implementation |
| Block | 6 (`ahb_ic`) |
| Owner | Team AeroSoC |
| Supersedes | GARUDA_AHB_Bus_Design_Spec_v3_1 |

## 0.2 Revision history

| Rev | Change | Driver |
|---|---|---|
| 1.0–2.x | Shared single-layer, 3 masters, 4 slaves. **This is what the RTL implements and what passes regression.** | — |
| 3.0–3.1 | Proposed six-layer multi-layer matrix with structural master-to-slave reachability restrictions. Never implemented. | — |
| 4.0 | Returns to the shared single layer, adds Debug SBA as a fourth master, and makes universal reachability normative. The Rev 3.x restrictions are withdrawn — they broke boot, `.rodata` and JTAG load. | ADR-0004, 0005, 0006, 0012 |

## 0.3 Normative references

1. AMBA 3 AHB-Lite Protocol Specification, ARM IHI 0033A.
2. `GARUDA-SYS-001` Rev 4.0 — System Definition. All master IDs, priorities, addresses and reachability are generated from it.
3. `GARUDA-ADR-001` Rev 1.0 — Architecture Decision Record.
4. `GARUDA-MEM-SPEC-001` Rev 2.0 — slave behaviour, ISRAM lock.
5. `GARUDA-DEBUG-SPEC-001` Rev 2.0 — the SBA master.
6. `GARUDA-CORE-SPEC-001` Rev 3.0 — I-port and D-port master behaviour.

---

## 1 Purpose and scope

### 1.1 In scope

One shared AHB-Lite layer connecting four masters to four slave regions: arbitration,
address decode, master multiplexing, slave multiplexing, and the default slave.

### 1.2 Out of scope

- Slave internals (`GARUDA-MEM-SPEC-001`, `GARUDA-AHB2APB-SPEC-001`).
- Master internals (core, DMA, Debug specs).

### 1.3 Why Rev 4.0 goes backwards

Rev 3.x was an attempt to raise bandwidth by giving each master its own path. It is
withdrawn for two reasons, and the second is the important one.

First, the bandwidth was not needed: measured utilisation is 7% of the available beats
during a flight-loop iteration. Six layers would have cost six arbiters, six decoders, a
6× increase in wire count on every AHB signal — `HPROT` alone goes from 4 to 28 wires —
and a routing congestion problem on a 1.45 mm die, in exchange for headroom nothing
consumes.

Second, and worse: to recover some of that area, Rev 3.1 §4 removed wires. It declared that
the I-port physically could not reach DSRAM or the bridge, and the D-port physically could
not reach ISRAM or Boot ROM — "no wire exists in the netlist." That restriction silently
broke three things that other documents assumed worked:

| What broke | How |
|---|---|
| The boot CRC | The bootloader runs on the core out of Boot ROM and must read back ISRAM to verify it. With no D-port path to ISRAM, and the I-port being fetch-only, **no master in the chip could perform that read.** The verification step in `GARUDA-MEM-SPEC-001` §8 was unimplementable. |
| `.rodata` | GCC places constants, jump tables and string literals next to code. Loading them is a data-port read of the instruction region. With no such path, every constant would have had to be copied to DSRAM at boot, consuming data memory and boot time. |
| JTAG firmware load | Both program-buffer and SBA writes land on a data master. With no data path to ISRAM, firmware could never be loaded over JTAG — every development iteration would require reflashing SPI, and a bad image would leave no in-circuit recovery. |

None of those three documents knew, because the restriction was local to this one. That is
the failure mode `GARUDA-SYS-001` now exists to prevent, and it is why [N-7.6] below is
stated as a normative property of the interconnect rather than left implicit.

---

## 2 Requirements

| ID | Requirement | Source |
|---|---|---|
| R-1 | Full compliance with AHB-Lite IHI 0033A, single-master-at-a-time semantics. | Protocol |
| R-2 | Four masters: I-port, D-port, Debug SBA, DMA. | ADR-0004, 0012 |
| R-3 | Four slave regions: ISRAM, Boot ROM, DSRAM, APB. | System |
| R-4 | Every master shall be able to reach every slave it is permitted to address. No structural reachability restriction. | ADR-0005 |
| R-5 | Fixed-priority arbitration, re-evaluated every beat, never inside a data phase. | ADR-0004 |
| R-6 | An undecoded address shall produce a two-cycle ERROR, never a hang. | Protocol |
| R-7 | The interconnect shall report to the ISRAM slave when the granted master is SBA. | ADR-0006 |
| R-8 | Zero wait states inserted by the interconnect itself. | System |
| R-9 | A master's burst shall not be corrupted by losing arbitration mid-burst. | Protocol |

---

## 3 Block diagram

```
   core I-port    core D-port    Debug SBA      DMA
   (M0, read)     (M1, r/w)      (M2, r/w)      (M3, r/w)
        │              │              │           │
        │  HTRANS/HADDR/HWRITE/HSIZE/HBURST/HWDATA │
        ▼              ▼              ▼           ▼
   ┌─────────────────────────────────────────────────────┐
   │                  ahb_interconnect                   │
   │                                                     │
   │  ┌──────────────┐        ┌──────────────────────┐   │
   │  │ ahb_arbiter  │───────▶│   ahb_master_mux     │   │
   │  │              │ grant  │  (selects the        │   │
   │  │ fixed prio   │        │   granted master's   │   │
   │  │ M3>M2>M1>M0  │        │   address/control)   │   │
   │  │ per-beat     │        └──────────┬───────────┘   │
   │  └──────────────┘                   │               │
   │         │                           ▼               │
   │         │                   ┌───────────────┐       │
   │         │                   │ ahb_decoder   │       │
   │         │                   │ HADDR[31:28]  │       │
   │         │                   └───┬───┬───┬───┤       │
   │         │  hmaster_is_sba       │   │   │   │ (none)│
   │         └──────────────────────┐ │   │   │   │       │
   │                                │ │   │   │   ▼       │
   │                    ┌───────────┼─┼───┼───┼── default │
   │                    │           │ │   │   │   slave   │
   │  ┌─────────────────▼───────┐   │ │   │   │  (ERROR)  │
   │  │    ahb_slave_mux        │◀──┴─┴───┴───┘           │
   │  │ (returns HRDATA/HREADY/ │                         │
   │  │  HRESP to the granted   │                         │
   │  │  master)                │                         │
   │  └─────────────────────────┘                         │
   └──────┬──────────┬──────────┬──────────┬──────────────┘
          ▼          ▼          ▼          ▼
       ISRAM     Boot ROM     DSRAM      AHB2APB
       (S0)        (S1)        (S2)        (S3)
```

---

## 4 Sub-block inventory

| Name | Type | RTL file | Role |
|---|---|---|---|
| `ahb_arbiter` | seq | `ahb_arbiter.v` | Fixed-priority grant, per-beat, data-phase-locked. |
| `ahb_master_mux` | comb | `ahb_master_mux.v` | Drives the shared address/control bus from the granted master. |
| `ahb_decoder` | comb | `ahb_decoder.v` | `HADDR[31:28]` → `HSEL` one-hot, plus `hsel_none`. |
| `ahb_slave_mux` | comb | `ahb_slave_mux.v` | Returns `HRDATA`/`HREADY`/`HRESP` from the selected slave. |
| `ahb_default_slave` | seq | `ahb_default_slave.v` | Two-cycle ERROR for undecoded addresses. |

---

## 5 Interfaces

### 5.1 Per-master interface (×4)

| Port | Dir | Width | Description |
|---|---|---|---|
| `hbusreq_i` | in | 1 | Transfer requested. |
| `haddr_i` | in | 32 | |
| `htrans_i` | in | 2 | IDLE / NONSEQ / SEQ. BUSY is not generated by any master here. |
| `hwrite_i` | in | 1 | |
| `hsize_i` | in | 3 | |
| `hburst_i` | in | 3 | SINGLE, or INCR for M0 only. |
| `hwdata_i` | in | 32 | |
| `hgrant_o` | out | 1 | |
| `hrdata_o` | out | 32 | |
| `hready_o` | out | 1 | |
| `hresp_o` | out | 1 | |

**[N-5.1]** M0 (I-port) drives `hwrite_i` low permanently and `hwdata_i` is unconnected. The
interconnect does not rely on this; a write from M0 would be routed normally and rejected by
the ISRAM lock or the ROM slave. Relying on it would be the Rev 3.1 mistake in miniature.

### 5.2 Per-slave interface (×4)

| Port | Dir | Width | Description |
|---|---|---|---|
| `hsel_o` | out | 1 | Region select. |
| `haddr_o`, `htrans_o`, `hwrite_o`, `hsize_o`, `hburst_o`, `hwdata_o` | out | — | Shared bus. |
| `hmaster_is_sba_o` | out | 1 | To ISRAM only. See [N-7.10]. |
| `hrdata_i` | in | 32 | |
| `hreadyout_i` | in | 1 | |
| `hresp_i` | in | 1 | |

### 5.3 Signals not implemented

**[N-5.2]** `HPROT` is not decoded, not used for access control, and not routed. It is tied
to `4'b0011` (data, privileged, non-bufferable, non-cacheable) at each slave. The chip is
M-mode only with no PMP, so there is no privilege distinction for `HPROT` to carry.

**[N-5.3]** `HMASTLOCK` is not implemented. No master requires locked sequences: the core is
single-hart with no atomics (no A extension), and the DMA's transfers are independent
beats.

**[N-5.4]** `HPROT`, `HMASTLOCK` and burst types beyond SINGLE/INCR being absent is stated
here so no other document assumes they exist.

---

## 6 Register map

**[N-6.1]** The interconnect has no registers and no APB window. It is not software-visible.
Bus errors surface as precise exceptions in the master that caused them, not as status bits
here — a status register would be read after the fact and could not identify which access
failed.

---

## 7 Functional description

### 7.1 Topology

**[N-7.1]** One shared AHB-Lite layer. Exactly one master holds the bus at a time. All four
slaves see the same address and control bus, distinguished by `HSEL`.

**[N-7.2]** Total bandwidth is one 32-bit beat per `hclk` cycle: 1 GB/s at 250 MHz.
Measured demand during a flight-loop iteration is approximately 7% of that.

### 7.2 Arbitration

**[N-7.3]** Fixed priority, from `GARUDA-SYS-001` `ahb.masters`:

| Priority | ID | Master | Rationale |
|---|---|---|---|
| Highest | M3 | DMA | Peripheral FIFOs overflow if not serviced. The core can always stall; a UART cannot. |
| | M2 | Debug SBA | Only active during a debug session, when real-time behaviour is already suspended. |
| | M1 | D-port | Load/store stalls the core one cycle at a time. |
| Lowest | M0 | I-port | The prefetch buffer absorbs fetch latency. |

**[N-7.4]** Grant is re-evaluated on every beat boundary — that is, on every cycle where
`HREADY` is high.

**[N-7.5]** Grant is **locked for the duration of a data phase.** Once a transfer's address
phase has been accepted, the grant cannot move until that transfer's data phase completes.
AHB-Lite has no way to abort a transfer in its data phase, so moving the grant would corrupt
both the outgoing and incoming transfers. This is the single most important property of the
arbiter.

**[N-7.6]** A burst from M0 is split at beat boundaries if a higher-priority master requests.
The interposed beat completes, then M0's burst resumes with `HTRANS = NONSEQ` on its next
beat rather than `SEQ`. M0's prefetch buffer treats a NONSEQ restart as a normal fetch, so
no state is lost.

**[N-7.7]** Starvation bound: M0 is the lowest priority and can in principle be starved
while M3, M2 and M1 all request continuously. In practice the DMA issues at most one beat
per peripheral byte — a 1 Mbit/s peripheral is one beat every 2000 cycles — so the bound is
not reachable. No round-robin or ageing is implemented; adding it would complicate the
arbiter to solve a problem the traffic profile makes unreachable.

### 7.3 Reachability — normative

**[N-7.8]** Every master shall be physically connected to every slave listed for it in
`GARUDA-SYS-001` `ahb.master_reachability`:

| Master | ISRAM | Boot ROM | DSRAM | APB |
|---|---|---|---|---|
| M0 I-port | ✔ | ✔ | ✔ | ✔ |
| M1 D-port | ✔ | ✔ | ✔ | ✔ |
| M2 SBA | ✔ | ✔ | ✔ | ✔ |
| M3 DMA | ✔ | ✖ | ✔ | ✔ |

**[N-7.9]** The only permitted access restriction mechanisms in this chip are (a) address
decode, (b) the ISRAM write lock, and (c) a slave's own rejection of an operation it does not
support, such as a write to Boot ROM. **Structural reachability restrictions — removing a
wire so a master cannot address a slave — are forbidden.** They save a multiplexer input,
they cannot be relaxed without an RTL change, and their effects are invisible to the
documents that depend on them. See §1.3.

**[N-7.10]** M3 (DMA) has no Boot ROM path because nothing requires it: the bootloader is
polled PIO (ADR-0015) and no runtime function reads the ROM. This is an omission of an
unused path, not an access-control mechanism, and it is recorded in `GARUDA-SYS-001` so any
future need for it is a one-line change there rather than a discovery during bring-up.

### 7.4 Address decode

**[N-7.11]** Decode is on `HADDR[31:28]`, giving 16 possible 256 MiB granules, of which four
are used:

| `HADDR[31:28]` | Region | Slave |
|---|---|---|
| `0x0` | ISRAM | S0 |
| `0x1` | Boot ROM | S1 |
| `0x2` | DSRAM | S2 |
| `0x4` | APB | S3 |
| all others | — | default slave |

**[N-7.12]** `HSEL` is one-hot. `hsel_none` is asserted for every unused encoding and
selects the default slave.

**[N-7.13]** Within a granule, addresses above the slave's size alias down; the slave
ignores the unused address bits. `GARUDA-MEM-SPEC-001` [N-7.2] states the same and gives
the reasoning.

### 7.5 SBA indication

**[N-7.14]** `hmaster_is_sba_o` is asserted whenever the granted master is M2, and is
routed to the ISRAM slave only. It carries the grant, registered into the data phase
alongside the transfer, so the slave evaluates it in the same cycle as the write.

**[N-7.15]** Its sole purpose is the ISRAM lock bypass of `GARUDA-MEM-SPEC-001` [N-7.9]. It
is not a general privilege signal and no other slave receives it.

### 7.6 Error response

**[N-7.16]** The default slave responds to any selected transfer with the AHB two-cycle
ERROR: `HRESP` high with `HREADY` low in the first cycle, then `HRESP` high with `HREADY`
high in the second.

**[N-7.17]** The ERROR is returned to the granted master, which raises a precise exception:
instruction access fault for M0, load or store access fault for M1. The DMA sets its
channel's error status and raises its error interrupt. The SBA sets `sberror`.

**[N-7.18]** The bus never hangs on an undecoded address. There is no timeout mechanism in
the interconnect because there is no path by which a transfer can fail to terminate: every
encoding of `HADDR[31:28]` selects either a real slave or the default slave, and the APB
bridge — the only slave that can take unbounded time — has its own 16-cycle timeout
(`GARUDA-AHB2APB-SPEC-001` §7).

### 7.7 Wait states

**[N-7.19]** The interconnect inserts no wait states. `HREADY` seen by the granted master
is the selected slave's `hreadyout`, combinationally. All three memories are
zero-wait-state; only the APB bridge extends transfers.

**[N-7.20]** An ungranted master sees `HREADY` low, which holds it in its address phase
until granted. This is the standard AHB-Lite mechanism for stalling a master and requires
no additional handshake.

---

## 8 Timing

### 8.1 Uncontended single transfer (M1 read from DSRAM)

```
              │ T0 │ T1 │ T2 │
hclk        ──┘‾‾┐_┌‾‾┐_┌‾‾┐_┌
m1_hbusreq  ──┌──────┐──────────
              │ addr │ data │
m1_haddr    ──┤ A    ├─────────
m1_htrans   ──┤NONSEQ├─IDLE───
hgrant[1]   ──┌──────────┐─────
hsel_dsram  ──────┌──────┐─────
hrdata      ─────────────┤ D ├─
hready      ──┌──────────────┐─   held high: zero wait state
```

### 8.2 Contention: DMA preempts an I-port burst

```
              │ T0 │ T1 │ T2 │ T3 │ T4 │
hclk        ──┘‾┐_┌‾┐_┌‾┐_┌‾┐_┌‾┐_┌

m0_hbusreq  ──┌────────────────────────┐──  I-port bursting
m0_htrans   ──┤NSEQ│ SEQ│    │    │NSEQ├──  ◀── restarts as NONSEQ,
                                              not SEQ  [N-7.6]
m3_hbusreq  ─────────┌────────┐───────────  DMA requests

hgrant[0]   ──┌──────────┐    ┌───────────
hgrant[3]   ──────────────┌────┐──────────
                          ▲
                          └── grant moves only at a beat boundary,
                              never inside a data phase  [N-7.5]

haddr       ──┤ I0 │ I1 │ D0 │ I2 ├───────
              (shared bus, granted master's address)
```

### 8.3 Undecoded address: two-cycle ERROR

```
              │ T0 │ T1 │ T2 │ T3 │
hclk        ──┘‾┐_┌‾┐_┌‾┐_┌‾┐_┌

haddr       ──┤0x8000_0000├──────────  no slave decodes 0x8
htrans      ──┤  NONSEQ   ├─IDLE────
hsel_none   ──────┌────────────┐─────
hresp       ──────┌────────────┐─────  ERROR asserted both cycles
hready      ──┌───┐            ┌─────  low, then high  [N-7.16]
                  └────────────┘
                               ▲
                               └── master takes a precise access fault
```

### 8.4 ISRAM write with the lock set

```
              │ T0 │ T1 │ T2 │
hclk        ──┘‾┐_┌‾┐_┌‾┐_┌

hgrant[1]   ──┌──────────┐───────  D-port granted
hmaster_    ──────────────────────  low: not SBA
  is_sba
hsel_isram  ──────┌──────┐───────
hwrite      ──┤ 1  ├─────────────
ilock       ──┌──────────────────  set by the bootloader
hresp       ──────┌──────┐───────  ERROR: write rejected
sram_we     ──────────────────────  never asserted
```

With `hmaster_is_sba` high instead, `hresp` stays low and `sram_we` asserts — the bypass of
[N-7.15].

---

## 9 Clock, reset and power

**[N-9.1]** The entire interconnect is in the `hclk` domain. There is no clock crossing
inside it. The `hclk`↔`pclk` relationship is handled entirely within the APB bridge and is
synchronous in any case (`GARUDA-CLKRST-SPEC-001` §7.4).

**[N-9.2]** Reset is `hreset_n`. On reset the arbiter grants M0, all `HSEL` are low, and
`HREADY` is high, so an ungranted master's first request is accepted immediately rather
than stalling on a bus that appears busy.

**[N-9.3]** Power: the interconnect is combinational apart from the arbiter's grant
register, so it consumes essentially nothing when idle. No clock gating is applied. Gating
the interconnect would require predicting the next request a cycle early, which is not
possible and would save a handful of flops.

---

## 10 Assertions

```systemverilog
// --- exactly one master granted at a time
a_grant_onehot: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i) $onehot(hgrant));

// --- THE critical property: grant never moves inside a data phase
a_grant_stable_in_data_phase: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (!hready && htrans_q != IDLE) |=> $stable(hgrant));

// --- HSEL is one-hot including the default slave
a_hsel_onehot: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (htrans != IDLE) |-> $onehot({hsel_isram, hsel_bootrom, hsel_dsram, hsel_apb, hsel_none}));

// --- every unused decode lands on the default slave, never nowhere
a_no_black_hole: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (htrans != IDLE && haddr[31:28] inside {[4'h3:4'h3], [4'h5:4'hF]}) |-> hsel_none);

// --- ERROR is always exactly two cycles
a_error_two_cycle: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (hresp && !hready) |=> (hresp && hready));

// --- ERROR never appears with HREADY high in the first cycle
a_error_first_cycle: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  $rose(hresp) |-> !hready);

// --- reachability: every master can select every permitted slave (R-4)
// Checked as a cover, not an assert: this is the property Rev 3.1 broke.
c_m1_reaches_isram: cover property (
  @(posedge hclk_i) hgrant[1] && hsel_isram);
c_m1_reaches_bootrom: cover property (
  @(posedge hclk_i) hgrant[1] && hsel_bootrom);
c_m0_reaches_dsram: cover property (
  @(posedge hclk_i) hgrant[0] && hsel_dsram);
c_m2_reaches_isram_write: cover property (
  @(posedge hclk_i) hgrant[2] && hsel_isram && hwrite);

// --- sba indication tracks the grant exactly
a_sba_ind: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  hmaster_is_sba_o == hgrant_q[2]);

// --- no wait states inserted by the interconnect itself
a_no_inserted_wait: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  hready == (hsel_isram ? isram_hreadyout :
             hsel_bootrom ? bootrom_hreadyout :
             hsel_dsram ? dsram_hreadyout :
             hsel_apb ? apb_hreadyout : default_hreadyout));

// --- an ungranted requesting master is held, never loses its address
a_ungranted_held: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (hbusreq[0] && !hgrant[0]) |-> !m0_hready_o);

// --- burst restart is NONSEQ after preemption
a_burst_restart_nonseq: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  ($fell(hgrant[0]) ##1 $rose(hgrant[0])) |-> (m0_htrans_i == NONSEQ));

// --- reset state: M0 granted, HREADY high, no slave selected
a_reset_state: assert property (
  @(posedge hclk_i) !hreset_n_i |=> (hgrant == 4'b0001 && hready && !hsel_none));
```

---

## 11 Verification plan

| Req | Test | Oracle | Coverage goal | Status |
|---|---|---|---|---|
| R-1 | `t_ahb_protocol` | AHB-Lite protocol checker, zero violations | — | **passing** (existing RTL) |
| R-2 | `t_ahb_four_masters` | all four masters complete transfers | all 4 | new (M2 is new) |
| R-3 | `t_ahb_decode` | every `HADDR[31:28]` value selects the right slave | all 16 | extend |
| R-4 | `t_ahb_reachability` | the four cover properties above all hit | 4/4 covers | **new — the Rev 3.1 regression guard** |
| R-5 | `t_ahb_priority` | under simultaneous request, highest priority wins | all 6 master pairs | extend |
| R-5 | `t_ahb_grant_lock` | `a_grant_stable_in_data_phase` under random contention | — | extend |
| R-6 | `t_ahb_error` | undecoded address → two-cycle ERROR → precise fault | all 12 unused encodings | extend |
| R-7 | `t_ahb_sba_ind` | `hmaster_is_sba` follows the grant; ISRAM lock bypass works | — | new |
| R-8 | `t_ahb_zero_wait` | no interconnect-inserted wait state | — | extend |
| R-9 | `t_ahb_burst_preempt` | INCR burst preempted mid-burst, restarts NONSEQ, no data lost | preempt at each beat position | extend |
| §7.3 | `t_ahb_starvation` | M0 progresses under sustained M1+M3 load | — | new |

**[N-11.1]** `t_ahb_reachability` exists specifically so that a future attempt to save area
by removing a master-slave path fails a test rather than silently breaking boot. The covers
are the regression guard for MEM-1, and they should be treated as non-negotiable.

**[N-11.2]** The existing regression already covers R-1, R-3, R-5, R-6, R-8 and R-9 for
three masters with zero protocol violations. Rev 4.0's incremental verification burden is
M2: the SBA master, its priority position, and the `hmaster_is_sba` indication.

---

## 12 Design decisions

| Decision | ADR |
|---|---|
| Single shared layer, four masters, fixed priority, per-beat, data-phase-locked | ADR-0004 |
| Universal reachability; structural restrictions forbidden | ADR-0005 |
| `hmaster_is_sba` routed to ISRAM for the lock bypass | ADR-0006 |
| Debug SBA as M2 | ADR-0012 |

---

## 13 Not implemented

| Feature | Why not |
|---|---|
| Multi-layer matrix | ADR-0004: six arbiters, six decoders and a 6× wire count for headroom that 7% utilisation does not need, on a die where routing is the constraint. |
| Structural reachability restrictions | ADR-0005, §1.3. They broke boot, `.rodata` and JTAG load, and saved a multiplexer input. |
| `HPROT` decode / access control | M-mode only, no PMP. Nothing to distinguish. |
| `HMASTLOCK` | No atomics, no locked sequences needed. |
| WRAP bursts, INCR4/8/16 | No master generates them. The prefetch buffer uses undefined-length INCR. |
| Round-robin or ageing arbitration | Starvation is unreachable with this traffic profile ([N-7.7]). |
| Bus-error status registers | Errors surface as precise exceptions in the responsible master, which is strictly more useful than a register read after the fact. |
| Interconnect-level timeout | Every address selects a slave, and the only slave that can stall indefinitely has its own timeout. |
| Multiple outstanding transactions | AHB-Lite has no mechanism for it. |

---

## 14 Open items

None.

---

## 15 Errata

**Existing RTL (shared single layer) — fixed and verified:**

| ID | Symptom | Root cause | Fix | Regression test |
|---|---|---|---|---|
| B-1 | Grant could move while a data phase was outstanding, corrupting both transfers. | Arbiter evaluated on every cycle rather than every beat boundary. | Grant locked while `!hready`. | `t_ahb_grant_lock` |
| B-2 | Single-cycle ERROR returned for undecoded addresses; master saw a corrupt response. | Default slave did not implement the two-cycle sequence. | Two-cycle ERROR state machine. | `t_ahb_error` |

**Defects introduced by Rev 3.x and withdrawn by this revision:**

| ID | Symptom | Root cause | Resolution |
|---|---|---|---|
| B-3 | Boot CRC unimplementable; `.rodata` homeless; JTAG load impossible. | Structural reachability restriction, Rev 3.1 §4. | Withdrawn. [N-7.8], [N-7.9], and `t_ahb_reachability` as the guard. |
| B-4 | A dedicated DMA→ISRAM path was added to work around B-3's boot problem. | Treating the symptom rather than the cause. | Path deleted; boot is polled PIO on the D-port (ADR-0015). |
