# GARUDA PWM — Design Specification

## 0.1 Identity

| Field | Value |
|---|---|
| Document ID | GARUDA-PWM-SPEC-001 |
| Revision | 1.0 |
| Date | 2026-09-23 |
| Status | Released for implementation |
| Block | 20 (`pwm`) |
| Owner | Team AeroSoC |
| Supersedes | — (first revision) |

## 0.2 Revision history

| Rev | Change | Driver |
|---|---|---|
| 1.0 | First specification. **In-house RTL**, not adapted — the only peripheral written from scratch. | D-21, D-22 |

## 0.3 Normative references

`GARUDA-SYS-001` Rev 4.0 · `GARUDA-AHB2APB-SPEC-001` Rev 2.0 ·
`GARUDA-CLIC-SPEC-001` Rev 2.0 §7.2 · `Docs/DECISIONS.md` D-17, D-21, D-22.

---

## 1 Purpose and scope

### 1.1 In scope

Four PWM outputs — `pwm0..pwm3` — on APB window 8 (`0x4000_8000`), CLIC ID 21.
One shared period, four independent duty cycles, double-buffered.

**These pins drive ESCs.** That single fact sets every requirement below: the
consequence of a glitch is not a corrupted byte, it is a propeller.

### 1.2 Out of scope

- Input capture, dead-time insertion, complementary outputs, phase shift.
- DShot and other digital ESC protocols. They need a bit-serialiser, not a
  counter-compare ([N-13.1]).
- DMA. Four 16-bit writes per frame is nothing at 50 Hz–4 kHz.

### 1.3 Why this one is in-house

**[N-1.1]** Every other peripheral in this chip is adapted from open-source
RTL (D-22). PWM is the exception, and deliberately. PULP's only option is
`apb_adv_timer`: four timers with four channels each, an event unit and a
capture/trigger matrix. **The verification cost dominates the design cost.**
For a general-purpose timer you have to show that no reachable combination of
mode, trigger and channel registers can glitch an output; for a counter and
four comparators the argument is exhaustive and fits on a page. When the thing
on the other end of the wire is a motor, that difference is the whole decision.

---

## 2 Requirements

| ID | Requirement | Source | Status |
|---|---|---|---|
| R-1 | Produce a pulse of programmable width at a programmable period, accurate to one tick. | SYS §6.4 | met |
| R-2 | Four channels with independent duty and independent enable. | SYS §6.4 | met |
| R-3 | All four channels share one time base; their rising edges are aligned. | [N-7.2] | met |
| R-4 | Word-only APB, never stalls. | AHB2APB [N-7.12], [N-7.15] | met |
| R-5 | **A duty written mid-pulse must never shorten the pulse in progress.** | [N-7.3] | met |
| R-6 | **Outputs low at reset, low when disabled, and low within one cycle of `EN` clearing.** | Board safety | met |
| R-7 | A duty wider than the period is clamped and reported, not left undefined. | [N-7.4] | met |
| R-8 | Period and duty resolution adequate for 50 Hz servo and 4 kHz OneShot125. | SYS §6.4 | met |
| R-9 | One held, level interrupt to CLIC ID 21. | CLIC §7.2, D-17 | met |

---

## 3 Block diagram

```
   APB window 8 (pclk 125 MHz)
        │
        ▼
  ┌──────────────── garuda_pwm_top ─────────────────┐
  │  garuda_apb_shim ──▶ register file              │
  │   0x00-0x1C  PRESCALE PERIOD CTRL STATUS DUTY0-3│
  │   0xFE0-0xFEC  tail                             │
  │                      │                          │
  │                      ▼  garuda_pwm_core         │
  │        prescaler ─▶ period counter ─┬─ cmp 0 ──▶│ pwm0
  │                          │          ├─ cmp 1 ──▶│ pwm1
  │                     wrap ┘          ├─ cmp 2 ──▶│ pwm2
  │                (loads the shadows)  └─ cmp 3 ──▶│ pwm3
  └─────────────────────────────────────────────────┘
```

---

## 4 Sub-block inventory

| Name | Type | RTL file | Role |
|---|---|---|---|
| `garuda_apb_shim` | seq (pclk) | `rtl/common/garuda_apb_shim.v` | decode, PSLVERR, sticky IRQ |
| `garuda_pwm_top` | seq (pclk) | `rtl/pwm/garuda_pwm_top.v` | register file, events |
| `garuda_pwm_core` | seq (pclk) | `rtl/pwm/garuda_pwm_core.v` | prescaler, counter, 4 comparators, shadows |

---

## 5 Interfaces

| Port | Dir | Width | Domain | Reset | Description |
|---|---|---|---|---|---|
| `pclk_i`, `preset_n_i` | in | 1 | pclk | — | 125 MHz |
| APB slave | — | — | pclk | — | window 8 |
| `irq_o` | out | 1 | pclk | 0 | CLIC ID 21, level |
| `pwm_o` | out | 4 | pclk | **0** | **low = no signal = motor stopped** |

---

## 6 Register map — APB window 8 (`0x4000_8000`)

Machine-readable source: `spec/regs/pwm.yaml`.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | `PRESCALE` | RW | 0 | `[15:0]` tick = `pclk / (PRESCALE + 1)` |
| 0x04 | `PERIOD` | RW | 0 | `[15:0]` ticks per frame |
| 0x08 | `CTRL` | RW | 0 | `[0]` EN, `[7:4]` per-channel enable |
| 0x0C | `STATUS` | RO | 0 | `[15:0]` live counter, `[19:16]` per-channel clamp |
| 0x10 | `DUTY0` | RW | 0 | `[15:0]` ticks high, channel 0 |
| 0x14 | `DUTY1` | RW | 0 | channel 1 |
| 0x18 | `DUTY2` | RW | 0 | channel 2 |
| 0x1C | `DUTY3` | RW | 0 | channel 3 |
| 0xFE0 | `IRQSTAT` | W1C | 0 | `[0]` period boundary, `[1]` a duty was clamped |
| 0xFE4 | `IRQEN` | RW | 0 | mask; `irq_o = \|(IRQSTAT & IRQEN)` |
| 0xFE8 | `DMACTL` | RW | 0 | present for uniformity; no DMA channel |
| 0xFEC | `ID` | RO | — | `{16'h6A5D, 8'd20, rev}` |

**[N-6.1]** `CTRL.EN` is the master switch and `CTRL[7:4]` are per-channel.
An output is high only when **both** are set and the counter is below that
channel's shadowed duty. Every other combination is low.

---

## 7 Functional description

### 7.1 Setting up a frame

**[N-7.1]** Pick a tick that makes the numbers whole, then work in ticks:

```
tick    = pclk / (PRESCALE + 1)
period  = PERIOD ticks
pulse   = DUTYn ticks
```

Worked settings at `pclk` = 125 MHz:

| Use | `PRESCALE` | tick | `PERIOD` | frame | `DUTYn` |
|---|---|---|---|---|---|
| Servo / standard ESC, 50 Hz | 124 | 1 µs | 20000 | 20 ms | 1000–2000 (1–2 ms) |
| OneShot125, 4 kHz | 12 | 104 ns | 2400 | 250 µs | 1200–2400 (125–250 µs) |
| Generic, 1 kHz | 124 | 1 µs | 1000 | 1 ms | 0–1000 |

`t_pwm_servo` measures the 50 Hz case end to end: the 1.5 ms centre pulse
measures 1.5 ms.

**[N-7.1a]** `PRESCALE` and `PERIOD` are **not** double-buffered — only the
duties are. Change them with `CTRL.EN` clear, then re-enable; changing the
period under a running frame is not defined and is not tested.

### 7.2 One time base

**[N-7.2]** There is one prescaler and one counter, and four comparators read
it. The four rising edges are therefore in the same clock cycle **by
construction**, not by configuration — no register value can skew them. That
is R-3, and `t_pwm_aligned` asserts `pwm_o == 4'b1111` in the cycle after a
rise.

Falling edges are deliberately *not* aligned: that is what different duty
cycles mean.

### 7.3 Double buffering — the requirement that shapes the design

**[N-7.3]** A write to `DUTYn` lands in a holding register. The core copies all
four into shadow registers **only at the period boundary**. So a control loop
that updates duty at an arbitrary moment — which is what a control loop does —
can never shorten the pulse already on the wire.

Without this, writing 0.5 ms while a 1.9 ms pulse is 1.0 ms old would truncate
it to 1.0 ms. An ESC reading a pulse far shorter than commanded interprets it as
a throttle step, and four of them doing it at once is a flight event. With it,
that write produces a clean 1.9 ms pulse followed by a clean 0.5 ms one.

`t_pwm_doublebuf` does exactly that: writes 50 ticks while a 400-tick pulse is
in progress, checks the pulse finishes at 400, checks the next is 50, and
checks no pulse anywhere in the run was shorter than either.

### 7.4 A duty wider than the period

**[N-7.4]** `DUTYn > PERIOD` is a programming error with a real-world meaning:
the line would stay high across the wrap and an ESC would see a continuous
signal rather than a frame. The core **clamps** the shadow to `PERIOD` (a
steady 100% duty, which is at least a defined state), sets `STATUS[16+n]`, and
raises `IRQSTAT[1]`.

Clamping rather than ignoring matters: it leaves the output defined for every
value firmware can write, so there is no register combination whose behaviour
is "undefined". The clamp flag clears by itself at the next boundary once the
duty is legal again.

### 7.5 Stopping

**[N-7.5]** Clearing `CTRL.EN` drives all four outputs low **combinationally**,
in the same cycle — not at the end of the frame. A fault handler that has
decided to stop the motors should not have to wait 20 ms for a frame boundary.
`t_pwm_stop` clears `EN` mid-pulse and checks all four are low two cycles later.

The same logic covers reset and a cleared per-channel enable: **low beats
everything**.

---

## 8 Timing

```
        │←────────── PERIOD ticks ──────────→│
pwm0 ───┐        ┌──────────────────────────┐        ┌────
        └────────┘                          └────────┘
        │← DUTY0 →│
pwm3 ───┐    ┌────────────────────────────┐    ┌─────────
        └────┘                            └────┘
        │←D3→│
        ▲                                  ▲
        └── all four rise here             └── shadows load here
```

---

## 9 Clock, reset and power

**[N-9.1]** Single domain, `pclk`, reset `preset_n`. No CDC, no pad inputs.

**[N-9.2]** `pwm_o` is 0 out of reset (R-6). This is the block where safe idle
is a *design* requirement rather than an integration detail: an ESC reads a low
line as "no signal" and holds the motor stopped, so a chip in reset, a chip
half-configured, and a chip with a disabled PWM block all present the same
harmless state to the motors.

---

## 10 Assertions

```systemverilog
a_low_when_off: assert property (@(posedge pclk_i)
                  (!preset_n_i || !en_q) |-> (pwm_o == 4'b0000));
a_aligned:      assert property (@(posedge pclk_i) disable iff (!preset_n_i)
                  $rose(pwm_o[0]) && ch_en_q == 4'hF |-> (pwm_o == 4'b1111));
a_pready:       assert property (@(posedge pclk_i) disable iff (!preset_n_i)
                  psel_i |-> pready_o);
```

---

## 11 Verification plan

`make test_pwm` — `tb/pwm/tb_pwm.sv`, 26 checks, 0 failures. Every width check
measures the **pulse on the pin**, which is what an ESC sees, rather than a
register value.

| Req | Test | Oracle | Status |
|---|---|---|---|
| R-1 | `t_pwm_width` | measured widths of 100/200/300/400 ticks | pass |
| R-1 | `t_pwm_servo` | a 1.5 ms pulse in a 20 ms frame measures 1.5 ms | pass |
| R-2 | `t_pwm_indep` | four different duties at once; disabling one leaves the rest | pass |
| R-3 | `t_pwm_aligned` | all four rise in the same cycle | pass |
| R-4 | `t_pwm_regs` | registers read back; PSLVERR on unmapped; PREADY always high | pass |
| R-5 | `t_pwm_doublebuf` | a mid-pulse write does not shorten the pulse in progress, and no runt appears | pass |
| R-6 | `t_pwm_reset` | low in reset, low before enable, low when configured but disabled | pass |
| R-6 | `t_pwm_stop` | clearing `EN` mid-pulse drops all four within one cycle | pass |
| R-7 | `t_pwm_clamp` | `DUTY > PERIOD` clamps to 100%, sets `STATUS[16]` and `IRQSTAT[1]`, and self-clears | pass |
| R-8 | `t_pwm_prescale` | `PRESCALE = 9` makes 25 ticks measure 2 µs | pass |
| R-9 | `t_pwm_irq` | clamp interrupt asserts and is held | pass |
| — | `t_chip_pwm` | all four pins from the core, through the real fabric | new |

---

## 12 Design decisions

| # | Decision | Alternative rejected |
|---|---|---|
| 1 | In-house counter-compare | PULP `apb_adv_timer` — the verification cost, [N-1.1] |
| 2 | Duties double-buffered; period and prescale not | buffering everything — more flops for a case firmware can avoid by disabling first |
| 3 | Clamp an over-wide duty and flag it | ignore the write, or let the output stay high across the wrap |
| 4 | `EN` stops combinationally | stopping at the frame boundary — up to 20 ms of motor after a fault |
| 5 | 16-bit period and duty | 32-bit — 65535 ticks covers every frame we need with a prescaler |

---

## 13 Not implemented

**[N-13.1]** DShot, dead-time insertion, complementary outputs, input capture,
phase-shifted channels. None is needed by a quadrotor ESC interface, and each
would enlarge exactly the state space [N-1.1] set out to keep small.

**[N-13.2]** `PERIOD`/`PRESCALE` are not double-buffered ([N-7.1a]).

---

## 14 Open items

- **OPEN-P1** — no output-stuck detection. If a pad shorts, the block cannot
  tell. A GPIO-style readback path would catch it but needs a pad input on
  these pins, which the 28-pin budget does not have. Board-level concern.

---

## 15 Errata

None. This block has no vendored RTL.
