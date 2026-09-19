# GARUDA Clock and Reset Subsystem — Design Specification

## 0.1 Identity

| Field | Value |
|---|---|
| Document ID | GARUDA-CLKRST-SPEC-001 |
| Revision | 2.0 |
| Date | 2026-09-18 |
| Status | Released for implementation |
| Blocks | 21 (`clk_div`), 22 (`reset_ctrl`) |
| Owner | Team AeroSoC |
| Supersedes | GARUDA_ClkRst_Design_Spec_v1_1 |

## 0.2 Revision history

| Rev | Change | Driver |
|---|---|---|
| 1.0 | Initial | — |
| 1.1 | Frequency raised to 250 MHz | — |
| 2.0 | Reset combining rewritten: stretch counter, source-outside-own-domain rule, DM carved out of `ndm_rst_n`. `pclk` moved into this document as a real 125 MHz toggle-flop divide. Divider placement fixed at the pad. Analog POR dependency removed. | ADR-0001, 0002, 0003, 0018, 0019 |

## 0.3 Normative references

1. `GARUDA-SYS-001` Rev 4.0 — System Definition. **All numeric values in this document are generated from it.**
2. `GARUDA-ADR-001` Rev 1.0 — Architecture Decision Record.
3. `GARUDA-DEBUG-SPEC-001` Rev 2.0 — for `ndmreset` and `hartreset` semantics.
4. `GARUDA-TIMERS-SPEC-001` Rev 2.0 — for the watchdog reset request.

---

## 1 Purpose and scope

### 1.1 In scope

`clk_div` (block 21) takes the external 500 MHz reference and produces the chip's two
functional clocks: `hclk` at 250 MHz and `pclk` at 125 MHz.

`reset_ctrl` (block 22) collects the three reset requests, stretches them, releases them
synchronously, and records why the last reset happened.

### 1.2 Out of scope

- The board-level supply supervisor that drives `ext_rst_n` (§2 `[R-4]` states the requirement it must meet).
- Clock tree synthesis and balancing (physical design).
- The per-block clock gates for power management — those live in the blocks they gate. This document defines only the root clocks they gate *from*.

### 1.3 Why this block is not trivial

Reset looks like the simplest logic in a chip and is one of the most common sources of
silicon bugs, because a reset that is too short, or that resets whatever produced it, fails
in a way no functional simulation notices. §7.2 and §7.3 exist specifically to close those
two failures.

---

## 2 Requirements

| ID | Requirement | Source |
|---|---|---|
| R-1 | Divide the external 500 MHz reference to 250 MHz `hclk`. | ADR-0001 |
| R-2 | Provide 125 MHz `pclk` for the APB peripherals, 50% duty. | ADR-0002 |
| R-3 | The divide ratio shall be a parameter, so a timing miss is recoverable without redesign. | ADR-0001 |
| R-4 | Reset shall not depend on any analog cell inside the chip. `ext_rst_n` is the only power-on reset source, driven by a board supervisor that holds it low until the core supply is stable. | ADR-0019 |
| R-5 | Every reset assertion shall last at least 1024 reference cycles at the point of use. | ADR-0003 |
| R-6 | No block shall be able to reset the logic that generates its own reset request. | ADR-0003 |
| R-7 | Reset release shall be synchronous to the clock of the domain being released. | ADR-0003 |
| R-8 | The cause of the last reset shall be readable by firmware after that reset. | ADR-0003 |
| R-9 | A debug-initiated reset shall not reset the Debug Module or the JTAG TAP. | RISC-V Debug 0.13 §3.2 |
| R-10 | 500 MHz shall exist on no net other than the pad-to-divider connection. | ADR-0018 |

---

## 3 Block diagram

```
                       ┌──────────── chip boundary ────────────┐
                       │                                        │
  refclk pad ──────────┼──▶ ┌─────────┐                         │
  (500 MHz)            │    │ div2    │  250 MHz                │
     [abuts pad, R-10] │    │ toggle  ├──────────┬──────────────┼──▶ hclk
                       │    └────┬────┘          │              │
                       │         │               ▼              │
                       │         │          ┌─────────┐         │
                       │         │          │ div2    │ 125 MHz │
                       │         │          │ toggle  ├─────────┼──▶ pclk
                       │         │          └─────────┘         │
                       │         │               │              │
                       │         │               └──────────────┼──▶ pclk_phase
                       │         │                              │
  ext_rst_n pad ───────┼───┐     │                              │
                       │   ▼     ▼                              │
                       │ ┌───────────────────────────────┐      │
  wdt_rst_req ─────────┼▶│         reset_ctrl            │      │
  ndm_rst_req ─────────┼▶│  ┌──────────┐  ┌───────────┐  ├──────┼──▶ hreset_n
  (from DM)            │ │  │ stretch  │  │ reason    │  │      │
                       │ │  │ counter  │  │ register  │  ├──────┼──▶ preset_n
                       │ │  │ (refclk) │  │ (ext only)│  │      │
                       │ │  └──────────┘  └───────────┘  ├──────┼──▶ core_rst_n
  hartreset_req ───────┼▶│                               │      │
  (from DM)            │ └───────────────────────────────┘      │
                       │                                        │
                       └────────────────────────────────────────┘
```

Note what the diagram does *not* show: any path from `wdt_rst_req` back into the watchdog's
own request flop, or from `ndm_rst_req` into the Debug Module. Their absence is the
substance of §7.3.

---

## 4 Sub-block inventory

| Name | Type | RTL file | Role |
|---|---|---|---|
| `clkdiv_toggle_hclk` | seq (500 MHz) | `clk_div_top.v` | Divide-by-2 toggle flop. The only 500 MHz logic in the chip. |
| `clkdiv_prog_hclk` | seq | `clk_div_top.v` | Programmable further division for DIV=4/8/16. Bypassed at DIV=2. |
| `clkdiv_toggle_pclk` | seq | `clk_div_top.v` | Divide-by-2 toggle flop, hclk → pclk. |
| `pclk_phase_gen` | seq | `clk_div_top.v` | Single-bit phase indicator so hclk logic knows which hclk edge coincides with a pclk edge. |
| `rst_sync_in` | seq | `reset_ctrl.v` | Synchronises `ext_rst_n` deassertion to refclk. |
| `rst_stretch` | seq (refclk) | `reset_ctrl.v` | 1024-cycle down counter. |
| `rst_reason` | seq (ext-reset domain only) | `reset_ctrl.v` | Sticky W1C cause bits. |
| `rst_release_hclk` | seq | `reset_ctrl.v` | 2-flop synchronous deassert onto hclk. |
| `rst_release_pclk` | seq | `reset_ctrl.v` | 2-flop synchronous deassert onto pclk. |
| `apb_regs` | seq (pclk) | `reset_ctrl_apb.v` | APB register interface, window 8. |

---

## 5 Interfaces

### 5.1 `clk_div` (block 21)

| Port | Dir | Width | Domain | Reset value | Description |
|---|---|---|---|---|---|
| `refclk_i` | in | 1 | — | — | 500 MHz external reference. |
| `raw_rst_n_i` | in | 1 | async | — | Unstretched, unsynchronised `ext_rst_n`. See §7.4 for why the divider uses the raw signal. |
| `div_sel_i` | in | 2 | hclk | `2'b00` | 00=DIV2, 01=DIV4, 10=DIV8, 11=DIV16. |
| `hclk_o` | out | 1 | — | — | 250 MHz at DIV2. |
| `pclk_o` | out | 1 | — | — | 125 MHz, always hclk/2. |
| `pclk_phase_o` | out | 1 | hclk | `1'b0` | 1 on the hclk cycle whose rising edge coincides with a pclk rising edge. |

### 5.2 `reset_ctrl` (block 22)

| Port | Dir | Width | Domain | Reset value | Description |
|---|---|---|---|---|---|
| `refclk_i` | in | 1 | — | — | Stretch counter clock. See §7.2. |
| `hclk_i` | in | 1 | — | — | For the hclk release synchroniser. |
| `pclk_i` | in | 1 | — | — | For the pclk release synchroniser. |
| `ext_rst_n_i` | in | 1 | async | — | Active-low external reset from the board supervisor. |
| `wdt_rst_req_i` | in | 1 | hclk | — | Watchdog timeout, one-cycle pulse. |
| `ndm_rst_req_i` | in | 1 | tck→hclk | — | Debug non-debug-module reset, already synchronised by the DM. |
| `hartreset_req_i` | in | 1 | tck→hclk | — | Debug core-only reset. |
| `hreset_n_o` | out | 1 | hclk | 0 | Reset for the AHB fabric, memories, DMA, CLIC, timers. |
| `preset_n_o` | out | 1 | pclk | 0 | Reset for the APB bridge and peripherals. |
| `core_rst_n_o` | out | 1 | hclk | 0 | Reset for core + DSU. Asserts with `hreset_n_o`, and additionally for `hartreset`. |
| APB slave | — | — | pclk | — | Window 8. See §6. |

**`preset_n_o` and `hreset_n_o` deassert on different clocks and therefore at different
times.** The bridge is the only block spanning both, and `GARUDA-AHB2APB-SPEC-001` §9
states its requirement: the bridge must hold `hreadyout` low until both are deasserted.

---

## 6 Register map — `reset_ctrl`, APB window 8

Machine-readable source: `spec/regs/reset_ctrl.yaml`.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | `RSTREASON` | R/W1C | see below | Cause of the most recent reset. |
| 0x04 | `RSTCTL` | RW | 0x0000_0000 | Software reset request and divider select. |
| 0x08 | `CLKSTAT` | RO | — | Divider status. |

### 6.1 `RSTREASON` (0x00)

| Bit | Name | Set by |
|---|---|---|
| 0 | `EXT` | `ext_rst_n` assertion |
| 1 | `WDT` | Watchdog timeout |
| 2 | `NDM` | Debug `ndmreset` |
| 3 | `SW` | `RSTCTL.SWRST` write |
| 4 | `BOOTFAIL` | Bootloader on CRC mismatch (§8 of the memory spec) |
| 31:5 | reserved | reads 0 |

**[N-6.1]** `RSTREASON` bits are reset only by `ext_rst_n`. They survive watchdog, debug and
software resets, because a reason register cleared by the reset it records is useless.

**[N-6.2]** Exactly one of bits 0–3 is set by any given reset. Bit 4 is set by software and
is orthogonal.

**[N-6.3]** Writing 1 to a bit clears it. Writing 0 has no effect.

### 6.2 `RSTCTL` (0x04)

| Bit | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0 | `SWRST` | W | 0 | Writing 1 requests a full reset. Self-clearing. |
| 9:8 | `DIVSEL` | RW | `2'b00` | Divider select, passed to `clk_div`. |
| 31:10, 7:1 | reserved | — | 0 | Writes ignored. |

**[N-6.4]** A `DIVSEL` write takes effect only at the next `pclk_phase` boundary, and the
divider transitions glitch-free (§7.5). Changing `DIVSEL` changes `hclk` and therefore all
peripheral baud rates and both timer rates. Firmware is responsible for reconfiguring them.

**[N-6.5]** `DIVSEL` is not reset by `SWRST`, so a software reset does not silently restore
250 MHz after firmware has stepped down to a lower frequency.

### 6.3 `CLKSTAT` (0x08)

| Bit | Name | Description |
|---|---|---|
| 1:0 | `DIVACT` | Divide ratio currently in effect. |
| 2 | `DIVBUSY` | 1 while a ratio change is pending. |
| 31:3 | reserved | reads 0 |

---

## 7 Functional description

### 7.1 Clock generation

**[N-7.1]** `hclk` at DIV=2 is generated by a single toggle flop clocked by `refclk`:

```verilog
always @(posedge refclk_i or negedge raw_rst_n_i)
  if (!raw_rst_n_i) hclk_div_q <= 1'b0;
  else              hclk_div_q <= ~hclk_div_q;
```

**[N-7.2]** A toggle flop is used rather than a clock gate. A gate that passes every other
reference pulse produces a 2 ns high time in an 8 ns period — 25% duty — which halves the
usable setup window for every negative-edge-sensitive element and distorts hold margins. A
toggle flop gives exactly 50%.

**[N-7.3]** `pclk` is a second toggle flop clocked by `hclk`, giving 125 MHz at 50% duty.

**[N-7.4]** `pclk_phase_o` is asserted for the one `hclk` cycle preceding each `pclk` rising
edge. The bridge uses it to know which `hclk` edge is safe for transfer between the two
clocks. This single bit is why no clock-domain-crossing logic is needed anywhere in the
chip between `hclk` and `pclk`:

> Every `pclk` rising edge coincides with an `hclk` rising edge. The set of `pclk` edges is
> a strict subset of the set of `hclk` edges. Both sides of the boundary therefore always
> sample on a shared edge, with a fixed and known phase relationship. This is a
> synchronous multi-frequency design, not an asynchronous crossing. Static timing analysis
> handles it with one `create_clock` on `refclk` and two `create_generated_clock`
> statements; no synchronisers, no metastability, no CDC waivers.

**[N-7.5]** Ratio changes are glitch-free: on a `DIVSEL` write, `DIVBUSY` sets, the divider
output is held at its current level until the counter reaches a state where the new ratio's
edge aligns, then the new ratio takes effect. No output pulse is shorter than the shorter of
the two ratios' half-periods.

**[N-7.6]** The three clocks and their relationship (values from `GARUDA-SYS-001`):

| Clock | Source | Ratio | Frequency at DIV=2 |
|---|---|---|---|
| `refclk` | external pad | — | 500 MHz |
| `hclk` | `refclk` / DIV | 2 (parameter) | 250 MHz |
| `pclk` | `hclk` / 2 | fixed 2 | 125 MHz |

### 7.2 Reset stretching — the mechanism that makes internal resets work

**[N-7.7]** All reset requests pass through a 1024-cycle down counter clocked by `refclk`.
A request loads the counter; the reset output stays asserted until the counter reaches zero.

**[N-7.8]** The stretch counter is clocked by `refclk`, not `hclk`. **This is load-bearing.**
`clk_div`'s divider is held in reset while reset is asserted (§7.4), so `hclk` is not
running during reset. A stretch counter on `hclk` would never advance, and reset would never
release. `refclk` comes directly from the pad and runs unconditionally.

**[N-7.9]** Without the stretch, an internally generated reset is self-cancelling. The
watchdog asserts `wdt_rst_req`; that resets the watchdog; the watchdog stops asserting;
the reset deasserts — one flop delay later. A pulse that short does not reliably reset a
flop, let alone a chip, and it is invisible in RTL simulation where reset is modelled as
instantaneous. The stretch counter makes the request's duration independent of the
requester's state.

**[N-7.10]** A new request arriving while the counter is running reloads it. Resets extend;
they do not queue.

### 7.3 Reset domains — no source inside its own domain

**[N-7.11]** The reset domain of each source:

| Request | Resets | Does **not** reset | Why |
|---|---|---|---|
| `ext_rst_n` | everything | `RSTREASON` | The reason register must survive to be read. |
| `wdt_rst_req` | everything except below | the watchdog's request flop, `RSTREASON` | Otherwise the request cancels itself (§7.9). |
| `ndm_rst_req` | everything except below | the Debug Module, the JTAG TAP, `RSTREASON` | RISC-V Debug 0.13 §3.2. Otherwise a debug-initiated reset kills the debug session that initiated it, and `dmcontrol.ndmreset` clears itself before the debugger can observe the effect. |
| `hartreset_req` | core + DSU only | fabric, memories, peripherals, DM | Lets the debugger hold the core while the bus stays alive for System Bus Access. |

**[N-7.12]** The watchdog's request flop is in the `ext_rst_n` domain. `GARUDA-TIMERS-SPEC-001`
§9 states this on the watchdog side; both documents must agree, and `GARUDA-SYS-001`
`reset.sources[wdt_rst_n].resets` is the authority.

**[N-7.13]** `hartreset` does not pass through the stretch counter. It is a level from the
Debug Module, held as long as the debugger holds it, and is released synchronously to
`hclk`.

### 7.4 Assertion and release

**[N-7.14]** Assertion is asynchronous. `ext_rst_n` reaches every flop's asynchronous reset
input without waiting for a clock, because at power-on there is no clock to wait for.

**[N-7.15]** Release is synchronous, through a two-flop synchroniser in the target domain:
one for `hclk`, one for `pclk`. This prevents flops in the same domain from leaving reset on
different cycles, which is how a reset-release race produces a state machine in an illegal
state.

**[N-7.16]** `clk_div`'s divider flops use `raw_rst_n` — `ext_rst_n` directly, unstretched
and unsynchronised. They cannot use the stretched output because that output depends on
`refclk` only, while the divider must be in a known state before `hclk` exists at all. This
is the one deliberate exception to [N-7.15] and it is safe because the divider is a single
toggle flop with no state machine to corrupt.

**[N-7.17]** Release order is `refclk` domain, then `hclk`, then `pclk`. `pclk` is last
because it is the slowest, so a peripheral can never see its bus interface active before its
own reset has released.

### 7.5 Reset sequence — timeline

| Phase | Duration | State |
|---|---|---|
| 1 | supply ramp | `ext_rst_n` low (board supervisor). Nothing is clocked. |
| 2 | ≤10 ref cycles | `ext_rst_n` released; `refclk` present; divider leaves raw reset; `hclk`/`pclk` begin. |
| 3 | 1024 ref cycles (≈2.05 µs at 500 MHz) | Stretch counter runs. All functional resets held. |
| 4 | 2 hclk cycles | `hreset_n` and `core_rst_n` release synchronously. |
| 5 | 2 pclk cycles | `preset_n` releases. |
| 6 | — | Core fetches from `0x1000_0000`. |

**[N-7.18]** Total reset time from `ext_rst_n` release to first instruction fetch is
approximately 2.1 µs at DIV=2. Nothing in the system depends on this being short.

### 7.6 Floorplan constraint — the 500 MHz net

**[N-7.19]** `clkdiv_toggle_hclk` shall be placed adjacent to the `refclk` pad. The
`refclk` net shall connect the pad's input buffer to that flop's clock input and to nothing
else.

**[N-7.20]** Rationale, and why this is in a design document rather than left to physical
design: 500 MHz is a 2 ns period, and this is a 1.45 mm die with a bond-wire package. A
500 MHz net routed across the die would need its own insertion-delay budget, would couple
into neighbours, and would make the reference clock's duty distortion a chip-wide concern.
Confining it to a short pad-adjacent connection means 500 MHz exists on roughly 50 µm of
metal and every other net in the chip is 250 MHz or slower.

**[N-7.21]** `clkdiv_toggle_hclk` is constrained at 500 MHz (2 ns period) and shall be
excluded from the `hclk` constraint set. Its timing path is a single flop with its output
inverted back to its own input — no combinational logic in between — which is the simplest
path that exists, and it will close. But it must be *told* to the timing tool explicitly, or
it will be checked against the wrong clock. Constraint sketch for the PD handoff:

```tcl
create_clock -name refclk -period 2.0 [get_ports refclk_i]
create_generated_clock -name hclk -source [get_ports refclk_i] \
    -divide_by 2 [get_pins u_clkdiv/hclk_div_q_reg/Q]
create_generated_clock -name pclk -source [get_pins u_clkdiv/hclk_div_q_reg/Q] \
    -divide_by 2 [get_pins u_clkdiv/pclk_div_q_reg/Q]
set_clock_groups -logically_exclusive -group {refclk} -group {hclk pclk}
```

---

## 8 Timing

### 8.1 Clock relationship

```
refclk   ─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─    2 ns
          └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘

hclk     ─┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐        4 ns, 50%
          └───┘   └───┘   └───┘   └───┘   └───

pclk     ─┐       ┌───────┐       ┌───────┐        8 ns, 50%
          └───────┘       └───────┘       └───

pclk_    ─────┐   ┌───┐       ┌───┐       ┌───     1 hclk cycle before
phase         └───┘   └───────┘   └───────┘        each pclk rising edge
              
              ▲       ▲       ▲       ▲
              └───────┴───────┴───────┴── every pclk edge lands on an hclk
                                          edge: this is why no CDC exists
```

### 8.2 Reset assertion and release

```
              ┌── supply stable
              │
ext_rst_n  ───┘‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
           ___________
refclk     ___________┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐
                      └┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘

hclk       _______________┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐
                          └──┘  └──┘  └──┘  └──┘  └──┘
                          ▲
                          └── divider leaves raw reset

stretch    ──────────────< 1024 >< 1023 >< ... >< 1 >< 0 >
counter

hreset_n   ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾┌────
           (asserted through the whole stretch)      └── 2 hclk after zero

preset_n   ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾┌──
                                                        └── 2 pclk after
```

### 8.3 Watchdog reset — the case the stretch exists for

```
wdt_rst_req   ────────┐
(from timers) ________│‾│___________________________________
                        └─ one hclk pulse, then the watchdog
                           is itself reset and stops asserting

stretch       ─────────< 1024 >< 1023 >< ... >< 1 >< 0 >
counter                 ▲
                        └── loaded by the pulse; runs on refclk,
                            independent of the watchdog's state

hreset_n      ‾‾‾‾‾‾‾‾‾‾╲______________________________┌────
                                                       └── full 1024 cycles

RSTREASON.WDT ─────────────┌────────────────────────────────
              _____________┘  survives the reset it records
```

Without the counter, `hreset_n` would be a pulse the width of `wdt_rst_req` — one hclk
cycle, and in silicon quite possibly less once the self-cancelling path settles.

---

## 9 Clock, reset and power

### 9.1 Domains

| Domain | Clock | Contents |
|---|---|---|
| refclk | 500 MHz | The `hclk` toggle flop, the stretch counter, `RSTREASON`. |
| hclk | 250 MHz | Core, DSU, AHB fabric, memories, DMA, CLIC, timers, DM. |
| pclk | 125 MHz | APB bridge peripheral side, all eight peripherals, `reset_ctrl`'s APB registers. |
| tck | ≤20 MHz, async | JTAG TAP and DTM only. |

**[N-9.1]** `hclk` and `pclk` are synchronous to each other (§7.4). The only genuinely
asynchronous boundary in the chip is `tck` ↔ `hclk`, inside the Debug Module.

### 9.2 Power

**[N-9.2]** `clk_div` provides no clock gating. The per-block gates (core WFI, DSU idle,
DMA per-channel, APB per-window) are defined in their own specs and gate these root clocks
locally.

**[N-9.3]** `pclk` at half `hclk` is itself a power measure: it halves the dynamic power of
the entire peripheral clock tree and of every peripheral flop, which is the majority of the
chip's flop count outside the core. This is the reason `pclk` exists as a real divided clock
rather than an access-rate trick — an enable scheme would deliver the same interface rate
while leaving every peripheral flop toggling at 250 MHz, saving nothing.

**[N-9.4]** No power domains, no isolation cells, no level shifters, no retention flops, no
voltage scaling. `DIVSEL` provides frequency scaling as a coarse, firmware-driven fallback
and is not a dynamic power-management mechanism.

---

## 10 Assertions

```systemverilog
// --- reset duration: the property the stretch counter exists to guarantee
property p_reset_min_duration;
  @(posedge refclk_i) $fell(hreset_n_o) |-> ##[1:$] (!hreset_n_o [*1023]);
endproperty
a_reset_min_duration: assert property (p_reset_min_duration);

// --- no reset source resets its own requester (R-6)
a_wdt_req_survives_reset: assert property (
  @(posedge hclk_i) $rose(wdt_rst_req_i) |-> ##1 !$isunknown(wdt_rst_req_i));

// --- reason register survives every reset except external
a_reason_survives_wdt: assert property (
  @(posedge refclk_i) disable iff (!ext_rst_n_i)
  $fell(hreset_n_o) && rst_reason_q[1] |=> rst_reason_q[1]);

// --- exactly one cause bit set per reset event
a_reason_onehot: assert property (
  @(posedge pclk_i) disable iff (!preset_n_o)
  $onehot0(rst_reason_q[3:0]));

// --- synchronous release: reset deasserts only on a clock edge
a_sync_release_hclk: assert property (
  @(posedge hclk_i) $rose(hreset_n_o) |-> $rose(hreset_n_o));

// --- pclk edges are a subset of hclk edges (the no-CDC argument, checked)
a_pclk_subset_hclk: assert property (
  @(posedge pclk_o) $rose(hclk_o) || hclk_o);

// --- pclk_phase leads each pclk rising edge by exactly one hclk cycle
a_pclk_phase: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_o)
  pclk_phase_o |=> $rose(pclk_o));

// --- pclk is always exactly half of hclk
a_pclk_ratio: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_o)
  $rose(pclk_o) |=> ##1 $fell(pclk_o));

// --- glitch-free ratio change: no short pulse during DIVBUSY
a_div_no_glitch: assert property (
  @(posedge refclk_i) disable iff (!ext_rst_n_i)
  div_busy |-> ##[0:3] !$fell(hclk_o) or (hclk_low_count >= 2));

// --- preset_n never deasserts before hreset_n (release order, N-7.17)
a_release_order: assert property (
  @(posedge pclk_i) $rose(preset_n_o) |-> hreset_n_o);

// --- hartreset resets the core without touching the fabric
a_hartreset_scope: assert property (
  @(posedge hclk_i) hartreset_req_i |-> !core_rst_n_o && hreset_n_o);
```

---

## 11 Verification plan

| Req | Test | Oracle | Coverage goal | Status |
|---|---|---|---|---|
| R-1 | `t_clk_div2` | `hclk` period = 2× `refclk`, duty 50% ±2% | — | new |
| R-2 | `t_pclk_div2` | `pclk` period = 2× `hclk`, duty 50% ±2% | — | new |
| R-3 | `t_div_sel` | each `DIVSEL` value gives the right ratio | all 4 values | new |
| R-3 | `t_div_switch_glitch` | `a_div_no_glitch` holds across all 12 ratio transitions | all ordered pairs | new |
| R-4 | `t_no_por` | chip resets correctly with `ext_rst_n` as the only source | — | new |
| R-5 | `t_reset_stretch` | every reset ≥1024 refclk cycles | all 4 sources | new |
| R-5 | `t_wdt_self_cancel` | watchdog single-cycle pulse → full-length reset | — | new |
| R-6 | `t_reset_domains` | each source's excluded blocks are not reset | all 4 sources | new |
| R-7 | `t_sync_release` | no flop in a domain leaves reset on a different cycle | — | new |
| R-8 | `t_rst_reason` | correct bit after each reset type; W1C works | all 5 bits | new |
| R-9 | `t_ndmreset_dm_alive` | DM and TAP respond during and after `ndmreset` | — | new |
| R-10 | — | not simulation-verifiable; checked at floorplan review | — | PD gate |
| §7.4 | `t_no_cdc_proof` | `a_pclk_subset_hclk` + `a_pclk_phase` over 10⁶ cycles | — | new |
| §7.13 | `t_hartreset` | core resets, fabric stays alive, SBA still works | — | new |
| §8.1 | `t_reset_release_order` | refclk → hclk → pclk ordering | — | new |

**Formal recommended for:** `a_reset_min_duration`, `a_pclk_subset_hclk`, `a_pclk_phase`.
These are small, bounded properties on a handful of flops, and they are the properties the
rest of the chip's no-CDC argument rests on. Proving them is cheap and worth more than any
number of directed tests.

---

## 12 Design decisions

| Decision | ADR |
|---|---|
| 500 MHz reference, DIV=2 → 250 MHz, no PLL, DIV parameterised with DIV=4 fallback | ADR-0001 |
| Real 125 MHz `pclk` from a toggle flop, not an ICG, not an access-enable scheme | ADR-0002 |
| 1024-cycle stretch on refclk; no source inside its own reset domain | ADR-0003 |
| Divider flop abuts the pad; 500 MHz confined to that net | ADR-0018 |
| No analog POR; board supervisor drives `ext_rst_n` | ADR-0019 |

---

## 13 Not implemented

| Feature | Why not |
|---|---|
| PLL | The reference already exceeds the target. A PLL is a mixed-signal IP dependency with lock, jitter and bring-up risk for no gain. |
| Analog POR cell | Cannot be assumed present in the PDK, and depending on an absent cell is an unrecoverable hole. A board supervisor is a few rupees and strictly simpler. |
| Non-power-of-2 division | 500→200 MHz needs 2.5×, which needs either a PLL or a non-50%-duty divider. 250 MHz avoids the question. |
| Independent low-power oscillator | A separate always-on oscillator for a sleep domain, for a chip with no sleep domain. |
| Clock gating in `clk_div` | Gating belongs at the consumer, where the idle condition is known. |
| Glitch-free clock *muxing* | There is one clock source. Nothing to mux. |
| Reset-release debouncing on `ext_rst_n` | The board supervisor provides a clean edge; that is the requirement in R-4. |

---

## 14 Open items

None. Previous opens closed as follows:

| Was open | Closed as | ADR |
|---|---|---|
| Is an analog POR available in the PDK? | Assume not. `ext_rst_n` mandatory. | ADR-0019 |
| Pad type and board SI for 500 MHz | Confine 500 MHz to a pad-adjacent net; standard pad. | ADR-0018 |
| Constraints for the 500 MHz divider flop | Stated in §7.21 with the SDC sketch. | ADR-0001 |

---

## 15 Errata

None. Neither block has RTL yet, which is precisely why the Rev 1.1 reset defects cost
nothing to fix: they were caught while the document was still the only artefact.

**Defects fixed in this revision, recorded so they are not reintroduced:**

| ID | Symptom | Root cause | Fix |
|---|---|---|---|
| CR-1 | Watchdog reset would be a runt pulse of one flop delay. | All four sources ORed into one signal that reset the requesters. | Stretch counter, §7.2. |
| CR-2 | Debug reset would kill the debug session and clear `dmcontrol.ndmreset` before the debugger could observe it. | DM was inside the `ndm_rst_n` domain. | Domain table, §7.3. |
| CR-3 | Reset cause would be destroyed by the reset it recorded. | `RSTREASON` was in the general reset domain. | `RSTREASON` reset by `ext_rst_n` only. |
| CR-4 | A stretch counter on `hclk` would never advance. | `hclk` is stopped while reset is asserted. | Counter on `refclk`, [N-7.8]. |
| CR-5 | `pclk` specified as 50% duty but generated by an ICG, which gives 25%. | Mechanism and waveform were specified independently. | Toggle flop, [N-7.2]. |
