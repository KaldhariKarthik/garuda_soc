# GARUDA SoC — bug register

**Every bug, erratum and specification defect found in this project, in one place.**
Not per-block: a bug that crosses a boundary belongs in one list, and the
cross-block ones are the expensive ones.

Last updated: 2026-10-05 (independent free-tool audit, §1i; block 14, §1e) · Covers Blocks 1 (core), 2 (DSU), 6 (interconnect),
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
| Testbench / toolchain | 25 | 7 | 1 | — |

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

> **2026-10-05 note (§1i):** no longer true. **T-13** and **T-14** are open RTL defects in `rtl/core/trap_ctrl.v` (§1i), and APB-1, AUD-4, AUD-9, AUD-11 and the vendored SPIM-2 and UART-3 are open (§1d, §1g, §1h). The summary counts above do not yet include §1i.
>
> **2026-10-05 note (§1j):** the summary counts above do not include §1j either. It adds two RTL defects that are fixed (T-15, PWM-4) and findings that wait for an owner decision (T-12, RDC-1, GPIO-2, SIM-1, C-16, CRG-3, AUD-12, AUD-13).

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
| ELEM-1..6 | TB | **FIXED 2026-10-04, all six were testbench defects (§1h)** | low | First-ever run of the 14 per-element TBs (Sep 2): 8 pass. `pc_gen` scoreboard samples one cycle late (its own SVA on the RTL passes); `prefetch_buffer` stimulus overfills the FIFO, violating the I-port slot-reservation contract; `iport` SVA encodes the pre-BUS-A HBURST; `load_store_unit` TB has a SystemVerilog syntax error (line 114); `if_stage_top`, `mem_stage` not yet triaged. The RTL they target is covered by ISA 63/63 lockstep incl. random waits. | `make test_elements` | owner: element-TB author |
| **ELEM-4** | TB | **FIXED: changed by inspection 2026-10-03, verified under Xcelium 2026-10-04 (§1h, ELEM-4)** | low | The nested implications in `tb_load_store_unit.sv`'s `constraint c_alignment` are rewritten as flat implications with a conjunction on the left: `A -> (B -> C)` and `(A && B) -> C` are the same proposition, so semantics and the stimulus distribution are unchanged, and there is no nesting left to parse. Done this way because **the tools disagree about the spelling**: Verilator accepts the parenthesised form and rejects the braced `constraint_set` form, xrun the other way round. **This is not locally verifiable and must be confirmed under xrun** — Icarus cannot parse the file at all (no concurrent-assertion support, which blocks **13 of the 14** element TBs), and Verilator parses it and then **segfaults** on 13 of 14, so its "0 errors" is not evidence either. What *is* evidence: at the parse stage Verilator reports 5 errors for the braced form and 0 for this one. | xrun; re-checked with Verilator | `make test_elements` |
| **ELEM-7** | docs | **OPEN (doc)** | low | `Docs/CORE_ELEMENT_VERIFICATION.md:157` cites covergroups `cp_lvl_vs_thresh` / `cp_lvl_vs_active` in `tb_clic_ctrl.sv` as the evidence that the strictly-greater-than threshold (test C24) was *"actually exercised rather than assumed"*. **That file is 74 lines and contains no covergroup and no SVA at all** — 9 directed vectors plus 5000 `$urandom` applications. The documented evidence does not exist. (It is also, not coincidentally, the only one of the 14 element TBs Icarus can compile, precisely because it has no SVA.) | reading the file against the doc | — |

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
| **AUD-3** | `dma_apb_slave.v`, `timers_apb.v` | **FIXED 2026-09-26** | Both are clocked **entirely by hclk**, while ADR-0002 Rev 2, `apb.clock: pclk` and both specs' §4/§5 say the APB side is pclk. `dma_top` even takes `pclk_i`/`preset_n_i` and discards them. Not a functional bug — pclk edges are a subset of hclk edges (D-5) — but PRDATA is combinational out of hclk registers, so it can move mid-access and the bridge's effective setup window is **4 ns, not 8**; and these flops run at 250 MHz, which is the power ADR-0002 Rev 2 restored pclk to save. **Migrated.** The APB side is now pclk with the registers still hclk, and PRDATA is registered on pclk so it holds for the whole access phase — the 4 ns hop is now local to each block instead of crossing to the bridge. `tb_timers` gained a monitor counting mid-access PRDATA movement: **3 against the old RTL, 0 against the new**, so the test discriminates. Synthesis after: 7712 flops (+65), still 1 latch, 0 unresolved. |
| **AUD-4** | PHYS §5 SDC | **OPEN** ([N-5.3]) | The SDC sketch will not elaborate: it constrains `[get_ports refclk_i]` (the pin is `refclk`), and `u_clk_div/u_clkdiv_toggle_hclk/Q` and `..._pclk/Q` (the flops are `t1_q` and `pclk_q`). Substantively, it declares a fixed `-divide_by 2` while `clk_div` implements a **selectable** ÷2/÷4/÷8/÷16 mux — and ADR-0001 makes ÷4 the timing fallback, so the other ratios need constraining too. `aon_clk` (D-14) is absent entirely. |
| **AUD-5** | MEM §8.3, §8.5 | FIXED | Boot-time and ROM estimates predated a working boot path. §8.6 assumed 32 SCLK per word; it is **64** (command + address precede every word), so a 64 KiB image is **~67 ms, not 26**. The ROM is **820 bytes**, not ~500. Both now carry the measured figures. [N-8.7]'s "no document has verified the sourced IP" is also stale — GARUDA-SPIM-SPEC-001 now does. |
| **AUD-6** | `ahb_interconnect.v`, `mul32.v` | FIXED | Comments still described the pre-ADR-0001 clock plan — "one 200 MHz domain", "200/100 MHz crossing", "TRM 100 MHz clock". The plan has been 500 → 250 → 125 since ADR-0001. |
| **AUD-7** | `garuda_soc_top.v` | FIXED | `dma_req_i[4]` was commented "ch4 is spare", citing DMA [N-6.4] — which now says the opposite: channel 4 serves the SPI slave and is **required** (ADR-0020 Rev 2). The tie-off itself is still correct because `rtl/spi_slave/` does not exist; the comment now says that, and names un-tying it as the work item. |

| **AUD-8** | CORE §11 | **PARTLY CLOSED 2026-09-26** | **The core's stated verification does not exist.** [N-11.2] calls `t_core_hold_flush_matrix` "the most valuable new test in this project" — a 20-entry cross product that it says produced four errata, all found by inspection rather than by a test. **There is no such test**, under that name or any other. [N-11.3] names five SVA assertions for `pipe_ctrl` — `a_flush_beats_hold`, `a_trap_beats_branch`, `a_h2_defers_flush`, `a_no_gate_with_bus`, `a_no_gate_with_flush` — and **`pipe_ctrl.v` contains no assertions at all**. **The five properties now exist** as `rtl/core/pipe_ctrl_sva.sv`, bound at `garuda_core_top` on the **ungated** clock (bound to `gclk` they would stop being evaluated at the moment the gate closes, which is the moment they check). 22 assertions and covers elaborate and run in every simulation that instantiates the core. **The matrix is now measured**, by `make pipe_matrix`, and the result is the finding: across *every* test hex in the build, the nine plain hold x register cells are reached — H1 40/25, H2 112, H4 5, H5 399 962 — and **all four hold-versus-flush collision cells are reached zero times**. Those four are exactly where errata P-1, P-2 and P-3 came from. `t_core_hold_flush_matrix` as a directed test is still unwritten; see the note below for why that may be the wrong instrument. |
| **AUD-9** | DSU §5 vs `rtl/dsu/` | **OPEN** | **The DSU's port names diverge from its spec wholesale, and from the house style.** Spec §5 names `dsu_busy_o`, `dsu_result_o`, `dsu_illegal_o`, `dsu_acc_o`, `dsu_ovf_o`; the RTL has `dsu_busy`, `dsu_rd_data`, `illegal_instr`, `dsu_overflow`. Internal names the spec uses — `dsu_idle`, `dsu_interlock`, `dsu_decode`, `dsu_taps` — do not exist either. The DSU is also **the only block in the chip with no `_i`/`_o` suffixes**. Nothing is functionally wrong; the cost is that the spec cannot be read against the code. Decide which way to converge — renaming the RTL touches the core/DSU interface, so it is not free. |
| **AUD-10** | `Design_Docs/*.docx` | PROCESS FIXED | **A second, hand-maintained source of truth.** No generator exists between `.md` and `.docx`. **Seven `.docx` are stale** — including every spec AUD-2 corrected, so a reviewer working from Word still reads the window-numbering error — and **five specifications have no `.docx` at all** (SPIM, I2C, UART, GPIO, PWM). Ruled in `Design_Docs/README.md`: the `.md` is normative. `make check_docs` now fails on drift; `make docs` regenerates via pandoc, which is not installed on the sim host. |

**On AUD-8, and why the missing test may be the wrong fix.** The four
uncovered cells may be *unreachable by construction* rather than merely
untested. `load_use_stall` is raised by ID against the instruction sitting in
ID/EX; `ex_redirect` is raised by the branch unit acting on that same ID/EX
instruction. One instruction cannot be both a load and a branch, so H1 versus
an EX redirect looks structurally impossible. If that holds for the other three
as well, the arbitration logic for those combinations is dead, and a directed
test could never reach them no matter how long it ran.

**Simulation cannot tell those two cases apart** — "never happened" and "cannot
happen" produce identical coverage. Formal can, and that is now the concrete
argument for CORE [N-11.3]'s recommendation rather than a general preference:
run formal on `pipe_ctrl`, and either it proves the cells unreachable (delete
the concern, and possibly the logic) or it produces the counterexample that
tells you exactly what `t_core_hold_flush_matrix` has to contain. Writing the
directed test first is guessing at a sequence that may not exist.

**What the audit did not find:** every register offset checked (DMA `GSTAT`,
CLIC `CLICINFO`/`CLICIE`/`CLICIP`) matches its spec; every spec revision cited
in an RTL header matches the document's actual revision; the 26 chip pins match
PHYS §3.1 name for name; and `tools/garuda_gen.py --check` is clean, so the
address map and CLIC IDs in RTL and C agree with the yaml.

**Second pass, 2026-09-26** — 127 normative notes across CORE, DSU and DEBUG,
every RTL identifier they name checked for existence. The three specs
themselves hold up well: `mepc` bit 0 is masked on write, `mtvec` MODE is
hardwired to 3, `IDCODE` is `0x0000_0DB1`, DTMCS reports version 1 / abits 7 /
idle 5, the reset vector comes from the generated header, the core is one clock
domain behind one gate on `~quiescent`, the MAC cluster has three accumulators
each with its own reset and overflow, and `tb_debug` checks nine DEBUG notes by
number. The gaps are AUD-8 and AUD-9, and both are about verification and
naming rather than behaviour.

**The pattern worth remembering:** the errors that survived longest were all in
places nothing executes — a table the generator does not read, a column of
index numbers, a test named in a spec but never written, and a set of exports
with no generator behind them. Everything the toolchain touches was correct.

---

## 1e. Block 14 (SPI slave) — 2026-09-26

| ID | Where | Status | Summary |
|---|---|---|---|
| **SPIS-1** | design decision | — | An SPI slave's shift clock comes from the far end of the wire, so the textbook build clocks the shifter on `sclk` and crosses to `pclk` through an async FIFO. That would have made DEBUG [N-7.16] — "`dmi_cdc` is the only asynchronous crossing in the chip" — false, for one peripheral. `garuda_spis_core.v` oversamples in `pclk` instead. The chip keeps one CDC; the cost is SCLK ≤ pclk/6 = 20 MHz, specified, and scaling with DIVSEL. |
| **SPIS-2** | `t_spis_rate` | MEASURED, caveated | The rate sweep passes at every half period down to 9 ns, far below the specified 24 ns limit. **That is simulation being kinder than silicon**: ideal edges cannot exercise metastability or finite edge rates, which is what actually sets the limit. The sweep confirms correctness at and above the spec figure; it does not derive it, and the log says so rather than letting a reader infer headroom that is not there. Half periods are deliberately not `pclk` multiples, because aligned edges make an oversampler look better than it is. |
| **SPIS-3** | `[N-9.2a]` | ACCEPTED, bounded | `miso_oe` drops **2 `pclk` (16 ns) after `cs_n` rises**, because `cs_n` arrives through the shim's synchroniser. Releasing from the raw pin would remove the tail but put a combinational path from an async pad input onto a pad output enable — on the one block whose premise is adding no async timing. Bounded instead: `t_spis_reset` fails above 3 `pclk`, and at max SCLK a bit is 50 ns so no master can reselect inside it. |
| **TOOL-6** | this session | FIXED | The commit that added block 14 went in with `rtl/include/garuda_map.vh` and `sw/common/garuda_map.h` **stale** against the yaml. `garuda_gen.py --check` had reported it, but the check was `&&`-chained ahead of a doc update while `git commit` sat on its own line, so the failure aborted the docs and not the commit. Regenerated in the next commit. The lesson is the shape of the command, not the tool: a gate that does not gate the thing it is protecting is decoration. |

---

## 1f. The licence-free local flow — 2026-10-03

Found while extending `scripts/run_sim.sh` from 5 of the 15 block testbenches to
all of them, and getting whole-chip Verilator lint and Yosys synthesis to run.
Full results and tool versions: `Docs/VERIFICATION_LOG_2026-10-03.md`.

**Every entry here is a check that was reporting a result it had not measured.**
That is this register's own recurring defect — `TOOL-4`, `TB-11` and the static
checker that "reported success having checked nothing" are the same thing three
times — and it is now five times.

| ID | Where | Status | Severity | Summary | Found by |
|---|---|---|---|---|---|
| **TB-22** | 5 block TBs | **FIXED** | **high (falsely reassuring / wasted debug)** | A reset held low from time 0 never reaches the design. A Verilog async reset is **edge** sensitive in simulation: `always @(posedge clk or negedge rst_n)` is not evaluated merely because `rst_n` is already low at time 0. `tb_crg`, `tb_ahb2apb`, `tb_timers`, `tb_spim` and `tb_dsu_top` declared theirs `= 0`, so no `negedge` ever occurred and every flop whose only reset was that signal stayed X for the entire run. In `clk_div` that flop is `pclk_q`, and `pclk_q <= ~pclk_q` keeps X forever, so `pclk` and `preset_n` never resolved. Measured under Icarus: *neither* `reg a = 0;` *nor* `initial a = 0;` creates the edge — the `always` block is not armed until after time 0. In silicon the reset pin is level sensitive and this cannot happen, so the fix belongs in the testbench: declare the reset de-asserted, assert it at time 0. **`tb_crg` 0 → 43 checks; `tb_ahb2apb` 1 → 20; `tb_timers` 0 → 23; `tb_debug` 15 failures → 0.** | `make local_sim` |
| **TOOL-7** | `scripts/run_synth.sh` | **FIXED** | **high (a gate that could not fail)** | The latch gate printed **"No latches inferred" while the netlist contained one**. It grepped its own log for `\$_?DLATCH`, a pattern that never matches the text yosys writes. It now reads the object list yosys emits with `select -list`, **refuses to report at all if that file is absent**, and allows `core_clk_gate`'s ICG enable latch **by name** so any other latch still fails the run. Proven by injecting a live latch into `clk_div`: exits 1 and names it; reverted, exits 0. The first attempt at that control was itself invalid — yosys optimised the injected latch away because nothing read it — which is also why log-grepping is unreliable in *both* directions: the "Latch inferred" warning fires for latches that are then deleted. Compare `ERR-U3`, where 24 real latches were caught only by synthesis. | building the negative control |
| **TOOL-8** | `scripts/expand_filelist.py` | **FIXED** | medium (blocked chip-level lint) | The expander emitted **CRLF**, so every path it printed carried a trailing CR, and a shell does not word-split on CR. iverilog tolerates a stray CR in a filename — which is why the Icarus flow never noticed — but Verilator reports the path as a module it cannot find. This is what made the expanded filelist look unusable for lint and kept chip-level lint a manual, per-block job (`RTL_LOG_2026-09-16.md:320`). It applied to **every** invocation on Windows regardless of the filelist's own line endings. | whole-chip Verilator lint |
| **TOOL-9** | `scripts/expand_filelist.py` | **FIXED** | medium (blocked whole-chip synthesis) | `--yosys` emitted `read_verilog` with no `-sv`, so yosys's Verilog-2005 front end rejected `input logic clk` at `spi_master_clkgen.sv:13` and **whole-chip synthesis failed outright** from the moment the vendored PULP SPI master joined the build. Flagged per file now, so Verilog-2005 sources keep being parsed as Verilog-2005. | `make local_synth` |
| **TOOL-10** | `scripts/run_sim.sh` | **FIXED** | medium | Two kinds of stale result. (a) Per-testbench results accumulate through a file because the loop runs in a subshell, and the file was not deleted first — a second run reported both runs added together, the same class as a stale `.vvp`. (b) No wall-clock cap, so one hanging testbench hung the regression; and on Windows `timeout` returns 124 while the native `vvp` child **survives**, leaving an orphan spinning in a zero-delay loop that takes a core for the rest of the session. Both fixed; each `.vvp` is also deleted before building and the compile's real exit code gates the run. | running it twice |
| **RTL-C1** | `rtl/dsu/mac_unit.v` | **FIXED** | low (blocked chip-level lint) | Verilator reads a comment whose **first word** is its own name as a lint pragma. A prose paragraph about yosys and the signed casts wrapped such that line 51 began *"Verilator both accept the casts…"*, so Verilator reported `BADVLTPRAGMA: Unknown verilator comment` and **aborted the whole-chip lint** — on a comment. Reworded, with a note not to re-wrap it back. | whole-chip Verilator lint |

**Not defects, recorded so nobody re-derives them.** Four block testbenches
cannot be built by Icarus, three of them because of vendored third-party PULP
RTL: `tb_mem_subsystem` (associative array keyed by a packed type),
`tb_uart`, `tb_gpio`, and `tb_spim` (compiles, but 12 × *"sorry: constant
selects in `always_*` not fully supported"* mis-models tx/rx and it then spins
with no simulation-time advance). They are listed in `run_sim.sh` with the
message that produced each, and are **still built and run every regression** so
that one which starts passing is reported as a stale entry — a skip list nobody
re-tests becomes a list of tests nobody runs.

Also: `tools/gen/DSU_gen.py` defaults `--outdir` to `.`, dropping
`dsu_stim.mem`, `dsu_expected.mem` and `dsu_crosscheck.txt` into the repo root,
where `.gitignore` does **not** cover them.

---

## 1g. The APB protocol checker — 2026-10-03

`Docs/HANDOFF.md` section 11, step 3, written before any of this hardware
existed: *"Write the APB protocol checker BEFORE the bridge ... A bridge built
before its oracle is a bridge nobody is looking at."* The bridge was built, so
were the shim and all seven peripherals, and the checker was not. The nearest
thing that existed was a single rule inside `tb/ahb2apb/apb_slave_model.v`
living in a **responder**, so it was only present in `tb_ahb2apb` and it was
checking the bus it was also driving.

`tb/common/apb_checker.v` now exists: a passive monitor, Verilog-2001 with no
SVA so it compiles under both xrun 22.09 and irun 15.20 without an assertion
licence, with ten per-rule counters and a `report_result` task. Its negative
control is `tb/common/tb_apb_checker_selftest.v` — **35 checks**, every rule
fired one at a time on an injected violation, plus legal traffic that must be
silent. Each scenario also asserts `v_total == 1`, so an injected violation is
required to fire *that* rule and no other; a checker whose rules cross-trigger
reports three violations for one defect and sends the reader after the wrong
signal.

Bound in six places, all clean: the four modelled windows of `tb_ahb2apb`,
**both sides** of `tb_apb_shim` (including the APB the shim generates out to the
wrapped IP, which nothing had ever looked at), and the config ports of
`tb_clic`, `tb_i2c`, `tb_pwm` and `tb_spis`. Check counts: bridge 20 → 22,
shim 22 → 25, clic 15 → 17, i2c 42 → 44, pwm 26 → 28, spis 32 → 34.
Accesses actually observed run from 2 per bridge window to **22,276** on the
I²C port, and every binding asserts a non-zero count so a silent checker fails
rather than passes.

| ID | Where | Status | Severity | Summary | Found by |
|---|---|---|---|---|---|
| **APB-1** | `rtl/ahb2apb/ahb2apb_apb_fsm.v` | **OPEN — needs an owner ruling, not an RTL change** | low (deliberate, documented trade-off) | **The 16-pclk timeout abandons an APB access mid-flight, which strict APB does not permit.** On expiry (`ahb2apb_apb_fsm.v:97-101`) the FSM drops `psel_o` and `penable_o` with `PREADY` still low. APB has no abort: an access, once started, is supposed to complete. Measured on `tb_ahb2apb`'s deliberately-hanging window 2 — PREADY stall of exactly 16 cycles, one abandoned access, one `PSEL dropped mid-ACCESS` violation, while `[N-7.15] 16-pclk PREADY timeout -> ERROR` passes. So this is intended behaviour, not a bug: the alternative is hanging the AHB side, and therefore the core, forever on a slave that is already broken. It is recorded because **nothing in the repository said the bridge knowingly breaks APB to protect AHB**, and because a reviewer or a future integrator binding a checker to a real peripheral window will hit it. The ruling wanted is whether to state the deviation in GARUDA-AHB2APB-SPEC-001 §7.5 and accept it, or to hold PSEL and let STA/integration deal with a wedged window. The checker is left strict so the next occurrence is still reported. | `apb_checker` bound to window 2 |
| **TB-24** | `tb/common/apb_checker.v` | **FIXED** | medium (would have mis-attributed traffic) | My own defect, found on the first bind and worth recording because of how it announced itself. The access counter triggered on `PENABLE`'s falling edge without also requiring the slave's own `PSEL` — and APB fans a **shared** PENABLE out to every window, so each per-slave checker counted the whole bus. The tell was windows 1 and 11 of `tb_ahb2apb` reporting byte-identical totals (28 accesses, 12 write, 16 read) for two different windows, and two "abandoned accesses" each that belonged to window 2's timeout. The self-test had not caught it because it drives a single PSEL, which is the same blind spot as checking a per-slave rule on a single-slave bus. Fixed by gating on `p_psel`, and scenario M was added — another window's traffic on the shared PENABLE must register as neither a violation **nor** an access. Verified to discriminate: with the fix reverted, scenario M fails. | first bind into `tb_ahb2apb` |

**A note on `EXTEND_MAX`.** The bridge's per-window APB divider
(GARUDA-AHB2APB-SPEC-001 §6.2) keeps `PENABLE` high for `div_cnt` further pclk
cycles after the slave has raised `PREADY`, which strictly is also past the end
of the access. That is the divider doing its job and `tb_ahb2apb` already
measured it as `max_pen_w11`, so rather than exempting it silently or firing on
it, the checker takes an `EXTEND_MAX` parameter: zero, strict APB, is the
default, and window 11 binds with `EXTEND_MAX=1` because it runs /2. The
stretch is reported either way as "longest PENABLE extension", so raising the
parameter hides nothing. Measured on window 11: exactly 1 cycle, as predicted.

**Still unbound:** `tb_timers`, `tb_dma`, `tb_debug`, and the three testbenches
Icarus cannot build (`tb_uart`, `tb_gpio`, `tb_spim`). The three unbuildable
ones can only be verified under xrun, so binding them is a change nobody could
check locally — which is why they were left rather than done blind.

---

## 1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04

Found while running the flow in order (static, block, core, integration, SoC top)
for the first time. Tool that exposed each one is named, because several of these
had been failing quietly behind a PASS.

Merged with the 2026-10-03 work on 2026-10-04. Both sides had numbered new entries
from the same starting point, so the IDs first used here for these entries were
renumbered: TB-22..25 are TB-26..29, TOOL-7 is TOOL-11, the flush defect first logged
as a second DSU-10 is DSU-13, and the element-bench IDs follow the order of the
ELEM-1..6 row (4 load_store_unit, 5 if_stage_top, 6 mem_stage).

| ID | Where | Status | Summary |
|---|---|---|---|
| **TOOL-11** | `Makefile` | FIXED | `run_blk`, `run_tb_top` and `run_tb_elem` counted `[FAIL]` lines only. Simulator assertion failures (`xmsim: *E,ASRTST`) never reached the summary, so four logs carried failing assertions under a PASS: `unit_decode_control` 88, `chip_irq` 3, `elem_garuda_iport_ahb_master` 382, `elem_garuda_prefetch_buffer` 750. The summary now prints an `SVA_FAIL` count and the first failing lines. |
| **C-13** | `rtl/core/decode_control.v` | FIXED | **Reserved register-register encodings executed instead of trapping.** `funct7 = 0100000` was accepted for every `funct3`; it exists only for SUB (000) and SRA (101). `0x402091b3` ran as SLL where Spike raises illegal-instruction. Same class as C-1, on OP_REG. Found by reading the decoder while chasing C-14; `reserved_funct7` in `tb_decode_control` now walks all eight `funct3` values. |
| **C-14** | `rtl/core/decode_control.v` | FIXED | **An illegal instruction left `reg_write` asserted.** OP_IMM set `reg_write` before examining `funct7`, so a reserved shift-immediate reached EX flagged illegal with a register write still enabled. The trap squash made it harmless in practice; the decoder's own contract (C-5: "no side effects enabled") was not met. `a_illegal_inert` in `tb_decode_control` had been failing 88 times per run. The bundle is now forced inert in one place at the end of the decode. |
| **TB-26** | `tb/core/tb_decode_control.sv`, `tb_id_stage.sv` | FIXED | Both reference models had been written to agree with the RTL on C-13 and C-14, and `tb_id_stage` even constrained "legal ALU" stimulus to include the reserved encodings. The scoreboard therefore passed what the assertion beside it rejected. Models and constraint corrected. The inlined standalone DUT copies in those files (unused when `GARUDA_REAL_RTL` is set, which the filelists always set) are **not** updated. |
| **SVA-1** | `rtl/core/pipe_ctrl_sva.sv` | FIXED (assertion) | `a_no_gate_with_flush` listed `ex_mem_flush`, which `pipe_ctrl` drives from `wfi_hold` itself to bubble EX/MEM (P-3). It therefore failed on every WFI sleep by construction — 3 times in `chip_irq`. CORE [N-11.3] defines the property over the flush *sources* (branch, trap, MRET, FENCE.I); the assertion now checks redirects and the IF/ID, ID/EX and MEM/WB flushes, and a trap squash of EX/MEM is still caught through `trap_redir_v`. RTL unchanged. |
| **I2C-5** | `rtl/i2c/garuda_i2c_top.v` | FIXED | **Combinational logic in an asynchronous reset path** (HAL `GLTASR`). The vendored controllers' `nReset` was `preset_n_i & en_q & ~(|abort_q)`. `abort_q` is a down-counter whose 4→3 and 2→1 steps move bits in opposite directions, so the OR can glitch and release the reset mid-abort. The comment claimed the CRG-2 rule was met; it was not. `nReset` now comes from one flop loaded from the next-state values, so it switches in the same cycle as before. |
| **PWM-1** | `rtl/pwm/garuda_pwm_core.v` | FIXED (hardening) | HAL `ULRELE`: `(cnt_q + 16'd1) >= period_i` is evaluated in 16 bits and would wrap at `cnt_q = 0xFFFF`. That value is unreachable today (the counter wraps at `period - 1`), so no behaviour changes; the compare is now 17 bits so it stays correct if the counter is ever preloaded. |
| **LINT-1** | whole chip, HAL 15.20 | 5 errors left, all dispositioned | First lint run on the chip: 696 errors, 5 749 warnings. With formatting and house-style rules off (`flow/2_static/hal.f`) and the fixes above: **5 errors, 777 warnings**. The five: `CDEFNC` ×2 and `TERMST`/`UNRCHS` are in vendored IP (PULP SPI master, OpenCores I²C); `GLTASR` ×1 is the core's `core_rst_n_i & hartreset_n_i`, which CORE [N-7.33] requires to be combined inside the core. Reasons in `flow/2_static/hal_waivers.txt`. |
| **SPIM-2** | `rtl/third_party/pulp/axi_spi_master/src/spi_master_controller.sv` | OPEN (vendored) | HAL `TERMST`/`UNRCHS`: state `MODE` is never entered and has no exit; in it chip-select is held low with the clock running. Unreachable in normal operation, but a state register upset would hang the SPI master until reset. A recovery arc to `IDLE` is a one-line vendor patch; not applied today because it needs a patch record under the vendoring mechanism. |
| **CDC-1** | HAL clock-domain checks | REVIEWED | Chip level: clocks found are `refclk` and `tck` only, so `dmi_cdc` is the one asynchronous boundary (DEBUG [N-7.16] holds). HAL does not analyse crossings into the divided/gated `hclk` at chip level, so the check was repeated on `debug_top`, where both clocks are ports: two-flop synchronisers found on the request and acknowledge toggles; **5 `CLKDMN` on the DMI payload** (`sbdata`, `hartreset`, `rdata_o`). Those are qualified-data crossings: the payload is loaded with the toggle and held until the acknowledge returns. A structural tool cannot see that, so they are waived on the handshake argument, not fixed. |
| **T-9** | `rtl/core/trap_ctrl.v` | FIXED | **A trap taken while a load or store was still on the D-port lost its redirect.** `trap_ctrl` had no view of H2: it entered the trap at once (mepc, mcause, mstatus written, ID/EX squashed) while `pipe_ctrl` withheld the redirect until the transfer finished, assuming the request would still be there. For an interrupt it was not, because the entry had just cleared `mstatus.MIE`; for an EX-point exception its own squash had removed it. The core ran on down the interrupted code with its CSRs saying it was in the handler. Found by `t_chip_integ` (a DMA error interrupt landing on a store: the next JALR used a stale `ra` and the chip ended in an access-fault storm with `mepc = X`), and confirmed for `sw; ecall`, `lw; illegal`, `sw; csr-illegal` and `sw; mret` by `t_hold_flush_matrix` bits 1, 2, 4, 5. This is the `c_h2_vs_redirect` cell AUD-8 said no test reached. No EX-point trap, interrupt or MRET is now taken while `mem_stall` is high. |
| **T-10** | `rtl/core/trap_ctrl.v` | FIXED | **A load/store bus error did not squash the instruction behind it.** `trap_squash_ex_mem` covered EX-point exceptions and interrupts only. On a MEM-point fault the younger instruction in EX moved into MEM, did its own bus access and wrote its register before the handler ran: `lw a4,204(a4)` behind a faulting load overwrote its base register, then trapped as misaligned when the handler returned to it. A store in that position would have written memory after a fault. Found by `t_chip_integ` step 6. |
| **P-4** | `rtl/core/pipe_ctrl.v` | FIXED | **The idle loop lost a load on wake.** During a WFI sleep the instruction behind the WFI is parked in ID/EX. If it was a load and the next instruction used its result, load-use fired, flush beat the H5 hold, and the load was destroyed: `wfi; lw a5,0(a4); beqz a5,...` (that is `while (!flag) wfi;`) woke up, skipped the load and branched on the stale register. `t_hold_flush_matrix` bit 12. |
| **P-5** | `rtl/core/pipe_ctrl.v` | FIXED | A JALR or mispredicted branch parked in EX behind a WFI redirected fetch, was flushed out of ID/EX by its own redirect and never reached EX/MEM: `wfi; jalr ra,...` jumped but wrote no link register and never retired. The EX redirect is now deferred to the wake. `t_hold_flush_matrix` bit 13. |
| **P-6** | `rtl/core/csr_file.v`, `garuda_core_top.v` | FIXED | **A CSR instruction wrote its CSR on every cycle it sat in EX, and in the cycle it was squashed.** Held behind a load/store or parked behind a WFI, `csrrw` wrote first and then returned the value it had just written, so `rd` got the new value. An interrupt taken on a `csrrw a0, mscratch, a0` swap wrote the CSR, squashed the instruction and ran it again on return, losing the old `mscratch`. The write and the read-to-clear of `dsu_ovf` now happen once, in the cycle the instruction leaves EX. `t_hold_flush_matrix` bits 7, 14. |
| **P-7** | `rtl/core/garuda_core_top.v` | FIXED | **A DSU operation parked in EX ran once per held cycle.** A MAC behind a store (H2) or behind a WFI (H5) accumulated its product every cycle it waited. The DSU's enable is now withheld until the instruction can move. `t_hold_flush_matrix` bits 8, 15. |
| **P-8** | `rtl/core/garuda_core_top.v` | FIXED | The clock gate could close with an instruction still in MEM/WB: a load or store stretched by wait states just before a WFI finished its data phase and the gate closed in the same cycle, leaving it unretired (and a load's register unwritten) for the whole sleep. "Idle" now also requires MEM and WB to be empty. Found by `t_hold_flush_matrix` with `+IRQ_EVERY=61 +DWAIT=2 +DRAND=1`. |
| **C-15** | `rtl/core/garuda_core_top.v` | FIXED | **FENCE.I raced an older store.** It redirects from ID, so the refetch went out on the I-port while the store before it was still in EX or waiting on the D-port; with one wait state the core executed the word the store was replacing. FENCE.I now waits in ID until no older store is in EX or on the bus. `t_hold_flush_matrix` bit 6 with `+DWAIT=3`. |
| **T-11** | `rtl/core/trap_ctrl.v` | FIXED | **An interrupt taken on a WFI put the core to sleep inside the handler.** When the interrupt was taken in the cycle a WFI sat in EX, the WFI was squashed but still armed the sleep latch, so the core slept on the first instruction of the handler. If the source had dropped its request, nothing woke it: the handler ran only when the next interrupt arrived, returned to the WFI, and the same happened again, so every interrupt was served one interrupt late and the program never got past the WFI. Found by sweeping `t_hold_flush_matrix` over interrupt periods and wait states (`+IRQ_EVERY=71 +DWAIT=5`); 60 further combinations now pass. |
| **DSU-13** | `rtl/dsu/mac_unit.v` | FIXED | A trap flush discarded a committed accumulate: the pending product belongs to a MAC that has already left EX, but `flush` cleared it. A MAC followed by an instruction that trapped, or on which an interrupt was taken, lost its product silently. `t_hold_flush_matrix` bits 9, 10. |
| **DSU-11** | `rtl/dsu/mac_unit.v` | FIXED | **One accumulator was corrupted by an instruction for another.** `load`/`clear` are cluster-wide decodes; the accumulator mux used them without checking the instruction addressed this unit. `MAC acc0; MACCLEAR acc1` set acc0 to 0, and `MAC acc0; MACLOAD acc1` loaded acc0 with the other instruction's operand. `tb_dsu_top` could not see it because it inserts an idle cycle after every instruction. `t_dsu_b2b` bits 0, 1. |
| **DSU-12** | `rtl/dsu/dsu_top.v` | FIXED | MACSAT behind a MAC on the same accumulator is held one cycle by the DSU interlock, but the saturate ran in the held cycle anyway: it clamped the stale accumulator, its write-back beat the pending fold, the product was lost and the sticky overflow flag was raised for a value that never existed. `t_dsu_b2b` bit 2. |
| **INT-1** | `Design_Docs/garuda_system.yaml` | FIXED | The system description listed the SPI slave as block 14 but not in `apb.windows`, `peripheral_functions` or `dma.assignment` (channel 4 said "reserved"). The generated map therefore had no SPI slave base, window index or DMA channel, and the chip top and `t_chip_periph` hard-coded window 0. Added; the RTL and test now use the generated names. |
| **INT-2** | CLIC ID map | FIXED, **owner to confirm** | **CLIC ID 7 reported the machine timer's cause.** A CLIC interrupt enters with `mcause = 0x8000_0000 | ID` and the timer with `0x8000_0007`, so "DMA error, channel 0" (the IMU channel) was indistinguishable from a timer tick. A handler written as `if (mcause == 0x80000007) timer();` would push `mtimecmp` away and return with the DMA error still asserted, forever. The DMA error interrupts move from IDs 7..12 to **8..13**; ID 7 is reserved. Changed in the yaml, the generated map and `garuda_soc_top.v`. **The ID tables in the CLIC, DMA and TRM documents still say 7..12 and need the same edit.** Found by `t_chip_integ` step 2. |
| **INT-3** | `rtl/soc/garuda_soc_top.v`, `tools/garuda_gen.py` | FIXED | **The SPI slave's interrupt could not be enabled.** `clic_top`'s default `IE_MASK = 0x007F_9FFE` still excluded IDs 13 and 14 from when the SPI slave had been removed, and the SoC top did not override it. The line was wired and could go pending; `CLICIE[14]` read back 0. The mask is now generated from the ID map (`GARUDA_CLIC_ID_MASK`) and passed in. Found by `t_chip_integ` step 4. |
| **SPIS-4** | `rtl/spi_slave/garuda_spis_core.v` | FIXED | **Every transmitted byte after the first went out shifted left by one bit.** At the eighth falling edge the shifter was reloaded with `{txdata[6:0], 1'b0}`: `TXDATA = 0xA5` was answered `A5 4A 4A ...`. A one-byte test cannot see it. |
| **SPIS-5** | `rtl/spi_slave/garuda_spis_core.v` | FIXED | Setting `CTRL.EN` while the master was already inside a frame started the shifter on whatever bit came next, pushed misaligned bytes into the FIFO as data and reported the packet complete. A packet now opens only on a `cs_n` falling edge seen while enabled. |
| **SPIS-6** | `rtl/spi_slave/garuda_spis_top.v` | FIXED | A write-1-to-clear in the cycle of a new event cleared the STATUS bit while IRQSTAT kept it: the interrupt said "overrun", STATUS said it had not happened. Set now beats clear. |
| **SPIS-7** | `rtl/spi_slave/garuda_spis_top.v` | FIXED | `IP_LIMIT` was `0x020` (copied from PWM) for a block with four registers: offsets 0x10..0x1C read 0 and swallowed writes instead of raising PSLVERR. |
| **I2C-6** | `rtl/i2c/garuda_i2c_top.v` | FIXED | `CTRL.EN = 0` in the middle of a transfer left TIP and the command bits latched with the core in reset. With `TIMEOUT = 0` (its reset value) firmware polling TIP never returned, and the next `EN = 1` sent the stale START and byte onto the bus unasked. |
| **DMA-8** | `rtl/dma/dma_chan.v` | FIXED | A failed beat marked the peripheral's request as taken. After firmware repaired the address and set EN again the channel sat ACTIVE and never eligible: a hang with no status bit set. Only a successful beat consumes the request. |
| **DMA-4/5/6** | `tb/dma/tb_dma_top.sv` | WAIVERS NOW TESTED | The three waived items each have a directed test (ICLR in the cycle the flag sets; STAT read directly behind the arming write; six back-to-back APB writes giving exactly six strobes). All pass on the current RTL. |
| **DBG-1** | `rtl/debug/dtm.v` | FIXED | **A debug request could run twice.** A DMI scan that captured "busy" must itself be ignored, but the refusal was decided at Update-DR, 41 or more `tck` later, when the earlier request had usually finished. The debugger was told "busy, ignored", retried, and the request executed twice: with `sbautoincrement`, a word written twice or skipped. |
| **DBG-2** | `rtl/debug/debug_module.v` | FIXED | `sbbusy` did not cover the cycle in which a finished transfer's result is written into `sbdata`/`sberror`. An `sbdata0` read landing there returned the previous word with `sbbusyerror` clear. |
| **DBG-3** | `rtl/debug/debug_module.v` | FIXED | `dmactive = 0` reset only `ndmreset`/`hartreset`: `sbcs`, `sberror`, `sbbusyerror` and `sbaddress0` survived the debugger's reset of the module, and SBA still ran with the module inactive. |
| **UART-3** | `rtl/third_party/pulp/apb_uart_sv/src/uart_tx.sv` | OPEN (vendored) | The baud counter compares for equality. A smaller divisor written while a frame is in flight leaves it counting to the 16-bit wrap: the line stalls for up to 65 536 `pclk` with TEMT low. Firmware must wait for `LSR.TEMT` before writing DLL/DLM. A `>=` compare is a one-line vendor patch. Found when the UART bench changed the divisor under a frame. |
| **TB-28** | `tb/pwm/tb_pwm.sv`, `tb/uart/tb_uart.sv` | FIXED | Two new checks were mis-sequenced: the PWM clamp-release check read a pulse width before one whole pulse at the new duty had completed, and the UART line-status checks changed the divisor under a frame still being sent (UART-3). |
| **TB-29** | `rtl/ahb/ahb_mem_slave.v` (verification model) | FIXED | An erroring transfer that also drew wait states ran its two ERROR cycles during the waits and then completed OKAY, so with `+DWAIT`/`+IWAIT` a faulting access did not fault at all and `t_buserr` failed. The model now serves the waits first. The core's bus-error handling was correct; it had simply never been exercised under wait states. |
| **AUD-8** | hold × flush matrix | **CLOSED in simulation** | `sw/tests/t_hold_flush_matrix.S` constructs 19 hold-versus-flush cells and checks architectural state. It found T-9, P-4..P-8, C-15 and DSU-13. All four collision cells that no test reached are now reached, and the test passes under eight wait-state and interrupt timings. Formal remains unavailable (FV-1). |
| **AUD-11** | the specifications' own verification plans (§10, §11), all 16 blocks | OPEN | **Each specification's planned tests and assertions were checked against what the benches actually do**, when the plans were moved into vPlanner (`tb/<block>/GARUDA_<BLOCK>_vplan.csv`). Of **221 planned tests**, 166 are run and pass, **28 are only partly run** (the test exists but not to the extent the plan states: fewer values, one window instead of all, no random sweep) and **27 are not written at all**. Of **165 assertions** in the §10 sections, **5 exist as SVA** (all in `rtl/core/pipe_ctrl_sva.sv`); most of the rest are checked procedurally by a bench check, and 17 are not checked in any form. Not written: CLIC `t_clic_level_trig`, `_no_edge`, `_latency`, `_nest`, `_spurious`, `_wfi_wake`; memories `t_boot_crc_fail`, `_recovery`, `_blank_flash`, `_trap`; timers `t_mtime_hi_alone`, `t_mtimecmp_naive`, `t_wdt_during_hartreset`, `t_timers_1khz`; debug `t_jtag_tap`, `t_sba_bulk_load`, `t_session_survives_reset`; clock/reset `t_no_por`, `t_sync_release`; DSU `t_dsu_apf`, `t_dsu_ekf_scope`; core `t_core_wfi_latency`; DMA `t_dma_random`; bridge `t_apb_no_cdc`; PWM `t_chip_pwm`; and two review gates. The per-test detail is in each plan's `implementation_note`. **Specification text found out of date while doing this:** DMA §10 `a_ch4_tied` contradicts its own [N-6.4] (channel 4 is the SPI slave); AHB2APB §11 lists windows 0x0 and 0xB–0xF as unmapped (0 is the SPI slave, 11 the timers); DEBUG R-8 says `dmactive` survives a reset where the bench checks decision D-18, that it does not; CORE §11 says 20 hold × flush combinations where the test has 19 cells. |
| **VIP-1** | Mirafra UVM environment on the SPI master | RUN, no defect attributed to GARUDA | Mirafra's `pulpino__spi_master__ip_verification` (their APB VIP on the registers, their SPI VIP on the pins, register model, scoreboard) was run against the block as integrated, `garuda_spim_top`, on Xcelium 22.09 with UVM 1.2. It ships a Questa makefile only; on Xcelium it needs `-scu` (its packages are imported at file scope) and `-timescale 1ns/1ps`, and it does not elaborate under irun 15.2, so its coverage cannot be opened in IMC here. **51 tests: 16 with no UVM errors, 35 with scoreboard errors. The same 51 on Mirafra's own RTL and top give the identical result, test for test**, so the 35 are the environment's behaviour on this simulator and not a defect in the GARUDA block: its scoreboard compares APB write data with MOSI only, so read tests and tests with no SPI traffic are reported as mismatches. One real difference between the two RTL copies: Mirafra's `spi_master_rx.sv` samples MISO on lane 0, upstream (which GARUDA vendors) samples lane 1, and the GARUDA wrapper wires the board MISO there. The read path is therefore **not** checked by this environment; it is checked by `tb_spim` and by the flash boot test. |
| **FV-1** | IFV 15.20 | NOT RUN (no licence) | `Incisive_Formal_Verifier` is not on the licence server (`*F,NSLICN`). The run is set up in `flow/2_static/fv_pipe_ctrl/` (whole core, `pipe_ctrl_sva` bound, free bus and interrupt inputs). **AUD-8 therefore stays open on formal**; the hold-versus-flush cells are pursued in simulation instead (stage 4). |
| **TB-27** | five element testbenches | FIXED | **The "randomised soak" loops were not random.** `bit x = $urandom...;` declared inside a loop in a static `initial` is a static variable: its initialiser runs once, at time 0. In `tb_garuda_pc_gen`, `tb_garuda_prefetch_buffer`, `tb_mem_stage`, `tb_mem_wb_reg` and `tb_garuda_if_stage_top` every soak iteration therefore drove the same frozen values. The declarations are now `automatic`. With the stimulus really random all five still pass, which is the first time that statement means anything. |
| **ELEM-1** | `tb_garuda_pc_gen` | FIXED (testbench) | 600 soak failures on `fetch_pc`. TB-27 froze the stimulus at "issue every cycle", and the stream test before it left `fetch_issue` high across the reset, so the model started 4 behind and never re-synchronised. Not a sampling-phase problem as first recorded. RTL correct. |
| **ELEM-2** | `tb_garuda_prefetch_buffer` | FIXED (testbench) | 2 492 failures and 750 `a_no_overflow`. The write enable was meant to be gated on `ref_fifo.size() < 4`; TB-27 evaluated that once, at time 0, so the bench wrote every cycle and overfilled the FIFO. RTL correct. |
| **ELEM-3** | `tb_garuda_iport_ahb_master` | FIXED (testbench) | Three defects. `a_hburst` (382 failures) demanded SINGLE on every non-SEQ beat, the pre-BUS-A behaviour that AMBA forbids. The post-redirect NONSEQ check started looking two cycles after the transfer it was looking for. The C12 fault was armed after the fetch stream had already passed the faulting address. RTL correct. |
| **ELEM-4** | `tb_load_store_unit` | FIXED (testbench) | Nested `->` inside parentheses in a constraint does not parse; the bench had never compiled. Rewritten as single implications. It now runs and passes — the first execution of this testbench. The same rewrite was made independently on 2026-10-03 (ELEM-4 in the table above, then unverified); this run is its verification. |
| **ELEM-5** | `tb_garuda_if_stage_top` | FIXED (testbench) | 19 failures. `int popped_before = popped;` was a static initialiser (always 0), so the stall check failed whenever anything had ever been popped; and `expect_no_pop` was raised a full cycle before the redirect in the soak, so a legitimate pop of the old stream was reported as stale. RTL correct. **Never triaged before today.** |
| **ELEM-6** | `tb_mem_stage` | FIXED (testbench) | "SH: HWDATA on the upper half". The store was presented while the previous store was still in its data phase and checked one edge later, which reads the previous store's data. The check now follows the address phase. RTL correct. **Never triaged before today.** |


## 1i. Independent audit on free tools — 2026-10-04/05

Found by the verification lead's independent reproduction of the verification plan at `aae00a2` on free
tools (Verilator 5.052, Icarus 12, Yosys and SymbiYosys; no Cadence licence). Every entry was re-verified
against the RTL and the run evidence before it was added. Only defects in the project's own RTL,
testbenches and verification scripts are listed; simulator limitations, assertion-quality notes and the
formal-closure status of `pipe_ctrl` are kept in the audit report, not in this register. **T-13** and
**T-14** are confirmed RTL defects; a 5-line fix to `trap_ctrl.v` and two directed tests are proposed
alongside this section. The section 1 summary counts have not been updated for this section.

| ID | Where | Status | Summary |
|---|---|---|---|
| **T-13** | `rtl/core/trap_ctrl.v` | OPEN | **A load or store bus error on the instruction directly before an MRET is silently dropped.** `trap_now = (exception \| any_int) & ~is_mret` (`rtl/core/trap_ctrl.v:205`) suppresses the older instruction's MEM-stage fault while the MRET sits in EX, and `mret_o` (`:213`) still pops: no trap is entered, `mepc` and `mcause` are not written, the load's write-back is squashed (`:251`) and execution continues at `mepc`. A directed test, `lw` to an erroring address followed by `mret` (`sw/tests/t_lead1_mret_buserr.S`, proposed with this entry), ends at the MRET target instead of the handler on two simulators, with and without D-port wait states, with the AHB checker reporting 0 violations and `t_buserr` passing on the same build. Realistic: trap-handler epilogues restore registers with loads immediately before `mret`. Proposed fix (5 lines together with T-14, not yet applied): take `mem_exc_valid_i` regardless of `is_mret`, and gate the MRET pop, redirect and target with `~mem_exc_valid_i`. Found by: a whole-core formal cover on `trap_ctrl` (reachable 12 cycles after reset), confirmed by directed simulation. |
| **T-14** | `rtl/core/trap_ctrl.v` | OPEN | **A bus error on the instruction directly before a WFI leaves the core asleep in the fault handler.** While the faulting access waits on the D-port, the WFI sits in EX and arms `wfi_active` (`rtl/core/trap_ctrl.v:168`): EX-point exceptions are gated by `~h2` (`:138`), so `wfi_squashed` is 0. When the access ends in ERROR the trap squashes the WFI, but the latch is cleared only by `wake_cond` (`:169`), so the handler is fetched and then held until an interrupt becomes pending; with none, the core hangs. A directed test, `lw` to an erroring address followed by `wfi` with interrupts disabled (`sw/tests/t_lead2_wfi_buserr.S`, proposed with this entry), times out after 6 retired instructions instead of reaching the handler on two simulators, with and without wait states; AHB checker clean, `t_buserr` passes on the same build. The T-11 symptom by another route. Proposed fix (with T-13, not yet applied): do not arm the latch while `h2` (`... & ~wfi_squashed & ~h2`). Found by: a whole-core formal cover on `trap_ctrl` (reachable 12 cycles after reset), confirmed by directed simulation. |
| **PWM-2** | `rtl/pwm/garuda_pwm_core.v` | OPEN (owner to rule) | **The PWM pins are driven combinationally, so an output can glitch when two of its inputs change on the same edge; severity depends on the minimum pulse width the ESC input can register.** `pwm_o[c] = en_i & ch_en_i[c] & (cnt_q < duty_s[c])` (`rtl/pwm/garuda_pwm_core.v:101`) has no output register. A CTRL write `0x0F0` to `0x051` turns EN on and channel 1 off on the same `pclk` edge; a 4-state event-driven run shows a zero-width pulse on channel 1 and `tb_pwm` reports 2 [FAIL] for [N-6.1] (`4 1 4 1`, `5 violations`), while simulators that settle both updates first pass (58/0). In silicon the two flops have different clock-to-Q, and the magnitude comparator can also glitch while `cnt_q` changes. GARUDA-PWM-SPEC-001 §1.1/§1.3: these pins drive ESCs, and the block is in-house so that no register combination can glitch an output. Proposed (not applied): register the compare and keep the enables as an AND on the output, which keeps the [N-7.5] immediate stop. Found by: Icarus run of `tb_pwm`. |
| **PWM-3** | `rtl/pwm/garuda_pwm_top.v` | OPEN (hardening) | **The read-mux loop variable `k` is inferred as a latch and then optimised away.** `integer k` (`rtl/pwm/garuda_pwm_top.v:65`) is assigned only inside the `default:` branch of the combinational read mux (`:114-122`), so Yosys `proc_dlatch` infers latches for `k` (three warnings in the whole-chip synthesis log); they have no fanout and are removed, and the final latch list holds only `core_clk_gate`. Harmless today; other tools may report it. A loop variable local to the block avoids it. Found by: Yosys whole-chip synthesis (`scripts/run_synth.sh`). |
| **UART-4** | `rtl/third_party/pulp/apb_uart_sv/src/apb_uart.sv` | OPEN (vendored) | **One byte of the vendored UART register array is not reset inside an asynchronous-reset block.** `regs_q` is `logic [9:0][7:0]` (`apb_uart.sv:42`); the reset branch of `always_ff @(posedge CLK, negedge RSTN)` (`:328-342`) assigns nine entries (IER, IIR, LCR, MCR, LSR, MSR, SCR, DLL+8, DLM+8) but not index 0, so that byte holds its value through reset. Yosys reports `Async reset value ... is not constant`; synthesis must build it as a flop with RSTN acting as a data enable (a reset-in-data-path lint item), and the byte powers up undefined. Benign if firmware never reads it before writing it. A one-line vendor patch adds it to the reset branch. Found by: Yosys whole-chip synthesis. |
| **TB-30** | `tb/soc/tb_chip.sv` | OPEN (testbench) | **`tb_chip` never gives the reset pin a falling edge, so RSTREASON reads EXT only if the simulator makes one at time zero.** `tb/soc/tb_chip.sv:21` starts `ext_rst_n` at 0. EXT is set only by the async branch at `rtl/reset_ctrl/reset_ctrl.v:139-141`, and `aon_clk` (`t1_q`, `rtl/clk_div/clk_div.v:66-69`) stays at 0 while the pin is low. Under Verilator 5.052 the three programs that read RSTREASON fail step 1 (`sw/chip/t_chip_basic.c:37`, `t_chip_wdt.c:25`, `t_chip_flash.c:45`); the four non-JTAG programs that do not read it pass. Xcelium evidently makes the edge (all eight passed on 2026-10-04); TB-22 found that Icarus does not. A copy that starts the pin high and drops it at 0.5 ns passes all seven non-JTAG programs. Same class as TB-22, whose fix covered five block benches but not this one. Silicon clears are level-sensitive: no confirmed RTL defect. Found by: a Verilator run of the stage 6 chip programs, then that diagnostic copy. |
| **TB-32** | `tb/core/tb_garuda_pc_gen.sv` | OPEN (testbench) | **`tb_garuda_pc_gen` checks the reset vector at 3 ns, before the first clock edge, relying on a time-zero reset edge the bench never makes.** `rst_n` is a `bit` (line 100), already 0, so `rst_n = 0` at line 170 is no event; the checks at lines 175-177 pass only if the simulator makes a falling edge on the DUT's 4-state `rst_n_i` net at time zero (`rtl/core/garuda_pc_gen.v:44-47`). Xcelium evidently does (the bench passes there, TB-27); under Verilator 5.052 both checks fail, expected 0x10000000, got 0x0. The rising edge at 5 ns resets the DUT anyway, and the re-reset checks after a real falling edge (lines 253-255) pass. Same class as TB-22. No confirmed RTL defect. Found by: a Verilator run of the element bench. |
| **TB-33** | `tb/core/tb_id_stage.sv` | OPEN | **The constrained-random sequences can never generate a bubble.** `c_defaults` forces `valid_val == 1` (line 561) while `c_op_shape` requires `valid_val == 0` for `IDK_RESET_BUBBLE` and `IDK_BUBBLE_WITH_FAULT` (575, 576), together 8 of the 110 `dist` weight (7.27%). A solver that honours the hard constraints must exclude both ops. Verilator 5.052 instead fixes `op` from the weights before solving, so 218 of 3 000 `randomize()` calls (7.27%) fail at line 769; each failed item is left as constructed (op 0, valid 0, instruction, PC and controls 0) and driven as an identical idle bubble. Either way the random mix never produces a bubble with a fault, a write-back or a load in EX; the six directed bubble cycles include one with a fault and none with the others. The bench still reports 3 067 PASS, 0 FAIL. Found by: Verilator run of `U_id_stage` (218 `[GEN] randomize() failed` errors behind a PASS summary). |
| **ELEM-8** | `tb/core/tb_d_port_ahb_master.sv` | OPEN (testbench) | **The soak's teardown withdraws a transfer still waiting in its address phase.** The loop re-rolls the request only while `mem_stall` is low (lines 361-367), but line 372 drops `start` at the next negedge after the 600th iteration without waiting for the access to finish. With Verilator 5.052's default seed the last access is a NONSEQ to `0xE4590028` held by HREADY low at 6255 and 6265 ns; `start` falls at 6270 ns, HTRANS returns to IDLE and `a_addr_stable` fails at 6275 ns, yet the bench prints 67 of 67 checks passed. Of seeds 1 to 12 (1 is the default) only seed 1 fails. Lines 368-369 also draw HREADY and HRESP independently, so all 17 soak ERROR responses in that run last one cycle, which AHB-Lite does not allow. HTRANS follows `start_i` combinationally, relying on the pipeline hold; no confirmed RTL defect. Found by: a Verilator run of the element bench, traced with a bound SV monitor. |
| **TOOL-12** | `tools/lockstep.py` | OPEN | **The Spike lockstep says MATCH when Spike's log is the one that ends early.** It compares the first `min(len(gold), len(rtl))` commits (line 159) and fails only an RTL log more than 3 short (168-172); when it runs Spike it does not read Spike's exit status (146), and only an empty Spike log is rejected (154). Negative control: the `add` Spike log cut to its first 213 commits (full log 428, RTL 427) prints `MATCH: 213 instructions identical` and exits 0. `scripts/run_regression.sh` and `flow/regress/run_test.sh` treat that line as a pass, so a Spike run that died part-way would leave the rest of the test checked only by its tohost self-check. Also failing when `len(rtl) - len(gold) > 3` closes it. By design only (pc, rd, value) is compared; CSR side effects and store data are not (lines 17-25). Found by: negative control N4 (truncated Spike log). |
| **TOOL-13** | `Makefile`, `scripts/run_sim.sh` | OPEN | **The Makefile's simulation macros and the Icarus runner never use the simulator's exit status.** Under `SIM=xrun`, `run_test` (lines 42-49), `run_tb_top` (119-128), `run_tb_elem` (173-184) and `run_blk` (215-223) run `$(XRUN) ...;` and then grep or printf the log; each recipe ends in printf, a grep with an echo fallback or a grep piped into head, so the target exits 0 whatever xrun returned. TOOL-11's SVA_FAIL count is printed, not returned. In `scripts/run_sim.sh`, `run_one` checks vvp's status only for the timeout code 124 (line 158) and returns 0; `verdict_of` (172-186) uses the last PASSED, FAILED or TIMEOUT word and the `[FAIL]` count. Exit status alone is not enough either: Verilator 5.052 with `+verilator+error+limit+1000` exited 0 after 8 assertion failures. A sound verdict needs exit status, pass marker and failure counts together. Found by: code reading during the independent audit; the Verilator figure comes from an SVA self-test. |
| **TOOL-14** | `scripts/run_coverage.sh` | OPEN | **The older coverage script cannot fail because a test failed.** `scripts/run_coverage.sh` sets only `set -u` (line 33), discards each `irun -R` run's console output without reading its exit status (88-91) and judges the run only by grepping its log for the TOHOST pass marker (93-95), so a run with assertion failures can still read PASS; a FAIL or TIMEOUT run's scope is merged anyway (97). The six unit benches are judged by `[FAIL]` lines only (134), without the `*E,ASRTST` count TOOL-11 added to the Makefile, and are merged regardless (136). IMC errors are only printed (159) and the script ends on an `echo` (168), so it exits 0 unless elaboration fails or no scope exists (57-59, 140). `make coverage`, `Docs/COVERAGE.md:49` and `Docs/HANDOFF.md:403` still point to it; the vManager flow (`flow/regress/run_test.sh:94-97`) fails a run on any `*E`. Found by: reading the script after TOOL-11. |
| **TOOL-15** | `scripts/expand_filelist.py` | OPEN | **The filelist expander silently drops `-define` lines.** `scripts/expand_filelist.py:59-62` skips every line beginning with `-` other than `-f` and `-incdir`, and still exits 0. Seven filelists carry a define: `tb/core/filelist_{decode_control,imm_gen,reg_file,branch_predict,hazard_forward_unit,id_stage}.f` (`GARUDA_REAL_RTL`, which removes each bench's inlined DUT snapshot) and `tb/soc/filelist_boot_cov.f` (`GARUDA_COV`, which enables `tb_boot`'s coverage self-report). Expanded by this script, a unit bench gets the real RTL and a snapshot module of the same name (for example `rtl/core/decode_control.v:21` and `tb/core/tb_decode_control.sv:59`), so it cannot be built as xrun builds it. Latent today: `run_sim.sh`, `make local_lint` and `run_synth.sh` read none of the seven, although `run_sim.sh`'s header promises the same source list as xrun. Found by: building the unit benches under Verilator, where a replacement expander had to restore the defines. |

---

## 1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)

Work restarted against the stage 0 to 8 flow: a feature-level vPlan per block with
sign-off criteria fixed first (`flow/0_signoff_criteria.md`), then static checks,
then a UVM environment per block. Entries here are found on that pass. Three entries were first written under other numbers and were renumbered on 2026-10-05, because section 1i was published with those numbers first: T-15 was T-13, PWM-4 was PWM-2 and TOOL-16 was TOOL-12; this section itself was 1i.

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **T-12** | `rtl/core/csr_file.v` | **OPEN, fix needs an owner decision** | **P1** | **A second trap inside an interrupt handler leaves the interrupt level wrong.** The core keeps one saved level (`mpil`). It is pushed on an interrupt, popped on every `mret`, and no CSR lets software read or write it (`mintstatus` is read-only and `mcause` does not carry it). Two consequences, both reproduced on the unmodified RTL with a 40-line bench driving `csr_file` directly. (a) Nested interrupts: handler A at level 80 is preempted by B at level 200; after B returns the level is 80 (correct), after A returns it is **still 80** where it must be 0, so every interrupt at level 80 or below is blocked until reset. (b) An exception inside a handler (illegal instruction, bus error, or the software divide, which is an illegal-instruction trap): the exception does not push, its `mret` pops, and the level drops to **0 while still inside handler A**; if A has re-enabled interrupts, its own still-asserted source re-enters it. A handler that never re-enables `mstatus.MIE` is not affected by either, which is why no existing test saw it: CLIC §8.3 and §11 plan nesting tests to depth 3 and none was ever written (AUD-11). The standard CLIC answer is `mcause.mpil` (bits 23:16), saved and restored by the handler with `mcause`, and a push on every trap. That changes what a handler reads in `mcause`, so it is the owner's call. | reading `csr_file.v` against CLIC §7.4/§8.3 while writing the CLIC feature plan (feature F27, F28) |
| **TOOL-16** | irun 15.20 with UVM | OPEN (tool, worked around) | P3 | Every UVM simulation under irun 15.2 prints `ncsim: *E,IMPDLL: Unable to load the implicit shared object` (`(null)/top/sv/_sv_export.so`): irun does not build its own stub library for UVM's DPI exports on this machine. Tried `-dpi`, `-snsvdpi`, `-gcc_vers 4.8`, UVM 1.1d, `UVM_NO_DPI`, 32-bit mode; none removes it. The simulation runs and the coverage database is written, and Xcelium 22.09 runs the same environment with no message. irun is used because IMC here reads only its databases. `make uvm_clic` ignores exactly this one line and fails on any other error. | first UVM run on irun |
| **VER-1** | CLIC UVM environment, negative control | DONE | n/a | **Does the new environment catch bugs?** Five real defects were planted in copies of the CLIC RTL, one at a time: ties going to the highest ID, the enable mask dropped, an extra offset decoded, the level of a non-candidate not gated, CLICIP read through the enables. **All five fail both the directed and the random test**, each caught independently by the scoreboard and by a bound property. A sixth mutant, `>=` changed to `>` in the selection compare, passes, and correctly: the compared keys are never equal, so it is the same circuit. | mutation run, 2026-10-04 |
| **RDC-1** | `rtl/core/garuda_core_top.v`, `rtl/debug` (halt by reset) | **OPEN, reproduced** | P2 | **A debugger halt resets the core at an arbitrary cycle, under a bus that is not in reset.** `hartreset` goes straight from a Debug Module flop into the core's asynchronous reset. If the core is in the waited data phase of a store (any peripheral write, about eight cycles), its write data and the address phase behind it change mid-transfer: the store in flight would complete with the wrong data and the next transfer is withdrawn, which AHB-Lite does not allow. From the reset-domain review (`flow/2_static/rdc_review.md`, crossing 5); **Reproduced on the unmodified RTL** by forcing `hartreset_n_i` low for 23 ns at 50 moments while `t_mem` runs with five data-port wait states: at 3139 ns the bus checker reports *"HWDATA changed during a wait state of its own write data phase"*; the other 49 moments fell outside a store. So the word being stored when the debugger halts the core is written with the wrong value. No existing test halts a core that is doing anything: `t_chip_jtag` halts it while it idles in the boot ROM. A permanent test is planned as `t_core_hartreset` (core plan F37); the fix is a design choice (finish the transfer in flight before the reset takes effect) and has not been made. | reset-domain review, stage 1 |
| **AUD-12** | specifications against RTL and against each other, all 16 blocks | **OPEN, each needs a ruling** | P2 | **Found while writing the feature-level plans (stage 0): 512 features, of which 27 are places where a specification is silent, out of date, or disagrees with the RTL or with another document.** Each is marked in its plan row. The ones where RTL and document disagree outright: (1) **DMA reach** - `garuda_system.yaml` and the AHB spec let the DMA address ISRAM; the DMA spec (R-9) and the DMA RTL refuse it. (2) **Clock gates that do not exist** - DMA [N-9.3] says a disabled channel receives no clock and DSU section 5 says the unit has its own idle gate; neither `rtl/dma` nor `rtl/dsu` contains a gate. (3) **Branch prediction** - CORE [N-7.1], [N-7.2] and section 13 say there is none; the RTL has a static predictor (`branch_predict.v`). (4) **Watchdog warning** - TIMERS [N-6.6], [N-6.8] say it is high for the one cycle the count equals the threshold; the RTL holds it while the count is at or below it (decision D-17). (5) **Register sources** - six specs name `spec/regs/<block>.yaml` as the machine-readable register source; the directory does not exist. (6) **Window numbers** - AHB2APB still says eleven windows and that window 0 is unmapped; MEM and AHB2APB place MEMCTL in window 8; the map has twelve windows, window 0 is the SPI slave and MEMCTL is in the reset controller's window. (7) **DMA CR** - the register table gives reset value 0 while SIZE resets to 2; a write of SIZE 3 is refused by the RTL and not mentioned in the spec. (8) **CLIC** - the ID map, [N-6.3] and four assertions in section 10 still describe the map before INT-2 and INT-3; [N-7.6] describes a two-stage tree where the RTL is a binary tree. (9) **mepc** - without the compressed extension both low bits should read zero; the RTL masked bit 0 only. Checked against Spike on 2026-10-05, confirmed and fixed as T-15. The remaining items are behaviours no document defines (what a write does when a FIFO is full, a second DIVSEL write while one is pending, which cause wins when two resets coincide, and similar); they are listed in the plans as open questions. | reading every spec feature by feature for the plans |
| **T-15** | `rtl/core/csr_file.v` (mepc write) | **FIXED** | P3 | **mepc bit 1 was writable.** Only bit 0 was masked. GARUDA has no compressed instructions, so the privileged specification makes both low bits of mepc always zero. Before the fix, on the unmodified RTL: `csrw mepc` with all ones read back `0xFFFF_FFFE` (Spike: `0xFFFF_FFFC`), `0x1000_0002` read back unchanged (Spike: `0x1000_0000`), and an `mret` to an mepc with bit 1 set put a misaligned address on the instruction port: the bus checker reported *HADDR is not aligned to HSIZE* ten times while the program still ended in PASS, because the memory ignores the low address bits. A handler that adds 2 to mepc, as code written for a core with compressed instructions does, would do this. Fix: the write masks both bits. Directed test added to the ISA regression: `sw/riscv-tests/local/csr_warl.S` (`p-csr_warl`), which writes all ones, zero and misaligned values to each writable CSR, returns through a misaligned mepc, and is compared with Spike value by value. After the fix: 64 ISA tests, 12 sanity programs, 8 chip tests, the unit benches and the DSU run pass; lint unchanged. This was item 9 of AUD-12. | the extended lockstep (VER-3), first new test |
| **VER-3** | `tools/lockstep.py`, `tb/soc/tb_boot.v` | DONE | n/a | **The Spike lockstep now compares stores, traps and CSR values, not only the PC and register writes.** The commit log gained three records (`MEM`, `CSR`, `TRAP`; see the header of `tb_boot.v`) and the tool compares each as an ordered stream against what Spike logs. On the 58 tests that are compared with Spike: 24,946 instructions, 2,873 stores (address, size, data), 110 traps (cause, epc, tval) and 1,019 CSR instructions (397 with a value) are identical. Two differences are by specification and are written into the tool or kept out of the test with the reason: mtvec MODE reads 3 on GARUDA (CLIC only), and GARUDA has no software or external interrupt enable in mie and a hardwired misa. Negative control: a store with one data bit changed, a duplicated store, a removed trap, a changed mepc value and a changed mtvec base in an RTL log are each reported as a divergence. Interrupts are still outside the compare: Spike is not told when the RTL takes one. **Random programs:** riscv-dv (`~/external/riscv-dv`, target and test list in `tb/core/riscv_dv/`, `make riscv_dv`) generated 200 programs, ten test types over 20 seeds each (arithmetic corners, random instructions, jump stress, loops, random jumps, load/store stress, illegal instructions, ebreak, misaligned access): all 200 end in PASS on the RTL and match Spike on 2,458,733 instructions, 357,979 stores, 5,614 traps and 210,840 CSR instructions. No RTL defect was found by them. **Two defects of the comparison itself were found and fixed on the way:** it reported MATCH when Spike's log was shorter than the RTL's (Spike's instruction limit charges a whole 5,000-instruction slice per trap and stopped at the first one, so 84 of 241 instructions had been compared), and it compared against a Spike that has PMP and trigger CSRs GARUDA does not have. A short Spike log is now a MISMATCH and Spike is run with `--pmpregions=0 --triggers=0`. The first of these is the defect section 1i records as TOOL-12, found independently in the audit; its other half, that Spike's exit status is not read, is still open. | stage 3 of the flow |
| **PWM-4** | `rtl/pwm/garuda_pwm_core.v` (prescaler compare) | **FIXED** | P2 | **Lowering PRESCALE while running froze the outputs for up to 65,536 clock cycles.** The tick was `prescaler == PRESCALE`. A PRESCALE written below the running count is never matched: the prescaler counts on to 0xFFFF and round, and until then there is no tick, the frame counter stands still and every pin stays as it was. A pin that was high stayed high for up to 0.52 ms at 125 MHz, on an output whose whole pulse is 1 to 2 ms. Reproduced on the unmodified RTL: PRESCALE 7, PERIOD 10, duty 6 on four channels, PRESCALE written to 2 with the pins high: all four still high 163 cycles later, where a frame is 80. PWM [N-7.1a] tells firmware to stop the block before changing PRESCALE, so this needs a firmware mistake; but a stretched pulse on a motor output is the one thing the block's design note says no register write can produce. The cycle-by-cycle model did not see it, because it was written with the same equality; the check that did is measured on the pins alone (`sb_no_stuck_high`: no pin with a duty below the period stays high for more than two frames). Fix: `>=`, the same hardening the period compare got in PWM-1; the tick in progress now ends in the next cycle. Added: property `a_tick_no_stall`, and the directed case that lowers PRESCALE at each count of the prescaler (`pwm_directed_test`, F17). After the fix: PWM UVM 22 of 22, `tb_pwm` 58 checks, 8 chip tests. | PWM UVM environment, random test, first run |
| **C-16** | `rtl/core/csr_file.v` (CSR address decode) | **OPEN, needs an owner decision** | P3 | **Four groups of CSRs that the privileged specification says exist are answered with an illegal-instruction trap.** The core specification cites privileged v1.12. That version has `mstatush` on RV32, `mconfigptr`, `mhpmcounter3` to `31` with their high halves, and `mhpmevent3` to `31`; each may read zero, but an access must not trap. GARUDA traps on all 89 addresses. Found by reading every one of the 4,096 CSR addresses on the RTL and on Spike and comparing the two maps (`tools/csr_map.py`, `make csr_map`): GARUDA has 26 addresses, 21 of them in common with Spike; 5 only on GARUDA (CLIC registers and the DSU flag, by design); and on Spike only, besides these 89, `mcountinhibit`, the trigger registers and `time`, which are optional. Firmware written for GARUDA does not touch these registers; code that is not written for it (a library that clears the hpm counters at start, a debugger reading `mconfigptr`) takes a trap. The fix is a decode that reads zero and ignores writes, about six lines; it changes the CSR table in CORE 6.1, so it is the owner's choice between that and recording the omission in the specification. The map tool keeps the list: a new difference with no recorded reason fails `make csr_map`. | CSR sweep, after two riscv-dv programs diverged on CSR existence |
| **AUD-13** | register ports of all blocks | **OPEN, needs a ruling** | P3 | **Two things about PSLVERR are decided block by block and written nowhere.** (1) A write to a read-only register: the timers (WDTVAL) and the DMA (status registers) answer PSLVERR; the CLIC (CLICINFO, CLICIP), the reset controller and every block behind the shared shim (PWM STATUS, every ID register) ignore the write silently. (2) An offset that is not word aligned: the timers and the CLIC answer PSLVERR; the shim answers PSLVERR in its own range (0xFE1) and nothing at all inside the IP range (0x001 reads 0, no error). The second cannot happen in the chip, because the bridge refuses sub-word accesses and passes word addresses; the first can. Firmware that relies on a bus error to catch a write to a status register gets it from two blocks out of sixteen. The PWM plan had assumed the timers' behaviour for both; its rows now state what the specification and the RTL do. One rule for the whole chip should be written in the bridge specification. | writing the PWM reference model from the specification |
| **VER-4** | PWM UVM environment, negative control | DONE | n/a | **Does the PWM environment catch bugs?** 21 defects planted one at a time in copies of the PWM core, the PWM top and the shared shim: the prescaler compare put back to equality (PWM-4), the tick one cycle long, no double buffer, no clamp, the channel enable ignored, the pulse one tick long, the counter kept while stopped, a stop that takes effect a cycle late, the channel enables taken from the wrong bits, the clamp flags missing from STATUS, the clamp event as AND instead of OR, PRESCALE stored in 15 bits, a write landing in the setup phase, the interrupt status not sticky, a clear beating its own event, the interrupt not masked by its enable, an alias of IRQEN decoded for reads and one for writes, bit 11 ignored for the IP registers, the IP range one register too long, a 5-bit compare for the duty registers. **20 are caught**, most by a bound property, the cycle compare and a measured-waveform check independently. The 21st, the 5-bit duty compare, passes, and correctly: the shim never selects the IP at the addresses where it would differ. Two of the 20 (the two IRQEN aliases) are caught only by the alias sweep added after VER-2; the random test alone does not reach those addresses often enough. A comment-only change was run as a control and passes. | mutation run, 2026-10-05 |
| **GPIO-2** | `rtl/third_party/pulp/apb_gpio/src/apb_gpio.sv`, `rtl/gpio/garuda_gpio_top.v`, GARUDA-GPIO-SPEC-001 | **OPEN, needs an owner decision** | P2 | **The GPIO specification and the vendored block disagree in five places.** Each is exercised by the directed test of the new environment; its reference model follows the block and says so at each line. (1) **The "level" interrupt type does not exist.** The register table gives INTTYPE `11` as level. The block decodes `00` falling, `01` rising and `10` either edge, and for `11` raises nothing, on either pin, for a rising edge, a falling edge or a steady level. Firmware that selects it waits for an interrupt that never comes. (2) **GPIOEN is not per pin.** [N-6.1] says bit n enables pin n's input path. The block runs the input flops of both pins when either bit is set (it gates in groups of four pins), so with only GPIOEN[0] set PADIN[1] is live; with both clear PADIN holds its last value instead of reading 0; and a pad that moves while the path is stopped is delivered as an edge, with its interrupt, when the path is started again. (3) **Offsets the register table does not list answer without an error:** 0x20 and 0x2C to 0x7C are inside the vendored register file (the wrapper passes everything below 0x80), read 0 and ignore writes. (4) **[N-6.2] says only bits 1:0 of each register mean something;** INTTYPE uses 3:0 (two bits per pin) and PADCFG0 7:0. (5) **An INTSTATUS read in the cycle a new event arrives does not clear:** the bits already set stay set and the new one is added; nothing is lost, but a handler can see a pin it has already served. Only (1) can cost an interrupt. The choice for each is to correct the specification or to change the wrapper (the block itself is vendored); none was changed here. Also corrected in the plan: a pad reaches PADIN after five clock cycles (two flops in the shim, three in the block), not two. | writing the GPIO reference model from the specification |
| **VER-5** | GPIO UVM environment, negative control | DONE | n/a | **Does the GPIO environment catch bugs?** 18 defects planted one at a time in copies of the vendored block and the wrapper: rising and falling swapped, INTEN ignored, GPIOEN ignored, the set register acting as an assignment, the clear register not inverting, the shim synchroniser bypassed, the output enable taken from PADOUT, pin 1's type taken from the wrong bits, "either edge" firing on rising only, INTSTATUS replaced instead of accumulated, a read that does not clear, PADIN read one flop early, the decoded range halved, PADDIR resetting to 1, type 11 firing as rising, a second event dropped while the line is high, the input clock enabled per pin, and the edge detector skipping a flop. **All 18 are caught.** At least four of them (swapped edges, "either" as rising only, type 11 as rising, the skipped flop) are also reported by the checks that use only the pads, the registers and the pins (a settled pad is what PADIN reads; a qualifying edge raises the interrupt and nothing else does), which do not share the model's synchroniser; a run prints only its first 20 messages, so the count may be higher. A comment-only change was run as a control and passes. | mutation run, 2026-10-05 |
| **CRG-3** | `rtl/reset_ctrl/reset_ctrl.v`, `rtl/reset_ctrl/reset_ctrl_apb.v`, GARUDA-CLKRST-SPEC-001 | **OPEN, needs an owner decision** | P3 | **Three behaviours of the reset controller that the specification does not state, or states differently.** Each is exercised by the directed test of the new environment, with the value the RTL gives written as the expectation. (1) **The cause register is rewritten in every cycle a request is up, so of two requests that overlap, the one that ends last is recorded.** Requests in the same cycle are taken watchdog, then software, then debugger (the specification is silent, plan F26); but the watchdog's request lasts two or three cycles and the debugger's `ndmreset` is a level that can last much longer. If the debugger asserts `ndmreset` within those cycles of a watchdog expiry, RSTREASON reads NDM and the firmware's watchdog-recovery path is not taken, although the watchdog fired first and caused the reset. Reproduced: a one-cycle watchdog request with a six-cycle debugger request gives 0x4. A rare coincidence under a debugger; capturing the first cause until the counter runs out would remove it. (2) **A RSTCTL write that sets SWRST never completes in the chip,** because the reset it causes reaches the bridge before the end of the access. Its BOOTFAIL bit is taken (it is seen during the access); its DIVSEL bits are not. So `RSTCTL = (ratio << 8) | 1` does not change the ratio, and a plain `RSTCTL = 1` does not clear it. In a bench whose APB master is not reset with the bus, the DIVSEL bits do land: `tb_crg` and the first version of the shared UVM driver both behaved that way, which is not the chip's behaviour. The driver now drops PSEL at once on reset, as the bridge does. (3) **[N-7.16] justifies releasing the divider's reset unsynchronised "because the divider is a single toggle flop".** It is now seven flops on four clocks. The argument still holds, for a longer reason that should be written down: every one of them, and every flop of the reset controller released by the same pin, either is a free-running divider (any state is a legal state) or has its reset value at its input for the first two cycles. Also written into the plan from the RTL: BOOTFAIL is set by RSTCTL bit 4; a write to CLKSTAT is ignored without an error (AUD-13); the stretch is 1024 cycles of the always-on clock, which is 2048 reference cycles. | writing the clock and reset environment |
| **VER-6** | clock and reset UVM environment, negative control | DONE | n/a | **Does the clock and reset environment catch bugs?** 21 defects planted one at a time in copies of `clk_div.v`, `reset_ctrl.v` and `reset_ctrl_apb.v`: the stretch halved, the debugger's reset reaching the Debug Module, hartreset resetting the system, the cause priority swapped, the cause accumulated instead of replaced, the cause not clearable, the watchdog cause not recorded, the debugger's reset not stretched, DIVSEL reset by any reset, the lock clearable, BOOTFAIL on the wrong bit, the boot-select flag on the wrong bit, an extra offset decoded, the ratio switched at any moment instead of when all dividers are low, the wrong divider tap for ratio 4, DIVBUSY stuck low, pclk_phase inverted, pclk made from the wrong clock, the core's reset asserted synchronously, the preset synchroniser not chained to hreset, and one synchroniser flop on the reset pin instead of two. **19 are caught**, the clock ones by properties that measure time on the pins (a switch at the wrong moment shows as a short pulse on hclk and pclk). **Two are not, and neither is visible in an RTL simulation by nature:** the unchained preset synchroniser still releases after hreset because pclk is the slower clock, which is all the specification asks; and a one-flop synchroniser behaves like a two-flop one until a real flop goes metastable, which is what the static clock-domain check is for. The first version of the random test did not catch the un-clearable cause register; its clears were then widened from one bit to any mask. A comment-only change was run as a control and passes. | mutation run, 2026-10-05 |
| **SIM-1** | `rtl/clk_div/clk_div.v` line 118 (the pclk divider), seen through `rtl/timers/timers_apb.v` | **OPEN, needs an owner decision** | P3 | **RTL simulation and silicon disagree by one hclk cycle on every register that pclk captures from hclk.** pclk is made by a toggle flop on hclk written with a non-blocking assignment, so in simulation the pclk edge arrives one step *after* every hclk flop has already taken its new value. A pclk flop therefore captures the value an hclk flop launched on that same edge. On silicon the two clock trees are balanced and the pclk flop captures the value from before the edge (the 4 ns path the header of `timers_apb.v` describes). **Measured:** the timers UVM bench first used the same divider style and the reference model, which follows the specification, disagreed with the RTL on every live `WDTVAL` read by exactly one count (8 of 8 mismatches); with both clocks made in one process the model and the RTL agree on 20,449 reads. **Does anything functional depend on it?** A copy of the tree with the divider flop made blocking was run through the 15 block benches, the 8 chip tests and the 12 sanity programs: everything passes except `tb_crg`'s own `a_pclk_phase` monitor (277 reports), which samples `pclk_phase` in a way that depends on the old ordering. So today the only visible effect is that the chip simulation reads `WDTVAL` one count lower than the chip will; the bridge's hclk-to-pclk handshake is a toggle with a stable payload and does not care. The risk is for later code: a one-hclk pulse sent from hclk logic to a pclk register would be caught in simulation and missed on silicon, or the reverse, and no RTL test could tell. The usual fix is a blocking assignment in the divider flop, with `pclk_phase_o` moved to its own non-blocking flop and the `tb_crg` monitor corrected; it needs one lint waiver. Not made: it is the clock generator and the choice is the owner's. Other hclk-to-pclk captures known from the block-alone lint runs: `dma_top.u_apb.prdata_q` and the bridge's request toggle. | the timers scoreboard, first run |
| **VER-2** | timers UVM environment, negative control | DONE | n/a | **Does the timers environment catch bugs?** 23 defects planted one at a time in copies of `rtl/timers`: the compare made strict, the shadow latched on every cycle, the compare reset value, a kick accepted with one bit wrong, EN made clearable, the warning compare made strict, the request raised one count early, a reload taking effect without a kick, two strobes per write, two strobes per read, no error on the read-only register, an extra offset decoded, the low word read live, the 32-bit carry dropped, a kick at count 0 rescuing the system, read data made combinational, WARNEN locked after enable, the request not sticky, a write landing in the setup phase, an alias of the kick register decoded, an alias of MTIME_LO latching the shadow, address bit 11 ignored. **22 are caught**, most by the scoreboard and a bound property independently. The other one, read data allowed to change after the access has ended, passes, and correctly: nothing on the bus can see it. One of the 22 (the alias of the kick register) survived the first version of the environment, which had no aliasing stimulus; a directed alias sweep, alias bins in `cg_tmr_apb` and the property `a_unmapped_no_strobe` were added because of that. A comment-only change was run as a control and passes. | mutation run, 2026-10-04 |

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

### TB-15 — the AHB protocol checker flags the AMBA-legal error cancel  ·  `FIXED 2026-10-03` · **Severity: low**

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

### TB-23 — `viol()` silently truncated its own messages  ·  `FIXED 2026-10-03` · **Severity: low (misleading logs)**

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
