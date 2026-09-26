# GARUDA Timers and Watchdog — Design Specification

## 0.1 Identity

| Field | Value |
|---|---|
| Document ID | GARUDA-TIMERS-SPEC-001 |
| Revision | 2.0 |
| Date | 2026-09-18 |
| Status | Released for implementation |
| Block | 11 (`timers`) |
| Owner | Team AeroSoC |
| Supersedes | GARUDA_Timers_Design_Spec_v1_0 |

## 0.2 Revision history

| Rev | Change | Driver |
|---|---|---|
| 1.0 | Initial. 64-bit `mtime`/`mtimecmp` exported to the core; `mtip` routed via CLIC ID 13 | — |
| 2.0 | The 64-bit comparison moves into this block; a single `mtip` wire goes to the core, removing 128 top-level signals and a 64-bit comparator from the core's timing cone. Watchdog request flop moved to the external-reset domain. Early-warning interrupt added on CLIC ID 22. | ADR-0010, 0003 |

## 0.3 Normative references

1. RISC-V Privileged Architecture v1.12 — `mtime`, `mtimecmp`, `mip.MTIP`.
2. `GARUDA-SYS-001` Rev 4.0.
3. `GARUDA-ADR-001` Rev 1.0.
4. `GARUDA-CLKRST-SPEC-001` Rev 2.0 — the watchdog reset path and its domain.
5. `GARUDA-CLIC-SPEC-001` Rev 2.0 — ID 22 for the early warning; ID 13 reserved.

---

## 1 Purpose and scope

### 1.1 In scope

Two counters:

- **Machine timer** — the RISC-V architectural timer. 64-bit `mtime`, 64-bit `mtimecmp`, and the comparison that produces `mtip`. Drives the 1 kHz flight loop.
- **Watchdog** — 32-bit down counter with an early-warning interrupt and a reset on timeout.

### 1.2 Out of scope

- The reset stretching and domain logic for `wdt_rst_req` (`GARUDA-CLKRST-SPEC-001` §7).
- The trap entry for `mtip` (core).

### 1.3 The change that matters in Rev 2.0

Rev 1.0 exported `mtime` and `mtimecmp` as 64-bit buses to the core, and additionally routed
`mtip` through CLIC ID 13. That meant:

- 128 wires crossing the top level for one bit of information.
- A 64-bit comparator inside the core (`garuda_core_top.v:126`), in a design whose critical path is already the 33×33 multiplier in EX.
- Two delivery mechanisms for one interrupt, because the core implements `mip.MTIP` directly *and* three documents said it arrived via the CLIC.

Rev 2.0 does the comparison here and sends one wire. The core keeps its existing, verified
`mip.MTIP` path; the 64-bit ports and the in-core comparator are deleted (RTL delta R4).

---

## 2 Requirements

| ID | Requirement | Source |
|---|---|---|
| R-1 | 64-bit monotonic `mtime` counter, readable by firmware. | Priv spec |
| R-2 | 64-bit `mtimecmp`, writable by firmware. | Priv spec |
| R-3 | `mtip` shall be delivered to the core as a single wire. | ADR-0010 |
| R-4 | A 32-bit read of `mtime`'s halves shall never return a torn value. | Priv spec |
| R-5 | Writing `mtimecmp` shall not produce a spurious `mtip`. | Priv spec |
| R-6 | 32-bit watchdog with a programmable timeout and a magic-value kick. | Safety |
| R-7 | The watchdog shall raise an interrupt before it resets, so firmware can record why. | Safety |
| R-8 | The watchdog's reset request shall not be cleared by the reset it causes. | ADR-0003 |
| R-9 | The watchdog shall not be disableable once enabled. | Safety |

---

## 3 Block diagram

```
   ┌────────────────────────────────────────────────────────────┐
   │                     timers  (block 11)                     │
   │                                                            │
   │  ┌──────────────────────────────────────────────────┐      │
   │  │  MACHINE TIMER                                   │      │
   │  │                                                  │      │
   │  │  ┌────────────┐      ┌──────────────┐            │      │
   │  │  │ mtime      │      │ mtimecmp     │            │      │
   │  │  │ 64-bit up  │      │ 64-bit       │◀── APB     │      │
   │  │  └─────┬──────┘      └──────┬───────┘            │      │
   │  │        │                    │                    │      │
   │  │        │  ┌─────────────────▼──────┐             │      │
   │  │        └─▶│  64-bit comparator     │             │      │
   │  │           │  mtime >= mtimecmp     ├─────────────┼──────┼──▶ mtip_o
   │  │           └────────────────────────┘             │      │   (1 wire)
   │  │        │                                         │      │
   │  │        ├─▶ ┌──────────────┐                      │      │
   │  │        │   │ hi shadow    │── coherent 64-bit    │      │
   │  │        │   │ latch        │   read  (§7.2)       │      │
   │  │        │   └──────────────┘                      │      │
   │  └──────────────────────────────────────────────────┘      │
   │                                                            │
   │  ┌──────────────────────────────────────────────────┐      │
   │  │  WATCHDOG                                        │      │
   │  │                                                  │      │
   │  │  ┌────────────┐   ┌──────────┐  ┌─────────────┐  │      │
   │  │  │ wdt 32-bit │──▶│ == WARN  │─▶│ warn irq    ├──┼──────┼──▶ CLIC 22
   │  │  │ down ctr   │   └──────────┘  └─────────────┘  │      │
   │  │  │            │   ┌──────────┐  ┌─────────────┐  │      │
   │  │  │  kick ◀────┼───│ == 0     │─▶│ rst req flop│──┼──────┼──▶ wdt_rst_req
   │  │  └────────────┘   └──────────┘  │ (ext-reset  │  │      │
   │  │                                 │  domain!)   │  │      │
   │  │                                 └─────────────┘  │      │
   │  └──────────────────────────────────────────────────┘      │
   │                                                            │
   │  ┌──────────────────────────────────────────────────┐      │
   │  │  timers_apb  — window 11 (0x4000_B000)           │◀─ APB │
   │  └──────────────────────────────────────────────────┘      │
   └────────────────────────────────────────────────────────────┘
```

---

## 4 Sub-block inventory

| Name | Type | RTL file | Role |
|---|---|---|---|
| `mtime_ctr` | seq (hclk) | `mtime.v` | 64-bit up counter. |
| `mtime_shadow` | seq (hclk) | `mtime.v` | Upper-word holding register for coherent reads. |
| `mtimecmp_reg` | seq (hclk) | `mtime.v` | 64-bit compare value. |
| `mtime_compare` | comb | `mtime.v` | 64-bit unsigned `>=`. Produces `mtip`. |
| `wdt_ctr` | seq (hclk) | `wdt.v` | 32-bit down counter. |
| `wdt_warn` | comb | `wdt.v` | Early-warning threshold comparison. |
| `wdt_rst_req_flop` | seq (**ext-reset domain**) | `wdt.v` | Holds the reset request. See §7.6. |
| `timers_apb` | seq (pclk) | `timers_apb.v` | Window 11 register interface. |

---

## 5 Interfaces

| Port | Dir | Width | Domain | Reset | Description |
|---|---|---|---|---|---|
| `hclk_i` | in | 1 | hclk | — | |
| `hreset_n_i` | in | 1 | hclk | — | Resets `mtime`, `mtimecmp`, the watchdog counter. |
| `ext_rst_n_i` | in | 1 | async | — | Resets **only** `wdt_rst_req_flop`. See §7.6. |
| `mtip_o` | out | 1 | hclk | 0 | To the core's `mip.MTIP`. **The only timer signal the core sees.** |
| `wdt_warn_irq_o` | out | 1 | hclk | 0 | To CLIC ID 22. |
| `wdt_rst_req_o` | out | 1 | hclk | 0 | To `reset_ctrl`. |
| APB slave | — | — | pclk | — | Window 11. |

**[N-5.1]** `mtime_i` and `mtimecmp_i` as 64-bit inputs to the core are **deleted**. The
core's port list loses 128 signals and its in-core comparator; see RTL delta R4.

---

## 6 Register map — APB window 11 (`0x4000_B000`)

*(Window number corrected 2026-09-26: was stated as 10, inherited from the
0-based table in GARUDA-AHB2APB-SPEC-001. The hardware decodes window *n* at
`0x4000_0000 + 0x1000 x n` (`haddr[15:12]`), so the base address quoted here was
always right and only the index was wrong.)*

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | `MTIME_LO` | RW | 0 | `mtime[31:0]`. A read latches `mtime[63:32]` into the shadow. |
| 0x04 | `MTIME_HI` | RW | 0 | Reads the shadow, not the live upper word. |
| 0x08 | `MTIMECMP_LO` | RW | 0xFFFF_FFFF | `mtimecmp[31:0]`. |
| 0x0C | `MTIMECMP_HI` | RW | 0xFFFF_FFFF | `mtimecmp[63:32]`. |
| 0x10 | `WDTCTL` | RW | 0 | Watchdog control. |
| 0x14 | `WDTLOAD` | RW | 0xFFFF_FFFF | Reload value. |
| 0x18 | `WDTVAL` | RO | — | Current count. |
| 0x1C | `WDTKICK` | W | — | Magic-value write to reload. |
| 0x20 | `WDTWARN` | RW | 0 | Early-warning threshold. |

### 6.1 `MTIMECMP` reset value

**[N-6.1]** `mtimecmp` resets to all ones, not zero. A zero reset value would satisfy
`mtime >= mtimecmp` on the first cycle after reset and assert `mtip` before firmware has
installed a handler. All-ones means `mtip` cannot assert for 2⁶⁴ cycles — about 2,300 years
at 250 MHz — which is to say never until firmware sets it.

### 6.2 `WDTCTL` (0x10)

| Bit | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0 | `EN` | RW1S | 0 | Enable. Write 1 to set. **Cannot be cleared by software.** |
| 1 | `WARNEN` | RW | 0 | Enable the early-warning interrupt. |
| 31:2 | reserved | — | 0 | |

**[N-6.2]** `EN` is write-1-to-set and sticky, clearable only by reset. Rationale: a
watchdog that firmware can disable is a watchdog that a hung firmware path can disable. The
canonical failure is a stuck loop that happens to include a register write that clears the
enable. On a flight controller, a watchdog that can be switched off by the bug it exists to
catch is worse than no watchdog, because it creates false confidence.

**[N-6.3]** Once `EN` is set, firmware must kick within `WDTLOAD` cycles forever. There is
no way back. This is deliberate and must be stated in the firmware's startup documentation.

### 6.3 `WDTKICK` (0x1C)

**[N-6.4]** Writing `0x5A5A_C3C3` reloads the counter from `WDTLOAD`. Any other value is
ignored and sets no error.

**[N-6.5]** A magic value rather than any write: a wild pointer sweeping through the
peripheral address space, or a runaway `memset`, would otherwise kick the watchdog and mask
exactly the failure it should catch. A specific 32-bit constant makes an accidental kick
improbable.

### 6.4 `WDTWARN` (0x20)

**[N-6.6]** When `WDTVAL` equals `WDTWARN` and `WARNEN` is set, `wdt_warn_irq_o` asserts
(CLIC ID 22).

**[N-6.7]** Purpose: the warning fires while the core is still running, so the handler can
record diagnostic state — the current task, a stack pointer, a loop counter — into DSRAM
before the reset arrives. After the reset, `RSTREASON.WDT` says the watchdog fired and the
DSRAM record says what the firmware was doing. Without the warning, a watchdog reset tells
you only that something hung.

**[N-6.8]** The warning is level-triggered like every CLIC source, and asserts while
`WDTVAL == WDTWARN`, which is one `hclk` cycle unless the counter is stopped. Firmware's
handler must be short. Setting `WDTWARN` to roughly 10% of `WDTLOAD` gives the handler
90% of the timeout budget to run in.

---

## 7 Functional description

### 7.1 `mtime`

**[N-7.1]** `mtime` is a 64-bit up counter incrementing every `hclk` cycle. At 250 MHz one
tick is 4 ns and the counter wraps after about 2,300 years.

**[N-7.2]** `mtime` increments on `hclk`, not on a divided tick. Rev 1.0's rate was
`hclk`-derived too, so nothing changes, but it is worth noting the consequence: `mtime` is a
cycle counter, and a `DIVSEL` change (`GARUDA-CLKRST-SPEC-001` §6.2) changes its rate.
Firmware that uses `mtime` for wall-clock timing must recompute its scaling after any
frequency change. The 1 kHz loop reload value is `GARUDA_HCLK_HZ / 1000`, taken from the
generated header, so it follows the frequency automatically at compile time but not at
runtime.

**[N-7.3]** `mtime` is writable, as the privileged specification requires, so firmware can
set the epoch. A write takes effect immediately and can therefore cause `mtip` to assert or
deassert on the next cycle. That is correct behaviour and firmware should write `mtime` only
during initialisation.

### 7.2 Coherent 64-bit read

**[N-7.4]** A 32-bit bus cannot read 64 bits atomically. If firmware reads the low word,
the counter carries into the high word, and then firmware reads the high word, the
combination is wrong by 2³².

**[N-7.5]** The mechanism: reading `MTIME_LO` latches `mtime[63:32]` into `mtime_shadow` in
the same cycle. A subsequent read of `MTIME_HI` returns the shadow. So the sequence
read-`LO` then read-`HI` returns a coherent 64-bit value.

**[N-7.6]** Firmware must read `LO` first. Reading `HI` alone returns whatever was last
latched, which may be stale. This is stated in the register description and must be in the
firmware's timer accessor, not left to whoever writes the next driver.

**[N-7.7]** The same technique is used for the DSU accumulator taps
(`GARUDA-DEBUG-SPEC-001` §6.8).

### 7.3 `mtip` generation

**[N-7.8]** `mtip_o = (mtime >= mtimecmp)`, a 64-bit unsigned comparison, combinational from
the two registers, registered once before leaving the block.

**[N-7.9]** The comparison is `>=`, not `==`. With `==`, a `mtimecmp` write to a value
already passed would never match and the interrupt would be lost for 2⁶⁴ cycles. `>=` means
a late write asserts `mtip` immediately, which is the recoverable behaviour.

**[N-7.10]** `mtip_o` is level, not a pulse. It stays asserted until firmware advances
`mtimecmp` past `mtime`. This is the privileged specification's contract: the timer handler
clears the interrupt by writing the next deadline. A handler that returns without advancing
`mtimecmp` re-enters immediately.

### 7.4 Writing `mtimecmp` safely

**[N-7.11]** Writing a 64-bit compare value through 32-bit registers can transiently create
a value that is neither the old nor the new one. Writing `LO` first can make the pair
momentarily smaller than `mtime`, asserting a spurious `mtip`.

**[N-7.12]** The required firmware sequence, which the privileged specification also
prescribes:

```c
// 1. Set LO to all-ones. The pair is now unreachable, so mtip cannot assert.
MTIMECMP_LO = 0xFFFFFFFF;
// 2. Write the real HI. Safe: LO still blocks any match.
MTIMECMP_HI = (uint32_t)(next >> 32);
// 3. Write the real LO. The pair becomes valid atomically from mtip's view.
MTIMECMP_LO = (uint32_t)next;
```

**[N-7.13]** Hardware does not enforce this and cannot: it has no way to know a two-register
write is one logical operation. A write-enable side register could serialise it, but that
adds a register and a firmware step for a sequence the architecture already specifies. The
sequence is therefore a firmware requirement, stated here and in the driver.

**[N-7.14]** For the 1 kHz loop the deadline advances within the low word almost always
(`GARUDA_HCLK_HZ / 1000` = 250,000 ticks), so step 2 is only needed on a low-word wrap,
roughly every 17 seconds. The driver should still perform all three steps unconditionally;
the saving is not worth a conditional path that is exercised once every 17 seconds and
therefore almost never tested.

### 7.5 Watchdog counting

**[N-7.15]** `wdt_ctr` is a 32-bit down counter, decrementing every `hclk` cycle while `EN`
is set. At 250 MHz a full 32-bit count is about 17 seconds, so any practical timeout is
representable.

**[N-7.16]** A `WDTKICK` magic write reloads from `WDTLOAD`. Reaching zero asserts the reset
request.

**[N-7.17]** The counter does not run while `EN` is clear, and `WDTVAL` reads `WDTLOAD`.

**[N-7.18]** `WDTLOAD` is writable while running. The new value takes effect at the next
kick, not immediately, so a firmware bug that writes a tiny `WDTLOAD` does not cause an
instant reset — it causes one at the next kick, which is at least diagnosable.

### 7.6 The watchdog reset request and its domain

**[N-7.19]** `wdt_rst_req_flop` is reset by `ext_rst_n_i`, **not** by `hreset_n_i`.

**[N-7.20]** This is the requirement of ADR-0003 seen from the watchdog's side, and it is
the single most important sentence in this document. The watchdog's reset request causes
`hreset_n` to assert. If the request flop were in the `hreset_n` domain, that reset would
clear the flop, the request would deassert, and `hreset_n` would deassert — one flop delay
after it asserted. The result is a runt pulse that does not reliably reset anything, and it
is invisible in RTL simulation where reset is modelled as instantaneous.

**[N-7.21]** With the flop in the `ext_rst_n` domain, the request persists through the
reset it caused. `reset_ctrl`'s stretch counter (`GARUDA-CLKRST-SPEC-001` §7.2) then holds
the reset for its full 1024 reference cycles regardless of the requester's state, and the
request is cleared when the counter expires, by an explicit clear from `reset_ctrl` rather
than by the reset itself.

**[N-7.22]** `RSTREASON.WDT` is likewise in the `ext_rst_n` domain, so firmware can read
after the reset that the watchdog caused it.

### 7.7 Interaction with debug

**[N-7.23]** The watchdog continues counting while the core is held in `hartreset` by the
debugger. A debug session that stops the core for longer than the timeout will therefore
trigger a watchdog reset.

**[N-7.24]** This is accepted rather than fixed. The alternatives are worse: a debug-mode
freeze bit would need the DM to signal this block, and more importantly a watchdog that
stops for one reason will eventually be stopped for another. The practical workaround is
that the watchdog is not enabled until late in firmware initialisation, and a debug session
that needs to stop the core for a long time uses `boot_sel` = 1 so firmware never runs.
This must be in the bring-up notes, because the symptom — the chip resetting itself every
few seconds during a debug session — is confusing if unexpected.

---

## 8 Timing

### 8.1 `mtip` assertion and clearing

```
              │        │        │        │        │
hclk        ──┘‾┐_┌‾┐_┌‾┐_┌‾┐_┌‾┐_┌‾┐_┌‾┐_┌‾┐_┌

mtime       ──┤ N-2 │ N-1 │  N  │ N+1 │ N+2 │ N+3 ├
mtimecmp    ──┤         N         │    N+250000   ├
                                  ▲
                                  └── handler writes next deadline

mtip        ──────────────┌───────────┐──────────────
                          ▲           ▲
                          │           └── deasserts when mtimecmp > mtime
                          └── mtime >= mtimecmp  [N-7.8]

(in core)
mip.MTIP    ──────────────────┌───────┐──────────────
take        ──────────────────────┌─┐────────────────
```

### 8.2 Coherent 64-bit read across a carry

```
mtime[31:0]  ──┤ FFFF_FFFE │ FFFF_FFFF │ 0000_0000 │ 0000_0001 ├
mtime[63:32] ──┤        0000_0007      │      0000_0008        ├
                                        ▲
                                        └── carry into the high word

read MTIME_LO ──┌─┐
                 │  returns FFFF_FFFF
                 └── latches shadow <= 0000_0007

shadow       ──┤ ???? │   0000_0007 (held)                     ├

read MTIME_HI ──────────────────────────┌─┐
                                         │  returns 0000_0007,
                                         │  NOT the live 0000_0008
                                         └── result: 0000_0007_FFFF_FFFF ✓
```

Without the shadow, the pair would read `0000_0008_FFFF_FFFF` — high by 2³².

### 8.3 Watchdog: warning then reset

```
WDTLOAD = 250_000_000  (1 s),  WDTWARN = 25_000_000  (100 ms left)

WDTVAL      ──┤ ... │ 25_000_001 │ 25_000_000 │ 24_999_999 │ ... │ 1 │ 0 ├
                                        ▲                                ▲
warn_irq    ────────────────────────────┌──┐                             │
                                        │                                │
                                        └── handler writes diagnostics   │
                                            to DSRAM                     │
                                                                         ▼
wdt_rst_req ────────────────────────────────────────────────────────────┌────
                                                                        │
                        ═══ ext_rst_n domain: survives the reset ═══     │
                                                                        │
hreset_n    ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾╲___
                                                                   (1024 refclk)
```

### 8.4 The bug that [N-7.19] prevents

```
IF wdt_rst_req_flop were in the hreset_n domain:

wdt_rst_req ────────────────┌─┐──────────  asserts on WDTVAL == 0
hreset_n    ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾╲_┌‾‾‾‾‾‾‾‾‾‾  ◀── runt pulse, ~1 hclk
                              │
                              └── the reset cleared the flop, which
                                  deasserted the request, which
                                  released the reset

Result: the chip is not reset. It continues from a hung state with
        RSTREASON possibly clear. Invisible in RTL simulation.
```

---

## 9 Clock, reset and power

**[N-9.1]** Both counters and the comparator are in `hclk`. The APB interface is in `pclk`.
Register values cross synchronously, no CDC.

**[N-9.2]** Reset domains:

| Element | Reset by | Why |
|---|---|---|
| `mtime`, `mtimecmp`, shadow | `hreset_n` | Ordinary state. |
| `wdt_ctr`, `WDTCTL`, `WDTLOAD`, `WDTWARN` | `hreset_n` | The watchdog restarts disabled after any reset, so firmware must re-enable it deliberately. |
| `wdt_rst_req_flop` | **`ext_rst_n` only** | §7.6. |

**[N-9.3]** `mtime` resetting to 0 on a watchdog reset means firmware cannot measure how long
it was hung. Accepted: preserving `mtime` across reset would need it in the `ext_rst_n`
domain, 64 flops in a second reset domain, and the DSRAM diagnostic record from the early
warning already gives the useful information.

**[N-9.4]** Power: neither counter can be clock gated in any useful way. `mtime` must
increment every cycle by definition, and the watchdog must count while the core is asleep —
indeed especially then, since a core that never wakes from WFI is exactly what the watchdog
catches. 96 flops toggling continuously is the cost of having a timer.

**[N-9.5]** This block is therefore one of the few that stays fully active during WFI. The
core's WFI clock gate does not extend here.

---

## 10 Assertions

```systemverilog
// --- mtime is monotonic except on an explicit write
a_mtime_monotonic: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  !mtime_wr |=> (mtime == $past(mtime) + 1));

// --- mtip is exactly the comparison (R-3, N-7.8)
a_mtip_correct: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  mtip_o == (mtime_q >= mtimecmp_q));

// --- mtip is level, not a pulse: it holds until mtimecmp advances
a_mtip_level: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (mtip_o && !mtimecmp_wr) |=> mtip_o);

// --- mtimecmp resets to all-ones so mtip cannot assert at reset (N-6.1)
a_mtimecmp_reset: assert property (
  @(posedge hclk_i) !hreset_n_i |=> (mtimecmp_q == 64'hFFFF_FFFF_FFFF_FFFF && !mtip_o));

// --- coherent read: MTIME_HI returns the shadow, never the live value (R-4)
a_shadow_latch: assert property (
  @(posedge pclk_i) disable iff (!preset_n_i)
  (apb_read && apb_addr == 12'h000) |=> (shadow_q == $past(mtime_q[63:32])));
a_hi_returns_shadow: assert property (
  @(posedge pclk_i) disable iff (!preset_n_i)
  (apb_read && apb_addr == 12'h004) |-> (apb_rdata == shadow_q));

// --- THE watchdog domain property (R-8, N-7.19)
a_wdt_req_survives_hreset: assert property (
  @(posedge hclk_i) (wdt_rst_req_o && !hreset_n_i) |=> wdt_rst_req_o);
a_wdt_req_cleared_only_by_ctrl: assert property (
  @(posedge hclk_i) disable iff (!ext_rst_n_i)
  $fell(wdt_rst_req_o) |-> $past(wdt_req_clear));

// --- watchdog enable is sticky (R-9, N-6.2)
a_wdt_en_sticky: assert property (
  @(posedge pclk_i) disable iff (!preset_n_i) $fell(wdt_en) |-> 1'b0);

// --- only the magic value kicks (N-6.5)
a_wdt_magic_only: assert property (
  @(posedge pclk_i) disable iff (!preset_n_i)
  (apb_write && apb_addr == 12'h01C && apb_wdata != 32'h5A5A_C3C3)
    |=> $stable(wdt_ctr));
a_wdt_magic_reloads: assert property (
  @(posedge pclk_i) disable iff (!preset_n_i)
  (apb_write && apb_addr == 12'h01C && apb_wdata == 32'h5A5A_C3C3)
    |=> ##[0:2] (wdt_ctr == wdt_load));

// --- the counter only runs when enabled
a_wdt_stopped: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i) !wdt_en |=> $stable(wdt_ctr));

// --- reset request only at zero
a_wdt_req_at_zero: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  $rose(wdt_rst_req_o) |-> ($past(wdt_ctr) == 32'd0));

// --- the warning precedes the reset (R-7)
a_wdt_warn_before_reset: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (wdt_en && wdt_warn_en && wdt_warn_q != 0) ##1 $rose(wdt_rst_req_o)
    |-> $past(wdt_warn_irq_o, 1, 1, wdt_warn_q));

// --- warning asserts at exactly the threshold
a_wdt_warn_at_thresh: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (wdt_en && wdt_warn_en) |-> (wdt_warn_irq_o == (wdt_ctr == wdt_warn_q)));

// --- no 64-bit timer bus leaves this block (R-3)
// structural, checked at integration review, not simulation
```

---

## 11 Verification plan

| Req | Test | Oracle | Coverage goal | Status |
|---|---|---|---|---|
| R-1 | `t_mtime_count` | increments every cycle; 32-bit boundary crossing | low-word wrap | new |
| R-1 | `t_mtime_write` | write takes effect immediately | — | new |
| R-2 | `t_mtimecmp_rw` | both halves readable and writable | — | new |
| R-3 | `t_mtip_single_wire` | `mtip` reaches `mip.MTIP`; no CLIC ID involved | — | new |
| R-4 | `t_mtime_coherent` | read `LO` then `HI` across a carry returns the right value | carry at the exact read cycle | new |
| R-4 | `t_mtime_hi_alone` | reading `HI` alone returns the shadow, documented as such | — | new |
| R-5 | `t_mtimecmp_seq` | the three-step sequence produces no spurious `mtip` | — | new |
| R-5 | `t_mtimecmp_naive` | the naive one-step write **does** produce a spurious `mtip`, confirming why the sequence is required | — | new |
| R-6 | `t_wdt_count` | counts down, kicks reload, zero asserts the request | — | new |
| R-6 | `t_wdt_magic` | only `0x5A5A_C3C3` kicks; sweep of other values | ≥100 random values | new |
| R-7 | `t_wdt_warn` | warning fires at the threshold, before the reset | 3 threshold values | new |
| R-8 | `t_wdt_req_survives` | request holds through `hreset_n`; full-length reset results | — | **critical, new** |
| R-9 | `t_wdt_no_disable` | no write clears `EN` | — | new |
| §7.3 | `t_mtip_late_write` | `mtimecmp` set to a past value asserts `mtip` immediately | — | new |
| §7.7 | `t_wdt_during_hartreset` | watchdog fires while the core is debug-held, as documented | — | new |
| — | `t_timers_1khz` | full 1 kHz loop with the real reload value, 1000 iterations, no drift | — | new |

**[N-11.1]** `t_wdt_req_survives` is the most important test in this document. It is the
regression guard for the runt-pulse class of bug described in §8.4, which RTL simulation
would otherwise hide because reset is modelled as instantaneous. The test must check the
*duration* of `hreset_n`, not merely that it asserted.

**[N-11.2]** `t_mtimecmp_naive` deliberately verifies that the wrong firmware sequence
fails. This is unusual but valuable: it documents in executable form why [N-7.12] exists, so
a future engineer who "simplifies" the driver sees a test fail rather than an intermittent
spurious interrupt at 17-second intervals.

---

## 12 Design decisions

| Decision | ADR |
|---|---|
| Compare in this block; single `mtip` wire to the core; 64-bit buses and the in-core comparator deleted | ADR-0010 |
| CLIC ID 13 released | ADR-0010 |
| `wdt_rst_req_flop` in the `ext_rst_n` domain | ADR-0003 |

---

## 13 Not implemented

| Feature | Why not |
|---|---|
| `mtime` as a CLIC source | ADR-0010. The core's `mip.MTIP` path is implemented and verified. |
| A prescaler on `mtime` | It is a cycle counter. A prescaler adds a register and a frequency question for no benefit at 4 ns resolution. |
| A second general-purpose timer | The 1 kHz loop needs one deadline. Additional software timers are a firmware list keyed off `mtime`. |
| Timer capture or compare outputs | No input capture requirement; PWM owns the motor outputs. |
| Watchdog windowing (kick-too-early detection) | Catches a specific runaway-loop shape. Worth having in v2; not worth the register and the firmware-timing constraint now. |
| A watchdog freeze-on-debug bit | §7.24. Needs a DM connection, and a watchdog that stops for one reason will be stopped for another. |
| `mtime` preserved across reset | §9.3. 64 flops in a second reset domain for information the early-warning record already provides. |
| A software-clearable watchdog enable | §6.2. A watchdog the hung firmware can disable is worse than none. |

---

## 14 Open items


- **OPEN-T1 — the APB side is still on `hclk`, not `pclk`.** `timers_apb.v` takes only `hclk_i`, though §4 lists it as `seq (pclk)` and §5 as an APB slave on pclk. ADR-0002 Rev 2 and
  `garuda_system.yaml` (`apb.clock: pclk`) both specify pclk here, and ADR-0002
  names this as the one pending RTL change. **Not a functional bug**: pclk edges
  are a subset of hclk edges (D-5), so the sampling is synchronous and the whole
  regression passes. Two things it does cost:
  **(a)** PRDATA is combinational out of hclk registers, so it can move at the
  hclk edge in the middle of a pclk access phase — the effective setup window at
  the bridge is 4 ns, not 8 ns, and the SDC must say so;
  **(b)** these flops run at 250 MHz, which is the dynamic power ADR-0002 Rev 2
  restored pclk to save. Decide before STA: migrate, or constrain and document.
None.

---

## 15 Errata

No RTL for this block yet. The core's `mip.MTIP` path is implemented and verified; its
64-bit comparator and ports are deleted by RTL delta R4.

**Defects fixed in this revision:**

| ID | Symptom | Root cause | Fix |
|---|---|---|---|
| TM-1 | Two delivery paths for one interrupt: `mip.MTIP` in the core RTL and CLIC ID 13 in three specs. | Routing decided independently in three documents. | ADR-0010; §7.3; ID 13 reserved. |
| TM-2 | 128 top-level wires and a 64-bit comparator in the core's critical timing cone, for one bit of information. | The comparison was placed at the consumer rather than the producer. | Comparator moves here; `mtip_o` is one wire. |
| TM-3 | Watchdog reset would be a runt pulse of roughly one `hclk` cycle, leaving the chip un-reset and possibly with a clear reason register. | The reset request flop was in the domain its own request reset. | §7.6; `ext_rst_n` domain; `t_wdt_req_survives`. |
| TM-4 | A watchdog reset gave no diagnostic information at all. | No early warning existed. | `WDTWARN` and CLIC ID 22, §6.4. |
| TM-5 | `mtimecmp` reset value of 0 would assert `mtip` immediately after reset, before any handler existed. | Reset value chosen as the default zero. | All-ones, §6.1. |
