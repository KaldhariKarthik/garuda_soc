# GARUDA-ADR-001 — Architecture Decision Record

| Field | Value |
|---|---|
| Document ID | GARUDA-ADR-001 |
| Revision | 1.0 |
| Date | 2026-09-18 |
| Status | Normative for every decision below |
| Owner | Team AeroSoC |

Each record states the decision, what it replaces, why, and what it costs. A decision
here is closed. Reopening one requires a new ADR that supersedes it by number, not an
edit to this text.

`Impact` names the affected specs and whether RTL must change.

---

## ADR-0001 — refclk is the programme-supplied 500 MHz reference. hclk = 250 MHz, DIV=2. No PLL.

**Status:** refclk frequency is an external constraint, not a project decision.

**Decision.** refclk is 500 MHz, fixed by the 1-TOPS tape-out programme. `clk_div` divides
by 2, giving hclk = 250 MHz as the single functional clock. `DIV` is a parameter with
options 2/4/8/16; DIV=4 (125 MHz) is the designated fallback. No PLL, no frequency
multiplication — the reference is already faster than the target, so division is all that
is needed.

**Why DIV=2 rather than DIV=4.** 250 MHz is the highest power-of-2 division of the
supplied reference, and the core spec expects to close there. Taking less performance than
the programme's reference offers, on a tape-out whose point is partly to demonstrate the
core, is not a trade worth making while closure is still plausible.

**Why the fallback is named now rather than later.** Core §8.3 declines to assert 250 MHz
closure, and names the critical path as the 33×33 multiplier in series with the EX result
mux, with the DSU in the same cone — roughly 4 ns of arithmetic. If Genus and Tempus say
it does not close after the October 31 handoff, the recovery must be a parameter change,
not a redesign. DIV=4 gives 125 MHz with the loop budget still 100× larger than the
workload needs (§flight), so the fallback costs nothing functional. Committing to a single
frequency with no declared fallback is how a timing miss becomes a schedule crisis.

**Consequences that need separate ownership.**
1. **500 MHz at the pad.** A 500 MHz single-ended clock entering through a general-purpose
   bond-wire pad in a 40-pin package is not a routine input. It needs a fast input pad or
   a differential receiver, controlled board-level impedance, and a clean return path, and
   the pad's own insertion delay and duty distortion become part of the clock budget. This
   is a pad-frame and board question, not an RTL one, and it is the one piece of ADR-0001
   nobody in this project currently owns. Tracked as OPEN-5.
2. **The divider is on the fastest net in the chip.** `clk_div`'s single toggle flop sees
   500 MHz — 2 ns, the tightest path in the design, and it sits in the pre-reset domain
   that nothing else can help. It must be constrained and reviewed explicitly, not
   inherited from the hclk constraint set. Tracked as OPEN-6.
3. **Peripheral frequency.** ADR-0002 removes pclk, so the sourced IPs see 250 MHz. That
   makes OPEN-1 (each IP's maximum frequency) blocking rather than advisory. The remedy if
   an IP cannot take it is a per-window access-enable divider in the bridge — a wait-state
   count within one clock domain — not a second clock.

**Rejected.** A PLL: the reference already exceeds the target, and a PLL is a
mixed-signal IP dependency with its own lock, jitter and bring-up risk for no gain.
Non-power-of-2 division: 500 → 200 MHz needs 2.5×, and 250 MHz avoids the question.

**Impact.** CLKRST (DIV and the fallback), CORE, AHB2APB (OPEN-1), TRM. RTL: no logic
change; `garuda_soc_top.v`'s 200/100 MHz comments are stale against the generated header.

>> ## ADR-0002 — pclk restored: 125 MHz toggle-flop for peripheral power (Rev 2)
>>
>> **Rev 2 (current) — pclk is KEPT.** Reverses Rev 1's removal. pclk exists as a real
>> 125 MHz clock (hclk / 2, toggle flop, 50% duty), generated in `clk_div` (`pclk_o`,
>> `Docs/DECISIONS.md D-5`). It clocks the 11 APB peripherals, the APB fabric, and the DMA
>> config port (APB window 4). hclk and pclk are a synchronous set - every pclk rising edge
>> is an hclk rising edge (`AHB2APB §7.2`), so there is NO CDC. **Reason:** without a real
>> pclk, peripheral flops toggle at 250 MHz through idle and save no power; a real half-rate
>> clock stops them (Level 3 dynamic power). The DMA *data engine* stays an hclk AHB master;
>> only its *config port* is pclk. **RTL status:** `clk_div` already generates pclk;
>> `dma_apb_slave.v` still runs on hclk and is the one pending RTL change.
>>
>> The Rev 1 text below is retained as history and is **SUPERSEDED**.

## ADR-0002 [SUPERSEDED Rev 1] — There is no pclk. APB runs on hclk.

**Supersedes:** AHB2APB Rev 1.4 §7 (pclk = hclk through an ICG at 125 MHz) and DMA
§15.3 (real CDC primitives on the config port).

**Decision.** One functional clock in the chip. The bridge holds APB timing with
PSEL/PENABLE phases on hclk. No clock gate, no generated clock, no `pclk_o` port, no
`preset_n`. The DMA's config port is an hclk APB slave and its gray-code counter,
toggle-handshake and level synchronisers are removed.

**Why.**
1. The Rev 1.4 mechanism is self-contradicting: it calls itself "no CDC" while the DMA
   spec implements full CDC primitives against the same clock, and the ICG construction
   it describes produces a 25% duty pulse train, not the 50% it claims.
2. A generated clock is real PD work — a second `create_generated_clock`, gate-level
   verification of the ICG, and CDC waivers that a reviewer has to trust.
3. At 100 MHz there is no power or timing reason for the peripherals to run slower.
4. Removing a clock domain removes an entire class of bug that is hard to find in
   simulation and harder at bring-up.

**Cost.** Peripherals see 250 MHz instead of 125 MHz. This is the one real cost of
removing pclk, and it makes OPEN-1 blocking: every sourced IP's maximum frequency must be
confirmed. If an IP cannot take 250 MHz, the bridge gives that window an access-enable
divider — the access is stretched by a wait-state count, still inside one clock domain —
rather than reintroducing a generated clock.

**Impact.** AHB2APB, DMA, CLKRST, TRM. RTL: delete `pclk`/`preset_n` from `dma_top` and
`garuda_soc_top`, delete `dma_cdc_gray.v`, `dma_cdc_pulse.v`, `dma_cdc_sync.v`.

---

## ADR-0003 — Every internal reset source is stretched and sits outside its own reset domain.

**Supersedes:** CLKRST Rev 1.1 §7's flat OR of all four reset sources into `raw_rst_n`.

**Decision.** `reset_ctrl` contains a 1024-cycle stretch counter clocked from **refclk**.
The watchdog's `wdt_rst_n` source flop is reset only by POR/external. The Debug Module
and TAP are outside `ndm_rst_n`. The reset-reason register is reset only by POR.

**Why.** As specified, `wdt_rst_n` and `dbg_rst_n` were ORed into the signal that resets
the blocks producing them. The source clears itself within one flop delay, so the reset
is a runt pulse; `raw_rst_n` also resets `clk_div`, so hclk stops part-way through it. A
debug-triggered reset would additionally reset the DM and so kill the debugger's own
session, which RISC-V Debug 0.13 forbids. The stretch must be on refclk because hclk is
not running while the divider is held.

**Cost.** One counter and one extra reset domain boundary. Roughly 10 µs of reset time.

**Impact.** CLKRST, TIMERS, DEBUG. RTL: none yet (block unwritten) — this is why the
decision lands now.

---

## ADR-0004 — The interconnect is a single shared AHB-Lite layer with four masters.

**Supersedes:** AHB Rev 3.0/3.1's six-layer multi-layer matrix.

**Decision.** One shared layer. Masters, in ascending priority: I-port, D-port, Debug
SBA, DMA. Fixed priority, re-arbitrated every beat, never inside a data phase. Bursts
split at beat boundaries.

**Why.** Utilisation is under 20% at 100 MHz, so six layers buy nothing measurable while
costing six arbiters, six decoders, a 6× wire-count increase on every AHB signal
(HPROT alone went from 4 to 28 wires by the spec's own count) and a routing-congestion
problem on a 1.45 mm die. The shared layer is also already built and carries zero
protocol violations across the full regression. The one thing multi-layer was meant to
deliver — bank-level parallelism between CPU and DMA — is not worth its cost at this
utilisation and is the first thing a v2 can revisit.

**Cost.** The CPU stalls for the DMA's beat under contention, bounded at one beat.

**Impact.** AHB, MEM, DMA, TRM. RTL: add the SBA master port to the existing arbiter and
master mux (a fourth instance of machinery that already exists three times).

---

## ADR-0005 — Master reachability is not structurally restricted. Address decode is the only gate.

**Supersedes:** AHB Rev 3.1 §4 ("I-Port physically cannot reach DSRAM or the bridge, and
D-Port physically cannot reach ISRAM or Boot ROM — no wire exists in the netlist").

**Decision.** Every master reaches every slave, except that the DMA does not reach Boot
ROM (nothing needs it to). Access control is by address decode and the ISRAM write lock.

**Why.** The Rev 3.1 restriction broke three things the design depends on, all of which
its own text elsewhere assumes work:
1. The boot CRC. The bootloader runs on the core out of Boot ROM and must read back
   ISRAM. No master could do that read.
2. `.rodata` and `.data` initialisers. GCC emits PC-relative loads against constants the
   D-port could not reach.
3. JTAG firmware load, since progbuf and SBA writes both land on a data master.

The restriction also saved nothing: the decoder is a 4-bit case statement either way.

**Cost.** None. This is the cheaper design as well as the working one.

**Impact.** AHB, MEM, DEBUG, CORE, TRM.

---

## ADR-0006 — ISRAM is write-locked by the bootloader before it jumps.

**Decision.** `MEMCTL.ILOCK`, a single sticky bit, set by the bootloader before jumping
to firmware and cleared only by reset. While set, writes to the ISRAM region take a
two-cycle AHB ERROR.

**Why.** ADR-0005 makes ISRAM writable by the D-port, which is necessary for boot but
means a wild pointer in flight code can corrupt instruction memory mid-flight. A single
bit closes that window and costs one flop and one decode term. The Debug SBA path
deliberately ignores the lock, otherwise JTAG recovery would be locked out too.

**Impact.** MEM, AHB, DEBUG.

---

## ADR-0007 — DSRAM is four macros behind one AHB slave port.

**Supersedes:** MEM Rev 1.2's four independent AHB slave endpoints.

**Decision.** Four 16 KiB macro instances, one AHB slave port, address bits selecting
the macro. One contiguous 64 KiB region.

**Why.** Four endpoints only had a purpose under the multi-layer matrix of ADR-0004.
With one shared layer, four ports mean four `hreadyout`/`hrdata` sets to mux for no
concurrency gain. One port also keeps the region contiguous, which the linker needs for a
single heap and stack.

**Cost.** No bank-level concurrency. There is none to have with one layer anyway.

**Impact.** MEM, AHB, TRM. RTL: matches the existing single `hsel_dsram`.

---

## ADR-0008 — One peripheral function table. One peripheral per DMA channel.

**Supersedes:** the mutually contradictory assignments in DMA §5 (UART0=sonar,
UART1=GPS, UART2=LoRa, CH5=GPIO/SPI2), TRM §13 (UART0=GPS, UART1=telemetry,
CH5 shared between GPIO and SPI slave) and TRM §14 (LoRa on UART2).

**Decision.** The table in `garuda_system.yaml` `peripheral_functions` and `dma.assignment`
is the only assignment in the project. No document restates it.

Key changes it embodies:
- Sonar moves to I²C. A UART sonar was consuming a whole serial port for one range value.
- Telemetry and LoRa are one role, the ground link, on UART1. Pick one radio at board
  level; the chip does not need both.
- ESP-NOW is the ESP32 companion on the SPI slave port, CH4. "GPIO/SPI2" named a block
  that does not exist and made a GPIO controller a DMA source, which it cannot be.
- UART2 (console) gets CH5. No channel is shared by two peripherals, which was never
  implementable — a channel has one `dma_req`/`dma_ack` pair.

**Impact.** DMA, CLIC, AHB2APB, TRM, and all eight Tier-3 specs.

---

## ADR-0009 — CLIC IDs are assigned once, here, and are level-triggered in hardware.

**Decision.** The `clic.map` table in `garuda_system.yaml`. ID 0 stays a permanently
unassigned sentinel. ID 13 is now reserved, freed by ADR-0010. IDs 23–31 reserved and
disabled at reset.

**Why.** Trigger type is a property of each source's hardware, not a firmware preference,
so making it configurable only creates a way to configure it wrongly. The sentinel at ID
0 makes a stuck or uninitialised ID visible instantly at bring-up.

**Impact.** CLIC, TRM.

---

## ADR-0010 — The machine timer reaches the core as a single `mtip` bit, not 64-bit buses.

**Supersedes:** TIMERS §6 and CLIC §6.3 routing `mtip` as CLIC ID 13, and the core's
present 64-bit `mtime_i`/`mtimecmp_i` inputs.

**Decision.** Block 11 holds `mtime`/`mtimecmp`, does the 64-bit compare, and drives one
`mtip` wire into the core's existing `mip.MTIP` path. CLIC ID 13 becomes reserved.

**Why.** There were two contradictory paths — the core already implements `mip.MTIP` and
it is verified, while three documents say the timer arrives through CLIC. Keeping the
verified path costs nothing, and moving the comparator into the timer block removes 128
top-level wires and a 64-bit comparator from the core's timing cone.

**Cost.** The machine timer cannot be level-prioritised against CLIC sources. It is the
RISC-V architectural timer; it does not need to be.

**Impact.** TIMERS, CLIC, CORE, TRM. RTL: replace the `mtime_i`/`mtimecmp_i` ports with
`mtip_i`, deleting the in-core comparator at `garuda_core_top.v:126`.

---

## ADR-0011 — There are 22 blocks, not 24.

**Decision.** Blocks 1–22 as listed in `garuda_system.yaml`. `clk_div` is 21 and
`reset_ctrl` is 22. Blocks 23 and 24 do not exist, and no block is "Reserved".

**Why.** The TRM's 24-block table carried two reserved rows nothing claimed and marked
six numbers Provisional, because three documents had been assigning their own numbers
(DMA §18.2 had CLIC at 16 and I²C at 12). Numbers are now assigned in exactly one place
and generated into every document, so Provisional as a status disappears.

**Impact.** All specs. Cross-reference tables become generated, not hand-maintained.

---

## ADR-0012 — Debug is System Bus Access only. The core does not change.

**Supersedes:** DEBUG Rev 1.0's Access Register + Program Buffer design and its
"deliberately no bus presence" decision.

**Decision.** JTAG TAP + DTM + DM with SBA as AHB master 2. No abstract register access,
no program buffer, no hart array, no `abstractauto`. Halt is `hartreset`. The DSU
accumulator taps stay.

**Why.**
1. The Rev 1.0 design rests on core features that do not exist. `rtl/core` has no `dpc`,
   no `dcsr`, no `dscratch0/1`, no halt request, no halt drain, no program-buffer fetch
   redirect. DEBUG §1 asserts the core "already commits" to all of them. Building them
   means a new pipeline-control mode in the block that produced most of this project's
   27 errata, then re-verifying it, in six weeks.
2. SBA needs zero core changes and delivers the thing that actually matters day to day:
   loading firmware into ISRAM over JTAG instead of reflashing SPI every iteration.
3. The "stay off the bus so debug works when the bus is broken" rationale did not hold —
   the Rev 1.0 design still depended on the core fetching from a program buffer, so a
   broken core broke debug anyway.

**Cost.** No GPR/CSR inspection, no breakpoints, no single-step in v1. Registers are
observable by having firmware write them to DSRAM, which SBA can read. The v2 upgrade
path is additive and stated in the YAML.

**Impact.** DEBUG (full rewrite), AHB (fourth master), CORE (`hartreset` input only),
MEM (ILOCK bypass), TRM.

---

>> **[Superseded - pin counts]** The "36 of 40, 4 spare" figure is superseded by ADR-0020
>> (28-pin baseline: 26 used, 2 spare) and amended again by **ADR-0020 Rev 2** (ESP-NOW
>> restored). The *allocation principles* below (dedicated PWM, two SPI chip-selects,
>> `boot_sel`) stand; only the counts moved. ADR-by-number rule: highest-numbered ADR wins.

## ADR-0013 — 36 of 40 signal pins allocated, 4 spare, power pads to be confirmed.

**Supersedes:** TRM §4.2's "GPIO = remaining budget" and "PWM shares GPIO pins".

**Decision.** The `pins.allocation` table. GPIO is exactly 8 pins, PWM is 4 dedicated
pins, SPI master gets 2 chip selects, and one pin is `boot_sel`.

**Why.** "Remaining budget" is not a specification — it meant no document owned the
pin-out and the count could not be checked. PWM is dedicated rather than GPIO-muxed
because an ESC output that a GPIO register write can steal is a flight-safety hazard for
4 pins of savings. SPI master needs two chip selects because flash and the IMU share the
bus, which no previous document had accounted for.

**Open.** Whether the 40-pin budget includes power/ground pads. At 28 nm with real
switching it almost certainly does, which would cut the signal budget hard. This must be
confirmed with 1-TOPS against the pad frame (OPEN-2) and it is the single pin-level item
that can still move.

**Impact.** TRM, GPIO, PWM, SPIM specs.

---

## ADR-0014 — `boot_sel` selects flash boot or JTAG recovery.

**Decision.** One pin. Low: boot from SPI flash. High: the ROM spins with ISRAM unlocked
so JTAG SBA can load an image, then release through `hartreset`.

**Why.** It makes a bricked board impossible and makes the development loop a JTAG load
rather than a flash program. One pin, about ten instructions of ROM.

**Impact.** MEM, DEBUG, TRM.

---

## ADR-0015 — The bootloader is polled PIO. No DMA in the boot path.

**Supersedes:** MEM §8.5's DMA P2M flash→ISRAM copy and AHB §13.6's dedicated DMA→ISRAM
path.

**Decision.** The ROM copies flash to ISRAM with polled SPI reads and D-port stores.

**Why.** The DMA copy depended on the sourced SPI master's data register having
P2M-friendly semantics that no document in this project has verified — SPI flash reads
need a command and address phase and a dummy write per received byte, and whether the
VLSI Society IP handles that with `SINC=0` is unknown. Boot is the one path where a
wrong guess is unrecoverable. PIO removes DMA, its arbiter path and the whole boot-time
clock-crossing question from the boot dependency set, at a cost of a few milliseconds
once per power-on. It also deletes the only new wire AHB Rev 3.0 added.

**Impact.** MEM, AHB, DMA, TRM.

---

## ADR-0016 — CRC-32 over the image, and a boot failure spins instead of halting.

**Supersedes:** MEM Rev 1.1's CRC-16-CCITT and dead halt on mismatch.

**Decision.** CRC-32 (IEEE 802.3, poly 0x04C11DB7, init 0xFFFFFFFF) over the image,
computed by the ROM through D-port reads. On mismatch: set the `BOOTFAIL` reason bit and
spin with ISRAM unlocked so JTAG can recover.

**Why.** CRC-32 costs the same table-free loop and the same ROM budget as CRC-16 while
taking the collision space from 2^16 to 2^32 over a 64 KiB image. A dead halt gives the
operator no diagnostic and no recovery; spinning with the lock open means a probe can
both read the reason register and load a good image.

**Impact.** MEM, DEBUG, TRM.

---

## ADR-0017 — The DSU's numeric contract is Q1.15 in, Q18.30 in the accumulator.

**Decision.** Operands Q1.15, products Q2.30, accumulators Q18.30 across 48 bits. Up to
65,536 accumulations before saturation is possible. EKF terms that need more input range
than Q1.15 are RV32IM firmware, not DSU work.

**Why.** No revision of the DSU spec stated a fixed-point format at all, which leaves
firmware to infer the binary point from the RTL — and makes the EKF claim unfalsifiable.
A 9-state EKF's covariance terms span a dynamic range Q1.15 cannot hold, so the spec has
to say which parts of the filter the DSU actually serves. APF repulsion terms and the
bounded matrix products are in range; covariance propagation is not.

**Impact.** DSU, CORE, TRM.

---

---

## ADR-0018 — 500 MHz exists only between the pad and the divider flop.

**Decision.** `clkdiv_toggle_hclk` is placed abutting the `refclk` pad. The 500 MHz net
connects the pad's input buffer to that flop's clock input and nothing else. The flop is
constrained at 2 ns and excluded from the `hclk` constraint set.

**Why.** A 500 MHz net crossing a 1.45 mm die in a bond-wire package needs its own
insertion-delay budget, couples into neighbours, and makes the reference's duty distortion
a chip-wide concern. Confining it to roughly 50 µm of metal turns a chip-wide risk into a
local one, and every other net in the chip becomes 250 MHz or slower. The flop's own path
is a single toggle with no combinational logic, which is the easiest path in the design —
but the timing tool has to be told about it explicitly or it is checked against the wrong
clock.

**Cost.** One floorplan constraint and three SDC lines, both stated in
GARUDA-CLKRST-SPEC-001 §7.6.

**Impact.** CLKRST, TRM, and the PD handoff package.

---

## ADR-0019 — No analog POR. A board supervisor drives `ext_rst_n`.

**Supersedes:** CLKRST Rev 1.1's assumption that an analog power-on-reset cell exists and
is out of scope.

**Decision.** The chip has no analog POR dependency. `ext_rst_n` is the only power-on reset
source, and the board provides a supply supervisor that holds it low until the core rail is
stable.

**Why.** Whether the 28 nm PDK offers a POR cell cannot be confirmed from inside this
project, and a design that depends on an absent cell has an unrecoverable hole: the chip
would come out of reset in an undefined state at every power-on, which is not something a
respin can be scheduled around. A supervisor part costs a few rupees, is a standard board
component, and makes the reset architecture strictly simpler — one external source, no
mixed-signal dependency, no analog characterisation.

**Cost.** A board component becomes mandatory rather than optional. The `RSTREASON.EXT` bit
now covers both power-on and manual reset, so firmware cannot distinguish them; nothing
needs to.

**Impact.** CLKRST, TRM, board design.

---

## ADR-0020 — Assume power pads are inside the 40. Budget 28 signal pins.

**Supersedes:** TRM §4.2's 40 signal pins with power pads counted separately.

**Decision.** Budget 12 pads for power and ground, leaving 28 signal pins. Allocation:
refclk 1, `ext_rst_n` 1, JTAG 4, SPI master 5, I²C 2, UART×3 6, PWM 4, GPIO 2,
`boot_sel` 1 — 26 used, 2 spare. GPIO drops from 8 to 2 and the SPI slave port is not
instantiated. Block number 14 is held for a 36-pin variant.

**Why.** This is the only decision in this set that cannot be undone after the pad frame is
fixed, so it is made pessimistically. A 40-pad ring on a 1.45 mm die switching at 250 MHz
needs on the order of 8–12 supply pads, distributed around the ring so no region is
current-starved; too few produces supply noise that is not fixable in firmware. Designing
for 28 and growing to 36 if the budget turns out to be signal-only is safe. Designing for
36 and discovering it is 28 is not.

**What was cut and why those two.** GPIO 8→2: nothing in the system needs eight discretes,
and the pin-change interrupt still works with two. SPI slave: the ESP-NOW mesh link is the
least essential system function, and keeping it would mean cutting PWM outputs or a sensor
bus instead. PWM stays at 4 dedicated pins because an ESC output a GPIO write can steal is
a flight-safety hazard.

**Cost.** No ESP-NOW mesh in the 28-pin configuration. DMA CH4 and CLIC ID 14 become spare.

**Impact.** TRM, GPIO, PWM, DMA, CLIC, and the new pin-out/floorplan document.

>> **Rev 2 (current) — ESP-NOW is RESTORED and REQUIRED.** Reverses Rev 1's cut.
>> **Reason:** the ESP-NOW mesh is the neighbour-position source for APF collision
>> avoidance - the workload the DSU exists to accelerate. Without it the swarm feature has
>> no input, so it is NOT the "least essential system function" Rev 1 assumed; it is
>> load-bearing. The SPI-slave port (pins 29-32 `spis_sclk/mosi/miso/cs_n`, block 14,
>> CLIC ID 14, DMA CH4) is reinstated.
>>
>> **Pin plan - gated on OPEN-2 (still open; PD mentor's call against the pad frame):**
>> - **Supply pads OUTSIDE the 40** -> the 4 pins are additive per PHYS §3.2; nothing in
>>   the 28-pin allocation moves. Result: 30 signal pins used.
>> - **Supply pads INSIDE the 40** -> reclaim 4 pins: the 2 spares + drop console UART2
>>   (2 pins; DMA priority 0, nothing waits on it; console moves to the ground link at
>>   bring-up). Alternative: ESP32 on the SPI-master bus as a 3rd chip-select (1 pin,
>>   poll-mode) instead of the 4-pin slave port.
>>
>> This ADR does NOT resolve OPEN-2 - it states the decision (ESP-NOW required) and both
>> pin outcomes. **RTL work items:** build `rtl/spi_slave/`; un-tie `dma_req_i[4]` in
>> `dma_top`/`soc_top`; pad-ring edit (PD).

---

## ADR-0021 — Assume plain single-port SRAM macros with no sleep, retain or ECC pins.

**Decision.** `sram_wrapper.v` is the only place a macro is instantiated, and its interface
is clock, address, write data, read data, write enable, byte enables. Any additional pin the
compiler provides is tied off inside that wrapper.

**Why.** Which macro options the compiler run produces cannot be confirmed from inside this
project, and no timing or power budget elsewhere may depend on an option that might not
exist. Designing to the lowest common denominator means the memory subsystem cannot be
blocked by the compiler run, and confining instantiation to one file means adopting a
retention pin later is a single-file change.

**Cost.** The SRAM leakage saving from retention is forgone. It was never quantifiable.

**Impact.** MEM, CLKRST §9.4, TRM power section.

## Open items — all closed

Every item is closed by a decision recorded above. None required an external answer,
because none was available: the programme left these decisions to the project. Each was
therefore closed in the direction that is recoverable if the assumption turns out wrong.

| Was | Closed as | ADR | Recoverable? |
|---|---|---|---|
| OPEN-1 Peripheral IP max frequency | `pclk` = 125 MHz with a per-window `APB_DIV` parameter | 0002 | Yes — change one parameter |
| OPEN-2 Do the 40 pins include power pads? | Assume yes. 28-signal-pin budget, expandable to 36 | 0020 | **No** — pad frame is physical. Closed pessimistically for that reason |
| OPEN-3 Analog POR cell in the PDK? | Assume not. Board supervisor drives `ext_rst_n` | 0019 | Yes — a POR cell could be added later without RTL change |
| OPEN-4 refclk part and jitter | Board choice; chip requires only 45–55% duty and ≤200 ps jitter | 0001 | Yes |
| OPEN-5 Pad type and board SI at 500 MHz | Confine 500 MHz to a pad-adjacent net; standard pad | 0018 | **Partly** — floorplan constraint, fixable before GDSII only |
| OPEN-6 Constraints on the 500 MHz divider flop | Stated with an SDC sketch in CLKRST §7.6 | 0001, 0018 | Yes |
| OPEN-7 Memory compiler retain/sleep pins | Assume none; tie off in `sram_wrapper.v` | 0021 | Yes — single-file change |
| OPEN-8 `t_clic` timeout | Not a decision. Debug task, must precede CLIC RTL | — | n/a |
| OPEN-9 DSU overflow guard width | Not a decision. Read `mac_unit.v`, make the doc match | — | n/a |
| OPEN-10 Firmware loop duty cycle | Measure with `mcycle`; no figure asserted in any spec | — | n/a |

**The two that matter.** OPEN-2 and OPEN-5 are the only ones that are not a parameter or an
RTL edit, because both are physical. If the programme's pad-frame documentation later shows
the 40 pads are signal-only, the 28→36 expansion is additive and safe. The reverse
discovery, after the pad ring is fixed, would not be.

## RTL delta implied by this ADR set

| # | Change | Files | Size |
|---|---|---|---|
| R1 | Delete `pclk`/`preset_n`; DMA config port on hclk | `dma_top.v`, `dma_apb_slave.v`, `garuda_soc_top.v` | small |
| R2 | Delete the three DMA CDC modules | `dma_cdc_*.v` | deletion |
| R3 | Add SBA as AHB master 2 | `ahb_interconnect.v`, `ahb_arbiter.v`, `ahb_master_mux.v` | medium |
| R4 | Replace `mtime_i`/`mtimecmp_i` with `mtip_i` | `garuda_core_top.v`, `garuda_soc_top.v` | small |
| R5 | Add `hartreset` input to the core | `garuda_core_top.v`, `pipe_ctrl.v` | small |
| R6 | ISRAM write lock | new `mem_ctl.v`, `ahb_decoder.v` | small |
| R7 | Remove `clic_mintthresh_o` (no consumer; CLIC takes no threshold input) | `garuda_core_top.v`, `csr_file.v` | small |
| R8 | Six new blocks: memories, bridge, CLIC, timers, debug, clk/rst | new | the real work |
| R10 | `clk_div`: DIV parameter 2/4/8/16, default 2; divider reset by raw por/ext only | new `clk_div_top.v` | small |
| R9 | Diagnose the `t_clic` timeout before CLIC RTL is written | existing | unknown |

## Errata and rulings (2026-09-19)

Contradictions inside the Rev 4.0 set were ruled on during RTL migration. The
rulings are recorded in `Docs/DECISIONS.md` D-4..D-13 and take precedence over
the text above where they differ:

| Ruling | Affects | Summary |
|---|---|---|
| D-5 | ADR-0002, R1, R2 | pclk exists (125 MHz, synchronous); APB register interfaces on pclk; DMA CDC deleted |
| D-6 | AHB2APB [N-7.19] | Window n = `0x4000_0000 + 0x1000·n`; unmapped = 0x0, 0xC–0xF (0xB is timers) |
| D-7 | ADR-0005, DMA R-9 | Decode is the only reachability gate |
| D-8 | ADR-0003, ADR-0019 | `RSTREASON` layout per CLKRST §6.1; cleared only by `ext_rst_n` |
| D-9 | ADR-0003, DEBUG [N-7.14] | 1024-refclk stretch for every source incl. ndmreset; DM/TAP on a separate reset |
| D-10 | ADR-0013 | Superseded by ADR-0020 |
| D-11 | yaml `boot.sequence` | MEM §8.1 32-byte header is normative |
| D-12 | yaml `dsu.instructions` | RTL decoder is normative |
