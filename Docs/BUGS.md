# GARUDA SoC — bug register

**Every bug, erratum and specification defect found in this project, in one place.**
Not per-block: a bug that crosses a boundary belongs in one list, and the
cross-block ones are the expensive ones.

Last updated: 2026-09-26 (doc-vs-RTL audit, §1d) · Covers Blocks 1 (core), 2 (DSU), 6 (interconnect),
9 (DMA), plus toolchain and testbench defects.

Specification-only entries now also reach blocks that have no RTL yet: the
Rev 2.0 documents for Blocks 3/4/5 (memory), 8 (bridge), 16 (CLIC) and 22/23
(clock/reset) resolved **AHB-5** and raised the cross-document defect recorded
in `docs/DECISIONS.md` (D-1). A spec defect found before the RTL exists is the
cheapest one this project will ever fix.

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
| 8 — AHB-to-APB bridge | 0 | 0 | 0 | 1 |
| 9 — DMA controller | 3 | 0 | 3 | 12 |
| 3/4/5 — Memory subsystem | 0 | 0 | 0 | 1 |
| 16 — CLIC | 1 | 0 | 0 | 0 |
| 22/23 — Clock and reset | 0 | 0 | 0 | 1 |
| Testbench / toolchain | 18 | 0 | 1 | — |

Blocks 8, 16 and 22/23 and the memory subsystem list **zero RTL defects**, and
that row should be read carefully. Their RTL was written on 2026-09-16 and now
compiles, simulates (1,007 checks, 0 failures across six testbenches) and
synthesises with zero latches — so the row is no longer "unproven". But it was
verified under Icarus and Yosys only, never Xcelium, with no gate-level, coverage
or timing, and by testbenches written by the same author at the same sitting as
the RTL. Their spec-defect counts (BRG-1, CRG-1, and D-1 for the memories) are
real findings from implementing the documents. Read the row as "passes its own
tests", not "verified".

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

## 1b. Rev 4.0 migration — 2026-09-19

Found or closed while bringing the RTL to the Rev 4.0 set (`Docs/DECISIONS.md`
D-4..D-20). Every FIXED entry has a test that fails without the fix; the two
marked *proved* were re-run against the reverted RTL to show it.

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| **OVF-1** | 2 DSU | FIXED | high (wrong overflow flag, top quarter of range) | 48-bit carry-save path dropped `maj[47]`; the adder's bit 48 carried no sign. Path widened to 49 bits, operands sign-extended before compression; `DSUModel` updated. Was open since `Docs/ORACLES.md` found it and missing from this register. Closes OPEN-9. | ArchDSU oracle sweep | `test_dsu` + clamp walk 33 168/0; oracle sweep 0/2000 at every magnitude (was 845–1023/2000) |
| **T-8** | 1 core | FIXED, *proved* | medium (core sleeps forever) | `wfi_active` cleared only on a CLIC wake while `wfi_hold` released on CLIC **or** timer: after a timer-only WFI wake, clearing MTIP re-froze the pipeline. | RTL audit | `t_mtip` (sanity); fails with the old term |
| **C-5** | 1 core | FIXED | medium (undefined bus traffic) | Reserved funct3 of JALR/BRANCH/LOAD/STORE, SYSTEM funct3=100 and non-architectural funct3=000 SYSTEM words decoded as legal: silent NOPs, not-taken branches, HSIZE=64-bit on AHB. Now illegal-instruction, as Spike. | RTL audit | `test_decode_control`, `test_id_stage` (models updated), ISA 63/63 |
| **CORE-3** | 1 core | FIXED | low | `RESET_VECTOR` parameter ignored (`garuda_pc_gen` hard-coded it). | RTL audit | chip tests boot from the parameter |
| **CRG-2** | 22 reset | FIXED | medium (glitch on an async clear) | Rev 2.0 `reset_ctrl` drove an async clear from combinational logic. Rewritten: every async clear comes from a flop. | RTL audit | `tb_crg` 43/43 |
| **DMA-7** | 9 DMA | FIXED (by design) | medium | Rev 2.0 `dma_ack` was one hclk wide; a pclk peripheral could miss it. Now one pclk period (D-16). | RTL audit | `tb_dma_top` P2M handshake |
| **ENG-1** | 9 DMA | FIXED | medium (duplicate beat) | New engine regranted in the cycle before the channel had decremented REMAINING. Caught during design, guarded in `dma_engine.v`. | review | `tb_dma_top` one-ack-per-request |
| OPEN-8 | 1 core | CLOSED — not a bug | — | `t_clic` TIMEOUT was the sanity runner's 50 k-cycle budget; the test is interrupt-bound (IRQ every 40 cycles) and needs ~60 k. `run_sanity.sh` default is now 200 k. | re-run | sanity 10/10 |
| TB-15 | TB | MOOT | — | The Rev 3.0 DMA never has a second transfer queued when an ERROR returns, so the error-cancel case the checker mis-flags cannot occur; `tb_dma_top` now binds the checker and it is clean. The checker gap itself remains for any future pipelined master. | — | `tb_dma_top` |
| DMA-4/5/6 | 9 DMA | MOOT | — | All three were properties of the deleted CDC / Rev 2.x register bank. | — | — |
| ELEM-1..6 | TB | OPEN (testbench) | low | First-ever run of the 14 per-element TBs (Sep 2): 8 pass. `pc_gen` scoreboard samples one cycle late (its own SVA on the RTL passes); `prefetch_buffer` stimulus overfills the FIFO, violating the I-port slot-reservation contract; `iport` SVA encodes the pre-BUS-A HBURST; `load_store_unit` TB has a SystemVerilog syntax error (line 114); `if_stage_top`, `mem_stage` not yet triaged. The RTL they target is covered by ISA 63/63 lockstep incl. random waits. | `make test_elements` | owner: element-TB author |

Spec defects resolved by ruling rather than RTL are D-5..D-20 in `Docs/DECISIONS.md`.

---

## 1c. Peripherals — vendored IP and wrappers, 2026-09-22/23

Found while adapting the open-source peripheral IP (D-22). The `ERR-*` entries are **defects in third-party RTL**. The default is to route
around them in the GARUDA wrapper and leave upstream untouched; ERR-U2 is the
one case where that was impossible, and it is fixed by a recorded patch under
`<ip>/patches/` (D-24). Either way each entry records what a future re-vendor
must re-check, and which test would fail if the behaviour changed silently.

| ID | Block | Status | Severity | Summary | Found by | Test |
|---|---|---|---|---|---|---|
| **SPIM-1** | 13 SPI | FIXED | **high** (every read returns zero) | Our wrapper connected MISO to the vendored engine's `spi_sdi0`. Upstream's lanes are quad-SPI pads: single-bit mode drives IO0 (`sdo0` = MOSI) and shifts in **IO1** (`data_int_next = {data_int[30:0], sdi1}`). Nothing complained — chip select, SCLK, command and address were all correct on the wire and the flash returned the right bytes; only the data read back as zero. Ruling D-23 came out of this. | `tb_spim` byte compare | `t_spim_flash_read`; 11 register-level checks passed *with the bug present* |
| **UART-1** | 16/17/18 | FIXED | **high** (every read off by one byte, for ever) | `garuda_apb_shim`'s pad synchronisers reset to 0. An idle serial line is **high**, so out of reset the receiver saw a start bit, framed a garbage byte, and left it at the head of the RX FIFO — after which every `RBR` read returned the previous byte. Shim gained `SYNC_RESET`; the UART passes 1. | `tb_uart` RX mismatch | `t_uart_rxidle`, and the loopback tests that failed without it |
| **ERR-U1** | 16/17/18 | WORKED AROUND | medium (wrong interrupt source) | `apb_uart.sv` wires its interrupt unit's receiver-data-available input to the wrong flag: `.RDA_i(regs_n[LSR][5])` is `THRE`, the **transmit** FIFO empty bit, where `regs_n[LSR][0]` (`DR`) belongs. With `IER[0]` set a 16550 driver takes an "RX data available" interrupt whenever the transmitter drains. Compounded: `trigger_level_reached` compares with `==` not `>=`, and `CTI_i` is tied to 0. | reading upstream per D-23 | wrapper leaves `event_o` unconnected and derives all events from `LSR` ([N-7.5]); `t_uart_irq` |
| **ERR-U2** | 16/17/18 | **FIXED** (vendored patch 0001) | medium (silent data corruption) | Parity errors could never be reported, two independent ways. (1) `apb_uart.sv` tied `uart_rx.err_clr_i` to `1'b1`; the flop is `if (err_clr_i) err_o<=0; else if (set_error) err_o<=1;` so `set_error` was unreachable and `err_o` constant 0. (2) `uart_rx` pushed the byte to the FIFO in `SAVE_DATA` and only *then* entered `PARITY`, so the stored flag could never describe its own byte. Stop bits were never checked at all and `LSR[3]` was never driven. **Fixed in the vendored RTL** — the only case so far where a wrapper could not do it, because the wrapper sees only the APB side and the raw `rx` pin. Push moved into the `STOP_BIT` `bit_done` cycle (not a later state: `s_rx_fall` is true for one clock, so an extra state misses a no-gap frame's start bit), error outputs made combinational so they are valid in the capture cycle, stop bit checked, RX FIFO 9→10 bits, `err_clr_i` driven from the push. R-7 now met. | reading upstream per D-23 | `t_uart_parity`, framing equivalents, no-leak-to-next-byte, and 16 back-to-back frames with no gap |
| **ERR-U3** | 16/17/18 | **FIXED** (vendored patch 0001) | medium (24 latches in the chip) | `apb_uart.sv` gave `fifo_tx_data` no default in the register-write `always_comb` — it was assigned only inside the `THR` branch — so synthesis inferred an 8-bit **latch** per instance, 24 across GARUDA's three UARTs, against a budget of one (the intended ICG). Functionally harmless: the TX FIFO samples the bus only when `fifo_tx_valid` is high, which is exactly when the branch assigns it. Physically not harmless — latches break scan insertion and need constraining by hand at STA. Fixed with a default assignment; the branch keeps its own, so behaviour is identical by inspection. | `make synth` — **not** by any simulation | `make synth`: 25 latches before, 1 after |
| **UART-2** | 16/17/18 | DOCUMENTED | low | `MCR` (0x10), `MSR` (0x18) and `SCR` (0x1C) are not implemented upstream at all — no write case, no read case, they fall to `default`. They decode without `PSLVERR` and read 0. `SCR` in particular is not a usable scratch register. | `tb_uart` | `t_uart_wordmap` asserts they read 0 |
| **I2C-1** | 15 I2C | AVOIDED (by design) | **high** (garbage on a shared bus) | The obvious way to abort a stuck I2C transfer is to drop the vendored core's `ena`. That is actively dangerous: the bit controller's divider is `else if (~\|cnt \|\| !ena \|\| scl_sync) begin cnt <= clk_cnt; clk_en <= 1; end`, so with `ena` low `clk_en` asserts **every cycle** and the bit state machine free-runs at `pclk` instead of 4x SCL — sprinting through the rest of the transfer and toggling SCL/SDA at 125 MHz on a bus shared with other devices. Its FSM returns to idle only on `!nReset` or arbitration loss. `garuda_i2c_top` therefore ties `ena` high and aborts via `nReset` (from a flop, per CRG-2), which also makes `CTRL.EN = 0` a held-in-reset state rather than a free-running one. | reading upstream per D-23, **before** writing the abort | `t_i2c_stretch` (timeout abort), `t_i2c_never_drives_high` |
| **GPIO-1** | 19 GPIO | SPEC CORRECTED | low | The first draft of GARUDA-GPIO-SPEC-001 said upstream's `interrupt` was a read-to-clear **level**, so clearing `IRQSTAT` alone would not drop the line. It is a one-cycle **pulse** (`assign interrupt = \|s_is_int_all`, a combinational edge detect); `INTSTATUS` is the separate per-pin sticky record. The sticky tail is therefore doing real work — without it a GPIO interrupt would be one `pclk` wide and the CLIC would miss it. Spec and test corrected to match the RTL. | `t_gpio_irq` failing | `t_gpio_irq`, `t_gpio_irq_cause` |
| **TB-16** | TB | FIXED | — (lost time) | Three testbench defects of the same family, all of which first looked like RTL bugs. (a) `tb_uart` ran both `fork` branches over the **same module-level loop index**, so the back-to-back test compared nonsense and reported "index 16" of a 16-iteration loop. (b) `tb_pwm` read `width[]` in the same delta its monitor wrote it, so every check saw the *previous* pulse. (c) `tb_i2c`'s SDA-stability checker flagged legal traffic because it asked "did SDA move during the high phase" instead of the actual I2C rule, "is the value at the rising edge still there at the falling edge". Recorded because in each case the first instinct was to go and change working RTL. | the tests themselves | all three now pass |
| **TOOL-5** | build | FIXED | low | Two vendored IPs in one elaboration passed `-timescale` twice and `xrun` failed `*E,OPTNOML`. The option is now in `rtl/third_party/timescale.f`, included once by each top-level filelist and never by a per-IP one. | `make test_chip_uart` | every chip target |

---

## 1d. Doc-vs-RTL audit — 2026-09-26

A full comparison of `Design_Docs/` against `rtl/`, prompted by the docs having
moved on 2026-09-22 (ADR-0002 Rev 2, ADR-0020 Rev 2) without the RTL following.
Findings go **both** ways, which is the point of doing it as an audit rather
than a patch-up.

| ID | Where | Status | Summary |
|---|---|---|---|
| **AUD-1** | `garuda_system.yaml` | FIXED | The SSOT's `blocks:` table described a chip from three weeks ago: **ten blocks marked `rtl: missing` that all exist** (isram, bootrom, dsram, apb_fabric, ahb2apb, clic, timers, debug, clk_div, reset_ctrl) and **seven marked `rtl: sourced_ip` that are all implemented**. Block 14 still said "dropped for pin budget" after ADR-0020 Rev 2 restored it. Every document calls this file normative. `tools/garuda_gen.py` does not read `blocks:`, which is why nothing caught it. |
| **AUD-2** | AHB2APB §6 + 4 specs | FIXED | **Two incompatible window numberings.** The AHB2APB window table was 0-based (`window 0 = 0x4000_1000`); the RTL decodes `win = haddr[15:12]`, so window *n* is at `0x4000_0000 + 0x1000n` — 1-based. DMA, CLIC, TIMERS and CLKRST each inherited the error and stated a window one lower than the hardware's. Base addresses were right everywhere; only the index was wrong. CLIC's "window 9" was `reset_ctrl`'s. |
| **AUD-3** | `dma_apb_slave.v`, `timers_apb.v` | **OPEN** (DMA OPEN-D1, TIMERS OPEN-T1) | Both are clocked **entirely by hclk**, while ADR-0002 Rev 2, `apb.clock: pclk` and both specs' §4/§5 say the APB side is pclk. `dma_top` even takes `pclk_i`/`preset_n_i` and discards them. Not a functional bug — pclk edges are a subset of hclk edges (D-5) — but PRDATA is combinational out of hclk registers, so it can move mid-access and the bridge's effective setup window is **4 ns, not 8**; and these flops run at 250 MHz, which is the power ADR-0002 Rev 2 restored pclk to save. Headers now state the gap instead of claiming pclk. **Decide before STA.** |
| **AUD-4** | PHYS §5 SDC | **OPEN** ([N-5.3]) | The SDC sketch will not elaborate: it constrains `[get_ports refclk_i]` (the pin is `refclk`), and `u_clk_div/u_clkdiv_toggle_hclk/Q` and `..._pclk/Q` (the flops are `t1_q` and `pclk_q`). Substantively, it declares a fixed `-divide_by 2` while `clk_div` implements a **selectable** ÷2/÷4/÷8/÷16 mux — and ADR-0001 makes ÷4 the timing fallback, so the other ratios need constraining too. `aon_clk` (D-14) is absent entirely. |
| **AUD-5** | MEM §8.3, §8.5 | FIXED | Boot-time and ROM estimates predated a working boot path. §8.6 assumed 32 SCLK per word; it is **64** (command + address precede every word), so a 64 KiB image is **~67 ms, not 26**. The ROM is **820 bytes**, not ~500. Both now carry the measured figures. [N-8.7]'s "no document has verified the sourced IP" is also stale — GARUDA-SPIM-SPEC-001 now does. |
| **AUD-6** | `ahb_interconnect.v`, `mul32.v` | FIXED | Comments still described the pre-ADR-0001 clock plan — "one 200 MHz domain", "200/100 MHz crossing", "TRM 100 MHz clock". The plan has been 500 → 250 → 125 since ADR-0001. |
| **AUD-7** | `garuda_soc_top.v` | FIXED | `dma_req_i[4]` was commented "ch4 is spare", citing DMA [N-6.4] — which now says the opposite: channel 4 serves the SPI slave and is **required** (ADR-0020 Rev 2). The tie-off itself is still correct because `rtl/spi_slave/` does not exist; the comment now says that, and names un-tying it as the work item. |

**What the audit did not find:** every register offset checked (DMA `GSTAT`,
CLIC `CLICINFO`/`CLICIE`/`CLICIP`) matches its spec; every spec revision cited
in an RTL header matches the document's actual revision; the 26 chip pins match
PHYS §3.1 name for name; and `tools/garuda_gen.py --check` is clean, so the
address map and CLIC IDs in RTL and C agree with the yaml.

**The pattern worth remembering:** the two errors that survived longest
(AUD-1, AUD-2) were both in places nothing executes — a table the generator
does not read, and a column of index numbers. Everything the toolchain touches
was correct.

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

### AHB-5 — spec §9.1's peripheral-access latency is optimistic  ·  `SPEC` / `RESOLVED (documentation)` · **Severity: low**

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

## 2b. Blocks 8 / 22 / 23 — found while writing the RTL, 2026-09-16

Specifications: `GARUDA-BRG-SPEC-001` Rev 2.0, `GARUDA-CRG-SPEC-001` Rev 2.0.
RTL: `rtl/ahb2apb/`, `rtl/clk_div/`, `rtl/reset_ctrl/`.
Narrative: `docs/RTL_LOG_2026-09-16.md`.

BRG-1 and CRG-1 are defects in the **specification**, found by implementing it.
The RTL as written does not contain them, and both have a passing test that
exercises the fix — `tb_ahb2apb` T8 for BRG-1 and `tb_crg` T9 for CRG-1.

CLIC-1 is different in kind: a defect in the **RTL**, found by Verilator lint
after the block was already written, simulating and synthesising. It is the only
RTL defect in the new blocks found by a tool rather than by reading.

### BRG-1 — "accepts only from H_IDLE" silently drops every second back-to-back access · `SPEC` / `FIXED IN RTL` · **Severity: high (silent data loss)**

- **Where:** bridge spec §7.5; RTL `rtl/ahb2apb/ahb2apb_hclk_fsm.v`.
- **The defect:** §7.5 states "the bridge accepts a new transaction only from
  H_IDLE". But `H_RESP_OKAY` and `H_ERROR_2` both drive `HREADYOUT` **high** —
  they must, that is how the transfer completes — and a high HREADY is by
  definition the condition under which the master's next address phase *is
  accepted*, in that same cycle. A bridge that latched only from `H_IDLE` would
  let the master consider the transfer accepted and move on while the bridge
  ignored it.
- **Failure mode:** the access never reaches APB. HREADYOUT stays high, no error
  is raised anywhere, and the master gets stale or zero read data. Firmware
  configuring a peripheral with a run of consecutive stores — which is exactly
  how the DMA and the CLIC get programmed at boot — would lose every second
  write. A half-configured DMA channel is a transfer that silently does the
  wrong thing.
- **Fix:** acceptance is qualified on `hreadyout_o` being high rather than on
  one state, so `H_IDLE`, `H_RESP_OKAY` and `H_ERROR_2` all accept.
  `rtl/ahb/ahb_default_slave.v` already reasons this way for the identical
  reason ("S_ERR2 can accept a new transfer directly"), so the bridge is now
  consistent with the block beside it.
- **Test:** `tb/ahb2apb/tb_ahb2apb.sv` T8 — issues 8 back-to-back transfers and
  requires the APB slave model's own access counter to read 8. Counting at the
  far side is the point: a dropped transfer is invisible from the AHB side.
- **Spec action:** §7.5 should read "only states asserting HREADYOUT accept
  work", which is the property actually intended.

### CRG-1 — a one-cycle watchdog pulse asserts the whole-chip reset for 5 ns · `SPEC` / `FIXED IN RTL` · **Severity: medium**

- **Where:** CRG spec §7.1; RTL `rtl/reset_ctrl/reset_ctrl.v`.
- **The defect:** §7.1 combines the sources as a bare term — `rst_n_qual` low
  when `por_n_i` is low **or** `wdt_reset_i` is high. Taken literally with the
  one-cycle watchdog pulse Block 19 produces, the entire chip's reset asserts
  for exactly one hclk period (5 ns) and then releases.
- **Failure mode:** too narrow to rely on. Reset is distributed through a
  buffered tree across a 1.45 mm die; a 5 ns pulse can arrive degraded or, after
  tree insertion-delay skew, fail to overlap at every leaf. The result is a
  *partial* reset — some flops cleared, some not — which is indistinguishable
  from corrupted state and would be blamed on anything but the reset controller.
- **Fix:** the watchdog request is stretched to `WDT_STRETCH` (default 16) hclk
  cycles. POR is untouched and remains fully asynchronous with no minimum width,
  because it arrives from outside and is already wide. The stretch counter is
  reset by `por_n_i` **only**, never by its own output — a counter cleared by
  the reset it generates would truncate its own pulse.
- **Test:** `tb/clk_div/tb_crg.sv` T9 — drives a single-cycle `wdt_reset_i` and
  requires the reset to be held materially longer than one cycle, then requires
  the chip to leave reset rather than latch in it.
- **Spec action:** §7.1 should specify a minimum assertion width.

### CLIC-1 — 32-entry arrays indexed with a 10-bit index · `FIXED` · **Severity: low (latent)**

- **Where:** `rtl/clic/clic_apb_regs.v`, ten index sites (lines 143–150 write
  path, 166–172 read mux).
- **The defect:** `ie_q`, `trig_q`, `shv_q`, `lvl_q`, `ip_w1c_q` and `ip_i` all
  hold `CLIC_N` = 32 entries and need a 5-bit index, but were indexed with
  `idx[9:0]` — the full 10-bit APB register offset. Verilator:
  `WIDTHTRUNC: Bit extraction of var[31:0] requires 5 bit index, not 10 bits`,
  at every one of the ten sites.
- **Why it was harmless in practice, and why it still matters:** `idx_ok`
  (`idx < CLIC_N`) gates every write and the read mux, so an out-of-range index
  never reaches an array in the current design. The truncation is therefore
  latent rather than active — but it is exactly the construct that turns into a
  silent aliasing bug the moment `CLIC_N` changes or the qualification is
  restructured, and it is the kind of thing a reader has to re-derive `idx_ok`
  to convince themselves about.
- **Fix:** added `IDX_W = $clog2(CLIC_N)` and `aidx = idx[IDX_W-1:0]`, used for
  array indexing only. `idx` deliberately stays 10 bits wide because the range
  check needs the full offset — narrowing it *there* would fold a stray address
  onto a live source, which is the precise failure `idx_ok` exists to prevent.
  No architectural or behavioural change.
- **Confirmed:** `WIDTHTRUNC` 7+ → **0**; `tb_clic` 33/33 with 0 failures;
  `clic_top` synthesis 3,449 → **3,322** cells (the narrower index removes
  width-extension logic), 0 latches; full regression still 1,007 / 0.
- **How it was found, and the process defect behind it:** only after two earlier
  Verilator attempts had aborted and been *misreported as clean*. The working
  invocation was already documented in this register as **TOOL-2**
  (`VERILATOR_ROOT`, and `+incdir+path` not `-I path`) and was not consulted.
  The register had the answer; nobody read it.

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

### TB-16 — the clock-alignment monitor raced the clock it was monitoring  ·  `FIXED` · **Severity: medium (falsely alarming)**

- **Where:** `tb/clk_div/tb_crg.sv`, edge-alignment monitor.
- **Symptom:** three failures against a divider that was behaving perfectly,
  all in fallback mode.
- **Root cause:** the check asked "was the last hclk rise at the same `$time` as
  this pclk rise?", comparing a timestamp written by one `always @(posedge)`
  block from inside another. Two always blocks woken by the same edge run in an
  arbitrary order, so the hclk block had often not written its timestamp yet.
  In **fallback that is guaranteed**, because hclk and pclk are then literally
  the same net and both blocks wake on the identical event.
- **Fix:** sample the hclk *level* 10 ps after the pclk edge instead. No
  ordering dependency: if the edges coincide, hclk is high, in both modes.
- **Lesson:** an event-ordering comparison between two always blocks is not a
  measurement, it is a race. Sample a level at a defined offset.

### TB-17 — a reset check written as absolute-time modulo  ·  `FIXED` · **Severity: low**

- **Where:** `tb/clk_div/tb_crg.sv` T8.
- **Root cause:** "hreset_n de-asserts on an hclk edge" was checked as
  `($time % hclk_period) == 0`. That assumes clock edges fall on exact multiples
  of absolute zero, so any earlier test that offsets time by a sub-period amount
  (T7 did, by 100 ps) breaks it for the rest of the run.
- **Fix:** check the property that actually matters — that release is *delayed*
  by the synchroniser depth, at least two hclk edges after the source released.

### TB-18 — the watchdog test armed its wait after the event  ·  `FIXED` · **Severity: high (test hung)**

- **Where:** `tb/clk_div/tb_crg.sv` T9. Symptom: the whole testbench **hung** and
  hit its 50 µs timeout.
- **Root cause:** `wdt_reset` was driven, and only *then* did the test
  `@(negedge hreset_n)`. But `hreset_n` drops combinationally the instant
  `wdt_reset_i` rises, so the edge had already happened; the wait then blocked
  forever on a second falling edge that never came.
- **Fix:** `fork` the wait so it is armed before the stimulus is driven.
- **Lesson:** for any signal that responds combinationally to stimulus, arm the
  wait first. "Drive, then wait" only works across a clock edge.

### TB-19 — an APB monitor check that is invalid for a shared-PENABLE bus  ·  `FIXED` · **Severity: medium (falsely alarming)**

- **Where:** `tb/ahb2apb/apb_slave_model.v`.
- **Symptom:** 25 `[APB-PROTO] PENABLE without PSEL` violations and two failed
  checks, against a bridge whose APB signalling was correct.
- **Root cause:** the model flagged `PENABLE && !PSEL`. APB fans out a **shared**
  PENABLE and selects peripherals with a per-slave PSEL, so during an access to
  window 9 the window 5 model legitimately sees PENABLE high with its own PSEL
  low. A real slave ignores PENABLE unless its PSEL is asserted.
- **Fix:** check removed; the valid "PENABLE in the same cycle PSEL rises" check
  is retained.
- **Lesson:** this is the TB-15 shape again. A monitor that cries wolf on legal
  traffic is worse than no monitor, because the next real violation lands in a
  log everyone has learned to ignore.

### TB-20 — CLIC latency sampled one edge early, and a stale source left asserted  ·  `FIXED` · **Severity: medium (falsely alarming)**

- **Where:** `tb/clic/tb_clic.sv` T4/T5/T7/T12. Seven failures against correct RTL.
- **Root causes, three of them:**
  1. Latency was sampled one clk edge early. Spec §9.1 budgets one clk from
     *pending* to `clic_irq` — but pending is itself registered, so from the
     source **line** rising it is two edges. Confirmed with a directed probe:
     `ip` sets at edge 1, the winner register and `clic_irq` follow at edge 2.
  2. T7 acknowledged a level source while its line was still high, then expected
     a different winner. Re-firing is *correct* behaviour (§8.4) — the test was
     asserting the opposite of the specification.
  3. T12 never cleared `irq_src[3]` from T4, so a level-4 source outranked the
     level-2 source under test and kept the request asserted.
- **Fix:** sample after two edges, clear the source before acknowledging, and
  clear all sources before the enable/disable test.

### TB-21 — the SoC interrupt check asserted behaviour the firmware had disabled  ·  `FIXED` · **Severity: medium (falsely alarming)**

- **Where:** `tb/soc/tb_soc_ahb.sv`, interrupt-path check. Failed **twice**, in
  two different forms, against correct RTL.
- **First form:** sampled `dma_irq[0]` and the CLIC pending bit at the END of the
  run — a point sample of a transient. The firmware polls `SR.COMPLETE` and then
  W1C-clears it, which drops `dma_irq[0]` long before the check runs. Replaced
  with sticky observers.
- **Second form, the real one:** with sticky observers the check *still* failed,
  which proved `dma_irq[0]` was never high at any point. Cause:
  `soc_dma_smoke.S` programs CR with **IE=0 and EIE=0** — stated plainly in its
  own header — because it was written before the CLIC existed and polls instead.
  `dma_irq[n]` is raised only when `SR.COMPLETE` is set **and** `CR.IE=1`, so the
  DMA was correct to raise nothing. The testbench was asserting that hardware
  should do something the software had explicitly switched off.
- **Fix:** assert the correct behaviour (no interrupt raised, no CLIC source
  pending) and add a **continuous** monitor that the DMA's 12 lines equal CLIC
  sources [11:0] every cycle — which proves the wiring without needing an
  interrupt to fire.
- **Coverage gap this exposed, and it is real:** the DMA→CLIC→core interrupt
  path is wired and structurally checked but **never fires in any test**.
  Exercising it end to end needs a boot image with `CR.IE=1`, a CLIC level
  programmed over APB, and an ISR. That test does not exist yet and is the
  single most obvious next thing to write.
- **Lesson:** before asserting that hardware did something, check that the
  software asked it to.

### TOOL-5 — the static checker reported success having checked nothing  ·  `FIXED` · **Severity: high (falsely reassuring)**

- **Where:** the ad-hoc elaboration checker used while no simulator was
  available (`scripts/`-adjacent, session tooling).
- **Symptom:** "0 errors, 0 warnings" on its first run, with no output at all —
  indistinguishable from "matched nothing".
- **Root cause:** the instantiation regex matched nothing on the first attempt,
  and a checker that checks nothing reports a clean run.
- **Fix:** it now counts the instantiations it cross-checked and **exits
  non-zero if that count is zero**, and it was validated against deliberately
  corrupted copies (a mistyped port, a missing module, an undefined macro)
  before any of its results were believed.
- **Lesson:** this is **TOOL-4 and TB-11 wearing a third set of clothes**. Any
  check that can pass by doing nothing must report how much it did. Three
  separate instances of this failure mode are now in this register; it is the
  single most recurrent defect class in the project.

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
