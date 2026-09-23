# GARUDA SoC — architecture decision record

**Decisions that resolve a contradiction between two documents, or that close an
open item a specification left for the architecture owner.**

This file exists because `docs/BUGS.md` is the register for defects *found*, and
a defect that spans two released documents needs a recorded *ruling* as well as an
entry. One decision per section. Never renumber — other files reference these by ID.

Related: `docs/BUGS.md` (defect register), `docs/SOC_RTL_LOG.md` (interconnect and
SoC reasoning), `Design_Docs/` (the specifications themselves).

---

## D-1 — CPU/DMA access to the Data SRAM is serialised at the interconnect

**Decided 2026-09-16 · Raised by** `GARUDA-MEM-SPEC-001` Rev 2.0 §7.3 (FLAGGED, cross-block)

### The contradiction

The TRM and the DMA specification both state that CPU and DMA accesses to
*different* Data SRAM banks proceed in parallel, with only a same-bank collision
costing a cycle. Under the frozen Block 6 architecture that is not achievable.
The AHB-Lite interconnect grants exactly one master at a time and presents a
single transaction to slave S2 through one shared address/control bundle. The
Data SRAM sees one transaction per cycle and has no signal identifying which
master issued it. Accesses to different banks are serialised exactly as
same-bank accesses are.

### Decision

**Keep the frozen Block 6 topology. The architecture remains serialised at the
interconnect. Do NOT add a second Data SRAM slave port.**

Banking stays, and stays justified — it buys lower access energy and a shorter
array read, which is what keeps the array inside the 5 ns cycle. It does not buy
CPU/DMA concurrency, and the documents must stop implying that it does. The
functional bank map (DMA buffers in Bank 0, EKF in Bank 1, FreeRTOS in Bank 3)
is retained as a locality and ownership convention enforced by the linker script.

Genuine concurrency would require a second slave port on the Data SRAM fed by a
dedicated DMA path bypassing the shared bundle, with the bank arbiter living in
the memory. That changes both Block 4's interface and Block 6's topology. It is
explicitly rejected for this tapeout.

### Actions taken

| Document | Status |
|---|---|
| `GARUDA-MEM-SPEC-001` Rev 2.0 | Already correct — it follows Block 6 and deleted its own draft bank arbiter. No change. |
| `GARUDA-DMA-SPEC-001` Rev 2.0 (`.docx`) | **Patched**, three passages (below). |
| TRM (`GARUDA - Team AeroSoC`) | **Erratum recorded below — not yet applied.** See the note on the TRM source. |

**DMA specification — three passages corrected in the `.docx`:**

- **§8.5 DMA-CPU bus sharing** — the claim that different-bank accesses proceed
  in parallel, and the "less than 5% of cycles" figure that depended on it,
  replaced with the serialisation rule and the one-beat bound on the CPU's cost
  of losing an arbitration turn.
- **§14 verification plan** — the system-contention stimulus read "CPU and DMA
  access same DSRAM bank simultaneously", describing a condition that cannot
  occur. Now "CPU and DMA both request the Data SRAM in the same cycle (any bank
  combination)". The expected result was already correct and is unchanged: the
  CPU stalls one beat, the DMA completes, no corruption.
- **§17 integration table** — "Bank arbiter resolves DMA-CPU conflicts" was
  pointing at hardware that does not exist. Now attributes the resolution to the
  Block 6 arbiter and states the Data SRAM has no bank arbiter.

> Note on the cross-reference: the Memory spec cites this as "DMA §16". The
> claim is actually in **§8.5**, with the two consequential restatements in §14
> and §17. §16 is Design Decisions and contains no bank-parallelism wording.

### TRM erratum — NOT YET APPLIED

The TRM body could not be edited in this repository. `Design_Docs/GARUDA - Team
AeroSoC.docx` contains only the cover page and table of contents; the body exists
only in the exported `.pdf`. Whoever holds the editable source must apply these
three corrections:

| Location | Current text | Should read |
|---|---|---|
| §III.II AHB-Lite Bus | "When CPU and DMA target the same SRAM bank, DMA wins, CPU stalls one cycle. **Different banks -- zero stall.**" | Delete the final sentence. The interconnect serialises masters before either reaches the memory, so bank index has no bearing on stall behaviour. The DMA wins arbitration and the CPU stalls one beat, whatever banks are involved. |
| §VIII.III Data SRAM | "**Banking allows DMA and CPU to access different banks simultaneously with zero stall.**" | Replace: banking reduces access energy and shortens the array read; it does not permit concurrent CPU/DMA access, because the Block 6 interconnect grants one master at a time. |
| §III.III APB Bus | "Peripheral access cost from CPU: **~3-4 cycles** including bridge CDC latency." | Replace with the figure from D-3 below: ≈6 pclk = 12 hclk ≈ 60 ns, plus one pclk per peripheral wait-state. |

Until that is done the PDF remains the one document in the project still
asserting the rejected model. Nothing depends on it in RTL, but it is the
document most likely to be read by someone new.

---

## D-2 — Reset-cause reporting is out of scope for the first tapeout

**Decided 2026-09-16 · Raised by** `GARUDA-CRG-SPEC-001` Rev 2.0 §8.5

The clock/reset specification scoped reset-cause reporting out, conditionally:
"unless the system architect states otherwise before RTL". This is that
statement, and it confirms the scope as written.

**Decision: no firmware-visible reset-cause reporting in Rev 2.0. Block 23
contains no status register. Proceed with the RTL at the current scope.**

The consequence is accepted and should be stated plainly rather than discovered
later: after a reset, firmware cannot distinguish a watchdog reset from a
power-on reset. A watchdog reset in flight is a genuinely different event from a
cold boot and a later revision may well want to log it or enter a degraded mode.

It is deferred because implementing it is not a wording change. A reset-cause
register must survive the reset it records, which needs either a separate
always-on reset domain or a flop set by `wdt_reset_i` and cleared only by
`por_n_i` — and it raises the unanswered question of whether GARUDA has an
always-on domain at all. Building speculative infrastructure for an undecided
requirement is the wrong thing to put in a block this small. If the distinction
is later required it becomes its own design addition with its own reset-domain
specification.

---

## D-3 — Bridge §9.1 is the authoritative peripheral-access latency

**Decided 2026-09-16 · Closes** `AHB-5` in `docs/BUGS.md`

`GARUDA-BRG-SPEC-001` Rev 2.0 §9.1 is the single authoritative figure for the
cost of a peripheral access, superseding the TRM's loose "~3-4 cycles":

> **≈6 pclk = 12 hclk ≈ 60 ns** with no wait-states, plus one pclk (2 hclk) per
> PREADY wait-state the addressed peripheral inserts.

This agrees with the 12–13 hclk measured against `tb/ahb/ahb2apb_bridge_model.v`,
which is what raised AHB-5 in the first place. Units are the trap here and the
spec says so explicitly: a pclk cycle is 10 ns and an hclk cycle is 5 ns, so
6 pclk is 12 core cycles, not 3.

**No other block may re-count this latency.** The DMA spec's "config-write
latency ≈ 6 pclk" and its "~5–7 hclk per beat" for a peripheral-mapped source
both describe this same crossing, which is owned by the bridge.

Write posting was considered as the alternative fix and is rejected (BRG §13.3):
it would let a store retire before the APB access completed, which breaks the
in-order two-cycle-ERROR reporting the DMA beat engine depends on to cancel a
pipelined write. The latency is correct as measured; it was the documented
number that was wrong.

---

## D-4 — Rev 4.0 (`GARUDA-SYS-001`, `garuda_system.yaml`) supersedes the Rev 2.0 block specs

**Decided 2026-09-19 · Owner:** Karthik (architecture sign-off)

The RTL landed on 2026-09-16 (D-1..D-3 above, Blocks 3/4/5/6/8/16/22/23) was
written to the Rev 2.0 documents: 200/100 MHz, an asynchronous bridge crossing,
three AHB masters, CLIC at APB window 9, timers at window 8. The Rev 4.0 set
(`Design_Docs/GARUDA-*-SPEC-001.md`, `GARUDA-TRM-001.md`, `GARUDA-ADR-001.md`,
`garuda_system.yaml`, all dated 2026-09-18) is now normative. The RTL is
migrated to it; block numbers in RTL comments follow the yaml (CLIC = 10,
timers = 11, clk_div = 21, reset_ctrl = 22).

Where the Rev 4.0 documents contradict each other, the rulings D-5..D-13 below
apply. The general rule is the yaml's own: **the yaml wins over prose**, except
where the yaml is itself inconsistent with a later ADR, in which case the
ruling says which way and why. Cross-block numbers reach the RTL and firmware
only through `tools/garuda_gen.py` → `rtl/include/garuda_map.vh` /
`sw/common/garuda_map.h`.

D-2 (reset cause out of scope) is **superseded**: Rev 4.0 specifies
`RSTREASON` (CLKRST §6.1) and it is implemented.

## D-5 — pclk exists; APB register interfaces are on pclk; no synchronisers

ADR-0002's title ("There is no pclk") and ADR R1 ("delete pclk") contradict the
yaml (`clocks.pclk.exists: true`, "ADR-0002 rev 2"), the TRM (§2, R1 as
restated in §9.2), CLKRST, AHB2APB, CLIC §9 and DMA §9.
**Ruling:** pclk = hclk ÷ 2 (125 MHz) from a toggle flop, edges a strict subset
of hclk edges. The APB bus and every block's APB register interface run on
pclk; block cores run on hclk. Values cross pclk→hclk on shared edges with no
synchroniser (not a CDC). The DMA's three `dma_cdc_*` modules are deleted. The
yaml keys `apb.clock: hclk` and `dma.cdc: none` are read as "no CDC", not as
"no pclk".

## D-6 — APB window addresses are normative; unmapped = 0x0 and 0xC–0xF

The yaml numbers windows 1–11 and the TRM/AHB2APB 0–10 in places, but every
document agrees on the base addresses. **Ruling:** window n is
`0x4000_0000 + 0x1000·n`; PSEL bit n = `haddr[15:12]`. The AHB2APB [N-7.19] /
`a_unmapped` / `t_apb_unmapped` set "0xB–0xF" is an erratum — 0xB is the
timers window. Unmapped windows are 0x0 and 0xC–0xF. Windows with no RTL yet
(the deferred peripherals 1–4, 6–8) are masked and fault with the two-cycle
ERROR until their IP lands. Aliasing across the 256 MiB region is by design
(yaml: decode on `HADDR[31:28]` plus in-region offset).

## D-7 — Master reachability: decode is the only gate

The yaml `master_reachability` omits Boot ROM for the DMA; DMA R-9 /
`a_no_isram` also forbids ISRAM. ADR-0005 forbids structural restrictions.
**Ruling:** ADR-0005 + yaml for the fabric: no master is structurally blocked
by the interconnect. The DMA's own R-9 restriction is enforced inside the DMA
(see D-16).

## D-8 — Reset reason register layout and domain

yaml (`por_n`=0, `ext`=1, `wdt`=2, `ndm`=3, reset only by POR) vs CLKRST §6.1
(`EXT`=0, `WDT`=1, `NDM`=2, `SW`=3, `BOOTFAIL`=4) vs ADR-0019 (no POR).
**Ruling:** CLKRST §6.1 layout. With no POR cell, `ext_rst_n` is the only
source that clears the register, and it sets `EXT`; every internal source sets
its own bit and leaves the others. W1C.

## D-9 — Every reset source is stretched; the DM and TAP sit outside ndmreset

ADR-0003 says "roughly 10 µs"; CLKRST/TRM say 1024 refclk cycles (≈2.05 µs).
DEBUG [N-7.14] lets `ndmreset` bypass the stretch; CLKRST [N-7.7] stretches
everything. **Ruling:** 1024 refclk cycles for every source including
`ndmreset` — one mechanism, no special case. `reset_ctrl` provides a separate
`dm_rst_n_o` (external and watchdog only) so the Debug Module survives the
`ndmreset` it issues.

## D-10 — Pin list: ADR-0020 supersedes ADR-0013

28 signal pins, `gpio0..1`, no SPI slave, 2 spare. DEBUG R-1's citation of
ADR-0013 is stale.

## D-11 — Boot image header: MEM §8.1 (32 bytes, two CRCs) is normative

The yaml `boot.sequence` 16-byte, single-CRC description is stale.

## D-12 — DSU instruction set: the RTL is normative

yaml `instructions: 9` vs DSU §7.1 (11). Per the project rule "when the RTL and
the document disagree, the RTL wins" for the frozen DSU boundary; the documents
are corrected to the decoder in `rtl/dsu/dsu_decoder.v`.

## D-13 — Documentation-only stale figures

ADR-0002/0004 "100 MHz", CORE [N-7.30] "4 ms loop", DMA [N-7.12] "125 million
beats", TRM "8 peripherals" are stale text with no RTL consequence.

---

## D-14 — Stretch counter clock, BOOTFAIL set path

**Decided 2026-09-19 · Raised by** CLKRST §7.2 [N-7.8] vs CLKRST R-10 / ADR-0018 / PHYS [N-5.6]

CLKRST puts the 1024-cycle stretch counter and `RSTREASON` on `refclk`, while
R-10 / ADR-0018 confine the 500 MHz net to the single pad-adjacent divider
flop, and PHYS declares `refclk` and `hclk` logically exclusive. Both cannot
hold. **Ruling:** the stretch counter, request capture and `RSTREASON` are
clocked by `aon_clk` — the output of the pad-adjacent ÷2 toggle flop (250 MHz),
which is reset only by the raw pin, runs through every reset, and does not
change with `DIVSEL`. 1024 `aon_clk` cycles = 2048 refclk cycles, which meets
R-5 (≥1024 reference cycles). The 500 MHz net reaches one flop, as R-10
requires. The SDC gets `aon_clk` as a generated clock (÷2 of `refclk`), with
`hclk`/`pclk` generated from it.

`RSTREASON` is W1C, so the bootloader cannot set `BOOTFAIL` through it.
**Ruling:** `RSTCTL[4]` (`SETBOOTFAIL`, write-1, self-clearing) sets it. This
uses a bit CLKRST §6.2 marks reserved.

---

## D-15 — Core CLIC surface: one trap vector, mintstatus address, misa

**Decided 2026-09-19 · Raised by** CORE-SPEC Rev 3.0 §6.1 / §15 T-5 vs the ratified CLIC

- `mtvec.MODE` reads 3 (CLIC). Exceptions **and** interrupts vector to
  `{mtvec[31:2], 2'b00}` — CORE erratum T-5's 4-byte alignment, applied to both
  so there is one rule. SHV and `mtvt` are removed (the Rev 4.0 CLIC has no
  per-source vectoring); the handler reads `mcause[4:0]`.
- `mintstatus` is at 0x346 as CORE §6.1 states; the ratified CLIC address
  0xFB1 is kept as a read-only alias so standard tooling still works.
- `misa` = 0x4000_1100 exactly as specified (the X bit is not set).
- `mie` implements MTIE only; `mip` shows MTIP only; `mnxti` reads 0.

## D-16 — DMA: R-9 enforced by the DMA itself; `dma_ack` width

**Decided 2026-09-19 · Raised by** DMA-SPEC R-9 / [N-7.20] vs ADR-0005 (and D-7)

- ADR-0005 forbids *structural* reachability restrictions in the fabric; DMA
  R-9 requires that the DMA never touch ISRAM or Boot ROM. Both hold: the
  interconnect stays universal, and the DMA engine checks its own SAR/DAR and
  refuses an ISRAM/Boot ROM address with ERROR/ERRPHASE and no bus transfer.
  D-7's first sentence stands for the fabric; this refines it for the DMA.
- `dma_ack` is held for 2 hclk cycles (one pclk period, parameter
  `ACK_CYCLES`) instead of one: a pclk-domain peripheral is guaranteed exactly
  one pclk edge on which to see it. A single-hclk pulse could fall between
  pclk edges and be missed.

## D-17 — Watchdog early warning is held, not a one-cycle level

**Decided 2026-09-19 · Raised by** TIMERS [N-6.6]/[N-6.8]

The spec asserts the warning only while `WDTVAL == WDTWARN` — one hclk cycle.
A level-triggered CLIC source that short is lost if the core is not taking
interrupts in that exact cycle (MIE briefly clear, another handler at a higher
level). **Ruling:** `warn = EN & WARNEN & (WDTVAL <= WDTWARN)`, held until a
kick (which reloads the counter above the threshold) or until firmware clears
`WARNEN`. The handler's contract is unchanged: record diagnostics, then either
kick or clear `WARNEN`.

## D-18 — Debug implementation details

**Decided 2026-09-19 · Raised by** DEBUG-SPEC §5, §6.8, §9

- The DM registers, including `dmactive`, are in hclk on `dm_rst_n`
  (external, watchdog, SWRST — not `ndmreset`, not `hartreset`), which meets
  R-8's intent: a debug-initiated reset never ends the session.
- The TAP additionally takes a power-on reset from the `ext_rst_n` pin. There
  is no TRST, and IEEE 1149.1 needs a defined TAP state at power-up; the
  5×TMS-high reset still works at any time.
- The core exposes one sticky DSU overflow flag (the three MAC flags are ORed
  inside the DSU); `dsuovf` reports it in bit 0.
- `dmi_cdc` re-arms after an hclk-only reset by adopting the tck-side request
  toggle, so a watchdog reset during a session cannot replay the last DMI
  request (possibly an `ndmreset` write).

---

## D-19 — How firmware reads `boot_sel`

**Decided 2026-09-19 · Raised by** MEM-SPEC §8.2 step 2 ("Sample boot_sel") — no
register is specified anywhere in the Rev 4.0 set.
**Ruling:** the pin is two-flop synchronised in `reset_ctrl` and read at
`CLKSTAT[8]` (`0x4000_9008`), next to the other boot/reset status the
bootloader already reads.

## D-20 — JTAG recovery hand-over: the DSRAM mailbox

**Decided 2026-09-19 · Raised by** MEM §8.2 step 12 / DEBUG [N-7.8], [N-7.18]

With `boot_sel = 1` the ROM "spins with ISRAM unlocked", and the debugger
"releases hartreset to start" the loaded image — but releasing `hartreset`
restarts the core at the reset vector ([N-7.9]), the ROM samples `boot_sel`
again and spins again. Nothing in the documents hands control to the image.
**Ruling:** the recovery loop polls a mailbox in the last 16 bytes of DSRAM
(`0x2000_FFF0`): word 0 = `0x4A54_4147` ("JTAG"), word 1 = entry. On a match
the ROM clears word 0 and jumps. The debugger's flow is: halt, load ISRAM over
SBA, write entry then magic, resume. Words 2/3 receive `mcause`/`mepc` if the
ROM itself traps, so a boot fault is readable over JTAG. The ROM stack sits
just below the mailbox (`0x2000_FF00`). Firmware must not use the top 256
bytes of DSRAM before its own init. Proven end to end by `make test_chip_jtag`.

---

## D-21 — The peripheral contract: held interrupts, and DMA requests that drop

**Decided 2026-09-22 · Raised by** adapting third-party IP to GARUDA's fabric

Every peripheral window presents the same front end, `rtl/common/garuda_apb_shim.v`,
whatever the IP behind it does natively. Four rules, implemented once:

1. **PREADY is driven high, always.** The bridge abandons a transfer after 16
   pclk (AHB2APB [N-7.15]), so an IP that stalls the bus while a wire
   transaction completes would turn a register access into a bus fault. All four
   vendored IPs tie PREADY high; a simulation assertion in the shim fires if a
   re-vendor ever changes that.
2. **Interrupts are captured sticky.** Upstream sources are a mix of pulses
   (SPI `events_o`), read-to-clear levels (GPIO) and state bits (16550 IIR). The
   shim captures each into `IRQSTAT`, so the line the CLIC sees is a held level
   cleared only by firmware — the D-17 rule applied uniformly. A source still
   asserted cannot be cleared by W1C (set beats clear), so an interrupt cannot be
   lost in the act of acknowledging it.
3. **DMA requests must drop after every beat.** `rtl/dma/dma_chan.v` takes
   exactly one beat per request assertion: its `taken_q` sets on `beat_done` and
   clears only when `req_i` drops. A FIFO-level request that stays high would
   therefore move one beat and then stall the channel **silently**. The shim
   drops `dma_req` on `dma_ack` and holds it off for one pclk.
   `tb/common/dma_req_checker.sv` enforces this and is bound in every block TB.
4. **Peripheral DMA beats are word-sized.** The bridge is word-only, so a DMA
   beat to an APB address must be a word. UART and I²C therefore expose their
   byte data register as one byte in bits [7:0] of a word; SPI keeps native
   32-bit words.

Common register tail in every window: `0xFE0 IRQSTAT` (W1C), `0xFE4 IRQEN`,
`0xFE8 DMACTL`, `0xFEC ID`.

## D-22 — Third-party RTL is vendored, never edited

**Decided 2026-09-22 · Raised by** sourcing the seven peripherals

The sourced peripheral IP never arrived, so the five peripheral functions are
adapted from open-source IP: PULP (`apb_spi_master` + `axi_spi_master`,
`apb_uart_sv`, `apb_gpio`, Solderpad 0.51) and the OpenCores I²C master
(Richard Herveille, notice-preserving licence). PWM is written in-house — the
only PULP option is the much larger `apb_adv_timer`, and an ESC output's
safe-idle requirement is cheaper to prove on a counter-compare.

**PULP's `apb_i2c.sv` register front end is deliberately not vendored**: it
carries no licence header and its repository has no LICENSE file. Only the
OpenCores bit/byte controllers underneath it are taken, and our own register
layer sits on top. Provenance a tapeout can stand behind matters more than the
~200 lines saved.

Policy: upstream files live under `rtl/third_party/` and are **never edited** —
every delta belongs in the GARUDA wrapper. An unavoidable change goes in
`<ip>/patches/*.patch` with a `Docs/BUGS.md` entry; an empty `patches/` is the
preferred state, but **not at the cost of a requirement** — see D-24, which
governs when to reach for it and what it costs. `rtl/third_party/MANIFEST.yaml` records url, commit and licence;
`HASHES.txt` records what was vendored; `tools/vendor_sync.py --check` fails if
anything drifts. Each IP compiles into its own Xcelium library (`-makelib`),
because PULP's generic module names (`clk_div`, FIFOs, clock gates) collide with
GARUDA's own. Licences are reproduced in `Docs/THIRD_PARTY_NOTICES.md` and ship
with the design.

---

## D-23 — Adapted IP is integrated against its source, not its port names

**Decided 2026-09-22 · Raised by** the first vendored block, SPI master

Bringing up `apb_spi_master` cost an afternoon to a two-character mistake. The
wrapper connected MISO to `spi_sdi0`, which is what the name suggests for a
single-bit SPI master. The upstream lanes are **quad-SPI pads**, and single-bit
mode uses a different lane in each direction: `spi_master_tx` drives IO0
(`sdo0` → MOSI) and `spi_master_rx` shifts in IO1 —
`data_int_next = {data_int[30:0], sdi1}` — because that is where MISO sits on a
quad-capable flash.

The failure mode is the reason this is a ruling. Nothing complained. The
transfer ran, the chip select and SCLK were perfect, the flash model decoded
the command and the address and returned the right bytes, the RX FIFO reported
a word — and every word read back as zero. On a board this looks like a dead
flash, and the scope agrees with you.

**Rule: for every vendored module, the integration is written from the RTL that
*uses* a port, not from the port's name or the datasheet.** In practice, for
each wrapper: find the assignment or shift expression each connected signal
actually reaches, and put the line of upstream that decides it in a comment next
to the connection. `garuda_spim_top.v` and [N-7.6] are the worked example.

Corollary for verification: a block TB must move **real data end to end through
the pins**, not just prove the registers read back. `tb_spim` passed eleven
contract checks — PREADY, PSLVERR, IRQ, DMA hold-off, chip-select exclusivity,
SCLK rate — with MISO connected to the wrong pin. Only `t_spim_flash_read`,
which compares bytes against a flash model that was programmed with a known
pattern, caught it.

---

## D-24 — A stated requirement outranks an untouched vendored file

**Decided 2026-09-23 · Raised by** UART parity/framing reporting (ERR-U2) ·
**Owner's call (Karthik), overruling the recommendation on this page's author**

D-22 says vendored RTL is never edited and every delta lives in a wrapper, with
`patches/` as an escape hatch whose goal state is empty. Faced with the first
real test of that — the vendored UART cannot report parity or framing errors,
two independent upstream defects — the proposal was to accept the gap, record
R-7 as not met, and rely on the checksums that MAVLink, UBX and the console
already carry.

**That was the wrong trade and it was rejected.** Two reasons, and both
generalise:

1. **"Empty `patches/`" is a preference; R-7 is a requirement.** D-22 provided
   the mechanism precisely for the unavoidable case, and this is unavoidable in
   the strict sense: the wrapper sees only the APB side and the raw `rx` pin, so
   detecting a parity error there would mean reimplementing the receiver. When
   the wrapper genuinely cannot do it, the escape hatch is the intended path,
   not a failure of discipline.
2. **A protocol checksum is not an error report.** It tells firmware to drop a
   packet; it does not say why. Error counters are how a flaky connector, EMI,
   or a baud mismatch get told apart on a GNSS or telemetry link in the field.
   Trading that away rests on an assumption about what firmware will always do,
   and that is not hardware's assumption to make.

**Rule: when a written requirement can only be met inside vendored RTL, patch
it — and pay the full price of doing so properly.** The price is not the diff.
It is:

- the pristine file snapshotted under `<ip>/patches/orig/`, so the delta stays
  auditable offline and forever;
- a patch file that states the defect, the fix, and *why the wrapper could not
  do it*;
- `tools/vendor_sync.py --check` extended to verify that the working files are
  still exactly `orig/` + the recorded patch, so an unrecorded edit fails CI —
  the mechanism existed only as a comment before this;
- a `Docs/BUGS.md` entry and a `THIRD_PARTY_NOTICES.md` modification notice,
  which Solderpad 0.51 requires of a modified file, plus a marker on every
  changed line;
- **tests for what the patch changes, not just for what it fixes.** Moving the
  UART's FIFO push changed when the receiver returns to `IDLE` relative to the
  next start bit, and `s_rx_fall` is true for exactly one clock. That is a
  behaviour no upstream user has ever exercised, because no upstream user has
  this patch. `t_uart_b2b` — sixteen frames with no inter-frame gap — exists for
  that reason and for no other.

The last point is the one that makes this affordable. Patching third-party RTL
is acceptable *because* we can state exactly what we changed and show it works;
it would not be acceptable on the strength of the diff looking small.

---

## D-25 — PWM is written, not adapted; I²C's register layer likewise

**Decided 2026-09-23 · Raised by** completing the seven peripherals

D-22 makes adaptation the default. Two blocks are exceptions, for two different
reasons, and both are worth stating so the next engineer does not "fix" them by
replacing them with something off the shelf.

**PWM is in-house because of the verification cost, not the design cost.** The
only PULP option is `apb_adv_timer`: four timers with four channels each, an
event unit and a capture/trigger matrix. Adapting it is a day. *Proving* that
no reachable combination of its mode, trigger and channel registers can glitch
an output is not, and the thing on the other end of these four wires is a
propeller. `garuda_pwm_core.v` is one counter and four comparators, so the
argument is exhaustive: the output is high only when the global enable, the
channel enable and the comparator all say so, and every other combination is
low by construction. That is a page of reasoning instead of a campaign.

**I²C's register layer is in-house because of provenance.** PULP's `apb_i2c.sv`
carries no licence header and its repository has no LICENSE file. The bit and
byte controllers underneath it are Richard Herveille's OpenCores code with a
proper notice, so those are vendored and the ~200-line register file above them
is ours. Two hundred lines is a cheap price for being able to state where every
line in the chip came from.

**The rule this leaves:** adapt by default; write it yourself when the
verification argument is the deliverable, or when the provenance cannot be
stated. Do not write it yourself merely because the upstream code is unfamiliar
or unattractive — that is how a schedule disappears.

---

## Open — carried forward, not decided

These are recorded so they are not mistaken for settled. Neither blocks RTL.

- **Memory §13.6 — pre-PDK array budgets.** The ≈2.8 ns array read inside a 5 ns
  cycle is analytic, derived from TRM targets, not compiler output. When the
  foundry memory compiler lands, three things get revisited: whether
  single-cycle access at 200 MHz survives (if not, the memories gain a
  wait-state, which changes the **core's** timing model), the per-bank aspect
  ratio and therefore the bank count, and whether byte-write-enable is native or
  must be built around a word-write macro. Until then, RTL uses behavioural array
  models behind the specified interfaces so only the array instantiation changes.
- **CLIC §11.1 — genuinely asynchronous interrupt sources.** The
  no-synchroniser configuration path is sound for sources in either on-chip
  domain, because pclk is a ÷2 of hclk from one source. It does not cover a
  source asynchronous to clk, the clear candidate being a GPIO interrupt from an
  external pad. Such a source needs a two-flop synchroniser before the CLIC
  samples it, and an edge-triggered pad input needs the edge detected *after*
  the synchroniser. The GPIO specification must state whether it synchronises
  internally or delivers the pad interrupt raw.
- **Duplicate bridge specification.** `Design_Docs/ahb2apb/` holds two documents
  both numbered Rev 2.0: `AS-GRD-08_...` (2026-09-02, APB **v3**, crossing
  described as *mesochronous*) and `GARUDA_AHB2APB_...` (2026-09-14, APB**4**
  with PSTRB, and §13.4 explicitly rejects "mesochronous" as inaccurate). The
  newer supersedes the older on both points. The stale file should be deleted or
  moved to an archive folder — pending owner confirmation.
