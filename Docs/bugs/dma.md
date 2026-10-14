# Bugs: DMA controller (rtl/dma)

Owner: Track A. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).
Priorities: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).

<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. Run `bugs.py check` before pushing. -->
| ID | Title | Status | Prio | Found-by | Found | Fixed-in | Regression test | Evidence | Formerly |
|---|---|---|---|---|---|---|---|---|---|
| DMA-7 | Rev 2.0 dma_ack was one hclk wide; | FIXED | P2 | RTL audit | 2026-09-19 | legacy | `tb_dma_top` P2M handshake | HISTORY_2026.md L94 | - |
| ENG-1 | New engine regranted in the cycle before the channel had decremented REMAINING | FIXED | P2 | review | 2026-09-19 | legacy | `tb_dma_top` one-ack-per-request | HISTORY_2026.md L95 | - |
| DMA-8 | A failed beat marked the peripheral's request as taken | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L333 | - |
| DMA-1 | inconsistent SR snapshot across the clock-domain crossing | FIXED | P1 | - | legacy | legacy | - | HISTORY_2026.md L646 | - |
| DMA-2 | a write to any register of a channel swallowed that channel's CR.EN clear | FIXED | P1 | - | legacy | legacy | - | HISTORY_2026.md L667 | - |
| DMA-3 | an arm event delivered outside IDLE was silently discarded | FIXED | P2 | - | legacy | legacy | - | HISTORY_2026.md L687 | - |
| DMA-3a | two near-misses inside the fix itself | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L729 | - |
| DMA-4 | SR.REMAINING is unreliable across the TCR load | WONTFIX | P3 | - | legacy | legacy | - | HISTORY_2026.md L751 | - |
| DMA-5 | dma_cdc_pulse merges events closer than ~3 destination clocks | WONTFIX | P2 | - | legacy | legacy | - | HISTORY_2026.md L760 | - |
| DMA-6 | simultaneous W1C clear and flag set | WONTFIX | P2 | - | legacy | legacy | - | HISTORY_2026.md L767 | - |
| SPEC-1 | §7.4's 6-state AHB FSM table contradicts its own "Drives" column and §11.1's latency | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L781 | - |
| SPEC-2 | 65,536-beat runaway | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L782 | - |
| SPEC-3 | no status bit set anywhere | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L783 | - |
| SPEC-4 | §3.1 vs §7.5 on where SR lives | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L784 | - |
| SPEC-5 | §15.3's synchronised EN level alone cannot safely start a channel — EN has two writers in two domains | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L785 | - |
| SPEC-6 | CIRC + bus error would hammer the faulting address forever | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L786 | - |
| SPEC-7 | CIRC + TCR=0 livelocks CONFIGURED→COMPLETE→CONFIGURED | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L787 | - |
| SPEC-8 | 64-bit, illegal on a 32-bit bus | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L788 | - |
| SPEC-9 | beat boundary only | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L789 | - |
| SPEC-10 | two-cycle | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L790 | - |
| SPEC-11 | §5.6 signal-count arithmetic wrong (73 not 71; | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L791 | - |
| SPEC-12 | §15.1 says 960 register flops; | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L792 | - |
| TB-15 | the AHB protocol checker flags the AMBA-legal error cancel | FIXED | P3 | - | 2026-09-19 | legacy | - | HISTORY_2026.md L892 | - |
| TB-1 | formal's | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L955 | - |
| TB-2 | A circular channel is free-running; | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L956 | - |
| TB-3 | A TB watching a beat counter and then lowering a forced dma_req is always 1–2 beats late | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L957 | - |
| TB-4 | Precondition never established — arming crosses pclk→hclk through 3 flops plus a CONFIGURED cycle | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L958 | - |
| TB-5 | Sampled a counter *after* wait_flag, which polls over APB and returns up to ~9 hclk late | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L959 | - |
| TB-6 | Identical to TB-5; | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L960 | - |
| TB-7 | Closing sample taken after wait_flag again, including the legitimate resumption | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L961 | - |
| TB-8 | A hierarchical reference cannot take a variable generate index | FIXED | - | - | legacy | legacy | - | HISTORY_2026.md L962 | - |
| DMA-9 | Setting EN again after a software stop restarts the transfer from CNT instead of continuing; SAR/DAR keep their advanced values, so the restarted transfer writes past the end of the buffer | RULING-NEEDED | P2 | block-level probe (Verilator 5.052, real rtl/dma) | 2026-10-05 | - | dma/probe probe_dma9 (xfail DMA-9) | logs/dma/evidence/DMA-9_10_11_probe_2026-10-12.txt | - |
| DMA-10 | A forbidden destination (ISRAM / Boot ROM) is refused only after the source has been read, so a peripheral FIFO loses one entry | RULING-NEEDED | P3 | block-level probe (Verilator 5.052, real rtl/dma) | 2026-10-05 | - | dma/probe probe_dma10 (xfail DMA-10); dma/block tb_dma_top a_no_read_before_refusal known x31 | logs/dma/evidence/DMA-9_10_11_probe_2026-10-12.txt | - |
| DMA-11 | Re-arming a channel while a beat of its previous transfer is still in flight lets that beat land in the new transfer (COMPLETE with REMAINING = 0xFFFF, or the old source's word in the new destination) | RULING-NEEDED | P2 | block-level probe (Verilator 5.052, real rtl/dma) | 2026-10-05 | - | dma/probe probe_dma11a, probe_dma11b; dma/chip t_chip_dma_rearm (xfail DMA-11) | logs/dma/evidence/DMA-9_10_11_probe_2026-10-12.txt, DMA-11_chip_reachability_2026-10-12.txt | - |
| DMA-12 | ACK_CYCLES outside 1..4 silently gives the wrong dma_ack width (the 2-bit ack counter wraps) | RULING-NEEDED | P3 | RTL reading for the DMA plan (vPlan row F49) | 2026-10-05 | - | - | - | - |
| TB-44 | tb_dma_top made pclk with a toggle flop on hclk, so pclk-domain flops (PRDATA) captured post-edge hclk values in simulation (the SIM-1 race inside the DMA bench) | IN-PROGRESS | P3 | dma_sva a_read_data (Track A DMA plan D1) | 2026-10-12 | - | dma/block tb_dma_top with dma_sva bound (a_read_data silent) | logs/dma/evidence/TB-44_before_after.txt | - |
| DMA-13 | A halfword or word channel with an unaligned SAR or DAR puts a misaligned transfer on the AHB bus (AHB-Lite violation); the specification does not say what should happen | RULING-NEEDED | P3 | dma_sva cover c_unaligned never hit (DMA plan D1); vPlan F17 open point | 2026-10-12 | - | dma/probe probe_unaligned (xfail DMA-13) | logs/dma/evidence/DMA-9_10_11_probe_2026-10-12.txt | - |
| DMA-14 | Stopping a channel with CR = 0 (which also writes SIZE = byte) while a beat is in flight changes that beat's size: the last beat moves a byte instead of a word, or is read as a word and written as a byte, and still counts as done | RULING-NEEDED | P2 | formal (single-clock harness, a_write_data counterexample), replayed in simulation (DMA plan D2) | 2026-10-12 | - | dma/probe probe_stop_size (xfail DMA-14) | logs/dma/evidence/DMA-14_stop_size_2026-10-12.txt | - |
| DMA-15 | Every M2M beat pulses dma_ack to the channel's peripheral, although no peripheral requested it | RULING-NEEDED | P3 | DMA environment (D4): scoreboard + dma_req_checker R2 | 2026-10-12 | - | dma/probe probe_m2m_ack (xfail DMA-15); dma/env counts it as [KNOWN DMA-15] | logs/dma/raw/probe/sim_probe_m2m_ack_s1.log (6 acks for a 6-beat M2M transfer) | - |
| DMA-16 | A P2M beat whose destination write gets an AHB ERROR has already popped its source FIFO; the item is lost (no ack, SAR/DAR/REMAINING frozen, a re-arm reads the next item) | RULING-NEEDED | P3 | external plan review (Fresh AHB/APB/DMA plan 2026-10-13), checked against RTL (Fresh DMA-CON-06) | 2026-10-13 | - | planned: bus plan F-phase pop-on-read source + destination write error (tb/soc) | dma_engine.v E_WA/E_WD error path; same mechanism as DMA-10 probe_dma10 | - |
| DMA-17 | garuda_system.yaml (normative) lets the DMA reach ISRAM (`dma: [isram, dsram, apb]`, ADR-0005 'decode is the ONLY restriction'), but DMA spec R-9 and dma_engine.v refuse ISRAM (0x0) as well as Boot ROM (0x1) | RULING-NEEDED | P2 | external plan review (Fresh AHB/APB/DMA plan 2026-10-13), checked against RTL (Fresh DMA-CON-01) | 2026-10-13 | - | dma/probe probe_r9_sar + probe_dma10 show today's refusal; test of the ruled behaviour follows the ruling | Design_Docs/garuda_system.yaml:173; rtl/dma/dma_engine.v R-9 check | - |
| DMA-18 | Arming a non-zero transfer clears STAT.COMPLETE, while the DMA spec register table calls COMPLETE sticky until ICLR | RULING-NEEDED | P3 | external plan review (Fresh AHB/APB/DMA plan 2026-10-13), checked against RTL (Fresh DMA-CON-08) | 2026-10-13 | - | dma/env model and dma_sva follow the RTL (a_remaining_complete_consistent) | rtl/dma/dma_chan.v:118-120 | - |

## Details

### DMA-7

*From `Docs/BUGS.md` at b90b481, line 94, section "1b. Rev 4.0 migration — 2026-09-19".*

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| **DMA-7** | 9 DMA | FIXED (by design) | medium | Rev 2.0 `dma_ack` was one hclk wide; a pclk peripheral could miss it. Now one pclk period (D-16). | RTL audit | `tb_dma_top` P2M handshake |

### ENG-1

*From `Docs/BUGS.md` at b90b481, line 95, section "1b. Rev 4.0 migration — 2026-09-19".*

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| **ENG-1** | 9 DMA | FIXED | medium (duplicate beat) | New engine regranted in the cycle before the channel had decremented REMAINING. Caught during design, guarded in `dma_engine.v`. | review | `tb_dma_top` one-ack-per-request |

### DMA-8

*From `Docs/BUGS.md` at b90b481, line 333, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **DMA-8** | `rtl/dma/dma_chan.v` | FIXED | A failed beat marked the peripheral's request as taken. After firmware repaired the address and set EN again the channel sat ACTIVE and never eligible: a hang with no status bit set. Only a successful beat consumes the request. |

### DMA-1

*From `Docs/BUGS.md` at b90b481, line 646, section "DMA-1 — inconsistent SR snapshot across the clock-domain crossing  ·  `FIXED` · **Severity: high**".*

#### DMA-1 — inconsistent SR snapshot across the clock-domain crossing  ·  `FIXED` · **Severity: high**

- **Symptom:** a single APB read of SR could return `COMPLETE=1` together with
  `REMAINING=1` — a snapshot of a state the channel was never in, contradicting
  §6.7.
- **Root cause:** the two halves of one register reached pclk by paths of
  different depth — `SR.COMPLETE` through `dma_cdc_sync` (2 pclk flops),
  `SR.REMAINING` through `dma_cdc_gray` (**1 hclk flop** + 2 pclk flops). The
  gray coder registers binary→gray in the *source* domain, which is correct, but
  that extra stage delays REMAINING by up to one hclk relative to the flag — and
  one hclk is enough to land on the far side of a pclk edge.
- **Found by:** wait-state sweep at `+GWAIT=8`, test T2. **Invisible at GWAIT
  0–5.** This is the classic "passes a fixed-timing regression, fails silicon"
  defect shape.
- **Fix:** made the consistency *structural* rather than a latency coincidence.
  The counter is exported raw plus a `cnt_valid` level, pushed through the
  **same** `dma_cdc_sync` instance as the status flags, gating REMAINING to zero
  in the pclk domain. Latency-matching the two synchronisers would also work
  today and would break the moment either path changed depth.
- **Files:** `dma_channel_fsm.v`, `dma_reg_bank.v`, `dma_top.v`.

### DMA-2

*From `Docs/BUGS.md` at b90b481, line 667, section "DMA-2 — a write to any register of a channel swallowed that channel's CR.EN clear  ·  `FIXED` · **Severity: high**".*

#### DMA-2 — a write to any register of a channel swallowed that channel's CR.EN clear  ·  `FIXED` · **Severity: high**

- **Symptom:** `CR.EN` reads 1 **forever** on a channel that has completed and
  gone idle. The transfer engine keeps working — arming is event-driven — which
  is what makes it nasty: **the block behaves correctly while its status
  register lies**, and anyone debugging from CR.EN is sent the wrong way.
- **Root cause:** the per-channel write block was one
  `if (write to channel c) case(reg_sel) … else if (en_clr_p[c])`. The `else if`
  is skipped whenever that channel is written *at all*, so an APB write to SAR,
  DAR, TCR or SR arriving in the same pclk cycle as the completion pulse took the
  write branch, matched a case arm that does not touch CR, and **dropped the
  clear**. `en_clr_p` is a one-shot recovered from a toggle handshake; a dropped
  one-shot never retries.
- **The collision is a normal software pattern, not a corner case:** a
  completion ISR writes SR (W1C) and re-programs SAR/DAR in exactly that window.
- **Fix:** decode each register independently so only a **CR** write can
  pre-empt the clear.
- **Test:** T17 sweeps the collision phase in 1-hclk steps across 14 trials;
  2 of 14 failed before the fix, 0 after.

### DMA-3

*From `Docs/BUGS.md` at b90b481, line 687, section "DMA-3 — an arm event delivered outside IDLE was silently discarded  ·  `FIXED` · **Severity: medium**".*

#### DMA-3 — an arm event delivered outside IDLE was silently discarded  ·  `FIXED` · **Severity: medium**

Found by code review, not by simulation. Fixed 2026-09-12 with a deferred start.

- **Where:** `rtl/dma/dma_channel_fsm.v`, the main state machine.
- **What was wrong:** `arm_pulse` was tested only in `DMA_ST_IDLE`. An arm event
  arriving while the channel was in CONFIGURED, WAITING, TRANSFERRING or
  COMPLETE was dropped with no record. The register bank had already accepted
  the CR write that produced it, so **CR.EN read 1 on a channel that would never
  run** — the same failure shape as DMA-2, and worse, because the block genuinely
  did nothing: no beats, no interrupt, no error bit. Firmware waits forever.
- **The window that makes it real** is COMPLETE. It is a single hclk cycle and
  firmware cannot avoid it: the arm toggle takes three hclk flops to cross from
  pclk, so a completion ISR that re-arms the channel lands there purely on the
  luck of the clock phase. In that cycle the previous transfer **has** finished,
  so the request is entirely legitimate and dropping it is simply wrong.
- **Fix — a deferred start ("doorbell"), the usual arrangement for a DMA engine
  that takes work from a register write.** An arm event is latched in
  `arm_pending_r` from any state and consumed when the channel next reaches a
  point where it can start. The contract becomes uniform with no undefined
  corner: *a CR write with EN=1 always starts a transfer; if the channel is
  busy, it starts when the current transfer finishes.*
  - **Coalesced to one bit.** Ten CR writes while busy queue ONE restart, not
    ten, and because CONFIGURED re-reads SAR/DAR/TCR/CR that restart uses the
    **latest** descriptor rather than a stale queued copy.
  - **EN is not cleared** on the deferred-start path out of COMPLETE — the
    channel is going straight back out, so CR.EN=1 is the truth. Clearing it
    would be the mirror image of the original bug.
  - **Qualified with `en_h`**, and that qualifier is load-bearing, not
    decorative — see the near-miss below.
  - **A CIRC lap absorbs a queued start**, so the bit cannot sit latched for the
    life of a circular channel.
- **Considered and rejected: the ARM PL330 arrangement**, where a start issued
  to a channel that is not stopped is refused and raises a fault. It is the
  other defensible answer and it is fail-safe, but it needs a new SR bit — SR's
  layout is published in spec §6.7 with firmware macros written against it in
  §13.1 — and, more importantly, **it gets the COMPLETE window wrong**: the one
  case that must be accepted is the one it would report as an error.
- **Tests:** T18 (re-arm mid-TRANSFERRING, checked on the data and on a
  re-programmed destination), T19 (30-phase sweep of the COMPLETE collision),
  T20a/b/c (the cancel paths). **Mutation-proven** — see §6.1.

### DMA-3a

*From `Docs/BUGS.md` at b90b481, line 729, section "DMA-3a — two near-misses inside the fix itself".*

##### DMA-3a — two near-misses inside the fix itself

Both were found by tests written for the fix, and both are recorded because
each was a *silent* wrong answer that the obvious test did not catch:

1. **The deferred start was not qualified with EN.** A queued start would then
   fire at COMPLETE on a channel software had already disabled. The WAITING
   abort path does not save you: a top-priority channel with a non-empty FIFO is
   granted in the same cycle it enters WAITING, so `go_i` wins that branch every
   time and the channel never observes an abortable cycle. Found by T20a.
2. **The declined start was not cleared.** With EN low the COMPLETE branch
   correctly refused the restart — and left `arm_pending_r` set, so IDLE
   consumed it on the very next cycle and the channel ran anyway. The qualifier
   without the clear is worth nothing. Also found by T20a.

A third clear, on the WAITING abort path, is **deliberately kept but is
redundant today and is not claimed as covered** — removing it fails no test, and
that was checked rather than assumed. With `en_h` already low a retained request
is consumed by IDLE and re-aborts on the next pass: one pointless
CONFIGURED→WAITING→IDLE lap that moves no data and changes no status. It is kept
because it stops being redundant the moment anyone weakens the `en_h` qualifier.

### DMA-4

*From `Docs/BUGS.md` at b90b481, line 751, section "DMA-4 — `SR.REMAINING` is unreliable across the TCR load  ·  `WAIVED` · **Severity: low**".*

#### DMA-4 — `SR.REMAINING` is unreliable across the TCR load  ·  `WAIVED` · **Severity: low**

`xfer_cnt` is loaded from TCR on entry to CONFIGURED — a multi-bit jump, across
which the gray code's one-bit-per-change guarantee does not hold. A read landing
in that ~2-pclk window can return a mixture. Accepted because §16.7 makes the
field advisory and closing it properly needs a full req/ack data handshake (~4×
the area, 6 instances) to harden a debug field. Firmware needing exactness must
read twice or use `SR.COMPLETE`.

### DMA-5

*From `Docs/BUGS.md` at b90b481, line 760, section "DMA-5 — `dma_cdc_pulse` merges events closer than ~3 destination clocks  ·  `WAIVED` · **Severity: low–medium**".*

#### DMA-5 — `dma_cdc_pulse` merges events closer than ~3 destination clocks  ·  `WAIVED` · **Severity: low–medium**

Inherent to a two-phase toggle handshake. Every user in the block is checked
against it by protocol (APB writes are ≥2 pclk apart; the EN clear fires once
per completion). **Argued safe, not proven by test.** A future faster event
source needs a full req/ack handshake, not this primitive.

### DMA-6

*From `Docs/BUGS.md` at b90b481, line 767, section "DMA-6 — simultaneous W1C clear and flag set  ·  `WAIVED` · **Severity: medium**".*

#### DMA-6 — simultaneous W1C clear and flag set  ·  `WAIVED` · **Severity: medium**

Set-wins ordering is implemented (same shape as ERRATUM DSU-8 in
`rtl/dsu/overflow_flag.v`) but has **never been deterministically forced in
simulation**. Still open as a verification gap rather than a known defect.

### SPEC-1

*From `Docs/BUGS.md` at b90b481, line 781, section "DMA spec defects — SPEC-1 … SPEC-12".*

| ID | Class | One-line |
|---|---|---|
| SPEC-1 | contradiction | §7.4's 6-state AHB FSM table contradicts its own "Drives" column and §11.1's latency. READ_DATA and WRITE_ADDR merged. |

### SPEC-2

*From `Docs/BUGS.md` at b90b481, line 782, section "DMA spec defects — SPEC-1 … SPEC-12".*

| ID | Class | One-line |
|---|---|---|
| SPEC-2 | contradiction | §6.5 vs §7.1 on TCR=0. Following §7.1 would decrement from 0, wrap to 0xFFFF and turn an empty descriptor into a **65,536-beat runaway**. |

### SPEC-3

*From `Docs/BUGS.md` at b90b481, line 783, section "DMA spec defects — SPEC-1 … SPEC-12".*

| ID | Class | One-line |
|---|---|---|
| SPEC-3 | contradiction | §3.1 "re-evaluates every cycle" vs §2/§8.3 "after every beat". A mid-beat grant swing corrupts two transfers with **no status bit set anywhere**. |

### SPEC-4

*From `Docs/BUGS.md` at b90b481, line 784, section "DMA spec defects — SPEC-1 … SPEC-12".*

| ID | Class | One-line |
|---|---|---|
| SPEC-4 | contradiction | §3.1 vs §7.5 on where SR lives. |

### SPEC-5

*From `Docs/BUGS.md` at b90b481, line 785, section "DMA spec defects — SPEC-1 … SPEC-12".*

| ID | Class | One-line |
|---|---|---|
| SPEC-5 | **ambiguity with a latent hang** | §15.3's synchronised EN level alone cannot safely start a channel — EN has two writers in two domains. Rising-edge start hangs; level start re-runs the transfer. Resolved with an arm *event*. |

### SPEC-6

*From `Docs/BUGS.md` at b90b481, line 786, section "DMA spec defects — SPEC-1 … SPEC-12".*

| ID | Class | One-line |
|---|---|---|
| SPEC-6 | gap | CIRC + bus error would hammer the faulting address forever. Guarded. |

### SPEC-7

*From `Docs/BUGS.md` at b90b481, line 787, section "DMA spec defects — SPEC-1 … SPEC-12".*

| ID | Class | One-line |
|---|---|---|
| SPEC-7 | gap | CIRC + TCR=0 livelocks CONFIGURED→COMPLETE→CONFIGURED. Guarded. |

### SPEC-8

*From `Docs/BUGS.md` at b90b481, line 788, section "DMA spec defects — SPEC-1 … SPEC-12".*

| ID | Class | One-line |
|---|---|---|
| SPEC-8 | gap | Reserved `CR.SIZE=2'b11` passed through gives HSIZE=3'b011 — **64-bit, illegal on a 32-bit bus**. Degraded to WORD in both the master and the address stepper, which must agree. |

### SPEC-9

*From `Docs/BUGS.md` at b90b481, line 789, section "DMA spec defects — SPEC-1 … SPEC-12".*

| ID | Class | One-line |
|---|---|---|
| SPEC-9 | gap | §6.6 "writing 0 to EN while active is undefined". Defined as a clean abort at a **beat boundary only**. |

### SPEC-10

*From `Docs/BUGS.md` at b90b481, line 790, section "DMA spec defects — SPEC-1 … SPEC-12".*

| ID | Class | One-line |
|---|---|---|
| SPEC-10 | **integration risk** | §5.3 never states that ERROR is the AMBA **two-cycle** response. The write-address cancel depends on it. Now normative in GARUDA-AHB-SPEC-001 §1.4. |

### SPEC-11

*From `Docs/BUGS.md` at b90b481, line 791, section "DMA spec defects — SPEC-1 … SPEC-12".*

| ID | Class | One-line |
|---|---|---|
| SPEC-11 | doc erratum | §5.6 signal-count arithmetic wrong (73 not 71; 107 not 105; 212 not 210). |

### SPEC-12

*From `Docs/BUGS.md` at b90b481, line 792, section "DMA spec defects — SPEC-1 … SPEC-12".*

| ID | Class | One-line |
|---|---|---|
| SPEC-12 | doc erratum | §15.1 says 960 register flops; actual is 558. |

### TB-15

*From `Docs/BUGS.md` at b90b481, line 892, section "TB-15 — the AHB protocol checker flags the AMBA-legal error cancel  ·  `FIXED 2026-10-03` · **Severity: low**".*

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| TB-15 | TB | MOOT | — | The Rev 3.0 DMA never has a second transfer queued when an ERROR returns, so the error-cancel case the checker mis-flags cannot occur; `tb_dma_top` now binds the checker and it is clean. The checker gap itself remains for any future pipelined master. | — | `tb_dma_top` |

#### TB-15 — the AHB protocol checker flags the AMBA-legal error cancel  ·  `FIXED 2026-10-03` · **Severity: low**

`tb/ahb/ahb_lite_checker.v`'s `v_retract` counter fires on any NONSEQ/SEQ
withdrawn to IDLE while HREADY was low. ARM IHI 0033A §5.1.3 **permits** a
master to cancel the following transfer during an ERROR response, and
`dma_ahb_master` does exactly that — it is the whole mechanism behind the
write-address cancel. The checker does not exempt the case where the previous
cycle carried `HRESP=ERROR` with `HREADY=0`. Not hit in the tests run so far
(the DMA's error tests are at block level, where no checker is bound), but it
**will** produce a false positive the first time a SoC-level test injects a bus
error into a DMA read. **Fix:** exempt the retract when `p_hresp && !p_hready`.

**Fixed 2026-10-03.** The exemption is applied, and the legal cancels are
**counted** (`n_err_cancel`, reported in the summary) rather than discarded: an
exemption that silently swallows traffic is indistinguishable from one that is
swallowing a real defect.

Verified by `tb/ahb/tb_ahb_checker_selftest.sv`, a new negative control for the
checker — which had none, against `Docs/ORACLES.md`'s own rule that *a clean
report from a checker that has not been shown to fail is worth nothing*. It
drives the monitor's taps directly, so the corner is hit deterministically
instead of being waited for, and the two scenarios differ in exactly one bit of
history:

| Scenario | Pre-fix | Post-fix |
|---|---|---|
| wait state **with** ERROR, then IDLE (legal cancel) | `v_retract=1` — false positive | `v_retract=0`, `n_err_cancel=1` |
| plain wait state, then IDLE (genuine retraction) | `v_retract=1` | `v_retract=1` — still caught |

The second row is the one that makes the first mean anything: without it,
deleting the check outright would also have "passed".

**The three contradictory statuses are now reconciled.** §1b's `MOOT` was
correct only about the Rev 3.0 DMA not reaching the case; the checker gap it
noted was real, is what this fixes, and §1's summary row saying *0 open*
testbench defects was simply wrong.

### TB-1

*From `Docs/BUGS.md` at b90b481, line 955, section "Earlier testbench bugs — TB-1 … TB-8".*

| ID | One-line |
|---|---|
| TB-1 | `chk_eq` formals are `[63:0]`; Verilog evaluates argument expressions at the **formal's** width, so `~pat` inverted a 64-bit zero-extension. |

### TB-2

*From `Docs/BUGS.md` at b90b481, line 956, section "Earlier testbench bugs — TB-1 … TB-8".*

| ID | One-line |
|---|---|
| TB-2 | A circular channel is free-running; by the time an APB read of SR completes, the next lap has already overwritten the buffer. |

### TB-3

*From `Docs/BUGS.md` at b90b481, line 957, section "Earlier testbench bugs — TB-1 … TB-8".*

| ID | One-line |
|---|---|
| TB-3 | A TB watching a beat counter and then lowering a forced `dma_req` is always 1–2 beats late. |

### TB-4

*From `Docs/BUGS.md` at b90b481, line 958, section "Earlier testbench bugs — TB-1 … TB-8".*

| ID | One-line |
|---|---|
| TB-4 | Precondition never established — arming crosses pclk→hclk through 3 flops plus a CONFIGURED cycle. |

### TB-5

*From `Docs/BUGS.md` at b90b481, line 959, section "Earlier testbench bugs — TB-1 … TB-8".*

| ID | One-line |
|---|---|
| TB-5 | Sampled a counter *after* `wait_flag`, which polls over APB and returns up to ~9 hclk late. |

### TB-6

*From `Docs/BUGS.md` at b90b481, line 960, section "Earlier testbench bugs — TB-1 … TB-8".*

| ID | One-line |
|---|---|
| TB-6 | Identical to TB-5; T7 was fixed and the fix was not propagated to T8. |

### TB-7

*From `Docs/BUGS.md` at b90b481, line 961, section "Earlier testbench bugs — TB-1 … TB-8".*

| ID | One-line |
|---|---|
| TB-7 | Closing sample taken after `wait_flag` again, including the legitimate resumption. |

### TB-8

*From `Docs/BUGS.md` at b90b481, line 962, section "Earlier testbench bugs — TB-1 … TB-8".*

| ID | One-line |
|---|---|
| TB-8 | A hierarchical reference cannot take a variable generate index. |

### DMA-9

Probe 2026-10-05 (Verilator 5.052, rtl/dma at b90b481, block level): CNT = 8, EN cleared after 4 beats (REMAINING 4, SAR/DAR advanced by 16). Setting EN = 1 again reloads REMAINING to 8 and runs 8 more beats, 12 in total, so 4 words land past the end of the 8-word buffer (last write 0x2000_102C). Cause: `dma_chan.v:104` reloads REMAINING from CNT on every 0->1 of EN, while SAR/DAR are not reloaded (they change only by a software write or a successful beat). vPlan F20 says 'setting EN again continues from there', which the RTL does not do; the spec is silent.

Proposed ruling (DMA plan D2): document 'clearing EN aborts the transfer; to resume, write CNT = REMAINING (SAR/DAR stay where they stopped) before setting EN again'; correct F20; add F42 (restart after a software stop) with a test of the documented behaviour. No RTL change. Alternative: change the RTL so that EN after a stop resumes from REMAINING. P2 (P1 if firmware follows F20 as written). Test: tb/dma/tb_dma_probe.sv case DMA-9 (xfail until ruled).

### DMA-10

Probe 2026-10-05: P2M with SAR = 0x4000_2000 and DAR = 0x0000_1000 issues one AHB read to the peripheral, then ERROR with ERRPHASE = write, no write and no ack. A FIFO data register loses one entry. Control case: a bad SAR is refused before any transfer. Cause: `dma_engine.v:117` checks SAR in E_RA, but `:141` checks DAR only in E_WA. The file header (`:19-22`) says the refusal 'issues no AHB transfer'. Only firmware misconfiguration reaches this.

Proposed ruling (DMA plan D3): check DAR in E_RA as well (SAR first, then DAR), and keep the E_WA check for a DAR rewritten in the middle of a beat (F46); the header comment then becomes true. vPlan F43. Detector: a_no_read_before_refusal in rtl/dma/dma_sva.sv (fires on today's RTL). Test: tb/dma/tb_dma_probe.sv case DMA-10.

**2026-10-12:** dma_sva bound in tb_dma_top: the detector fires 31 times = 1 (step 5) + 6 (step 10) + 24 (step 13). Two bench checks encode today's behaviour and must change with the fix: step 10 expects 'the read happens, the write is refused' (n_rd == nr0 + 1), and step 13's ICLR-vs-ERROR sweep uses the late refusal to time its error (DAR in Boot ROM, 24 iterations), so its collision coverage must be re-checked after the fix.

### DMA-11

Probe 2026-10-05, block level: (a) EN cleared in the middle of a beat, then re-armed with CNT = 0 before the beat finished: COMPLETE = 1 with REMAINING = 0xFFFF, which breaks R-6 and a_remaining_complete_consistent. (b) Re-armed with a new SAR/DAR and CNT = 2: the new dst[0] got the old source's word (A0000000), the new src[0] was never copied, and the new transfer moved only 1 beat of its own. Cause: `dma_chan.v:114-115` decrements REMAINING (and `:107-110` advance SAR/DAR) on any beat_done, whether or not the beat belongs to the current arming. After EN = 0, ACTIVE drops at once while the engine finishes the beat, and the engine's busy_o is left unconnected (`dma_top.v:101`), so firmware cannot wait for the beat to end.

Reachability at chip level is open: two or more configuration writes must land inside one beat, and at chip level they share the bus with M3. Evidence to come from the formal reachability cover (DMA plan D2) and the chip program t_chip_dma_rearm (D9, run early). Proposed ruling (D4), after that result: (A) ignore a beat_done that started before the re-arm (a per-channel arm-generation flag), or (B) connect busy_o to a STAT bit and state a firmware rule (wait for it before re-arming). If unreachable at chip level: document it, keep a_remaining_complete_consistent as the guard, and lower to P3. Detectors: a_beat_belongs_to_arm, a_remaining_complete_consistent, a_no_rem_underflow (fire on today's RTL). vPlan F44.

**2026-10-12:** REACHABLE AT CHIP LEVEL (DMA plan D9, run early): sw/chip/t_chip_dma_rearm.c on tb_chip. Firmware that stops a channel and re-arms it straight after starting it (two back-to-back stores: CR = stop, CR = EN, with CNT = 0 written while the old transfer ran) re-arms while a beat is in flight: 2 of 96 two-store attempts (DSRAM-source beats at d = 0, APB-source beats at d = 2); a_beat_belongs_to_arm fires and REMAINING wraps to 0xFFFF with COMPLETE set. None of 96 five-store re-arms (new SAR/DAR/CNT) reached it. So DMA-11 cannot be left to documentation: firmware cannot see the beat in flight (busy_o is unconnected). Proposed ruling (D4) is now (A) an RTL fix: a beat that started before the re-arm must not count in the new transfer (per-channel arm generation, or drop the stale beat_done), optionally (B) a BUSY bit in STAT so firmware can also wait. Priority stays P2.

### DMA-12

`dma_engine.v:85` declares ack_cnt as 2 bits and `:163` loads ACK_CYCLES - 1. ACK_CYCLES = 0 loads 3 (ack 4 hclk wide); ACK_CYCLES = 5 loads 0 (ack 1 hclk wide, which a pclk peripheral can miss: the DMA-7 failure again). GARUDA uses ACK_CYCLES = 2 (D-16), so the shipped chip is correct; the parameter is unguarded. Proposed fix (DMA plan ruling D6): an elaboration-time check that stops the build for ACK_CYCLES outside 1..4 (or ack_cnt sized from the parameter). Test: an elaboration with ACK_CYCLES = 5 must fail (vPlan F49).

### TB-44

With dma_sva bound, a_read_data failed 20 times in tb_dma_top, always on a STAT read during an active transfer. The bench made pclk with `always @(posedge hclk) pclk <= ~pclk`, so the pclk edge came one delta cycle after the hclk-domain flops had updated: dma_apb_slave's PRDATA flop (posedge pclk) captured the post-edge STAT value (REMAINING already decremented), which silicon never does (D-5: every pclk edge is an hclk edge, both sample pre-edge values). The property's sampled values are the silicon-correct ones. Same mechanism as SIM-1 (clk_div at chip level, Karthik's). Fix (tb only): pclk is generated in the same time step and region as hclk, same phase (rises with hclk at t = 2 + 8k); tb_dma_top stays 64/64 and a_read_data is silent. FIXED once committed.

### DMA-13

`dma_engine.v` drives HADDR from SAR (E_RA) and DAR (E_WA) with HSIZE = {0, SIZE} and never checks SAR/DAR[1:0] against SIZE, so a word channel with SAR = 0x2000_0002 (or a halfword channel with an odd address) issues a NONSEQ whose HADDR is not aligned to HSIZE. AHB-Lite requires the alignment; a strict slave may answer ERROR or misbehave, and tb_chip's ahb_lite_checker reports it as a violation. Same class as the core's BUS-E. vPlan F17 (Karthik) already says an unaligned halfword or word 'is not covered by the specification; to be decided and written down'. The 2026-10-05 D-drive bench saw the misaligned addresses (113 a_aligned hits with unconstrained SAR/DAR). Only firmware misconfiguration reaches it. Proposed ruling: (A) refuse a misaligned beat like an R-9 address (ERROR, ERRPHASE = read or write, no AHB transfer) [recommended: no illegal transfer can reach the bus, and firmware gets a clean error]; (B) align by masking the low bits (silent, firmware never learns); (C) document 'SAR/DAR must be aligned to SIZE' and keep the violation (not recommended). Detector: a_haddr_aligned in rtl/dma/dma_sva.sv. Test: tb/dma/tb_dma_probe.sv case unaligned (xfail DMA-13).

### DMA-14

The engine reads the selected channel's SIZE (and SAR, DAR) live during a beat (`dma_engine.v:70-72`), and dma_chan updates SIZE on every CR write (`dma_chan.v:93`), including the write that stops the channel. The obvious stop, `DMA_CR(n) = 0`, writes SIZE = 0 (byte). If it lands while a word beat is in flight: (1) between the beat's read and its write, the write goes out as a byte (two HSIZEs in one beat); (2) just after the engine took the beat, the whole beat becomes a byte beat. Either way the beat counts as done (REMAINING drops by one, SAR/DAR step by 1 instead of 4), so the destination holds a partial word that firmware believes was moved. This breaks F20 ('stops at a beat boundary ... REMAINING, SAR and DAR agree with the beats done') and is the F45 gap. Found by formal (a_write_data; with an unaligned SAR the wrong lane is written), replayed with real timing by tb_dma_probe +CASE=stop_size: 72 stop points, 38 beats written with a different HSIZE than read, 44 words counted as moved but wrong. Detector: a_beat_size_atomic (a beat keeps the SIZE it was taken with) in rtl/dma/dma_sva.sv. Workaround: stop with a CR write that keeps SIZE (read CR, clear EN, write back). Proposed ruling: (A) the engine latches SIZE, SAR and DAR when it takes the beat, and the channel steps SAR/DAR by the beat's size [recommended: it also settles F46 (DAR rewritten mid-beat) and simplifies the DMA-11 fix]; (B) dma_chan ignores SIZE/MODE/SINC/DINC writes while a beat of that channel is in flight; (C) document the stop rule only (fragile: every driver must know it).

### DMA-15

`dma_engine.v:161-163` sets dma_ack for the channel on every successful beat, whatever the mode. In M2M no peripheral requested the beat, yet the channel's peripheral (spi_master, i2c, uart0/1/2, spi_slave) sees an ack. The shared shim (`garuda_apb_shim.v:153-158`) uses the ack only to hold its own request low for one pclk, so at chip level the effect is a suppressed request on a line the M2M channel does not use: harmless today. But it contradicts the handshake as written (spec section 7.3, D-21: the ack answers a request) and Karthik's tb/common/dma_req_checker.sv rule R2 (an ack only while a request is outstanding), and a future peripheral that counts acks would break. Proposed ruling: (A) qualify the ack with MODE != M2M in dma_engine (or dma_top) [recommended: one line, the handshake becomes exact]; (B) document that M2M beats ack the channel's peripheral and relax R2 for M2M channels.

### DMA-16

Fresh plan DMA-CON-06, checked against the RTL 2026-10-13. In P2M the source is a peripheral data register that pops on read (UART/SPI RX FIFO). The engine reads it (E_RA/E_RD), then the destination write gets an AHB ERROR (for example DAR in an unmapped region or a hole that the default slave answers). Today the channel goes to ERROR with ERRPHASE = write, gives no ack, and leaves SAR/DAR/REMAINING frozen, which is right for the registers. But the peripheral has already given up the item, and AHB cannot undo a read. After ICLR and re-arm the next read returns the *next* item, so one item is lost without a trace. It's the same mechanism as DMA-10 (where the DMA itself refuses the destination after the read); DMA-10's proposed fix (check DAR before the read) covers the forbidden-address case only, not an ERROR returned by the bus.

Only firmware misconfiguration, or a slave that faults at run time, reaches it. Proposed ruling: **(A, recommended)** accept and document it as a limitation in DMA spec section 7 (error handling): "a P2M beat whose write fails loses the source item; firmware must treat the peripheral stream as broken after a DMA write error". **(B)** add a one-word holding buffer and retry-the-write-only on re-arm (needs a new register bit and changes F20/F42). Reproducer: the bus plan's DMA-through-fabric phase, a pop-on-read source with a write to an unmapped DAR; not a plain RAM model, which hides the effect.

### DMA-17

Fresh plan DMA-CON-01. `Design_Docs/garuda_system.yaml` says it is normative where prose specs disagree. Its `master_reachability` lists `dma: [isram, dsram, apb]` (no bootrom), under ADR-0005's note that address decode is the only restriction. DMA spec R-9 and `dma_engine.v` refuse SAR/DAR in region 0x0 (ISRAM) **and** 0x1 (Boot ROM) before any transfer (probe_r9_sar, probe_dma10). The two normative sources disagree, so neither 'pass' nor 'fail' can be claimed for the R-9 tests until it is ruled.

Options: **(A)** the YAML is right: allow ISRAM (keep the Boot ROM refusal); a DMA write to ISRAM then obeys MEMCTL.ILOCK like any other master (the write is dropped or answered with ERROR, per the mem spec), and the DMA spec R-9, F32 and the probes change. **(B)** R-9 is right: change the YAML to `dma: [dsram, apb]` and regenerate the derived maps. Recommendation: **(B)**. Flight code has no use for DMA into instruction memory, and B keeps the ADR-0006 lock argument simple. But it's an architecture call (Karthik).

### DMA-18

Fresh plan DMA-CON-08. The spec register table describes STAT.COMPLETE as sticky until ICLR. `dma_chan.v:118-120` clears COMPLETE when a non-zero transfer is armed, so that COMPLETE ⇒ REMAINING = 0 always holds (property a_remaining_complete_consistent, DMA-11's detector). The environment model, the SVA and the chip programs follow the RTL. Proposed ruling: keep the RTL and edit the spec: "COMPLETE is sticky until ICLR **or until the channel is re-armed with CNT ≠ 0**". Also state the ICLR-vs-last-beat collision rule (set wins, D-2), which the RTL already follows.
