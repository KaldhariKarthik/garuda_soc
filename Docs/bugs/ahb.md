# Bugs: AHB-Lite interconnect (rtl/ahb)

Owner: Track A. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).
Priorities: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).

<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. Run `bugs.py check` before pushing. -->
| ID | Title | Status | Prio | Found-by | Found | Fixed-in | Regression test | Evidence | Formerly |
|---|---|---|---|---|---|---|---|---|---|
| TB-29 | An erroring transfer that also drew wait states ran its two ERROR cycles during the waits and then completed OKAY, so... | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L340 | - |
| AHB-1 | HWDATA follows the wrong master | FIXED | P1 | - | legacy | legacy | - | HISTORY_2026.md L415 | - |
| AHB-2 | the prescribed arbitration rule starves the DMA | FIXED | P1 | - | legacy | legacy | - | HISTORY_2026.md L436 | - |
| AHB-3 | an interrupted INCR burst reaches the slave as an orphan SEQ | FIXED | P2 | - | legacy | legacy | - | HISTORY_2026.md L491 | - |
| AHB-4 | §7.3 applied to an idle master deadlocks the SoC | FIXED | P1 | - | legacy | legacy | - | HISTORY_2026.md L510 | - |
| AHB-5 | spec §9.1's peripheral-access latency is optimistic | FIXED | P3 | - | legacy | legacy | - | HISTORY_2026.md L528 | - |
| AHB-6 | AHB spec and RTL header text disagree with the (consistent) RTL: [N-7.14] says hmaster_is_sba is registered into the data phase, [N-7.10] says the DMA has no Boot ROM path, ahb_interconnect.v says 3 masters | IN-PROGRESS | P3 | bus plan B1 A0 (spec vs RTL vs users) | 2026-10-13 | - | - | rtl/ahb/ahb_interconnect.v:11-16,283; rtl/mem/ahb_mem_slave_if.v:65,85; GARUDA-AHB-SPEC-001.md [N-7.10], [N-7.14] | - |
| AHB-7 | The AHB-2 response hold can capture an ERROR: if the grant moves during the first ERROR cycle, the owner (still presenting) sees HREADY low + ERROR for 2+ cycles and a replayed one-cycle completion; a master that cancels after the ERROR first cycle (legal AHB-Lite) then retracts a waited address phase on the slave bus | RULING-NEEDED | P3 | formal (bus plan B1 A2, ahb7_find, free masters) | 2026-10-13 | - | ahb/fv_ahb ahb7_find (xfail AHB-7); detectors a_held_resp_okay, a_master_err_shape | logs/ahb/evidence/AHB-7_formal.txt | - |
| TB-47 | tb/ahb/ahb_lite_sram.v drove HRESP = ERROR through the wait states before an ERROR (hresp_o = dp_err), an illegal AHB-Lite slave response; tb_ahb_interconnect still printed 802/0 | IN-PROGRESS | P3 | bound SVA a_master_err_shape / a_slave_err_shape (bus plan B1) | 2026-10-13 | - | ahb/ic ic_wait (+GRAND=1 +GWAIT=3) | logs/ahb/evidence/TB-47_before_after.txt | - |
| TB-13 | an unconnected model input silently became X | FIXED | P2 | - | legacy | legacy | - | HISTORY_2026.md L874 | - |
| TB-14 | the slave model's error path jumped its own wait-state queue | FIXED | P2 | - | legacy | legacy | - | HISTORY_2026.md L883 | - |
| TB-23 | viol() silently truncated its own messages | FIXED | P3 | - | legacy | legacy | - | HISTORY_2026.md L929 | - |

## Details

### TB-29

*From `Docs/BUGS.md` at b90b481, line 340, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **TB-29** | `rtl/ahb/ahb_mem_slave.v` (verification model) | FIXED | An erroring transfer that also drew wait states ran its two ERROR cycles during the waits and then completed OKAY, so with `+DWAIT`/`+IWAIT` a faulting access did not fault at all and `t_buserr` failed. The model now serves the waits first. The core's bus-error handling was correct; it had simply never been exercised under wait states. |

### AHB-1

*From `Docs/BUGS.md` at b90b481, line 415, section "AHB-1 — HWDATA follows the wrong master  ·  `SPEC` / `FIXED` · **Severity: high (silent data corruption)**".*

#### AHB-1 — HWDATA follows the wrong master  ·  `SPEC` / `FIXED` · **Severity: high (silent data corruption)**

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

### AHB-2

*From `Docs/BUGS.md` at b90b481, line 436, section "AHB-2 — the prescribed arbitration rule starves the DMA  ·  `SPEC` / `FIXED` · **Severity: high (real-time failure)**".*

#### AHB-2 — the prescribed arbitration rule starves the DMA  ·  `SPEC` / `FIXED` · **Severity: high (real-time failure)**

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

### AHB-3

*From `Docs/BUGS.md` at b90b481, line 491, section "AHB-3 — an interrupted INCR burst reaches the slave as an orphan SEQ  ·  `SPEC` / `FIXED` · **Severity: medium**".*

#### AHB-3 — an interrupted INCR burst reaches the slave as an orphan SEQ  ·  `SPEC` / `FIXED` · **Severity: medium**

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

### AHB-4

*From `Docs/BUGS.md` at b90b481, line 510, section "AHB-4 — §7.3 applied to an idle master deadlocks the SoC  ·  `SPEC` / `FIXED` · **Severity: high (dead chip)**".*

#### AHB-4 — §7.3 applied to an idle master deadlocks the SoC  ·  `SPEC` / `FIXED` · **Severity: high (dead chip)**

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

### AHB-5

*From `Docs/BUGS.md` at b90b481, line 528, section "AHB-5 — spec §9.1's peripheral-access latency is optimistic  ·  `SPEC` / `RESOLVED (documentation)` · **Severity: low**".*

#### AHB-5 — spec §9.1's peripheral-access latency is optimistic  ·  `SPEC` / `RESOLVED (documentation)` · **Severity: low**

- §9.1 budgets "~3–4 core" cycles for a peripheral access via the bridge. Any
  bridge built on a two-phase toggle handshake across 200/100 MHz costs roughly
  2 hclk + 3 pclk + 2 hclk ≈ **10–12 hclk**; `tb/ahb/ahb2apb_bridge_model.v`
  measures 12–13. Not an RTL defect — the number in the specification was wrong.
- **Resolved 2026-09-16** when Block 8 was specified. `GARUDA-BRG-SPEC-001` Rev 2.0
  §9.1 is now the authoritative figure and supersedes the TRM's loose wording:
  a base peripheral access is **≈6 pclk = 12 hclk ≈ 60 ns** with no wait-states,
  plus one pclk (2 hclk) per PREADY wait-state the peripheral inserts. That agrees
  with the 12–13 measured against the bridge model. The bridge spec states the
  TRM's "3–4 core cycle" wording is superseded and must not be used, and that no
  other block may re-count this latency. Write posting was considered and
  deliberately rejected (BRG §13.3) — it would break in-order two-cycle-ERROR
  reporting, which the DMA depends on.

---

### TB-13

*From `Docs/BUGS.md` at b90b481, line 874, section "TB-13 — an unconnected model input silently became X  ·  `FIXED` · **Severity: medium**".*

#### TB-13 — an unconnected model input silently became X  ·  `FIXED` · **Severity: medium**

Adding `seed_i` to `ahb_lite_sram` left `u_dsram.seed_i` unconnected in
`tb_soc_ahb` (the edit pattern matched two of three instances). The PRNG went X,
`wcnt` went X, `HREADYOUT` went X, and the SoC hung — presenting as a DMA data
corruption with `0xXXXX0000` in memory. **Lesson:** Verilator's `PINMISSING` is
on by default and would have caught this in one second; testbench files should
be linted too, not just RTL.

### TB-14

*From `Docs/BUGS.md` at b90b481, line 883, section "TB-14 — the slave model's error path jumped its own wait-state queue  ·  `FIXED` · **Severity: medium**".*

#### TB-14 — the slave model's error path jumped its own wait-state queue  ·  `FIXED` · **Severity: medium**

`ahb_lite_sram` tested `dp_err` before decrementing `wcnt`, so an errored access
with wait states started its ERROR response immediately and left `wcnt` non-zero
afterwards — pinning `HREADYOUT` low forever. Only visible at `GWAIT>0`
(T9/T9b failed on all 40 wait-state runs). Fixed by making the branch order
explicit: burn the wait states, *then* respond. The comment in the file now says
the ordering is load-bearing.

### TB-23

*From `Docs/BUGS.md` at b90b481, line 929, section "TB-23 — `viol()` silently truncated its own messages  ·  `FIXED 2026-10-03` · **Severity: low (misleading logs)**".*

#### TB-23 — `viol()` silently truncated its own messages  ·  `FIXED 2026-10-03` · **Severity: low (misleading logs)**

`ahb_lite_checker.v`'s `viol()` declared its argument `input [8*72-1:0] msg`.
A Verilog string argument narrower than the literal passed to it drops the
**leading** characters, with no warning. Three of the eighteen messages
overflowed 72 characters: the retract message printed as `ddress phase
RETRACTED…`, and the two-cycle-ERROR message lost **17** characters off the
front, so it began *"requires HRESP high for two…"* and named no rule at all.
Widened to 96. Found while building the TB-15 negative control, which printed
one of the three.

> Pre-existing ID collisions, noted but deliberately not renumbered because
> this file's own rule is never to renumber: `TOOL-5` names three unrelated
> defects and `TOOL-6` two. Cite either by description, not by number.

### AHB-6

Documentation only. Three statements were settled in bus plan B1 A0 by reading the spec, the RTL and the users:

1. **[N-7.14]** says `hmaster_is_sba_o` "carries the grant, registered into the data phase alongside the transfer, so the slave evaluates it in the same cycle as the write". The RTL drives it combinationally from the address-phase grant (`ahb_interconnect.v:283`). Its only user, `ahb_mem_slave_if.v:85`, combines it with the **address-phase** `hwrite_i` (`lock_write = hwrite_i && wr_lock_i && !lock_bypass_i`) and registers the decision into `dp_err`. So the RTL is consistent end to end, and the spec sentence describes a design that was not built. Fix: change [N-7.14] to "asserted while the address phase on the bus belongs to M2; the ISRAM slave samples it with the other address-phase signals". Property a_sba_ind checks the RTL behaviour.
2. **[N-7.10]** says "M3 (DMA) has no Boot ROM path". The interconnect is one shared layer decoded by address ([N-7.9] forbids structural restrictions), so the fabric does route DMA addresses in region 0x1 to the ROM. It's the DMA engine's own R-9 refusal that keeps the DMA out. Fix: reword as "the DMA does not address Boot ROM (DMA spec R-9 refuses SAR/DAR there); the fabric path exists". The ISRAM half is DMA-17.
3. **`ahb_interconnect.v:11-16`** header: "3 masters ... M2 DMA". Since Rev 4.0 there are 4 masters (M2 = debug SBA, M3 = DMA); the port list in the same file is already right.

### AHB-7

Found by SBY on 2026-10-13 (bus plan B1 A2): task `ahb7_find` (four free AHB-Lite masters, no FA-4), depth 6, master 0. Evidence `logs/ahb/evidence/AHB-7_formal.txt` + trace.

**Mechanism.**
1. The I-port's fetch is accepted (HREADY high), and the I-port keeps presenting its next fetch.
2. In the next cycle, ERROR cycle 1 (HREADY low), the arbiter's freeze `hold_r` is 0, because the previous cycle accepted. So the grant may move: the DMA requests and gets it.
3. In ERROR cycle 2 the I-port is presenting and not granted, so `ahb_master_port` captures the response: an **ERROR**.
4. The I-port sees HREADY low + ERROR in cycle 1 and again in cycle 2, then HREADY high + ERROR when it is next granted.

The header of `ahb_master_port.v` ("A capture can never coincide with an error completion ... the grant cannot have moved") misses that the grant can move in ERROR cycle 1.

**Effect.**
- A master sees an ERROR whose first cycle lasts two or more cycles, which is not a legal AHB-Lite response.
- If that master cancels its next transfer after the first ERROR cycle (AHB-Lite allows it), the cancel retracts an address phase that is waiting on the shared slave bus. The formal trace of `a_slave_addr_stable` shows this for the D-port.

**Today's chip: harmless.**
- The I-port never cancels: since BUS-C it holds a presented fetch until accepted, and it takes the fault on `data_phase_done` with the right PC.
- The D-port drives IDLE during its data phase, so it is never captured.
- The DMA is never preempted.
- So no functional failure today: P3, latent. It breaks a future master that cancels on ERROR, and any strict master-side ERROR-shape checker.

**Proposed fix (ruling).** Keep the grant on the data-phase owner from ERROR cycle 1, when that owner is presenting: `grant_o = (dph_valid && hresp_shared && !hready && owner_presenting) ? dph_master : (hold_r ? grant_r : winner)`.
- The owner then sees the real two-cycle ERROR, and its next transfer is accepted on ERROR cycle 2.
- A higher master waits one extra beat, only during an ERROR.
- It adds a path from HRESP into the grant mux, which needs timing review.
- Alternative: document the extended ERROR at the master ports and forbid cancel-on-error masters (spec note in AHB section 8.2).

Proof status: every property PROVEN under FA-4 ("a master that saw its own ERROR first cycle presents IDLE next cycle"). FA-4 is exactly the condition under which AHB-7 cannot occur.

### TB-47

Found 2026-10-13 when the new bound properties ran in Karthik's `tb_ahb_interconnect` with random waits (`+GRAND=1 +GWAIT=3`). `ahb_lite_sram.v` drove `hresp_o = dp_err` for the whole data phase of an erroring access, so the shared bus showed HREADY low + ERROR during every wait state before the real two-cycle ERROR. AHB-Lite reads HREADY low + ERROR as the ERROR first cycle, so the model was an illegal slave. Masters saw an ERROR first cycle lasting several cycles. `a_slave_err_shape` fired 4 times and `a_master_err_shape` 4 times, while the bench's own summary said "802 checks, 0 failures": `ahb_lite_checker` checks master behaviour, not slave responses. The design is not involved.

Fix (one line, Karthik's file): `assign hresp_o = dp_err && (wcnt == 8'd0);`. After the fix `ic` and `ic_wait` are clean. The new bound property `a_slave_err_shape` checks every slave's ERROR shape in every bench and chip run from now on.


**AHB-6 fix, 2026-10-14 (doc/comment only, made in Track A):** [N-7.10] and [N-7.14] of `GARUDA-AHB-SPEC-001.md` are rewritten as described above, and the port table points to [N-7.14]. The `ahb_interconnect.v` header lists the 4 masters. The `.docx` is regenerated. No logic change.
