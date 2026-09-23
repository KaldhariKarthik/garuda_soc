# GARUDA I²C Master — Design Specification

## 0.1 Identity

| Field | Value |
|---|---|
| Document ID | GARUDA-I2C-SPEC-001 |
| Revision | 1.0 |
| Date | 2026-09-23 |
| Status | Released for implementation |
| Block | 15 (`i2c`) |
| Owner | Team AeroSoC |
| Supersedes | — (first revision; the block was `sourced_ip` with no document) |

## 0.2 Revision history

| Rev | Change | Driver |
|---|---|---|
| 1.0 | First specification. The bit and byte controllers are OpenCores RTL; **the register layer is GARUDA's own**, because the usual front end has no licence (D-22). | D-21, D-22, D-23 |

## 0.3 Normative references

1. `GARUDA-SYS-001` Rev 4.0 — System Definition.
2. `GARUDA-AHB2APB-SPEC-001` Rev 2.0 — the APB contract.
3. `GARUDA-DMA-SPEC-001` Rev 3.0 §7.3 — request/acknowledge.
4. `GARUDA-CLIC-SPEC-001` Rev 2.0 §7.2 — level interrupts.
5. `Docs/DECISIONS.md` D-16, D-21, D-22, D-23, D-24.
6. NXP UM10204 — I²C-bus specification, Rev 6.

---

## 1 Purpose and scope

### 1.1 In scope

One I²C **master** on APB window 2 (`0x4000_2000`), CLIC ID 16, DMA channel 1,
pins `i2c_scl` / `i2c_sda`. Standard mode (100 kHz) and fast mode (400 kHz),
7-bit addressing, single master with arbitration-loss detection.

### 1.2 Out of scope

- **Slave mode.** The vendored controllers are master-only.
- 10-bit addressing, general call, SMBus PEC, high-speed mode.
- Multi-master bus scheduling beyond detecting that we lost.

### 1.3 Where the RTL comes from

`rtl/third_party/opencores/i2c` (Richard Herveille, notice-preserving licence),
unmodified: `i2c_master_bit_ctrl.sv`, `i2c_master_byte_ctrl.sv`,
`i2c_master_defines.sv`.

**The register layer is not vendored.** PULP's `apb_i2c.sv`, which normally sits
on these controllers, carries no licence header and its repository has no
LICENSE file, so it is deliberately not taken (D-22). `rtl/i2c/garuda_i2c_top.v`
implements GARUDA's own register file over the byte controller's
`start/stop/read/write/din/dout/cmd_ack` interface. This block is therefore the
one peripheral where the register map is ours to design rather than inherit —
so it is the clean one, with no DLAB and no byte addressing.

---

## 2 Requirements

| ID | Requirement | Source | Status |
|---|---|---|---|
| R-1 | Master write and read transfers to a 7-bit addressed slave, with repeated start. | SYS §6.4 | met |
| R-2 | SCL **at or below** 100 kHz and 400 kHz from `pclk` = 125 MHz. | SYS §6.4, UM10204 §3.1.9 | met |
| R-3 | Word-only APB, 32-bit registers at word-aligned offsets. | AHB2APB [N-7.12] | met |
| R-4 | Never stall the APB bus. | AHB2APB [N-7.15] | met |
| R-5 | One held, level interrupt to CLIC ID 16. | CLIC §7.2, D-17 | met |
| R-6 | DMA request/acknowledge on channel 1, one beat per assertion. | DMA §7.3, D-21 | met (PIO-assisted, [N-7.7]) |
| R-7 | Report a NACK, and arbitration loss, without hanging. | UM10204 §3.1.6 | met |
| R-8 | **A wedged slave must not hang the SoC**: a transfer that stalls is abandoned and the bus released. | Board safety | met ([N-7.5]) |
| R-9 | Open-drain discipline: the block never drives either line high. | UM10204 §3.1.1 | met ([N-9.2]) |
| R-10 | Pins released (inputs) from reset until firmware acts. | Board safety | met |

---

## 3 Block diagram

```
   APB window 2 (pclk 125 MHz)
        │
        ▼
  ┌──────────────────── garuda_i2c_top ─────────────────────┐
  │                                                         │
  │  garuda_apb_shim ──▶ GARUDA register file               │
  │   0x00-0x1C  our own       PRESCALE CTRL TXDATA RXDATA  │
  │   0xFE0-0xFEC  tail        CMD STATUS TIMEOUT           │
  │                                 │                       │
  │              start/stop/rd/wr/din ▼  cmd_ack/dout/al    │
  │            i2c_master_byte_ctrl (vendored)              │
  │                    └─ i2c_master_bit_ctrl (vendored)    │
  │                                 │                       │
  │  bus-timeout counter ──▶ abort  │  scl_oen / sda_oen    │
  │  scl/sda ──▶ 2-flop sync        ▼                       │
  └──────────────── scl_i/o/oe, sda_i/o/oe ─────────────────┘
```

---

## 4 Sub-block inventory

| Name | Type | RTL file | Role |
|---|---|---|---|
| `garuda_apb_shim` | seq (pclk) | `rtl/common/garuda_apb_shim.v` | decode, PSLVERR, sticky IRQ, DMA, pad sync |
| `garuda_i2c_top` | seq (pclk) | `rtl/i2c/garuda_i2c_top.v` | **GARUDA's register file**, timeout, abort |
| `i2c_master_byte_ctrl` | seq | `rtl/third_party/opencores/i2c/src/` | byte sequencer, shift register (vendored) |
| `i2c_master_bit_ctrl` | seq | same | SCL generation, start/stop/bit timing, arbitration (vendored) |

---

## 5 Interfaces

| Port | Dir | Width | Domain | Reset | Description |
|---|---|---|---|---|---|
| `pclk_i`, `preset_n_i` | in | 1 | pclk | — | 125 MHz |
| APB slave | — | — | pclk | — | window 2, `0x4000_2000` |
| `irq_o` | out | 1 | pclk | 0 | CLIC ID 16, level |
| `dma_req_o` / `dma_ack_i` | — | 1 | pclk | 0 | DMA channel 1 |
| `i2c_scl_i` / `i2c_sda_i` | in | 1 | async | — | synchronised in the wrapper |
| `i2c_scl_o` / `i2c_sda_o` | out | 1 | pclk | **0** | tied low — see [N-9.2] |
| `i2c_scl_oe` / `i2c_sda_oe` | out | 1 | pclk | **0** | 1 = pull the line low |

---

## 6 Register map — APB window 2 (`0x4000_2000`)

Machine-readable source: `spec/regs/i2c.yaml`.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | `PRESCALE` | RW | 0 | `[15:0]` SCL divider ([N-6.1]) |
| 0x04 | `CTRL` | RW | 0 | `[0]` EN core enable, `[1]` ABORT (self-clearing, [N-7.5]) |
| 0x08 | `TXDATA` | RW | 0 | `[7:0]` byte to transmit; for an address byte, `[0]` is R/W̅ |
| 0x0C | `RXDATA` | RO | 0 | `[7:0]` byte received ([N-6.4]) |
| 0x10 | `CMD` | W | 0 | `[0]` STA, `[1]` STO, `[2]` RD, `[3]` WR, `[4]` NACK ([N-6.2]) |
| 0x14 | `STATUS` | RO | 0 | `[0]` TIP, `[1]` BUSY, `[2]` AL, `[3]` RXNACK, `[4]` TIMEOUT, `[5]` RXVALID ([N-6.3]) |
| 0x18 | `TIMEOUT` | RW | 0 | `[15:0]` `pclk` ticks before a stalled transfer is abandoned; 0 disables ([N-7.5]) |
| 0xFE0 | `IRQSTAT` | W1C | 0 | `[0]` transfer complete, `[1]` arbitration lost, `[2]` bus timeout, `[3]` NACK |
| 0xFE4 | `IRQEN` | RW | 0 | mask; `irq_o = \|(IRQSTAT & IRQEN)` |
| 0xFE8 | `DMACTL` | RW | 0 | `[0]` request on RX byte, `[1]` request on TX ready |
| 0xFEC | `ID` | RO | — | `{16'h6A5D, 8'd15, rev}` |

### 6.1 `PRESCALE` (0x00)

**[N-6.1]** The nominal divider is five prescaler ticks per SCL bit:

```
SCL(ideal) = pclk / (5 x (PRESCALE + 1))
```

**The real bus is slower than that, and the difference is not noise.** The
vendored bit controller runs a spike filter whose reload is `clk_cnt >> 2`, and
that filter sits in the path that decides when SCL may move, so it adds roughly
a quarter of a prescaler period to every bit plus a small fixed cost. Measured
in `tb_i2c`:

| PRESCALE | ideal `5(P+1)` | **measured** | SCL |
|---|---|---|---|
| 249 | 1250 pclk | **1323 pclk** | **94.5 kHz** |
| 61 | 310 pclk | **335 pclk** | **373.1 kHz** |

which both fit

```
period(pclk) ~= 5.25 x (PRESCALE + 1) + 10          (measured, +/-1 pclk)
```

**This does not need correcting, and that is the point.** I²C bus speeds are
*maxima*, not targets (UM10204 §3.1.9): a 94.5 kHz bus is a legal standard-mode
bus and a 373 kHz bus is a legal fast-mode bus. Computing `PRESCALE` from the
ideal formula therefore errs in the **safe** direction — always a slower bus,
never one that overruns the mode's limit. Recommended values at `pclk` = 125 MHz:

| Mode | `PRESCALE` | measured SCL |
|---|---|---|
| Standard (≤100 kHz) | 249 | 94.5 kHz |
| Fast (≤400 kHz) | 61 | 373.1 kHz |

`PRESCALE` must only be changed while `CTRL.EN` is 0 or the bus is idle.

### 6.2 `CMD` (0x10)

**[N-6.2]** Write-only and self-clearing: the bits are handed to the byte
controller for one transfer and drop when it acknowledges. The usual
combinations:

| Want | `CMD` |
|---|---|
| start + send address/byte | `STA \| WR` = `0x09` |
| send a further byte | `WR` = `0x08` |
| read a byte, ACK it (more to come) | `RD` = `0x04` |
| read the **last** byte, NACK it | `RD \| NACK` = `0x14` |
| stop | `STO` = `0x02` |
| last byte then stop | `WR \| STO` = `0x0A` |

**[N-6.2a]** `NACK` (`[4]`) is the level this master drives on the acknowledge
bit **after a read**. I²C requires the master to NACK the final byte it reads,
so that the slave releases SDA; forgetting it is the classic reason a bus then
refuses to produce a STOP.

**[N-6.2b]** Writing `CMD` while `STATUS.TIP` is set is ignored and raises
`PSLVERR`. One command at a time — the byte controller has no queue.

### 6.3 `STATUS` (0x14)

**[N-6.3]**

| Bit | Name | Meaning |
|---|---|---|
| 0 | `TIP` | transfer in progress: a `CMD` is outstanding |
| 1 | `BUSY` | the bus has seen a START and not yet a STOP |
| 2 | `AL` | arbitration lost — **sticky**, cleared by writing `IRQSTAT[1]` |
| 3 | `RXNACK` | the last byte written was **not** acknowledged by the slave |
| 4 | `TIMEOUT` | a transfer was abandoned — **sticky**, cleared by `IRQSTAT[2]` |
| 5 | `RXVALID` | `RXDATA` holds a byte that has not been read |

### 6.4 `RXDATA` (0x0C)

**[N-6.4]** Reading it clears `RXVALID` and drops the DMA request. It does not
start a transfer — the next byte needs another `RD` command.

---

## 7 Functional description

### 7.1 A register write to a slave

**[N-7.1]** Write value `V` to register `R` of the device at 7-bit address `A`:

```
PRESCALE = 312                    once
CTRL     = 1                      EN
TXDATA   = (A << 1) | 0           address, write
CMD      = STA | WR               start, send address
poll STATUS until TIP == 0
if STATUS.RXNACK: no such device  -> abort, STO
TXDATA   = R      ; CMD = WR      ; poll TIP
TXDATA   = V      ; CMD = WR | STO; poll TIP
```

### 7.2 A register read from a slave

**[N-7.2]** The repeated start is what makes this atomic on a shared bus:

```
TXDATA = (A << 1) | 0 ; CMD = STA | WR      ; poll TIP    address, write
TXDATA = R            ; CMD = WR            ; poll TIP    register number
TXDATA = (A << 1) | 1 ; CMD = STA | WR      ; poll TIP    REPEATED start, read
                        CMD = RD | NACK | STO; poll TIP   one byte, NACK, stop
value = RXDATA
```

### 7.3 Interrupts

**[N-7.3]** Four sources into the standard sticky tail (D-21):

| `IRQSTAT` | Set when |
|---|---|
| 0 | a `CMD` completes (`cmd_ack` from the byte controller) |
| 1 | arbitration lost (`i2c_al`) |
| 2 | the bus timeout expired and the transfer was abandoned |
| 3 | a written byte came back NACKed |

### 7.4 Arbitration loss

**[N-7.4]** The vendored bit controller detects that SDA read back low while
this master was releasing it, asserts `i2c_al`, and the byte controller returns
to idle. GARUDA latches it sticky in `STATUS.AL` and raises `IRQSTAT[1]`.
Firmware must treat the whole transfer as failed and retry from the START; the
byte in `RXDATA` is meaningless.

### 7.5 The bus timeout — why this block has one

**[N-7.5]** I²C lets a slave hold SCL low to stall the master ("clock
stretching"), and the vendored bit controller honours it by freezing its divider
(`slave_wait`). There is **no upper bound**. A slave that is confused, held in
reset, or simply absent while something else pulls SCL low therefore stalls the
transfer for ever: `TIP` never clears, and firmware polling it never returns.

On a flight controller that is a hang, not an error.

`TIMEOUT[15:0]` counts `pclk` ticks while `TIP` is set. On expiry the block:

1. drops the vendored core's `ena` for four `pclk`, which returns the bit and
   byte controllers to idle and **releases both pins** (`_oen` high);
2. sets `STATUS.TIMEOUT` sticky and raises `IRQSTAT[2]`;
3. clears `TIP`, so the polling firmware gets control back.

Writing `CTRL.ABORT` does the same thing on demand. At 125 MHz the 16-bit
counter spans 524 µs, which is longer than one byte at 100 kHz (90 µs) and
short enough to be invisible in a control loop. **0 disables the timeout**, and
that is the reset value — it must be programmed deliberately, because a value
shorter than one byte time would abort every transfer.

**[N-7.5a]** A timeout releases the pins but does **not** send a STOP — there
is no way to send one on a bus whose clock is held low by somebody else. The
bus recovers when the slave lets go. Firmware that wants to force the issue
must clock the bus manually, which GARUDA cannot do without GPIO on these pins;
recorded as OPEN-I1.

### 7.6 Open-drain

**[N-9.2]** See §9.

### 7.7 DMA

**[N-7.7]** `DMACTL[0]` requests a beat while `STATUS.RXVALID` is set;
`DMACTL[1]` requests while the block can accept a byte (`EN` and not `TIP`).
Beats are word-sized with the byte in `[7:0]` (D-21).

**This moves the data, not the commands.** Each byte still needs its own `CMD`
write from firmware, so a DMA-driven transfer is one DMA beat plus one CPU
write per byte — useful for a long burst from a magnetometer, not a
fire-and-forget descriptor. A command sequencer that would make it fully
autonomous is **deliberately staged** (OPEN-I2): it needs a length counter and
an auto-repeat mode, and this block is on the critical path for the IMU bring-up
now, not later.

---

## 8 Timing

### 8.1 SCL

```
         ┌──┐  ┌──┐  ┌──┐        SCL = pclk / (4 x (PRESCALE+1))
SCL   ───┘  └──┘  └──┘  └──      100 kHz -> PRESCALE 312
      ──╥─────╥─────╥─────       SDA changes while SCL is low
SDA     ╨─────╨─────╨──────      and is stable while SCL is high
```

### 8.2 Clock stretching and the timeout

```
                    slave holds SCL low
SCL  ──┐        ┌───────────────────────────────  ...
       └────────┘                    ▲
TIP  ──────────────────────────────────────────┐
                                     │         └─ cleared by the timeout
                          TIMEOUT expires ──────▶ pins released, IRQSTAT[2]
```

---

## 9 Clock, reset and power

**[N-9.1]** Single domain: `pclk`, 125 MHz, reset `preset_n`. No CDC inside the
block.

**[N-9.2] Open drain, and the one rule that matters.** The vendored bit
controller hardwires `scl_o = 1'b0` and `sda_o = 1'b0` and expresses everything
through `scl_oen` / `sda_oen`. GARUDA inverts those into the pad's active-high
output enable and **keeps `_o` tied to 0**:

```verilog
assign i2c_scl_o  = 1'b0;        assign i2c_scl_oe = ~scl_oen;
assign i2c_sda_o  = 1'b0;        assign i2c_sda_oe = ~sda_oen;
```

So the block can only ever pull a line **low** or release it. That is R-9, and
it is not a style preference: an I²C line driven high by one master while
another pulls it low is a short between a driver pair, on a bus that is by
definition shared. `t_i2c_never_drives_high` watches both `_o` pins for the
whole simulation.

**[N-9.3]** `scl` and `sda` inputs are asynchronous and pass through the shim's
two-flop synchronisers. The vendored core adds its own spike filter on top
(`filter_cnt`, 16× SCL).

**[N-9.4]** Out of reset both `_oe` are 0 — lines released, pulled up by the
board. R-10.

---

## 10 Assertions

```systemverilog
a_never_high: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
                (i2c_scl_o == 1'b0) && (i2c_sda_o == 1'b0));
a_pready:     assert property (@(posedge pclk_i) disable iff (!preset_n_i)
                psel_i |-> pready_o);
a_dma_drop:   assert property (@(posedge pclk_i) disable iff (!preset_n_i)
                dma_ack_i |=> !dma_req_o);
a_tip_bounded: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
                $rose(tip) && (timeout_q != 0) |-> ##[1:$] !tip);
```

---

## 11 Verification plan

`make test_i2c` — `tb/i2c/tb_i2c.sv` against `tb/models/i2c_slave_model.sv`.

| Req | Test | Oracle | Status |
|---|---|---|---|
| R-1 | `t_i2c_write` | the slave model records address, register and data | new |
| R-1 | `t_i2c_read` | the DUT returns what the model was preloaded with | new |
| R-1 | `t_i2c_repeated_start` | a register read with repeated start, no STOP between | new |
| R-1 | `t_i2c_burst` | 8-byte read, ACK on all but the last | new |
| R-2 | `t_i2c_scl_rate` | **measured** SCL at PRESCALE 249 and 61, against the mode limit | pass |
| R-3 | `t_i2c_regs` | every register reads back; PSLVERR on unmapped and on `CMD` while TIP | new |
| R-4 | `t_i2c_pready` | PREADY high in every cycle of every access | new |
| R-5 | `t_i2c_irq` | held ≥50 `pclk`, drops only on W1C | new |
| R-6 | `t_i2c_dma` | `dma_req_checker`; request drops after ack | new |
| R-7 | `t_i2c_nack` | an unaddressed slave leaves `RXNACK` set and `IRQSTAT[3]` | new |
| R-8 | `t_i2c_stretch` | a slave that stretches **past** the timeout is abandoned, pins released, `IRQSTAT[2]` | new |
| R-8 | `t_i2c_stretch_ok` | a slave that stretches **within** the timeout completes normally | new |
| R-9 | `t_i2c_never_drives_high` | `_o` pins are 0 for the entire run | new |
| R-10 | `t_i2c_reset` | both `_oe` low out of reset | new |

---

## 12 Design decisions

| # | Decision | Alternative rejected |
|---|---|---|
| 1 | Our own register layer over the vendored controllers | PULP's `apb_i2c.sv` — no licence header, no repository LICENSE (D-22) |
| 2 | A bus timeout with automatic abort | trusting slaves not to stretch for ever — a hang, not an error |
| 3 | `_o` tied to 0, `_oe` from `~_oen` | passing `_oen` to the pad as-is and relying on the pad's polarity |
| 4 | DMA moves data, firmware issues commands | a full sequencer now — staged as OPEN-I2 |
| 5 | `TIMEOUT` resets to 0 (disabled) | a default that could abort valid transfers on a slow bus |

---

## 13 Not implemented

**[N-13.1]** Slave mode, 10-bit addressing, general call, SMBus PEC, high-speed
mode. The vendored controllers support none of them.

**[N-13.2]** No bus-recovery clocking ([N-7.5a]).

---

## 14 Open items

- **OPEN-I1** — bus recovery. After a timeout GARUDA releases the pins, but
  cannot clock SCL manually to free a slave that is mid-byte, because these pins
  are not muxed to GPIO. Decide at board level whether that matters; the usual
  answer is a power cycle of the sensor rail.
- **OPEN-I2** — the DMA command sequencer ([N-7.7]). Deliberately staged.
  Needs a length counter and an auto-repeat mode in the register layer.

---

## 15 Errata

None yet in the vendored controllers. Note for a future re-vendor: they use
`<= #1` throughout, a simulation-only delay that synthesis ignores. It is
harmless here and is **not** patched.
