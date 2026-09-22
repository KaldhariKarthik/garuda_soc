# GARUDA Pin-out and Physical Constraints — Specification

## 0.1 Identity

| Field | Value |
|---|---|
| Document ID | GARUDA-PHYS-SPEC-001 |
| Revision | 1.0 |
| Date | 2026-09-18 |
| Status | Released for the GDSII handoff |
| Owner | Team AeroSoC |
| Audience | Physical design (1-TOPS mentor), board design |
| Supersedes | nothing — this document did not previously exist |

## 0.2 Why this document exists

No document in this project owned the physical constraints. The pin table lived in the TRM
with GPIO defined as "the remaining budget", which is not a specification — it meant nobody
could check the count, and the count turned out to be the one decision in the whole project
that cannot be undone after the pad ring is fixed.

Four constraints in this document are not derivable from any block spec: the signal-pin
budget, the pad-adjacent placement of the 500 MHz divider, the SDC for the reference clock,
and the supply-pad distribution. A physical design engineer reading the eleven block specs
would not find them. They are collected here so the GDSII handoff is one package.

## 0.3 Normative references

1. `GARUDA-SYS-001` Rev 4.0 — the pin allocation table is generated from `pins`.
2. `GARUDA-ADR-001` Rev 1.0 — ADR-0001, 0013, 0018, 0019, 0020.
3. `GARUDA-CLKRST-SPEC-001` Rev 2.0 §7.6 — the clock constraint this document expands.

---

## 1 Die and package

| Parameter | Value | Source |
|---|---|---|
| Process | 28 nm CMOS | programme |
| Die edge | 1.45 mm | programme |
| Die area | 2.10 mm² | derived |
| Pad ring perimeter | 5.80 mm | derived |
| Total pads | 40 | programme |
| Signal pads | 28 | ADR-0020 |
| Supply pads | 12 (assumed) | ADR-0020 |

**[N-1.1]** At a 70 µm pad pitch, 5.80 mm of perimeter accommodates approximately 82 pads, so
40 pads is not perimeter-limited. The 40-pad figure is a programme constraint, presumably
packaging, and the die has room to spare.

---

## 2 The signal-pin budget and why it is 28

**[N-2.1]** This project assumes the 40 pads include supply pads, leaving 28 for signals.

**[N-2.2]** The reasoning, stated because this is the one irreversible decision here. A chip
switching 30,000-odd flops at 250 MHz in 28 nm needs supply pads both for average current
and, more importantly, for distribution: a pad ring with too few supply connections, or with
them clustered, produces local supply droop and ground bounce that no amount of firmware
work can fix, and that does not appear in any pre-silicon simulation this project runs. Eight
to twelve pads, spread around the ring, is the conventional figure for a die of this class.

**[N-2.3]** The asymmetry that decides it: if the 40 pads turn out to be signal-only, adding
GPIO and the SPI slave back is a top-level wiring change and a pad-ring edit, both cheap and
both before tape-out. If they are not, and the design assumed 40 signals, the discovery comes
when the pad ring is being closed and there is no recovery. Designing for 28 and expanding is
safe; the reverse is not.

**[N-2.4]** **Action for the PD mentor:** confirm against the programme's pad frame whether
supply pads are counted in the 40. If they are not, the 36-pin expansion of §3.2 applies and
it is additive only.

---

## 3 Pin allocation

### 3.1 The 28-pin configuration (baseline)

Generated from `GARUDA-SYS-001` `pins.allocation`:

| # | Name | Dir | Type | Function | Block |
|---|---|---|---|---|---|
| 1 | `refclk` | in | **fast/differential-capable** | 500 MHz reference | 21 |
| 2 | `ext_rst_n` | in | CMOS, Schmitt | External reset from the board supervisor | 22 |
| 3 | `tck` | in | CMOS, Schmitt | JTAG clock, ≤20 MHz | 12 |
| 4 | `tms` | in | CMOS, pull-up | JTAG mode select | 12 |
| 5 | `tdi` | in | CMOS, pull-up | JTAG data in | 12 |
| 6 | `tdo` | out | CMOS, tri-state | JTAG data out | 12 |
| 7 | `spim_sclk` | out | CMOS | SPI master clock | 13 |
| 8 | `spim_mosi` | out | CMOS | SPI master out | 13 |
| 9 | `spim_miso` | in | CMOS | SPI master in | 13 |
| 10 | `spim_cs_flash_n` | out | CMOS, pull-up | Boot flash chip select | 13 |
| 11 | `spim_cs_imu_n` | out | CMOS, pull-up | IMU chip select | 13 |
| 12 | `i2c_scl` | bidir | **open-drain** | I²C clock | 15 |
| 13 | `i2c_sda` | bidir | **open-drain** | I²C data | 15 |
| 14 | `uart0_rx` | in | CMOS | GPS receive | 16 |
| 15 | `uart0_tx` | out | CMOS | GPS transmit | 16 |
| 16 | `uart1_rx` | in | CMOS | Ground-link receive | 17 |
| 17 | `uart1_tx` | out | CMOS | Ground-link transmit | 17 |
| 18 | `uart2_rx` | in | CMOS | Console receive | 18 |
| 19 | `uart2_tx` | out | CMOS | Console transmit | 18 |
| 20 | `pwm0` | out | CMOS | ESC output 0 | 20 |
| 21 | `pwm1` | out | CMOS | ESC output 1 | 20 |
| 22 | `pwm2` | out | CMOS | ESC output 2 | 20 |
| 23 | `pwm3` | out | CMOS | ESC output 3 | 20 |
| 24 | `gpio0` | bidir | CMOS | Discrete IO | 19 |
| 25 | `gpio1` | bidir | CMOS | Discrete IO | 19 |
| 26 | `boot_sel` | in | CMOS, **pull-down** | 0 = flash boot, 1 = JTAG recovery | 4 |
| — | spare ×2 | — | — | Reserved | — |

**Total: 26 allocated, 2 spare, 28 budget.**

**[N-3.1]** `boot_sel` has a pull-down so an unconnected pin boots from flash. A floating
`boot_sel` that read high would leave every board spinning in the recovery loop, looking
dead.

**[N-3.2]** `tms` and `tdi` have pull-ups per IEEE 1149.1, so an unconnected JTAG header
cannot hold the TAP in an active state.

**[N-3.3]** `i2c_scl`/`i2c_sda` must be open-drain pads with no internal pull-up. I²C bus
pull-ups are sized at board level against the bus capacitance; an internal pull-up of unknown
value fights that.

**[N-3.4]** The four PWM pins are dedicated, not GPIO-multiplexed. An ESC output that a GPIO
register write can steal is a flight-safety hazard, and four pins is affordable even in the
28-pin budget. This is the one place in the pin budget where safety beat economy.

**[N-3.5]** Two chip selects on the SPI master, because the boot flash and the IMU share the
bus. No previous document accounted for the second one.

### 3.2 The 36-pin expansion (contingent)

**[N-3.6]** ESP-NOW is **required** (ADR-0020 Rev 2 — it is APF's neighbour-position
source), so the SPI-slave port below is in scope, not contingent. *How* it is added
depends on OPEN-2: if supply pads are **outside** the 40, these pins are additive and
nothing in §3.1 moves; if they are **inside** the 40, 4 pins are reclaimed (baseline:
2 spares + console UART2 — see ADR-0020 Rev 2). OPEN-2 remains the PD mentor's call.

| # | Name | Dir | Function | Block |
|---|---|---|---|---|
| 29–32 | `spis_sclk`, `spis_mosi`, `spis_miso`, `spis_cs_n` | mixed | ESP32 companion / ESP-NOW mesh | 14 |
| 33–38 | `gpio2`–`gpio7` | bidir | Discrete IO | 19 |

**[N-3.7]** The design already supports this: block 14's number is held, DMA channel 4 and its
registers and interrupts exist with `dma_req_i[4]` tied low, CLIC ID 14 is reserved, and APB
window `0x4000_0000` is left unmapped rather than compacting the map. The expansion is a
top-level wiring change and a pad-ring edit, not a redesign. This is what "closed in the
recoverable direction" meant in ADR-0020.

---

## 4 Supply pads

**[N-4.1]** Twelve pads assumed: 6 VDD (1.0 V core) and 6 VSS, distributed around the ring
with no more than about 1.2 mm of perimeter between adjacent supply pairs.

**[N-4.2]** Distribution matters more than count. Supply pads clustered on one edge leave the
opposite corners of the die fed through the full width of the power grid, and at 250 MHz the
resulting IR drop and ground bounce is a functional failure, not a margin question.

**[N-4.3]** If the pad library provides separate IO supplies (VDDIO/VSSIO), the split between
core and IO supplies is the PD engineer's call against the pad library's requirements. This
document does not constrain it beyond [N-4.1]'s distribution requirement.

**[N-4.4]** The `refclk` pad's supply should be on the quietest available segment, and
ideally not shared with the PWM outputs, which switch hard into inductive loads. Jitter
injected onto the reference propagates to every clock in the chip.

---

## 5 The 500 MHz reference clock — the critical physical constraint

**[N-5.1]** This section is the reason this document exists as more than a pin table.

### 5.1 Placement

**[N-5.2]** `clkdiv_toggle_hclk` — the single divide-by-2 toggle flop in `clk_div` — shall be
placed **abutting the `refclk` pad**. The `refclk` net shall connect the pad's input buffer to
that flop's clock input, and to nothing else.

**[N-5.3]** Target net length: under 100 µm. Nothing else may be placed on this net, and it
should not be routed on a layer or in a channel shared with long parallel neighbours.

**[N-5.4]** Rationale. 500 MHz is a 2 ns period on a 1.45 mm die in a bond-wire package. A
500 MHz net routed across the die would need its own insertion-delay budget inside the clock
tree, would couple into every neighbour it runs alongside, and would make the reference's duty
distortion a chip-wide concern rather than a local one. Confining it to the pad's immediate
neighbourhood means 500 MHz exists on roughly 50–100 µm of metal and **every other net in the
chip is 250 MHz or slower.** This converts a chip-wide risk into a local, inspectable one.

### 5.2 Timing constraints

**[N-5.5]** The reference clock and the two derived clocks, for the SDC. This expands
`GARUDA-CLKRST-SPEC-001` §7.6:

```tcl
# ---- reference: 500 MHz, 2 ns. The only net at this frequency.
create_clock -name refclk -period 2.0 [get_ports refclk_i]
set_clock_uncertainty -setup 0.15 [get_clocks refclk]
set_input_transition 0.10 [get_ports refclk_i]

# ---- hclk: 250 MHz, derived by the pad-adjacent toggle flop
create_generated_clock -name hclk \
    -source [get_ports refclk_i] -divide_by 2 \
    [get_pins u_clk_div/u_clkdiv_toggle_hclk/Q]

# ---- pclk: 125 MHz, derived from hclk by a second toggle flop
create_generated_clock -name pclk \
    -source [get_pins u_clk_div/u_clkdiv_toggle_hclk/Q] -divide_by 2 \
    [get_pins u_clk_div/u_clkdiv_toggle_pclk/Q]

# ---- hclk and pclk are synchronous: shared edges, integer ratio.
#      DO NOT declare them asynchronous or exclusive. Paths between them
#      are real and must be timed. See GARUDA-AHB2APB-SPEC-001 §7.2.
set_clock_groups -logically_exclusive -group {refclk} -group {hclk pclk}

# ---- JTAG: genuinely asynchronous, the only such boundary in the chip
create_clock -name tck -period 50.0 [get_ports tck]
set_clock_groups -asynchronous -group {tck} -group {hclk pclk}

# ---- the divider flop is the tightest path in the design: 2 ns, one flop,
#      output inverted to its own input, no combinational logic between.
#      It must be constrained at refclk, never inherited from hclk.
set_max_delay 1.8 -from [get_pins u_clk_div/u_clkdiv_toggle_hclk/Q] \
                  -to   [get_pins u_clk_div/u_clkdiv_toggle_hclk/D]
```

**[N-5.6]** The `set_clock_groups -logically_exclusive` between `refclk` and `{hclk, pclk}` is
correct because no functional path crosses from the 500 MHz domain to the derived clocks other
than through the divider flop itself, which is constrained separately.

**[N-5.7]** **`hclk` and `pclk` must not be declared asynchronous or exclusive of each
other.** Every path between them is real, synchronous and must be timed. This is the whole
basis of the chip's no-CDC architecture, and an incorrect `set_clock_groups` here would
silently waive the paths the design depends on. It is called out because it is the single most
likely constraint mistake in this design, and its symptom is silicon that fails
intermittently at the bridge.

### 5.3 What to check after synthesis

**[N-5.8]** Three checks specific to this design, beyond normal closure:

| Check | Why |
|---|---|
| `refclk` fanout is exactly 1 | Confirms [N-5.2]. Any other load means 500 MHz escaped the pad. |
| `hclk`/`pclk` paths are timed, not waived | Confirms [N-5.7]. Look for unexpected `set_clock_groups` or false paths in the report. |
| WFI clock gate produces no runt pulse at gate level | The ICG's enable timing is invisible in RTL simulation (`GARUDA-CORE-SPEC-001` [N-11.4]). |

---

## 6 Floorplan guidance

**[N-6.1]** Not constraints, except where marked. The PD engineer owns the floorplan; these
are the adjacencies the design's timing depends on.

| Element | Placement | Binding? |
|---|---|---|
| `clkdiv_toggle_hclk` | abutting the `refclk` pad | **yes, §5.1** |
| ISRAM (64 KiB) | near the core's IF and the D-port LSU | no |
| DSRAM (4 × 16 KiB) | near the LSU; the four macros may be split | no |
| Boot ROM (4 KiB) | anywhere; accessed once per power-on | no |
| Core + DSU | one region; the EX critical path must not cross a macro | **guidance, important** |
| AHB interconnect | central to the four slaves | no |
| APB peripherals + bridge | perimeter, near their pads | no |
| JTAG TAP + DTM | near the JTAG pads | no |
| PWM | near the PWM pads, away from `refclk` | **guidance, §4.4** |

**[N-6.2]** The core and DSU should be a contiguous region. The critical path is the 33×33
multiplier in series with the EX result multiplexer with the DSU in the same cone
(`GARUDA-CORE-SPEC-001` §7.9); routing that cone around a memory macro is how 4 ns becomes
unachievable.

**[N-6.3]** Memory area estimate, for floorplanning: 132 KiB of SRAM in 28 nm is roughly
0.25–0.40 mm² depending on the compiler's density option, against 2.10 mm² of die. Memory is
12–19% of the die and the rest is logic and routing, so the floorplan is not
memory-dominated.

---

## 7 Timing closure and the fallback

**[N-7.1]** Target 250 MHz. **Closure is not asserted** by any document in this project.

**[N-7.2]** If closure fails, the recovery is `DIVSEL` = 1 in `clk_div` — DIV=4, `hclk` =
125 MHz, `pclk` = 62.5 MHz. This is a register default change, no RTL edit, no floorplan
change. The flight loop then has 125,000 cycles per iteration, which remains far more than
the workload needs.

**[N-7.3]** The fallback is stated in advance deliberately. A timing miss found during PD is a
schedule problem only if the recovery has to be invented at that point. Here it is a parameter
the PD engineer can apply without consulting anyone.

**[N-7.4]** Order of remedies, if 250 MHz is close but missing:

1. Confirm the EX cone is not routed around a macro ([N-6.2]).
2. Retime or pipeline the 33×33 multiplier — this changes the core and needs re-verification, so it is a last resort, not a first.
3. `DIVSEL` = 1. Costs nothing functional.

**[N-7.5]** Step 2 before step 3 only if there is a reason to want 250 MHz specifically.
There is no functional reason in this design; the only reason is the programme's expectation
of the core's performance.

---

## 8 Board-level requirements

**[N-8.1]** These are requirements on the board, arising from chip-level decisions. The board
designer needs them and would not find them in a block spec.

| # | Requirement | Source |
|---|---|---|
| B-1 | A supply supervisor shall hold `ext_rst_n` low until the core rail is stable. The chip has no analog power-on-reset. | ADR-0019 |
| B-2 | A 500 MHz reference oscillator, 45–55% duty, ≤200 ps peak-to-peak jitter. Not a crystal — a driven XO or equivalent. | ADR-0001 |
| B-3 | The `refclk` trace shall be short, impedance-controlled, with a continuous return path, and routed away from the PWM outputs. | ADR-0018, [N-4.4] |
| B-4 | I²C pull-ups sized at board level; the chip provides none. | [N-3.3] |
| B-5 | `boot_sel` may be left unconnected for flash boot; tie high for JTAG recovery. | [N-3.1] |
| B-6 | The ground-link radio is a board-level choice of one part — telemetry radio **or** LoRa — on `uart1`. The chip does not support both. | ADR-0008 |
| B-7 | Sonar shall be an I²C part. The design has no UART available for it. | ADR-0008 |
| B-8 | In the 28-pin configuration there is no ESP-NOW mesh link. | ADR-0020 |
| B-9 | Boot flash and IMU share the SPI master bus with separate chip selects. | [N-3.5] |

---

## 9 Handoff checklist

**[N-9.1]** For the GDSII package, in order:

| # | Item | Owner | Reference |
|---|---|---|---|
| 1 | Confirm whether supply pads are inside the 40 | PD mentor | §2, [N-2.4] |
| 2 | Pad ring per §3.1 (or §3.2 if item 1 says so) | PD | §3 |
| 3 | Supply pad distribution per [N-4.1] | PD | §4 |
| 4 | `clkdiv_toggle_hclk` abutting the `refclk` pad; `refclk` fanout = 1 | PD | §5.1, [N-5.8] |
| 5 | SDC per §5.2, **including** the `hclk`/`pclk` synchronous relationship | PD | §5.2, [N-5.7] |
| 6 | Core + DSU as a contiguous region | PD | [N-6.2] |
| 7 | WFI ICG checked at gate level for runt pulses | PD + verification | [N-5.8] |
| 8 | If 250 MHz misses, apply `DIVSEL` = 1 rather than escalating | PD | §7 |

---

## 10 Open items

**[N-10.1]** One remains, and it is the only irreversible item in this project:

| ID | Item | Owner | Consequence if the assumption is wrong |
|---|---|---|---|
| OPEN-2 | Are supply pads inside the 40? | PD mentor, against the programme's pad frame | If they are **not**: apply §3.2, additively, nothing moves. If they **are**: the baseline is already correct. Either way the design is safe — which is why it was closed this way. |

All other opens from the original eleven documents are closed. See `GARUDA-ADR-001`
"Open items — all closed."
