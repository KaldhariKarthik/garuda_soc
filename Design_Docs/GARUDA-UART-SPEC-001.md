# GARUDA UART — Design Specification

## 0.1 Identity

| Field | Value |
|---|---|
| Document ID | GARUDA-UART-SPEC-001 |
| Revision | 1.0 |
| Date | 2026-09-23 |
| Status | Released for implementation |
| Blocks | 16 (`uart0`), 17 (`uart1`), 18 (`uart2`) — one design, three instances |
| Owner | Team AeroSoC |
| Supersedes | — (first revision; the blocks were `sourced_ip` with no document) |

## 0.2 Revision history

| Rev | Change | Driver |
|---|---|---|
| 1.0 | First specification. An adaptation of `pulp-platform/apb_uart_sv` behind a GARUDA wrapper, not vendor IP. The interrupt model is GARUDA's, not the 16550's — see [N-7.5] and §15. | D-21, D-22, D-23 |

## 0.3 Normative references

1. `GARUDA-SYS-001` Rev 4.0 — System Definition. All cross-block values come from it.
2. `GARUDA-AHB2APB-SPEC-001` Rev 2.0 — the APB contract this block must satisfy.
3. `GARUDA-DMA-SPEC-001` Rev 3.0 §7.3 — the request/acknowledge handshake.
4. `GARUDA-CLIC-SPEC-001` Rev 2.0 §7.2 — level interrupts.
5. `Docs/DECISIONS.md` D-16, D-21, D-22, D-23.
6. `GARUDA-SPIM-SPEC-001` Rev 1.0 — the first block built this way; the shared tail is identical.

---

## 1 Purpose and scope

### 1.1 In scope

Three independent asynchronous serial ports, one design instantiated three
times. Each is 8-bit, one start bit, configurable parity and stop bits, with a
16-byte transmit and a 16-byte receive FIFO.

| Instance | Block | APB window | Base | CLIC ID | DMA ch | Pins | Intended use |
|---|---|---|---|---|---|---|---|
| `uart0` | 16 | 3 | `0x4000_3000` | 17 | 2 | `uart0_rx/tx` | telemetry link |
| `uart1` | 17 | 4 | `0x4000_4000` | 18 | 3 | `uart1_rx/tx` | GNSS receiver |
| `uart2` | 18 | 6 | `0x4000_6000` | 19 | 5 | `uart2_rx/tx` | console |

### 1.2 Out of scope

- Modem control and flow control. GARUDA has no RTS/CTS/DTR/DSR pins
  (PHYS §3.1), so `MCR`/`MSR` exist but control nothing ([N-13.1]).
- Auto-baud detection, IrDA, RS-485 direction control, 9-bit/address mode.
- The console protocol and any firmware framing — firmware's business.

### 1.3 Where the RTL comes from

`rtl/third_party/pulp/apb_uart_sv` (Solderpad 0.51), **unmodified**, behind
`rtl/uart/garuda_uart_top.v`. The upstream block is a 16550-style register file
over a plain start/data/parity/stop shifter pair with 16-entry FIFOs.

**What had to be taken over, and why, is the substance of this document.**
Upstream's interrupt unit is not usable as it stands ([N-7.5], §15 ERR-U1), so
GARUDA derives its interrupts from the Line Status Register instead — a wrapper
change, in line with D-22.

One defect could **not** be handled in the wrapper: upstream cannot report a
receive error at all (§15 ERR-U2), and the wrapper sees only the APB side and
the raw `rx` pin, so detecting one there would mean reimplementing the receiver.
R-7 is therefore met by a recorded patch to the vendored RTL —
`patches/0001-report-parity-and-framing-errors.patch`, governed by **D-24**,
verified by `tools/vendor_sync.py --check`, and declared in
`Docs/THIRD_PARTY_NOTICES.md` as Solderpad 0.51 requires. It is the only
modified third-party file in the design.

---

## 2 Requirements

| ID | Requirement | Source | Status |
|---|---|---|---|
| R-1 | Transmit and receive 8N1 frames at a programmable baud rate, byte-accurate in both directions. | SYS §6.4 | met |
| R-2 | 115200 baud from `pclk` = 125 MHz with ≤1% baud error. | TRM §3.5 | met |
| R-3 | Word-only APB: every register is 32 bits at a word-aligned offset, even though upstream is byte-addressed. | AHB2APB [N-7.12] | met |
| R-4 | Never stall the APB bus. | AHB2APB [N-7.15] | met |
| R-5 | One held, level interrupt per instance to its CLIC ID. | CLIC §7.2, D-17 | met |
| R-6 | DMA request/acknowledge on the instance's channel, one beat per assertion, word-sized beats carrying one byte in `[7:0]`. | DMA §7.3, D-21 | met |
| R-7 | Report parity and framing errors to firmware without losing received data. | SYS §6.4 | met, via vendored patch 0001 (D-24) |
| R-8 | `tx` high (line idle) from reset until firmware acts; `rx` synchronised before use. | Board safety, D-14 | met |
| R-9 | Three instances are independent: no shared register, interrupt, DMA channel or clock enable. | §1.1 | met |

---

## 3 Block diagram

```
   APB window 3 / 4 / 6  (pclk 125 MHz)
        │
        ▼
  ┌──────────────────────── garuda_uart_top ────────────────────────┐
  │                                                                 │
  │  garuda_apb_shim ──── IP APB ────▶ apb_uart_sv (vendored)       │
  │   ADDR_SHIFT = 2      (byte addr)   ├─ uart_tx  ─┐              │
  │   0x00-0x1C  pass-through           ├─ uart_rx  ─┤ 16-byte      │
  │   0xFE0-0xFEC  IRQSTAT/IRQEN/       ├─ io_generic_fifo x2       │
  │                DMACTL/ID            └─ uart_interrupt (UNUSED)  │
  │                                              │                  │
  │  LSR poll (idle cycles) ──▶ lsr_q ──▶ evt[2:0], dma_req         │
  │  LCR[7] write snoop     ──▶ dlab_q ──▶ gates dma_req            │
  │  rx ──▶ 2-flop sync                          ▼                  │
  └──────────────────────────────────────────── tx, rx ─────────────┘
```

---

## 4 Sub-block inventory

| Name | Type | RTL file | Role |
|---|---|---|---|
| `garuda_apb_shim` | seq (pclk) | `rtl/common/garuda_apb_shim.v` | word decode, PSLVERR, sticky IRQ, DMA request, pad sync |
| `apb_uart_sv` | seq (pclk) | `rtl/third_party/pulp/apb_uart_sv/src/` | 16550 register file + FIFOs (vendored) |
| `uart_tx`, `uart_rx` | seq | same | shifters and baud counters |
| `io_generic_fifo` | seq | same | 16-byte TX and RX FIFOs |
| `uart_interrupt` | seq | same | **instantiated but its output is unused** ([N-7.5]) |
| `garuda_uart_top` | wrapper | `rtl/uart/garuda_uart_top.v` | address shift, LSR poll, DLAB snoop, event derivation |

---

## 5 Interfaces

| Port | Dir | Width | Domain | Reset | Description |
|---|---|---|---|---|---|
| `pclk_i`, `preset_n_i` | in | 1 | pclk | — | APB domain, 125 MHz |
| APB slave | — | — | pclk | — | window 3, 4 or 6 |
| `irq_o` | out | 1 | pclk | 0 | to CLIC ID 17/18/19, level |
| `dma_req_o` | out | 1 | pclk | 0 | DMA channel 2/3/5, level |
| `dma_ack_i` | in | 1 | pclk | — | 2 hclk = 1 pclk (D-16) |
| `uart_tx_o` | out | 1 | pclk | **1** | line idle is high |
| `uart_rx_i` | in | 1 | async | — | synchronised in the wrapper ([N-9.2]) |

`BLOCK_NUM` is a parameter: 16, 17 or 18, so `ID` distinguishes the three
instances at run time.

---

## 6 Register map — one 4 KiB window per instance

Machine-readable source: `spec/regs/uart.yaml`. Offsets `0x00`–`0x1C` are the
vendored 16550 register file **at word offsets**; `0xFE0`–`0xFEC` are the GARUDA
tail common to every peripheral (D-21).

| Offset | Name (DLAB=0) | Name (DLAB=1) | Access | Reset | Description |
|---|---|---|---|---|---|
| 0x00 | `RBR` / `THR` | `DLL` | R / W | 0 | receive byte `[7:0]` / transmit byte `[7:0]` |
| 0x04 | `IER` | `DLM` | RW | 0 | upstream interrupt enables — **leave 0** ([N-7.5]) |
| 0x08 | `IIR` (R) / `FCR` (W) | — | R / W | 0 | upstream interrupt ID / FIFO control |
| 0x0C | `LCR` | — | RW | 0 | line control: word length, stop bits, parity, DLAB |
| 0x10 | `MCR` | — | — | 0 | **not implemented** ([N-13.1]) |
| 0x14 | `LSR` | — | RO | 0x60 | line status ([N-6.3]) — `[3]` exists only because of patch 0001 |
| 0x18 | `MSR` | — | — | 0 | **not implemented** ([N-13.1]) |
| 0x1C | `SCR` | — | — | 0 | **not implemented** ([N-13.2]) |
| 0xFE0 | `IRQSTAT` | | W1C | 0 | `[0]` RX data available, `[1]` TX holding empty, `[2]` line error |
| 0xFE4 | `IRQEN` | | RW | 0 | mask; `irq_o = \|(IRQSTAT & IRQEN)` |
| 0xFE8 | `DMACTL` | | RW | 0 | `[0]` request on RX data, `[1]` request on TX space |
| 0xFEC | `ID` | | RO | — | `{16'h6A5D, BLOCK_NUM, rev}` |

### 6.1 Word offsets over a byte-addressed IP

**[N-6.1]** Upstream decodes `register_adr = PADDR[2:0]` — eight registers at
*byte* offsets 0–7. GARUDA's bridge rejects sub-word accesses before they reach
a peripheral (AHB2APB [N-7.12]), so a byte-addressed register file cannot be
reached at all. The shim is configured with `ADDR_SHIFT = 2`, which presents
our word offset `4n` to the IP as byte offset `n`. Nothing else changes: the
register *contents* are the 16550's.

**[N-6.2]** `PRDATA[31:8]` reads 0, not X: upstream zero-extends every read
(`PRDATA = {24'b0, …}`). Firmware may read a whole word and mask.

### 6.2 `LCR` (0x0C) and the DLAB discipline

**[N-6.2a]** `LCR[7]` is the Divisor Latch Access Bit. While it is set, offsets
`0x00` and `0x04` address the baud divisor (`DLL`, `DLM`) instead of the data
and interrupt-enable registers. This is the 16550's original sin and it is
preserved here because the register file is.

**Rule:** firmware sets `DLAB` only to program the divisor and clears it
immediately afterwards. **The hardware enforces the dangerous half of that:**
the wrapper snoops writes to `LCR` and holds a shadow of `LCR[7]`, and
`dma_req_o` is forced low while the shadow is set ([N-7.6]). A DMA transfer
cannot therefore be pointed at the divisor latch by a driver that forgot to
clear `DLAB` — the request simply never comes, which is a stall a developer can
see, rather than a baud rate silently overwritten with payload bytes.

### 6.3 `LSR` (0x14)

**[N-6.3]** Bits GARUDA relies on. Bits 0, 5 and 6 are **levels** recomputed
every `pclk` from FIFO occupancy; bits 2 and 3 describe **the byte currently at
the head of the RX FIFO** and travel with it:

| Bit | Name | Meaning |
|---|---|---|
| 0 | `DR` | RX FIFO is not empty — a byte can be read |
| 2 | `PE` | parity error on the byte currently at the head of the RX FIFO |
| 3 | `FE` | framing error (stop bit low) on that same byte |
| 5 | `THRE` | TX FIFO is empty — bytes can be written |
| 6 | `TEMT` | TX FIFO **and** the shift register are empty — the line is idle |

**[N-6.3a]** Reading `LSR` has no effect on data. Upstream's read path asserts
`clr_int` into `uart_interrupt` and nothing else — it does not pop a FIFO and
does not alter `regs_q[LSR]`. This is what makes the wrapper's idle-cycle poll
([N-7.4]) safe, and it was verified by reading the upstream read mux, not by
assuming (D-23).

**[N-6.3b]** `TEMT` (bit 6), not `THRE` (bit 5), is the bit to poll before
cutting power or changing the baud rate. `THRE` goes high as soon as the last
byte leaves the FIFO for the shift register, up to ten bit-times before the
stop bit is actually on the wire.

---

## 7 Functional description

### 7.1 Baud rate

**[N-7.1]** The divisor is a plain per-bit counter — there is **no 16×
oversampling**:

```
baud = pclk / (divisor + 1)          divisor = {DLM, DLL}, 16 bits
divisor = (pclk / baud) - 1
```

At `pclk` = 125 MHz:

| Baud | divisor | actual | error |
|---|---|---|---|
| 115200 | 1084 | 115207 | +0.006% |
| 57600 | 2169 | 57603 | +0.005% |
| 9600 | 13020 | 9600.0 | +0.000% |
| 921600 | 134 | 925926 | +0.47% |

R-2 is met with room to spare. `DIVSEL` (CLKRST §6.2) changes `pclk` and
therefore every baud rate: firmware that changes the chip frequency must
re-program `DLL`/`DLM` on all three instances.

### 7.2 Sending a byte

**[N-7.2]**

```
LCR  = 0x83            DLAB=1, 8 bits, 1 stop, no parity
DLL  = 1084 & 0xFF     divisor low
DLM  = 1084 >> 8       divisor high
LCR  = 0x03            DLAB=0 - do not skip this ([N-6.2a])
poll LSR until [5]     THRE: the TX FIFO has room
THR  = byte
```

### 7.3 Receiving a byte

**[N-7.3]**

```
poll LSR until [0]     DR: a byte is waiting
byte = RBR & 0xFF      reading RBR pops the FIFO
```

**Read `LSR` before `RBR`, never after.** `LSR[2]` (parity error) describes the
byte *at the head of the FIFO* — the one the next `RBR` read will return. Read
`RBR` first and the error bit you then read belongs to the following byte.

### 7.4 How the wrapper knows what the FIFOs are doing

**[N-7.4]** Upstream exposes `tx_elements` and `rx_elements` only as internal
signals — they are not ports. The wrapper needs them as levels for both the
interrupt and the DMA request, so, exactly as the SPI master does with its
`STATUS` register (SPIM [N-7.4]), the wrapper — the only APB master into the
IP — **reads `LSR` in the cycles when the SoC is not accessing this window**
and latches the result. No upstream change, no hierarchical reference, and the
status is never more than one `pclk` stale.

This is sound only because of [N-6.3a]: an `LSR` read has no data side effect.
The one thing it does do — pulse `clr_int` into `uart_interrupt` — is harmless
here precisely because that unit's output is not used ([N-7.5]).

### 7.5 Interrupts: GARUDA's model, not the 16550's

**[N-7.5]** `uart_interrupt`'s output is **left unconnected**, and firmware
must leave `IER` (offset 0x04) at 0. The block's interrupt is built in the
wrapper from the `LSR` levels of [N-7.4] and delivered through the standard
sticky tail (D-21):

| `IRQSTAT` bit | Set by | Cleared by |
|---|---|---|
| 0 | `LSR[0]` — RX data available | W1C, and it re-arms while data remains |
| 1 | `LSR[5]` — TX holding register empty | W1C |
| 2 | `LSR[2] \| LSR[3]` — parity **or** framing error at the FIFO head | W1C |

**[N-7.5a]** Bit 2 is one "line error" event for both causes: the interrupt only
has to say *the byte at the head of the FIFO is suspect*. Firmware reads `LSR`
to tell them apart, and the distinction is worth having — a parity error means
noise on the line, a framing error means the baud rate is wrong.

`irq_o = |(IRQSTAT & IRQEN)`, held until firmware writes `IRQSTAT` — which is
the CLIC's requirement (D-17) and is *not* what upstream provides.

**Why, and this is a correctness matter, not a style preference:** upstream
wires the receiver-data-available input of its interrupt unit to the wrong
`LSR` bit — `.RDA_i(regs_n[LSR][5])`, which is `THRE`, the **transmit** FIFO
empty flag, where `regs_n[LSR][0]` (`DR`) was intended. With `IER[0]` set, a
16550 driver would take a "received data available" interrupt whenever the
transmitter drained, and `IIR` would report `0b1000` for it. The only remaining
route to a genuine RX interrupt is `trigger_level_reached`, which upstream
computes with `==` rather than `>=`, so it is missed unless the occupancy is
sampled at exactly the trigger value, and `CTI_i` (character timeout) is tied
to zero, so a part-full FIFO below the trigger level never raises anything.

Recorded as **ERR-U1** in §15 and in `Docs/BUGS.md`. Deriving our own events
from `LSR` costs about fifteen lines in the wrapper, needs no patch to
third-party RTL, and gives firmware the same interrupt model as every other
GARUDA peripheral. That is the trade D-22 exists to make.

### 7.6 DMA

**[N-7.6]** `DMACTL[0]` requests a beat while `LSR[0]` is set (a byte is
waiting); `DMACTL[1]` requests while `LSR[5]` is set (the TX FIFO has room).
The request drops for at least one `pclk` after every `dma_ack_i` — the shim's
hold-off — because `dma_chan.v` takes one beat per assertion and a request that
stays high deadlocks the channel after the first beat (D-16, D-21).

**[N-7.6a]** Beats are word-sized; the byte lives in `[7:0]` and `[31:8]` reads
0. Firmware sets the DMA channel's `SIZE` to word and the peripheral address to
this window's offset `0x00`.

**[N-7.6b]** `dma_req_o` is forced low while the `DLAB` shadow is set
([N-6.2a]).

---

## 8 Timing

### 8.1 One 8N1 frame at 115200 baud

```
        │← start →│← b0 →│ … │← b7 →│← stop →│
tx   ───┐         ┌──────┐   ┌──────┐        ┌────────
        └─────────┘      └───┘      └────────┘
         8.68 us each, 10 bits = 86.8 us per byte
```

A 16-byte FIFO therefore holds 1.39 ms of traffic at 115200 baud — the budget
firmware has to service an RX interrupt before an overrun.

### 8.2 Where the receiver samples

**[N-8.1]** Upstream samples each bit at its **centre**. On the falling edge of
the start bit the baud counter runs to `cfg_div_i[15:1]` — a **half** bit
period — rather than the full `cfg_div_i` it uses for every later bit:

```verilog
if      (!start_bit && (baud_cnt == cfg_div_i))          // data bits: full
else if ( start_bit && (baud_cnt == {1'b0,cfg_div_i[15:1]}))   // start: half
```

That half-bit step is what aligns every subsequent sample to a bit centre.
Measured in `tb_uart`, with the DUT at divisor 124 the samples land 1.54, 2.54,
3.54 … bit periods after the falling edge, against ideal centres of 1.5, 2.5,
3.5 — the 0.04 bit of lag is the pad synchronisers, and it is the same three
flops that delayed the edge detection, so it very nearly cancels.

**Measured receiver baud tolerance: at least ±6%**, which is the full range
`t_uart_baud_tol` sweeps; the receiver did not fail at either end, so the true
figure is wider. 115200 baud against a partner with a ±2% crystal-less clock is
comfortable.

*(Rev 1.0 draft of this section asserted bit-boundary sampling and a tolerance
"smaller than ±5%". That was wrong — it read the data-bit branch of the baud
counter and missed the start-bit branch. The measurement above replaces it, and
D-23's rule earned its keep twice: the first reading of upstream was wrong, and
only running real bytes through it settled the question.)*

### 8.3 DMA request hold-off

As SPIM §8.2 — identical mechanism, identical timing.

---

## 9 Clock, reset and power

**[N-9.1]** Single clock domain: `pclk`, 125 MHz, from `preset_n`. The IP is
fully synchronous to it; there is no CDC inside the block.

**[N-9.2]** `uart_rx_i` is a pad input asynchronous to `pclk` and is passed
through the shim's two-flop synchroniser before it reaches the IP. Upstream
adds three more flops of its own (`reg_rx_sync`), which is harmless — five
flops of latency on a signal whose bit period is 1085 clocks.

**[N-9.3]** `uart_tx_o` is high out of reset (R-8). Upstream resets its
transmitter to the idle line state, and the wrapper adds nothing: a UART line
held low is a continuous break condition to whatever is on the other end.

**The receive side needs the same care and did not get it for free.** The
shim's pad synchronisers reset to `SYNC_RESET`, and this block passes
`SYNC_RESET = 1` because **an idle serial line is high**. With the shim's
original reset-to-zero, the receiver saw a low `rx` for two `pclk` out of reset,
framed that as a start bit, and left a garbage byte at the head of the RX FIFO —
after which *every* read returned the previous byte, for ever. It cost an hour
and it would have looked like an off-by-one in the driver on a board.
`t_uart_rxidle` covers it.

---

## 10 Assertions

```systemverilog
// PREADY is never low - the 16-pclk bridge timeout would fault the access
a_pready: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
            psel_i |-> pready_o);

// the interrupt is a level: it may only fall on an IRQSTAT write
a_irq_held: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
              $fell(irq_o) |-> $past(irqstat_write));

// one beat per request (D-16)
a_dma_drop: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
              dma_ack_i |=> !dma_req_o);

// the divisor latch is never a DMA target
a_dma_dlab: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
              dlab_q |-> !dma_req_o);
```

---

## 11 Verification plan

`make test_uart` — `tb/uart/tb_uart.sv` against `tb/models/uart_model.sv`,
53 checks, 0 failures.

| Req | Test | Oracle | Status |
|---|---|---|---|
| R-1 | `t_uart_tx_byte` | the model decodes what the DUT transmits | pass |
| R-1 | `t_uart_rx_byte` | the DUT receives what the model transmits | pass |
| R-1 | `t_uart_loopback` | 256 bytes both ways, no loss or reorder | pass |
| R-2 | `t_uart_baud` | measured bit period at divisor 1084 is 8.68 µs ±1% | pass |
| — | `t_uart_baud_tol` | **measures** the mismatch the receiver tolerates: **at least ±6%** ([N-8.1]) | pass |
| R-3 | `t_uart_wordmap` | each word offset reaches the intended 16550 register | pass |
| R-3 | `t_uart_dlab` | `0x00`/`0x04` bank correctly, and `PRDATA[31:8]` is 0 | pass |
| R-4 | `t_uart_pready` | `PREADY` high in every cycle of every access, FIFO full and empty | pass |
| R-5 | `t_uart_irq` | held ≥50 `pclk`, drops only on W1C | pass |
| R-6 | `t_uart_dma` | `dma_req_checker`; and no request while `DLAB` is set | pass |
| R-1 | `t_uart_parity` | a clean 8E1 frame carries data and raises no error | pass |
| R-7 | `t_uart_parity_err` | a wrong-parity frame sets `LSR[2]` and `IRQSTAT[2]`, **and still delivers the byte** | pass |
| R-7 | `t_uart_frame_err` | a low stop bit sets `LSR[3]` and the same event | pass |
| R-7 | `t_uart_err_noleak` | neither flag leaks into the following byte | pass |
| — | `t_uart_b2b` | 16 frames with **no inter-frame gap** — the timing patch 0001 changes ([N-8.2]) | pass |
| R-8 | `t_uart_reset` | `tx` high out of reset | pass |
| R-9 | `t_chip_uart` | three instances, three windows, three CLIC IDs, no crosstalk | new |
| — | `t_uart_rxidle` | `rx` synchroniser resets high, so no garbage byte at power-on ([N-9.3]) | pass |

**The test that earns its keep is `t_uart_loopback`.** As D-23 records, a
register-level test suite passes happily with the data path connected to the
wrong pin. Only bytes compared end to end catch that.

---

## 12 Design decisions

| # | Decision | Alternative rejected |
|---|---|---|
| 1 | One module, three instances, `BLOCK_NUM` parameterised | three copies — three places for a fix to be missed |
| 2 | Interrupts derived in the wrapper from `LSR` | using upstream's `event_o` — it is wired to the wrong bit (ERR-U1) |
| 3 | `LSR` polled in idle cycles for FIFO state | patching upstream to export `rx_elements`/`tx_elements` — D-22 prefers an empty `patches/` |
| 4 | Hardware gates DMA while `DLAB` is set | documenting the rule and trusting the driver |
| 5 | `ADDR_SHIFT = 2` in the shim | re-implementing the register file at word offsets |

---

## 13 Not implemented

**[N-13.1]** `MCR` (0x10) and `MSR` (0x18) are **not implemented at all**:
upstream's write case list is `THR`/`IER`/`LCR`/`FCR` and its read mux covers
`RBR`/`LSR`/`LCR`/`IER`/`IIR`; everything else falls to `default`. They decode
without `PSLVERR` and read 0. No modem-control pin exists on GARUDA anyway
(PHYS §3.1), so firmware must not use hardware flow control. `t_uart_wordmap`
asserts this, so a re-vendor that implements them fails the test rather than
changing behaviour quietly.

**[N-13.2]** `SCR` (0x1C), the 16550 scratch register, is likewise not
implemented — writes are dropped and reads return 0. Do not use it as a
scratchpad; it is not one.

**[N-13.2a]** Upstream's `FCR` trigger-level field is writable and feeds
`uart_interrupt`, which GARUDA does not use ([N-7.5]). It therefore has no
observable effect. It is left writable rather than blocked so that the vendored
register file is untouched.

**[N-13.3]** No break generation or detection, no auto-baud, no RS-485
direction pin, no 9-bit address mode.

---

## 14 Open items

- **OPEN-U1** — *closed 2026-09-23.* Measured at **at least ±6%** ([N-8.1]),
  the full range the sweep covers; the receiver did not fail at either end. No
  board-level constraint is needed.
- **OPEN-U3** — *closed 2026-09-23.* R-7 is met by vendored patch 0001 (D-24).
  The recommendation at the time was to accept the gap and rely on protocol
  checksums; that was overruled by the owner, correctly — a checksum tells
  firmware to drop a packet, it does not say why, and error counters are how a
  flaky connector is told from EMI in the field.

- **OPEN-U2** — no RX FIFO overrun status. Upstream's `LSR[1]` (overrun) is
  never written by the register file, so a byte lost to a full FIFO is silent.
  Options: derive an overrun event in the wrapper from a write to a full FIFO,
  or accept it and rely on the DMA keeping the FIFO drained. Decide before the
  telemetry link is brought up at 921600.

---

## 15 Errata

**ERR-U1 — upstream's receiver-data-available interrupt is wired to the
transmit flag.** `apb_uart.sv` connects `.RDA_i(regs_n[LSR][5])` (`THRE`) where
`regs_n[LSR][0]` (`DR`) belongs. Compounded by `trigger_level_reached` using
`==` instead of `>=` and `CTI_i` being tied to zero, the upstream interrupt
path cannot reliably signal received data at all.

**Not fixed in the vendored file** (D-22: upstream is never edited). GARUDA
does not use `uart_interrupt`; the wrapper derives all three events from `LSR`
([N-7.5]). Firmware must leave `IER` at 0. Recorded in `Docs/BUGS.md`.

If this block is ever re-vendored from a newer upstream, **re-check this**: if
upstream has fixed it, the wrapper still works unchanged, because it does not
depend on the unit either way.

---

**ERR-U2 — parity errors could never be reported, for two independent reasons.**
**FIXED by vendored patch 0001** (D-24). Recorded here because a re-vendor must
re-apply or re-derive it.

1. `apb_uart.sv` instantiated the receiver with `.err_clr_i(1'b1)`. In
   `uart_rx` the error flop is `if (err_clr_i) err_o <= 0; else if (set_error)
   err_o <= 1;` — with the clear tied high the `set_error` branch was
   unreachable and `err_o` a constant 0.
2. The ordering was wrong regardless. `uart_rx` pushed the byte to the RX FIFO
   in `SAVE_DATA` with `data_i = {parity_error, rx_data}`, and only *then*
   advanced to `PARITY` to check the bit, so the flag stored beside a byte
   belonged to the previous frame.

`LSR[2]` is driven from that FIFO bit, so it never set. Framing errors were not
detected at all — the stop bit was never examined — and `apb_uart.sv` never
drove `LSR[3]`.

**Why this one was patched and ERR-U1 was not.** ERR-U1 is a miswired input
whose effect the wrapper can simply decline to use. ERR-U2 cannot be worked
around from outside: the wrapper sees the APB side and the raw `rx` pin, and
nothing else, so detecting a parity error there would mean reimplementing the
receiver. That is the unavoidable case D-22 kept `patches/` for, and D-24
records the ruling.

**What the patch changes, and the risk it carries.** The push moves into the
`STOP_BIT` `bit_done` cycle — after both checks, but *not* into a later state,
because `s_rx_fall` is true for exactly one clock and an extra state makes the
receiver miss the start bit of a frame that follows with no gap. The error
outputs are combinational (flop OR set-strobe) so they are valid in the cycle
they are captured. `SAVE_DATA` survives for the FIFO-full case only.

The consequence worth stating plainly: **we are the only people who have run
this receiver.** `t_uart_b2b` — sixteen frames with no inter-frame gap — exists
for that reason and for no other. It is the test that would fail if the timing
argument above is wrong.

---

**ERR-U3 — an inferred latch, 24 of them.** `apb_uart.sv` gave `fifo_tx_data`
no default in the register-write `always_comb`, assigning it only inside the
`THR` branch, so synthesis inferred an 8-bit latch per instance. **FIXED by the
same patch 0001.** Functionally harmless — the TX FIFO samples the bus only
when `fifo_tx_valid` is high, which is exactly when that branch assigns it —
but latches break scan insertion and must be constrained by hand at STA.

Found by `make synth`, which reported 25 latches against a budget of 1. **No
simulation would ever have found it**, which is the argument for running
synthesis as each block lands rather than once at the end.

*(During bring-up `t_uart_b2b` did fail, 1 frame of 16. The cause was a
testbench bug — both `fork` branches incremented the same module-level loop
index — not the patch. Worth recording: the first instinct was to blame the
new RTL, and that instinct would have led to "fixing" working logic.)*
