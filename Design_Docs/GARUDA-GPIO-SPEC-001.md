# GARUDA GPIO — Design Specification

## 0.1 Identity

| Field | Value |
|---|---|
| Document ID | GARUDA-GPIO-SPEC-001 |
| Revision | 1.0 |
| Date | 2026-09-23 |
| Status | Released for implementation |
| Block | 19 (`gpio`) |
| Owner | Team AeroSoC |
| Supersedes | — (first revision) |

## 0.2 Revision history

| Rev | Change | Driver |
|---|---|---|
| 1.0 | First specification. `pulp-platform/apb_gpio` behind a GARUDA wrapper. | D-21, D-22, D-23 |

## 0.3 Normative references

`GARUDA-SYS-001` Rev 4.0 · `GARUDA-AHB2APB-SPEC-001` Rev 2.0 ·
`GARUDA-CLIC-SPEC-001` Rev 2.0 §7.2 · `Docs/DECISIONS.md` D-14, D-17, D-21,
D-22, D-23.

---

## 1 Purpose and scope

### 1.1 In scope

**Two** general-purpose bidirectional pins, `gpio0` and `gpio1`, on APB window 7
(`0x4000_7000`), CLIC ID 20. Direction, output value, input read, and a
per-pin edge/level interrupt.

### 1.2 Out of scope

- **DMA.** GPIO has no DMA channel in the Rev 4.0 map, and nothing to stream.
- Pad drive strength, slew and pull configuration. The IP has `PADCFG`
  registers for it, but GARUDA has no pad cells yet ([N-13.1]).
- Pin multiplexing. These two pins are GPIO and nothing else.

### 1.3 Where the RTL comes from

`rtl/third_party/pulp/apb_gpio` (Solderpad 0.51), unmodified, behind
`rtl/gpio/garuda_gpio_top.v`. It is the **closest thing to a drop-in** of the
four vendored IPs: already word-addressed (`s_apb_addr = PADDR[6:2]`), `PREADY`
tied high, `PSLVERR` tied low, and it carries its own input synchronisers.

---

## 2 Requirements

| ID | Requirement | Source | Status |
|---|---|---|---|
| R-1 | Drive either pin high or low under firmware control. | SYS §6.4 | met |
| R-2 | Read the level on either pin, whether driven or not. | SYS §6.4 | met |
| R-3 | Per-pin direction control, independently. | SYS §6.4 | met |
| R-4 | Word-only APB, 32-bit registers at word-aligned offsets. | AHB2APB [N-7.12] | met |
| R-5 | Never stall the APB bus. | AHB2APB [N-7.15] | met |
| R-6 | One **held** level interrupt to CLIC ID 20, from a per-pin edge or level condition. | CLIC §7.2, D-17 | met ([N-7.3]) |
| R-7 | Pad inputs synchronised before use. | D-14 | met |
| R-8 | **Both pins released (inputs) from reset** until firmware acts. | Board safety | met |

---

## 3 Block diagram

```
   APB window 7 (pclk 125 MHz)
        │
        ▼
  ┌──────────────── garuda_gpio_top ─────────────────┐
  │  garuda_apb_shim ── IP APB ──▶ apb_gpio (vendored)│
  │   0x00-0x7C pass-through   PADDIR GPIOEN PADIN    │
  │   0xFE0-0xFEC tail         PADOUT SET CLR INTEN   │
  │                            INTTYPE INTSTATUS      │
  │   interrupt (read-to-clear) ──▶ sticky IRQSTAT[0] │
  │   gpio_in ──▶ 2-flop sync                         │
  └───────────── gpio_i / gpio_o / gpio_oe ───────────┘
```

---

## 4 Sub-block inventory

| Name | Type | RTL file | Role |
|---|---|---|---|
| `garuda_apb_shim` | seq (pclk) | `rtl/common/garuda_apb_shim.v` | decode, PSLVERR, sticky IRQ, pad sync |
| `apb_gpio` | seq (pclk) | `rtl/third_party/pulp/apb_gpio/src/` | register file, edge detect, interrupt (vendored) |
| `garuda_gpio_top` | wrapper | `rtl/gpio/garuda_gpio_top.v` | 2-pin mapping, direction polarity, sticky IRQ |

---

## 5 Interfaces

| Port | Dir | Width | Domain | Reset | Description |
|---|---|---|---|---|---|
| `pclk_i`, `preset_n_i` | in | 1 | pclk | — | 125 MHz |
| APB slave | — | — | pclk | — | window 7 |
| `irq_o` | out | 1 | pclk | 0 | CLIC ID 20, level |
| `gpio_i` | in | 2 | async | — | pad input, synchronised |
| `gpio_o` | out | 2 | pclk | 0 | pad output value |
| `gpio_oe` | out | 2 | pclk | **0** | 1 = drive the pad, 0 = input |

---

## 6 Register map — APB window 7 (`0x4000_7000`)

Machine-readable source: `spec/regs/gpio.yaml`. The vendored register file is
32 pins wide; GARUDA has two, so **only bits `[1:0]` of each register are
meaningful** and the rest read 0 ([N-6.2]).

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | `PADDIR` | RW | 0 | `[n]` 1 = output, 0 = input |
| 0x04 | `GPIOEN` | RW | 0 | `[n]` 1 = enable the pin's input path and interrupt ([N-6.1]) |
| 0x08 | `PADIN` | RO | — | `[n]` the level on the pin |
| 0x0C | `PADOUT` | RW | 0 | `[n]` the value driven when `PADDIR[n]` is 1 |
| 0x10 | `PADOUTSET` | W | — | `[n]` 1 sets `PADOUT[n]` ([N-6.3]) |
| 0x14 | `PADOUTCLR` | W | — | `[n]` 1 clears `PADOUT[n]` ([N-6.3]) |
| 0x18 | `INTEN` | RW | 0 | `[n]` 1 = this pin may raise an interrupt |
| 0x1C | `INTTYPE` | RW | 0 | 2 bits per pin: 00 falling, 01 rising, 10 either, 11 level |
| 0x24 | `INTSTATUS` | **R, clears** | 0 | `[n]` 1 = this pin caused the interrupt ([N-7.3]) |
| 0x28 | `PADCFG0` | RW | 0 | pad drive/pull — **no effect** ([N-13.1]) |
| 0xFE0 | `IRQSTAT` | W1C | 0 | `[0]` a GPIO interrupt occurred |
| 0xFE4 | `IRQEN` | RW | 0 | mask; `irq_o = IRQSTAT[0] & IRQEN[0]` |
| 0xFE8 | `DMACTL` | RW | 0 | present for uniformity; **no DMA channel** ([N-13.2]) |
| 0xFEC | `ID` | RO | — | `{16'h6A5D, 8'd19, rev}` |

**[N-6.1]** `GPIOEN[n]` gates the input path. A pin used only as an output does
not need it; a pin read or used as an interrupt source **does**, and forgetting
it is the usual reason a GPIO interrupt never arrives.

**[N-6.2]** Bits `[31:2]` of every register exist in the vendored RTL and are
writable, but no pin is attached. Firmware must ignore them. `t_gpio_width`
asserts that reads return 0 there.

**[N-6.3]** `PADOUTSET` and `PADOUTCLR` exist so two contexts can own one pin
each without a read-modify-write race on `PADOUT`. On a chip with an interrupt
handler toggling one pin and a control loop toggling the other, use them.

---

## 7 Functional description

### 7.1 Driving a pin

**[N-7.1]**

```
PADDIR    |= (1 << n)        make pin n an output
PADOUTSET  = (1 << n)        drive it high
PADOUTCLR  = (1 << n)        drive it low
```

### 7.2 Reading a pin

**[N-7.2]**

```
PADDIR &= ~(1 << n)          make it an input (this is also the reset state)
GPIOEN |=  (1 << n)          enable its input path  <- easy to forget
level = (PADIN >> n) & 1
```

`PADIN` reflects the **pin**, not `PADOUT`, so a pin configured as an output can
be read back to confirm it is actually at the level driven — which is how a
short to ground is detected.

### 7.3 Interrupts, and the one wrinkle

**[N-7.3]** The vendored block's `interrupt` output is a **one-cycle pulse**,
not a level: `assign interrupt = |s_is_int_all`, and `s_is_int_all` is a
combinational edge detect gated by `INTEN`/`GPIOEN`/`INTTYPE`. It is therefore
exactly the SPI master's situation ([SPIM N-7.7]) and the shim's sticky
`IRQSTAT[0]` is what turns it into the held level D-17 requires. **The tail is
not a formality here; without it a GPIO interrupt would be one `pclk` wide and
the CLIC would miss it.**

`INTSTATUS` is a **separate, per-pin sticky record** (`r_status`), and reading
it clears it. So the two registers answer two different questions:

| Register | Says | Cleared by |
|---|---|---|
| `IRQSTAT[0]` | "a GPIO interrupt happened" — the line the CLIC sees | W1C |
| `INTSTATUS[n]` | "it was pin n" | reading it |

A handler needs both:

```
cause = INTSTATUS        which pin - and clears the record for the next one
...handle it...
IRQSTAT = 1              W1C: drops the line to the CLIC
```

Either order works, because they are independent. **Read `INTSTATUS` even if
only one pin is enabled**: leaving it set makes the *next* interrupt's cause
ambiguous, since the bits accumulate with `r_status | s_is_int_all`.

**[N-7.3a]** For the same reason **the wrapper must never poll `INTSTATUS`**.
The SPI and UART wrappers read a status register in idle cycles to recover FIFO
state ([SPIM N-7.4]); doing that here would silently eat every interrupt. GPIO
needs no such polling — it has no FIFO and no DMA — and the wrapper does none.

---

## 8 Timing

Combinational from `PADOUT`/`PADDIR` to the pins; input path is the shim's two
flops plus the IP's own synchroniser. Nothing here is timing-critical.

---

## 9 Clock, reset and power

**[N-9.1]** Single domain, `pclk`, reset `preset_n`.

**[N-9.2]** `gpio_oe` is **0 out of reset** — both pins are inputs until
firmware says otherwise (R-8). On a flight controller a GPIO that powers up
driving is a pin fighting whatever is on the other side of it.

**[N-9.3]** The IP's `dft_cg_enable_i` is tied low. It bypasses an internal
clock gate in test mode; DFT insertion must revisit it ([N-14.1]).

---

## 10 Assertions

```systemverilog
a_pready:   assert property (@(posedge pclk_i) disable iff (!preset_n_i)
              psel_i |-> pready_o);
a_oe_reset: assert property (@(posedge pclk_i) !preset_n_i |-> (gpio_oe_o == 2'b00));
a_irq_held: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
              $fell(irq_o) |-> $past(irqstat_write));
```

---

## 11 Verification plan

`make test_gpio` — `tb/gpio/tb_gpio.sv`, 25 checks, 0 failures.

| Req | Test | Oracle | Status |
|---|---|---|---|
| R-1 | `t_gpio_drive` | each pin drives high and low, independently | pass |
| R-2 | `t_gpio_read` | `PADIN` follows an externally driven pin | pass |
| R-2 | `t_gpio_readback` | an output pin reads back the level it drives | pass |
| R-3 | `t_gpio_dir` | one pin output, one input, at the same time | pass |
| R-4 | `t_gpio_regs` | registers read back; PSLVERR on unmapped; `[31:2]` read 0 | pass |
| R-5 | `t_gpio_pready` | PREADY high in every cycle of every access | pass |
| R-6 | `t_gpio_irq` | rising-edge interrupt; **held across 60 pclk** though the IP pulses for 1; W1C drops it | pass |
| R-6 | `t_gpio_irq_cause` | `INTSTATUS` names the pin and self-clears on read | pass |
| R-6 | `t_gpio_irq_masked` | an edge on a pin with `INTEN` clear raises nothing | pass |
| R-6 | `t_gpio_irq_type` | falling, rising and either-edge each fire correctly | pass |
| R-7 | `t_gpio_sync` | an input change is seen, with synchroniser latency | pass |
| R-8 | `t_gpio_reset` | both `gpio_oe` are 0 out of reset | pass |
| — | `t_chip_gpio` | both pins from the core, through the real fabric | new |

---

## 12 Design decisions

| # | Decision | Alternative rejected |
|---|---|---|
| 1 | `PAD_NUM = 2`, matching the pin count | the default 32 — ~150 flops of registers with no pins behind them |
| 2 | Sticky tail over the IP's read-to-clear interrupt | exposing the read-to-clear line to the CLIC, against D-17 |
| 3 | No idle-cycle polling in this wrapper | consistency with SPI/UART — it would eat every interrupt ([N-7.3a]) |

---

## 13 Not implemented

**[N-13.1]** `PADCFG` (drive strength, pull-up/down, slew) is writable and has
**no effect**: GARUDA has no pad cells in RTL, so there is nothing to configure.
When the pad ring lands, these bits become real and this note must go.

**[N-13.2]** `DMACTL` exists so every peripheral window has the same tail, but
GPIO owns no DMA channel in the Rev 4.0 map. Writing it does nothing.

---

## 14 Open items

- **OPEN-G1** ([N-9.3]) — `dft_cg_enable_i` is tied low. Scan insertion must
  drive it from the test-mode signal, which does not exist yet. Part of the DFT
  gap already recorded in `Docs/HANDOFF.md`.

---

## 15 Errata

None found in the vendored RTL.
