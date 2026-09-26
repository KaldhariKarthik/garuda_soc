# GARUDA SPI Slave — Design Specification

## 0.1 Identity

| Field | Value |
|---|---|
| Document ID | GARUDA-SPIS-SPEC-001 |
| Revision | 1.0 |
| Date | 2026-09-26 |
| Status | Released for implementation |
| Block | 14 (`spi_slave`) |
| Owner | Team AeroSoC |
| Supersedes | — (first revision; the block was `reserved` with no document) |

## 0.2 Revision history

| Rev | Change | Driver |
|---|---|---|
| 1.0 | First specification. **In-house RTL.** The block was held as a reserved number by ADR-0020 and restored as required by ADR-0020 Rev 2. | ADR-0020 Rev 2, D-25 |

## 0.3 Normative references

`GARUDA-SYS-001` Rev 4.0 · `GARUDA-AHB2APB-SPEC-001` Rev 2.0 ·
`GARUDA-DMA-SPEC-001` Rev 3.0 §7.3 · `GARUDA-CLIC-SPEC-001` Rev 2.0 §7.2 ·
`GARUDA-PHYS-SPEC-001` §3.2 · `GARUDA-DEBUG-SPEC-001` [N-7.16] ·
`Docs/DECISIONS.md` D-14, D-17, D-21, D-25.

---

## 1 Purpose and scope

### 1.1 In scope

One SPI **slave** on APB window 0 (`0x4000_0000`), CLIC ID 14, DMA channel 4,
pins 29–32 `spis_sclk` / `spis_mosi` / `spis_miso` / `spis_cs_n`. The master is
an ESP32 companion running ESP-NOW.

**Why this block exists at all**, in one line, because it was nearly deleted:
ESP-NOW is the **neighbour-position source for APF collision avoidance** — the
workload the DSU exists to accelerate. ADR-0020 Rev 1 cut it as "the least
essential system function"; Rev 2 reversed that, because without it the swarm
feature has no input. It is load-bearing.

### 1.2 Out of scope

- Master mode. That is block 13 (`GARUDA-SPIM-SPEC-001`).
- Quad/dual SPI, and CPOL/CPHA other than mode 0 ([N-7.2]).
- The ESP-NOW protocol, packet format and framing above the byte — firmware's.

### 1.3 Where the RTL comes from

**In-house**, `rtl/spi_slave/garuda_spis_core.v` + `garuda_spis_top.v`. Written
rather than adapted, and the reason is [N-7.1] rather than taste: the
interesting decision in an SPI slave is how SCLK enters the chip, and that is
an architectural choice this design has already made elsewhere. Vendoring a
slave would import someone else's answer to it.

---

## 2 Requirements

| ID | Requirement | Source | Status |
|---|---|---|---|
| R-1 | Receive bytes from an external SPI master, MSB first, mode 0. | ADR-0020 Rev 2 | met |
| R-2 | Transmit a response byte on the same transfer. | ADR-0020 Rev 2 | met |
| R-3 | Frame a packet on `cs_n`: a falling edge starts one, a rising edge ends it. | [N-7.3] | met |
| R-4 | **Add no new asynchronous clock domain to the chip.** | DEBUG [N-7.16], D-14 | met ([N-7.1]) |
| R-5 | Word-only APB, never stalls. | AHB2APB [N-7.12], [N-7.15] | met |
| R-6 | One held, level interrupt to CLIC ID 14. | CLIC §7.2, D-17 | met |
| R-7 | DMA request/acknowledge on channel 4, one beat per assertion, byte in `[7:0]`. | DMA §7.3, D-21 | met |
| R-8 | Report an RX overrun rather than dropping a byte silently. | [N-7.5] | met |
| R-9 | `miso` released and all state idle out of reset; a partial packet must not be presented as data. | Board safety | met |

---

## 3 Block diagram

```
   APB window 0 (pclk 125 MHz)
        │
        ▼
  ┌──────────────── garuda_spis_top ─────────────────┐
  │  garuda_apb_shim ──▶ register file               │
  │   0x00-0x1C  RXDATA TXDATA CTRL STATUS           │
  │   0xFE0-0xFEC  tail                              │
  │                     │                            │
  │                     ▼   garuda_spis_core         │
  │   sclk/mosi/cs_n ─▶ 2-flop sync ─▶ edge detect   │
  │                     ─▶ 8-bit shifter ─▶ RX FIFO  │
  │                     ◀─ TX holding reg ─▶ miso    │
  └──────────── sclk, mosi, miso, cs_n ──────────────┘
        ▲ all sampled in pclk - no second clock domain
```

---

## 4 Sub-block inventory

| Name | Type | RTL file | Role |
|---|---|---|---|
| `garuda_apb_shim` | seq (pclk) | `rtl/common/garuda_apb_shim.v` | decode, PSLVERR, sticky IRQ, DMA, pad sync |
| `garuda_spis_core` | seq (pclk) | `rtl/spi_slave/garuda_spis_core.v` | oversampled shifter, CS framing, byte assembly |
| `garuda_spis_top` | seq (pclk) | `rtl/spi_slave/garuda_spis_top.v` | register file, FIFO, events |

---

## 5 Interfaces

| Port | Dir | Width | Domain | Reset | Description |
|---|---|---|---|---|---|
| `pclk_i`, `preset_n_i` | in | 1 | pclk | — | 125 MHz |
| APB slave | — | — | pclk | — | window 0, `0x4000_0000` |
| `irq_o` | out | 1 | pclk | 0 | CLIC ID 14, level |
| `dma_req_o` / `dma_ack_i` | — | 1 | pclk | 0 | DMA channel 4 |
| `spis_sclk_i` | in | 1 | **async** | — | driven by the ESP32; oversampled ([N-7.1]) |
| `spis_mosi_i` | in | 1 | async | — | oversampled |
| `spis_cs_n_i` | in | 1 | async | — | oversampled |
| `spis_miso_o` | out | 1 | pclk | **0** | response data |
| `spis_miso_oe_o` | out | 1 | pclk | **0** | 0 = released; driven only while selected ([N-9.2]) |

---

## 6 Register map — APB window 0 (`0x4000_0000`)

**[N-6.0]** Window 0 was deliberately left unmapped by ADR-0020 rather than
compacting the window map when this block was cut, precisely so it could come
back without moving anything. This is the block it was held for.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | `RXDATA` | RO | 0 | `[7:0]` received byte; reading pops the FIFO ([N-6.1]) |
| 0x04 | `TXDATA` | RW | 0 | `[7:0]` byte shifted out on the **next** transfer ([N-6.2]) |
| 0x08 | `CTRL` | RW | 0 | `[0]` EN, `[1]` RXFLUSH (self-clearing) |
| 0x0C | `STATUS` | RO | 0 | `[0]` RXVALID, `[1]` CS active, `[2]` OVERRUN (sticky), `[3]` packet done (sticky), `[8:4]` RX FIFO level |
| 0xFE0 | `IRQSTAT` | W1C | 0 | `[0]` byte received, `[1]` packet complete (CS rose), `[2]` overrun |
| 0xFE4 | `IRQEN` | RW | 0 | mask; `irq_o = \|(IRQSTAT & IRQEN)` |
| 0xFE8 | `DMACTL` | RW | 0 | `[0]` request while a received byte is waiting |
| 0xFEC | `ID` | RO | — | `{16'h6A5D, 8'd14, rev}` |

**[N-6.1]** Reading `RXDATA` pops one byte and drops the DMA request for it.
`[31:8]` read 0.

**[N-6.2]** `TXDATA` is **not** double-buffered per byte: it is loaded into the
shifter at the start of each byte. Firmware or the DMA must write the next
response before the master clocks the following byte, which at the [N-7.2]
maximum SCLK leaves at least 8 × 6 = 48 `pclk`. If nothing is written, the
previous value is re-sent — a defined, repeatable value, not an X.

---

## 7 Functional description

### 7.1 SCLK does not get its own clock domain — and that is the design

**[N-7.1]** An SPI slave's shift clock is generated by the other end of the
wire. The obvious implementation clocks the shift register on `sclk` directly
and hands bytes to `pclk` through an asynchronous FIFO. **This design does not
do that**, for a reason that is about the chip and not about this block:

> `GARUDA-DEBUG-SPEC-001` [N-7.16] states that the JTAG `dmi_cdc` crossing is
> **the only asynchronous crossing in the chip**. That single sentence is worth
> a great deal at signoff — one CDC to constrain, one to review, one to argue
> about with a mentor. Adding a second, on a peripheral, to save a handful of
> flops, spends it.

So `sclk`, `mosi` and `cs_n` are **synchronised and oversampled in `pclk`**.
Edges are detected on the synchronised `sclk`, and the shifter advances on a
detected rising edge. The chip keeps exactly one asynchronous boundary, and
this block needs no CDC review, no asynchronous FIFO and no clock constraint of
its own.

**[N-7.1a] The price, stated plainly.** Oversampling imposes a maximum SCLK.
Two `pclk` of synchroniser plus edge detection need the half-period to be at
least three `pclk` to be seen reliably, so **SCLK ≤ pclk / 6 = 20.8 MHz**, and
the specification limit is **SCLK ≤ 20 MHz** with `pclk` at 125 MHz. An ESP32
SPI master defaults well below this; it is a configuration constraint on the
companion, recorded here and checked by `t_spis_rate`.

**[N-7.1b]** If `DIVSEL` lowers `pclk`, the SCLK limit scales with it. At the
DIV=4 timing fallback (`pclk` = 62.5 MHz) the limit is 10 MHz. Firmware that
changes the chip frequency must re-negotiate the companion's SPI clock, exactly
as it must re-program the UART divisors.

### 7.2 Mode

**[N-7.2]** Mode 0 only: SCLK idles low, `mosi` is sampled on the rising edge
and `miso` changes on the falling edge, MSB first, 8 bits per byte. Matching
block 13's mode ([SPIM N-7.4]) keeps one convention in the chip.

### 7.3 Packet framing

**[N-7.3]** `cs_n` falling starts a packet: the bit counter and shifter reset,
so a packet always begins byte-aligned regardless of what preceded it. `cs_n`
rising ends it and sets `IRQSTAT[1]` and `STATUS[3]`.

**[N-7.3a]** A packet whose bit count is not a multiple of 8 leaves a partial
byte in the shifter. **That partial byte is discarded, never pushed.** A
truncated ESP-NOW frame must not appear to firmware as a short but valid one;
the packet-complete interrupt plus the FIFO level is how firmware sees the
truncation.

### 7.4 Interrupts

**[N-7.4]** Three sources into the standard sticky tail (D-21): `[0]` a byte
arrived, `[1]` the packet completed, `[2]` overrun. The intended handler waits
on `[1]`, then drains the FIFO — one interrupt per packet rather than per byte.

### 7.5 Overrun

**[N-7.5]** If a byte completes while the RX FIFO is full, the **new byte is
dropped**, `STATUS[2]` latches and `IRQSTAT[2]` sets. Dropping the newest
rather than the oldest keeps the bytes already accepted contiguous, so a packet
is truncated rather than interleaved — a truncated packet fails its checksum,
an interleaved one might not.

An overrun means firmware or the DMA did not keep up; with the FIFO depth of
[N-8.1] and DMA channel 4 enabled it should not occur, which is why it is
reported rather than tolerated.

### 7.6 DMA

**[N-7.6]** `DMACTL[0]` requests a beat while `STATUS[0]` (`RXVALID`) is set.
Word-sized beats, byte in `[7:0]`, request drops for at least one `pclk` after
every `dma_ack_i` — the shim's hold-off, for the `dma_chan.v` `taken_q` rule
(D-16, D-21). Channel 4 is this block's; `dma_req_i[4]` was tied low at the SoC
top for as long as the block did not exist, and un-tying it is part of landing
this specification.

---

## 8 Timing

**[N-8.1]** RX FIFO depth is **16 bytes**, matching the UART's. At the maximum
SCLK an 8-bit byte takes 400 ns, so a full FIFO represents 6.4 µs of slack for
the DMA or firmware to respond — comfortably more than an interrupt latency.

```
cs_n  ‾‾‾╲______________________________________╱‾‾‾
sclk  ______╱‾╲_╱‾╲_╱‾╲_ ... _╱‾╲______________________
mosi  ----< b7 X b6 X b5 X ... X b0 >------------------
           ▲ sampled on the rising edge (oversampled in pclk)
                                    ▲ byte pushed here
                                                   ▲ packet done
```

---

## 9 Clock, reset and power

**[N-9.1]** One clock domain: `pclk`. **No CDC** — that is [N-7.1] and it is
the block's main design property. The three pad inputs pass through the shim's
two-flop synchronisers.

**[N-9.2]** `spis_miso_oe_o` is **0 out of reset** and is asserted only while
`cs_n` is active and `CTRL.EN` is set. On a bus the ESP32 may share, a slave
that drives MISO while not selected is a contention fault, not a protocol one.

**[N-9.2a] There is a bounded release tail, and it is deliberate.** `cs_n`
reaches the block through the shim's two-flop synchroniser, so the output
enable drops **2 `pclk` (16 ns at 125 MHz) after the pin rises**, measured in
`tb_spis`. Releasing from the raw pin instead would remove the tail but put a
combinational path from an asynchronous pad input onto a pad output enable —
trading a bounded, analysable 16 ns against an unconstrainable path, on the one
block whose entire design premise ([N-7.1]) is that it adds no asynchronous
timing to the chip. The tail is accepted and bounded: `t_spis_reset` fails if
it ever exceeds 3 `pclk`. At the maximum SCLK a bit is 50 ns, so no master can
reselect inside it.

**[N-9.3]** All framing state — bit counter, shifter, byte-assembly — resets
with `preset_n` and again on every `cs_n` falling edge ([N-7.3]), so the block
cannot come up mid-byte after a reset that lands during a transfer.

---

## 10 Assertions

```systemverilog
a_miso_only_when_selected: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
    spis_miso_oe_o |-> (cs_active && en_q));
a_pready:   assert property (@(posedge pclk_i) disable iff (!preset_n_i)
    psel_i |-> pready_o);
a_dma_drop: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
    dma_ack_i |=> !dma_req_o);
a_no_partial_push: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
    cs_rise |-> !rx_push);
```

---

## 11 Verification plan

`make test_spis` — `tb/spi_slave/tb_spis.sv` against
`tb/models/spi_master_model.sv`, 32 checks, 0 failures.

| Req | Test | Oracle | Status |
|---|---|---|---|
| R-1 | `t_spis_rx` | bytes the model sends appear in `RXDATA`, in order | pass |
| R-2 | `t_spis_tx` | the model receives what `TXDATA` was loaded with | pass |
| R-3 | `t_spis_packet` | `cs_n` framing: bit counter resets, `IRQSTAT[1]` on the rising edge | pass |
| R-3 | `t_spis_partial` | a 12-bit packet delivers **one** byte, not two ([N-7.3a]) | pass |
| R-4 | `t_spis_rate` | correct at every half period from 49 ns down to 9 ns, none of them a `pclk` multiple. **Caveat**: ideal simulation edges cannot find the real limit, which is set by metastability and edge rates — the pclk/6 figure is an analysis result the sweep confirms, not one it derives | pass |
| R-5 | `t_spis_pready` | PREADY high in every cycle of every access | pass |
| R-6 | `t_spis_irq` | held ≥50 `pclk`, drops only on W1C | pass |
| R-7 | `t_spis_dma` | `dma_req_checker`; request drops after ack | pass |
| R-8 | `t_spis_overrun` | 20 bytes into a 16-deep FIFO: 16 kept, `IRQSTAT[2]` set, no interleave | pass |
| R-9 | `t_spis_reset` | `miso_oe` low out of reset and while deselected | pass |
| — | `t_chip_spis` | the block from the core, through the real fabric | new |

---

## 12 Design decisions

| # | Decision | Alternative rejected |
|---|---|---|
| 1 | Oversample SCLK in `pclk` | a real `sclk` domain + async FIFO — a second CDC in the chip, for one peripheral ([N-7.1]) |
| 2 | Drop the newest byte on overrun | dropping the oldest — truncates rather than interleaves ([N-7.5]) |
| 3 | Discard a partial byte at `cs_n` rise | pushing it — a truncated frame must not look valid ([N-7.3a]) |
| 4 | `TXDATA` single-buffered | per-byte double buffering — 48 `pclk` of slack is ample, and it re-sends a defined value |
| 5 | Window 0 | compacting the map — ADR-0020 held this slot for exactly this |

---

## 13 Not implemented

**[N-13.1]** CPOL/CPHA other than mode 0, quad/dual, 16-bit words, hardware
packet length or CRC. The ESP-NOW frame format is firmware's.

**[N-13.2]** No TX FIFO: one holding register ([N-6.2]).

---

## 14 Open items

- **OPEN-S1 — bonding, not RTL.** Whether pins 29–32 are additive or reclaimed
  is **OPEN-2**, the PD mentor's call against the pad frame (ADR-0020 Rev 2,
  PHYS [N-3.6]). The RTL, the window, the CLIC ID and the DMA channel are all
  in place either way; what remains is a pad-ring decision. `WITH_SPI_SLAVE`
  on `garuda_chip_top` is the switch.

---

## 15 Errata

None. This block has no vendored RTL.
