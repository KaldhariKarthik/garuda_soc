# GARUDA SoC — bug register

**Every bug, erratum and specification defect found in this project, in one place.**
Not per-block: a bug that crosses a boundary belongs in one list, and the
cross-block ones are the expensive ones.

Last updated: 2026-09-12 · Covers Blocks 1 (core), 2 (DSU), 6 (interconnect),
9 (DMA), plus toolchain and testbench defects.

Related: `docs/SOC_RTL_LOG.md` (interconnect + SoC reasoning), `docs/DMA_RTL_LOG.md`
(Block 9 narrative).

---

## How to read this

| Column | Meaning |
|---|---|
| **ID** | Stable. Never renumber — other files reference these by name. |
| **Status** | `FIXED` verified fixed · `OPEN` real, not fixed · `WAIVED` understood and deliberately left · `SPEC` a defect in a design document, resolved in RTL |
| **Severity** | What it costs if it reaches silicon, not how hard it was to find. |
| **Found by** | The mechanism. This column is the most useful one in the table: it says what kind of testing actually pays. |

A bug listed as FIXED means a test exists that fails without the fix. Where a
mutation test was run to prove that, it is named.

---

## 1. Summary

| Block | Fixed | Open | Waived | Spec defects |
|---|---:|---:|---:|---:|
| 1 — RV32IM core | 7 | 1 | 0 | 0 |
| 2 — DSU | 10 | 0 | 0 | 0 |
| 6 — AHB-Lite interconnect | 3 | 0 | 0 | 3 |
| 9 — DMA controller | 3 | 0 | 3 | 12 |
| Testbench / toolchain | 11 | 0 | 1 | — |

**Every RTL defect found so far is fixed.** What remains open is a small set of
waived limitations and one uncovered-but-redundant line, all named below.

**The four most instructive entries, if you read nothing else:**

- **AHB-2** — the arbitration rule the interconnect spec prescribes silently
  starves the DMA, which is the one master that must never be starved.
- **TOOL-4** — a seeded regression that was not actually varying with the seed,
  reporting ten passes for one stimulus. It recurred this session as **TB-11**.
- **DMA-2** and **DMA-3** — a status register that lied while the block kept
  working, and a start request the block accepted and then silently discarded.
  Both have the same shape: correct-looking hardware, a register saying
  something untrue, and nothing in any status bit to point at it.
- **CORE-1** — RTL that means one thing to a simulator and something else to a
  synthesiser, and had done for the life of the project.

---

## 2. Block 6 — AHB-Lite interconnect

Specification: `Design_Docs/AHB_Int/GARUDA_AHB_Bus_Design_Spec_v2.0.docx`
(GARUDA-AHB-SPEC-001 Rev 2.0). RTL: `rtl/ahb/`. Tests: `tb/ahb/tb_ahb_interconnect.sv`.

### AHB-1 — HWDATA follows the wrong master  ·  `SPEC` / `FIXED` · **Severity: high (silent data corruption)**

- **Where:** spec §3.1 sub-block table; RTL `rtl/ahb/ahb_master_mux.v`.
- **The defect:** §3.1 lists the Master Mux as steering
  "HADDR/HTRANS/HWRITE/HSIZE/HBURST/HPROT/**HWDATA**" from *the granted master*.
  HWDATA does not belong in that list. AHB-Lite is pipelined: the slave samples
  HWDATA one cycle **after** the address phase it belongs to. Selecting it on
  the address-phase grant means every cycle the bus changes owner presents the
  **new** master's write data to a slave still committing the **old** master's
  write.
- **Why it bites here specifically:** `dma_ahb_master` drives HTRANS=IDLE in
  `S_WDATA` while its write data phase is in flight — deliberately, so the bus
  can be handed on. Following §3.1 literally, that hand-off writes the D-Port's
  HWDATA into the DMA's destination address. The DMA reports the beat complete,
  the store reports OKAY, and the destination buffer silently holds the wrong
  word. **No status bit is set anywhere.**
- **Resolution:** HWDATA is muxed on `dph_master_i`, the registered data-phase
  owner. Address and control stay on `grant_i`.
- **Test:** T14 in `tb_ahb_interconnect.sv`. **Mutation-proven**: restoring the
  spec's wiring produces 8 failures (`MUT-1`).

### AHB-2 — the prescribed arbitration rule starves the DMA  ·  `SPEC` / `FIXED` · **Severity: high (real-time failure)**

This is the hardest thing in the block and the one to read before changing any
HREADY logic. Full derivation is in the header of `rtl/ahb/ahb_master_port.v`.

- **Where:** spec §7.2 (re-sample the grant on every HREADY-high boundary) and
  §7.3 (an ungranted master is held by driving its HREADY low). Each is
  individually reasonable. Together, applied literally, they lose read data.
- **Root cause:** AHB-Lite masters have **no HGRANT**. A full-AHB master knows
  when it does not own the bus and ignores HREADY. An AHB-Lite master has one
  wire, and `HREADY=1` means *both* "your data phase completed" *and* "your
  address phase was accepted". An interconnect cannot separate them.
  For master A with a read data phase in flight, still presenting a transfer,
  when higher-priority B arrives:
  - drive A's HREADY low (§7.3 literally) → A holds its address phase correctly,
    but the slave completed A's read **this cycle** and drives HRDATA for one
    cycle only. A misses it. **Silent data loss.**
  - leave A's HREADY high so it can take its data → A also concludes the address
    phase it is presenting was accepted, and starts a data phase for a transfer
    that never reached a slave. **Silent data corruption.**
- **The first fix, which was wrong:** pin the grant to the data-phase owner
  while it is still requesting (`force_owner = dph_valid && req[dph_master]`).
  That makes the hand-off trivially safe — and starves the DMA.
  `garuda_iport_ahb_master` sustains one fetch per cycle whenever the prefetch
  buffer is popped every cycle (straight-line code at 1 IPC): `projected_occ`
  settles at 3, `room_for_new_fetch` stays true indefinitely, and HTRANS is
  never IDLE. The **lowest**-priority master would hold an unbounded lock on the
  bus. That defeats the entire rationale for fixed priority in §7.1 — *"a
  stalled DMA can overflow a peripheral RX FIFO and lose sensor data"* — and it
  defeats it silently: every transfer still completes correctly, just far too
  late for a 1 kHz sensor loop.
- **Resolution:** `rtl/ahb/ahb_master_port.v` gives each master a one-deep
  **response hold**. A master preempted mid-data-phase has its HREADY driven low
  *and* has the response it would have missed captured, replayed on the cycle it
  is next granted. From the master's point of view its transfer simply took
  extra wait states. Fixed priority then applies unconditionally at every
  boundary. `force_owner` is deleted, with a comment saying not to reintroduce it.
- **Why one entry is enough:** a master whose response is held is stalled with
  HREADY=0, so it cannot issue another transfer and has no further data phase in
  flight. No second capture can occur before the first is delivered.
- **Why replaying HRESP is safe despite the two-cycle ERROR rule:** a capture
  can never coincide with an error completion. An error completes on its second
  cycle and its first cycle drove HREADY low; the arbiter's grant freeze
  (`hold_r`) re-uses the previous grant on any cycle preceded by HREADY=0, and a
  capture requires the grant to have *moved*. The capture is therefore always an
  OKAY response.
- **Tests:** T12 (DMA granted within **2 arbitration boundaries** of asking —
  counted in boundaries, not cycles, so the check is wait-state independent) and
  T13 (every preempted beat returns its own data, in order).
  **Mutation-proven**: reinstating `force_owner` fails T12 (`MUT-2`); disabling
  the capture fails T13 and the soak with 39 failures (`MUT-3`).
- **Measured in the SoC:** longest DMA request-to-grant wait on a real
  instruction stream is **12–13 hclk**, and that bound is set by the AHB-to-APB
  bridge's data phase, not by arbitration.

### AHB-3 — an interrupted INCR burst reaches the slave as an orphan SEQ  ·  `SPEC` / `FIXED` · **Severity: medium**

- **Where:** spec §8.5 claims an interrupted I-Port burst "resumes later with a
  fresh NONSEQ". The frozen I-Port RTL does not do that:
  `garuda_iport_ahb_master` only re-arms `need_nonseq` on paths where it drives
  IDLE. Held by HREADY=0 it keeps presenting the same SEQ and re-presents it
  unchanged when re-granted.
- **Effect:** the slave side sees `NONSEQ(I) … NONSEQ(DMA) NONSEQ(DMA) … SEQ(I)`
  — a SEQ with no open burst. Harmless against a flat memory model; a
  mispredicted address on any slave that does burst-address prediction.
- **Resolution:** fixed in the interconnect rather than by touching the frozen
  core boundary. `seq_break_o` flags the first accepted transfer after the
  address-phase owner changes, and the master mux rewrites SEQ→NONSEQ for that
  one transfer. The rewrite is one-way and therefore always safe: NONSEQ is
  legal at any address.
- **Test:** T15 plus the slave-side protocol checker.
  **Mutation-proven**: removing the rewrite produces **79** `SEQ following a
  SINGLE burst` violations on the slave bus (`MUT-4`).

### AHB-4 — §7.3 applied to an idle master deadlocks the SoC  ·  `SPEC` / `FIXED` · **Severity: high (dead chip)**

- **Where:** spec §7.3, "a master that is not currently granted sees its
  `<m>hready` driven 0."
- **The defect:** `garuda_iport_ahb_master` issues an address phase only when
  `fetch_issue_o = ~redirect_i & i_hready_i & …` — it needs HREADY **high** to
  present HTRANS≠IDLE in the first place. The arbiter grants on HTRANS≠IDLE. So
  an ungranted I-Port cannot request, and a non-requesting master cannot be
  granted. Out of reset, with the grant parked anywhere but M0, the reset-vector
  fetch never happens and the SoC is dead with no error anywhere.
- **Resolution:** gate only what needs gating. A master is held only while it
  has something in flight to hold:
  `pending = (HTRANS is NONSEQ/SEQ) || (this master owns the data phase)`;
  a master with nothing pending sees HREADY=1 unconditionally. See
  `rtl/ahb/ahb_master_port.v`.
- **Test:** implicitly every test — nothing runs without it. Explicitly, T0's
  post-reset HREADY check and the SoC testbench booting at all.

### AHB-5 — spec §9.1's peripheral-access latency is optimistic  ·  `SPEC` / `OPEN (documentation)` · **Severity: low**

- §9.1 budgets "~3–4 core" cycles for a peripheral access via the bridge. Any
  bridge built on a two-phase toggle handshake across 200/100 MHz costs roughly
  2 hclk + 3 pclk + 2 hclk ≈ **10–12 hclk**; `tb/ahb/ahb2apb_bridge_model.v`
  measures 12–13. Not an RTL defect — the number in the specification should be
  corrected when Block 8 is specified, or the bridge needs write posting.

---

## 3. Block 9 — DMA controller

Specification: GARUDA-DMA-SPEC-001 Rev 2.0. RTL: `rtl/dma/`.
Full narrative in `docs/DMA_RTL_LOG.md`.

### DMA-1 — inconsistent SR snapshot across the clock-domain crossing  ·  `FIXED` · **Severity: high**

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

### DMA-2 — a write to any register of a channel swallowed that channel's CR.EN clear  ·  `FIXED` · **Severity: high**

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

### DMA-3 — an arm event delivered outside IDLE was silently discarded  ·  `FIXED` · **Severity: medium**

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

#### DMA-3a — two near-misses inside the fix itself

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

### DMA-4 — `SR.REMAINING` is unreliable across the TCR load  ·  `WAIVED` · **Severity: low**

`xfer_cnt` is loaded from TCR on entry to CONFIGURED — a multi-bit jump, across
which the gray code's one-bit-per-change guarantee does not hold. A read landing
in that ~2-pclk window can return a mixture. Accepted because §16.7 makes the
field advisory and closing it properly needs a full req/ack data handshake (~4×
the area, 6 instances) to harden a debug field. Firmware needing exactness must
read twice or use `SR.COMPLETE`.

### DMA-5 — `dma_cdc_pulse` merges events closer than ~3 destination clocks  ·  `WAIVED` · **Severity: low–medium**

Inherent to a two-phase toggle handshake. Every user in the block is checked
against it by protocol (APB writes are ≥2 pclk apart; the EN clear fires once
per completion). **Argued safe, not proven by test.** A future faster event
source needs a full req/ack handshake, not this primitive.

### DMA-6 — simultaneous W1C clear and flag set  ·  `WAIVED` · **Severity: medium**

Set-wins ordering is implemented (same shape as ERRATUM DSU-8 in
`rtl/dsu/overflow_flag.v`) but has **never been deterministically forced in
simulation**. Still open as a verification gap rather than a known defect.

### DMA spec defects — SPEC-1 … SPEC-12

Twelve contradictions, gaps and errata in GARUDA-DMA-SPEC-001 Rev 2.0, each
resolved on the record in `docs/DMA_RTL_LOG.md` §9.4. Summarised here because
four of them were latent failure modes the spec never addressed:

| ID | Class | One-line |
|---|---|---|
| SPEC-1 | contradiction | §7.4's 6-state AHB FSM table contradicts its own "Drives" column and §11.1's latency. READ_DATA and WRITE_ADDR merged. |
| SPEC-2 | contradiction | §6.5 vs §7.1 on TCR=0. Following §7.1 would decrement from 0, wrap to 0xFFFF and turn an empty descriptor into a **65,536-beat runaway**. |
| SPEC-3 | contradiction | §3.1 "re-evaluates every cycle" vs §2/§8.3 "after every beat". A mid-beat grant swing corrupts two transfers with **no status bit set anywhere**. |
| SPEC-4 | contradiction | §3.1 vs §7.5 on where SR lives. |
| SPEC-5 | **ambiguity with a latent hang** | §15.3's synchronised EN level alone cannot safely start a channel — EN has two writers in two domains. Rising-edge start hangs; level start re-runs the transfer. Resolved with an arm *event*. |
| SPEC-6 | gap | CIRC + bus error would hammer the faulting address forever. Guarded. |
| SPEC-7 | gap | CIRC + TCR=0 livelocks CONFIGURED→COMPLETE→CONFIGURED. Guarded. |
| SPEC-8 | gap | Reserved `CR.SIZE=2'b11` passed through gives HSIZE=3'b011 — **64-bit, illegal on a 32-bit bus**. Degraded to WORD in both the master and the address stepper, which must agree. |
| SPEC-9 | gap | §6.6 "writing 0 to EN while active is undefined". Defined as a clean abort at a **beat boundary only**. |
| SPEC-10 | **integration risk** | §5.3 never states that ERROR is the AMBA **two-cycle** response. The write-address cancel depends on it. Now normative in GARUDA-AHB-SPEC-001 §1.4. |
| SPEC-11 | doc erratum | §5.6 signal-count arithmetic wrong (73 not 71; 107 not 105; 212 not 210). |
| SPEC-12 | doc erratum | §15.1 says 960 register flops; actual is 558. |

---

## 4. Block 1 — RV32IM core

Found in prior sessions; listed here so the register is complete.

| ID | Status | Severity | One-line |
|---|---|---|---|
| I-1 | FIXED | high | A single `fetch_outstanding` flag fired one cycle early, sampling HRDATA during the **address** phase. Every instruction was paired with the previous bus cycle's data; the first fetch decoded as illegal and trapped on instruction one. AHB-Lite is pipelined — two flags are required, not one. |
| D-1 | FIXED | high | Same root cause on the D-port. **Every store wrote zero** (HWDATA collapsed when the pipeline advanced) and every load returned the previous bus cycle's data. |
| BUS-A | FIXED | medium | HBURST derived from the *current* HTRANS, so the opening beat of every burst declared SINGLE and each following beat declared INCR. 494 violations in one `add.hex` run. |
| BUS-B | FIXED | medium | A burst broken by a full prefetch buffer resumed with SEQ — a SEQ beat with no open burst. |
| BUS-C | FIXED | medium | On redirect the master retracted an already-presented address phase. **AHB-Lite has no cancel.** |
| BUS-D | FIXED | medium | Nothing enforced the 1 KB burst boundary. Harmless against a flat memory; a decode bug the moment a fabric exists — which it now does. |
| **CORE-1** | **FIXED** | medium (synthesis blocker) | `rtl/core/mem_wb_reg.v`, `ex_mem.v` and `if_id.v` all wrote `always @(posedge clk_i or negedge rst_n_i) … if (!rst_n_i \|\| flush_i)`. A **synchronous** signal in an **asynchronous** reset condition, not in the sensitivity list. Simulation treats `flush_i` as synchronous (correct); synthesis cannot tell, and Yosys 0.69 refused outright: `ERROR: Multiple edge sensitive events found for this signal!` on `mem_wb_reg.rd_o`. A tool that *accepts* it may infer flush as a second asynchronous reset — a functional difference in silicon, not a lint nit. **Fix:** keep the async reset, move the flush to `else if (flush_i)` with the same body. Priority is unchanged (reset, then flush, then stall). **Proven behaviour-preserving** by an old-vs-new equivalence testbench: both versions of all three registers driven from identical stimulus for 20,000 cycles, including flush and stall asserted together and async reset overlapping flush — **0 mismatches**. Unblocks full-SoC synthesis. |
| CORE-2 | OPEN | low | `garuda_core_top` and `csr_file` carry an unused parameter (Verilator `UNUSEDPARAM`). Cosmetic. |

---

## 5. Block 2 — DSU

Nine errata were found and fixed in prior sessions (see
`Design_Docs/DSU/DSU_Verification_reports/`), of which ERRATUM DSU-8 —
an overflow coinciding with its own clear being lost — is referenced by the DMA
RTL as the shape its W1C ordering avoids.

| ID | Status | Severity | One-line |
|---|---|---|---|
| **DSU-10** | **FIXED** | medium (synthesis blocker) | `rtl/dsu/mac_unit.v:43–44` connected `$signed(a0)` / `$signed(b0)` to `mult_16x16`'s ports. Yosys 0.69 aborted with an internal assertion: `Assert 'arg->is_signed == sig.as_wire()->is_signed' failed` (genrtlil.cc:2145). **The four casts were semantic no-ops** — `mult_16x16` already declares `input wire signed [15:0] a, b`, and a port connection's signedness is governed by the *formal*, not the actual, so the multiply was already signed with or without them. **Fix:** delete them. Icarus and Verilator both accept the casts, which is why this stayed invisible until the first full-SoC synthesis run. DSU block TB re-run after the change: 90/90 tests, 0 mismatches. Unblocks full-SoC synthesis. |

---

## 6. Testbench and toolchain defects

These are not RTL bugs. They are in the list because **every one of them
initially looked like an RTL bug**, and because two of them made a green
regression untrustworthy.

### TOOL-4 — Icarus silently ignores `$random`'s seed  ·  `FIXED` · **Severity: high (falsely reassuring)**

Icarus Verilog 14 accepts `$random(seed)` and **ignores the seed**. A 10-seed
sweep produced byte-identical stimulus and reported 10 passes — *one run counted
ten times*. Verified with a 6-line standalone case (all seeds →
`48, -99, -39, -9`). Replaced everywhere with an explicit 32-bit xorshift PRNG,
which also reproduces identically on any simulator — which matters for replaying
a failing seed under VCS.

> **This is the most dangerous entry in this document.** It did not produce a
> wrong answer; it produced a **falsely reassuring** one.

### TB-11 — the SoC/interconnect seed sweep was not varying the bus timing  ·  `FIXED` · **Severity: high (falsely reassuring)**

**New this session — TOOL-4 wearing different clothes, and worth the emphasis
because it recurred in code written by someone who had just read the TOOL-4
writeup.**

- **Symptom:** a `+SEED` sweep over `tb_soc_ahb` reported identical numbers for
  every seed (`longest DMA request-to-grant wait = 12 hclk`, same cycle count).
- **Root cause:** `ahb_lite_sram` seeded its PRNG from a **parameter**, fixed at
  elaboration. The `+SEED` plusarg was parsed and then never reached the slave
  models, so every run of a single build drew the same wait states. The stimulus
  varied; the *bus timing*, which is what actually finds interconnect bugs, did
  not.
- **Fix:** `seed_i` is now a runtime **input**, sampled out of reset, XORed with
  a per-instance parameter salt so four slaves in one testbench do not stall on
  the same cycles. The generator advances on every accepted transfer.
- **Evidence it works:** SoC cycle counts now move with the seed
  (5721 / 5743 / 5745 / 5789 / 5740), and the fix immediately exposed **14
  previously-hidden failures** in the interconnect regression (all of which were
  an over-tight testbench bound, TB-12).

### TB-12 — T12's DMA-grant bound was a statement about the slave, not the arbiter  ·  `FIXED` · **Severity: medium**

Once TB-11 was fixed, T12 began failing at `GWAIT=10`: "DMA granted after 14
cycles" against a hard-coded bound of 6. The DUT was correct — while HREADY is
low the bus is genuinely busy and the grant is *supposed* to be frozen. The
check was rewritten to count **arbitration boundaries** (accepted address
phases) rather than cycles, and asserts ≤2. That is wait-state independent and
says the thing that actually matters. It still catches `MUT-2`.

### TB-13 — an unconnected model input silently became X  ·  `FIXED` · **Severity: medium**

Adding `seed_i` to `ahb_lite_sram` left `u_dsram.seed_i` unconnected in
`tb_soc_ahb` (the edit pattern matched two of three instances). The PRNG went X,
`wcnt` went X, `HREADYOUT` went X, and the SoC hung — presenting as a DMA data
corruption with `0xXXXX0000` in memory. **Lesson:** Verilator's `PINMISSING` is
on by default and would have caught this in one second; testbench files should
be linted too, not just RTL.

### TB-14 — the slave model's error path jumped its own wait-state queue  ·  `FIXED` · **Severity: medium**

`ahb_lite_sram` tested `dp_err` before decrementing `wcnt`, so an errored access
with wait states started its ERROR response immediately and left `wcnt` non-zero
afterwards — pinning `HREADYOUT` low forever. Only visible at `GWAIT>0`
(T9/T9b failed on all 40 wait-state runs). Fixed by making the branch order
explicit: burn the wait states, *then* respond. The comment in the file now says
the ordering is load-bearing.

### TB-15 — the AHB protocol checker flags the AMBA-legal error cancel  ·  `OPEN (checker gap)` · **Severity: low**

`tb/ahb/ahb_lite_checker.v`'s `v_retract` counter fires on any NONSEQ/SEQ
withdrawn to IDLE while HREADY was low. ARM IHI 0033A §5.1.3 **permits** a
master to cancel the following transfer during an ERROR response, and
`dma_ahb_master` does exactly that — it is the whole mechanism behind the
write-address cancel. The checker does not exempt the case where the previous
cycle carried `HRESP=ERROR` with `HREADY=0`. Not hit in the tests run so far
(the DMA's error tests are at block level, where no checker is bound), but it
**will** produce a false positive the first time a SoC-level test injects a bus
error into a DMA read. **Fix:** exempt the retract when `p_hresp && !p_hready`.

### Earlier testbench bugs — TB-1 … TB-8

Eight defects from the DMA block-level bring-up, detailed in
`docs/DMA_RTL_LOG.md` §9.2. **Six of the eight are the same shape**: *the
testbench observing a fast hardware event through a slow APB read*. In a design
with a 200 MHz core domain and a 100 MHz config port, any check of the form
"poll a status register, then sample a counter" is racing the DUT by tens of
nanoseconds. Every such check was converted to sample on a hardware event.

| ID | One-line |
|---|---|
| TB-1 | `chk_eq` formals are `[63:0]`; Verilog evaluates argument expressions at the **formal's** width, so `~pat` inverted a 64-bit zero-extension. |
| TB-2 | A circular channel is free-running; by the time an APB read of SR completes, the next lap has already overwritten the buffer. |
| TB-3 | A TB watching a beat counter and then lowering a forced `dma_req` is always 1–2 beats late. |
| TB-4 | Precondition never established — arming crosses pclk→hclk through 3 flops plus a CONFIGURED cycle. |
| TB-5 | Sampled a counter *after* `wait_flag`, which polls over APB and returns up to ~9 hclk late. |
| TB-6 | Identical to TB-5; T7 was fixed and the fix was not propagated to T8. |
| TB-7 | Closing sample taken after `wait_flag` again, including the legitimate resumption. |
| TB-8 | A hierarchical reference cannot take a variable generate index. |

### Toolchain environment issues — TOOL-1, 2, 3, 5

| ID | One-line |
|---|---|
| TOOL-1 | `choco install iverilog` needs Administrator. Portable `oss-cad-suite` into the session scratchpad instead; nothing installed system-wide. |
| TOOL-2 | Verilator in the portable bundle has a baked-in absolute path — set `VERILATOR_ROOT`. Also: it needs `+incdir+path`, not `-I path`. |
| TOOL-3 | `yosys.exe` needs `oss-cad-suite/lib` **before** `bin` on PATH, with unix-style paths. |
| TOOL-5 | No Cadence/Synopsys/Vivado tools available. **The team flow is unexercised.** |
| TOOL-6 | *(new)* No RISC-V toolchain on this machine, so the SoC test program is built with the stopgap `tools/gen/mini_rv32_asm.py`. The `.S` is plain GNU as syntax and builds either way; delete the generated `.hex` once `sw/Makefile` can run. |

---

## 6.1 Mutation testing — do the tests actually catch the bugs?

A green regression proves nothing unless it goes red for the right reason. Every
fix in this document that is marked FIXED with a named mutation was reverted in
a scratch copy and the regression re-run.

| ID | Mutation | Result |
|---|---|---|
| MUT-1 | AHB-1: HWDATA muxed on `grant` (as spec §3.1 says) | **8 failures**, all T14 |
| MUT-2 | AHB-2: `force_owner` reinstated (spec §7.2 literally) | **1 failure**, T12 — DMA starved |
| MUT-3 | AHB-2: response hold disabled | **39 failures**, T13 and the soak |
| MUT-4 | AHB-3: SEQ→NONSEQ rewrite removed | slave-side checker: **79** `SEQ following a SINGLE burst` |
| MUT-5 | Data-phase select bypassed (use address-phase HSEL) | **394 failures** across T1, T13, T16 |
| MUT-6 | DMA-3: arm latch removed (pre-fix behaviour) | **10 failures**, T18 and T19 |
| MUT-7 | DMA-3a: `en_h` qualifier removed from the deferred start | **1 failure**, T20a |
| MUT-8a | DMA-3: WAITING abort-path clear removed | **PASSES — uncovered, and known to be redundant.** See DMA-3a. |
| MUT-8b | DMA-3a: COMPLETE decline-path clear removed | **1 failure**, T20a |
| MUT-9 | DMA-3: CIRC absorb removed | **1 failure**, T20b |

**9 of 10 caught**, each by the test that claims to cover it. MUT-8a is reported
as a miss rather than quietly dropped: the line it removes is genuinely
redundant today, the test that would have covered it was written and does not
discriminate, and that is stated in DMA-3a rather than papered over.

> **A note on the harness itself.** The first run of MUT-9 appeared to fail
> `T20a`, a test with CIRC disabled — which made no sense. The cause was a
> working-directory bug in the mutation script: MUT-9's tree was copied from
> MUT-8's already-mutated tree, so it carried both mutations. Two mutations at
> once is not a mutation test. The script now copies from the repository by
> absolute path. Worth recording because the wrong conclusion — "the CIRC absorb
> is covered" — was one shrug away from being written down as fact.

---

## 7. What this register does not contain

No entry here has been confirmed under the team's simulator (Xcelium/VCS), at
gate level, or with timing. Everything in sections 2–5 was found by Icarus
simulation, Verilator lint, Yosys synthesis and code review on one Windows
machine. In particular:

- **No CDC bug can be found by simulation.** The crossings in the DMA and the
  bridge model are correct *by inspection*; only STA with proper constraints
  proves they close. No SDC exists yet.
- **Coverage is still zero** across every block. Spec §14 (DMA) and §12 (AHB)
  both require it.
- **A green regression is evidence, not signoff** — TOOL-4 and TB-11 are in this
  document specifically to make that concrete.
