# GARUDA SPI Master — Design Specification

## 0.1 Identity

| Field | Value |
|---|---|
| Document ID | GARUDA-SPIM-SPEC-001 |
| Revision | 1.0 |
| Date | 2026-09-22 |
| Status | Released for implementation |
| Block | 13 (`spi_master`) |
| Owner | Team AeroSoC |
| Supersedes | — (first revision; the block was `sourced_ip` with no document) |

## 0.2 Revision history

| Rev | Change | Driver |
|---|---|---|
| 1.0 | First specification. The block is an adaptation of `pulp-platform/apb_spi_master` behind a GARUDA wrapper, not vendor IP. | D-22 |

## 0.3 Normative references

1. `GARUDA-SYS-001` Rev 4.0 — System Definition. All cross-block values come from it.
2. `GARUDA-AHB2APB-SPEC-001` Rev 2.0 — the APB contract this block must satisfy.
3. `GARUDA-MEM-SPEC-001` Rev 2.0 §8 — the boot sequence this block must support.
4. `GARUDA-DMA-SPEC-001` Rev 3.0 §7.3 — the request/acknowledge handshake.
5. `Docs/DECISIONS.md` D-16, D-21, D-22.

---

## 1 Purpose and scope

### 1.1 In scope

One SPI master on APB window 1, serving two devices on one bus: the **boot
flash** (`cs_flash_n`) and the **IMU** (`cs_imu_n`). It is the only block the
Boot ROM needs beyond the core, the bus and the memories, so it is on the
critical path of every board bring-up.

### 1.2 Out of scope

- The flash image format and the CRC — `GARUDA-MEM-SPEC-001` §8.
- The IMU driver and its sample rate — firmware.
- Quad/dual SPI. The upstream IP supports them; this block does not use them
  ([N-7.6]).

### 1.3 Where the RTL comes from

`rtl/third_party/pulp/apb_spi_master` + `rtl/third_party/pulp/axi_spi_master`
(Solderpad 0.51), unmodified, behind `rtl/spi_master/garuda_spim_top.v`. The
upstream register model — a command/address/dummy/data length engine — *is* a
flash read, which is why the boot path fits the 4 KiB ROM budget.

---

## 2 Requirements

| ID | Requirement | Source |
|---|---|---|
| R-1 | Read the boot flash with a single-bit SPI mode-0 transfer: command `0x03`, 24-bit address, streamed data. | MEM §8.2 |
| R-2 | Hold one chip select asserted across command, address and data phases of a transfer. | MEM §8.3 |
| R-3 | Two independent chip selects: `cs_flash_n`, `cs_imu_n`. | PHYS [N-3.5], ADR-0008 |
| R-4 | SCLK ≤ 20 MHz from `pclk` = 125 MHz. | MEM §8.2 step 3 |
| R-5 | Never stall the APB bus: the register interface is polled. | AHB2APB [N-7.15] |
| R-6 | One held, level interrupt to CLIC ID 15. | CLIC §7.2, D-17 |
| R-7 | DMA request/acknowledge on channel 0, one beat per assertion. | DMA §7.3, D-21 |
| R-8 | `cs_*_n` high and `sclk` low from reset until firmware acts. | Board safety |

---

## 3 Block diagram

```
   APB window 1 (pclk 125 MHz)
        │
        ▼
  ┌──────────────────────── garuda_spim_top ────────────────────────┐
  │                                                                 │
  │  garuda_apb_shim ──── IP APB ────▶ apb_spi_master (vendored)    │
  │   0x000-0x0FF  pass-through          ├─ spi_master_apb_if       │
  │   0xFE0-0xFEC  IRQSTAT/IRQEN/        ├─ spi_master_controller   │
  │                DMACTL/ID             ├─ spi_master_clkgen       │
  │                                      ├─ spi_master_tx / _rx     │
  │  events ──▶ sticky IRQSTAT           └─ spi_master_fifo x2      │
  │  FIFO counts ──▶ dma_req (hold-off)         │                   │
  │  miso ──▶ 2-flop sync                       ▼                   │
  └──────────────────────────────────────── sclk, mosi, miso, csn ──┘
                                                 │
                                    cs_flash_n ──┴── cs_imu_n
```

---

## 4 Sub-block inventory

| Name | Type | RTL file | Role |
|---|---|---|---|
| `garuda_apb_shim` | seq (pclk) | `rtl/common/garuda_apb_shim.v` | window decode, PSLVERR, sticky IRQ, DMA request, pad sync |
| `apb_spi_master` | seq (pclk) | `rtl/third_party/pulp/apb_spi_master/src/` | register file + SPI engine (vendored) |
| `spi_master_controller` | seq | `rtl/third_party/pulp/axi_spi_master/src/` | command/address/data sequencer, chip select |
| `spi_master_clkgen` | seq | same | SCLK generation from `CLKDIV` |
| `garuda_spim_top` | wrapper | `rtl/spi_master/garuda_spim_top.v` | CS mapping, mode forcing, safe reset state |

---

## 5 Interfaces

| Port | Dir | Width | Domain | Reset | Description |
|---|---|---|---|---|---|
| `pclk_i`, `preset_n_i` | in | 1 | pclk | — | APB domain, 125 MHz |
| APB slave | — | — | pclk | — | window 1, `0x4000_1000` |
| `irq_o` | out | 1 | pclk | 0 | to CLIC ID 15, level |
| `dma_req_o` | out | 1 | pclk | 0 | DMA channel 0, level |
| `dma_ack_i` | in | 1 | pclk | — | 2 hclk = 1 pclk (D-16) |
| `spim_sclk_o` | out | 1 | pclk | **0** | SCLK |
| `spim_mosi_o` | out | 1 | pclk | 0 | |
| `spim_miso_i` | in | 1 | async | — | synchronised in the wrapper ([N-9.2]) |
| `spim_cs_flash_n_o` | out | 1 | pclk | **1** | boot flash |
| `spim_cs_imu_n_o` | out | 1 | pclk | **1** | IMU |

---

## 6 Register map — APB window 1 (`0x4000_1000`)

Machine-readable source: `spec/regs/spim.yaml`. Offsets `0x00`–`0x2C` are the
vendored register file; `0xFE0`–`0xFEC` are the GARUDA tail common to every
peripheral (D-21).

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | `STATUS` | RW | 0 | Write starts a transfer; read returns engine state ([N-6.1]) |
| 0x04 | `CLKDIV` | RW | 0 | SCLK divider ([N-6.2]) |
| 0x08 | `SPICMD` | RW | 0 | Command word, MSB-first |
| 0x0C | `SPIADR` | RW | 0 | Address word, MSB-first |
| 0x10 | `SPILEN` | RW | 0 | `[5:0]` cmd bits, `[13:8]` addr bits, `[31:16]` data bits |
| 0x14 | `SPIDUM` | RW | 0 | `[15:0]` dummy cycles before read, `[31:16]` before write |
| 0x18 | `TXFIFO` | W | — | Transmit data (32-bit) |
| 0x20 | `RXFIFO` | R | — | Receive data (32-bit) |
| 0x24 | `INTCFG` | RW | 0 | Upstream FIFO threshold configuration |
| 0x28 | `INTSTA` | R | 0 | Upstream event status |
| 0xFE0 | `IRQSTAT` | W1C | 0 | `[0]` transfer complete, `[1]` RX threshold, `[2]` TX threshold |
| 0xFE4 | `IRQEN` | RW | 0 | mask; `irq_o = \|(IRQSTAT & IRQEN)` |
| 0xFE8 | `DMACTL` | RW | 0 | `[0]` request on RX data, `[1]` request on TX space |
| 0xFEC | `ID` | RO | — | `{16'h6A5D, 8'd13, rev}` |

### 6.1 `STATUS` (0x00)

**Write** — `[0]` start read, `[1]` start write, `[4]` soft reset,
`[11:8]` chip-select register.

**[N-6.1]** `[8]` selects `cs_flash_n` and `[9]` selects `cs_imu_n`; `[11:10]`
are unused and must be written 0. The upstream IP has four chip selects; the
wrapper maps the low two to pins and ties the rest off.

**Read** — `[0]` engine idle, `[20:16]` RX FIFO occupancy, `[28:24]` TX FIFO
occupancy.

**[N-6.1a]** **Poll `[20:16]`, not `[0]`, to wait for read data.** `[0]` means
"the engine is in its IDLE state", which is also true in the cycles between the
`STATUS` write and the engine acting on it: a poll loop tight enough to read
`STATUS` before the engine has started sees idle, reads an empty `RXFIFO` and
gets zero. Waiting for a word to *arrive* has no such race. For a transfer with
no read data (a write, or a bare command), wait on `IRQSTAT[0]` instead —
clear it, start the transfer, poll it — which is sticky and cannot be missed.

### 6.2 `CLKDIV` (0x04)

**[N-6.2]** `SCLK = pclk / (2 × (CLKDIV + 1))`. At `pclk` = 125 MHz, R-4 (≤20
MHz) requires `CLKDIV ≥ 3`, which gives 15.6 MHz. **`CLKDIV = 3` is the boot
value.** A `DIVSEL` change (CLKRST §6.2) changes `pclk` and therefore SCLK;
firmware that lowers the chip frequency must re-program this register, and the
Boot ROM runs at the reset `DIVSEL`, so the boot value is always valid.

### 6.3 Chip-select discipline

**[N-6.3]** The engine asserts the selected chip select for the whole
transfer — command, address, dummy and data — and releases it at the end. This
is R-2, and it is why a flash read works without software CS control. Firmware
must not change `[11:8]` while `STATUS[0]` reads 0.

---

## 7 Functional description

### 7.1 A flash read, register by register

**[N-7.1]** The sequence the Boot ROM performs (`sw/bootrom/spim.c`), once per
32-bit word:

```
CLKDIV = 3                              once, at spim_init()
SPICMD = 0x03 << 24                     command 0x03 in the top 8 bits
SPIADR = byte_addr << 8                 24-bit address in the top 24 bits
SPILEN = (32 << 16) | (24 << 8) | 8     32 data bits, 24 addr bits, 8 cmd bits
STATUS = (1 << 8) | (1 << 0)            select cs_flash_n, start a read
poll STATUS until [20:16] != 0          a word has arrived ([N-6.1a])
word = RXFIFO
```

**[N-7.2]** `SPICMD` and `SPIADR` are shifted **MSB-first from bit 31**, which
is why both are left-aligned. Getting this wrong is the classic flash bring-up
failure: the command goes out as zeros and the flash returns all ones, which
looks exactly like an erased device.

**[N-7.3]** `RXFIFO` returns the four bytes in the order they arrived, first
byte in `[31:24]`. `spim_read_word()` therefore byte-swaps into the
little-endian word the image header expects, and `tools/mkbootimg.py` writes the
image in that same order. The two must agree; the test that proves they do is
`make test_chip_flash`.

**[N-7.3a] Boot time.** One word per command costs 64 SCLK — 8 command, 24
address, 32 data — so **half the bus time is per-word overhead**. Measured:
4.1 µs per word at `CLKDIV = 3`, and `make test_chip_flash` boots a 700-byte
image in 1.12 ms. Extrapolated to a full 64 KiB ISRAM image that is **~67 ms**,
which is a long time to hold a flight controller in reset.

The fix, when boot time becomes a requirement, is a burst read: the engine
holds the chip select for the whole transfer, so one command with
`SPILEN.data = 32 × n` streams *n* words into the RX FIFO back to back and
drops the overhead to zero, taking the same image to ~34 ms. It is not done
today because `spim_read_word()` is the interface `boot.c` is written against
and the RX FIFO is only `BUFFER_DEPTH` (10) words deep, so a burst needs the
ROM to drain it while the transfer runs. Left as a deliberate, measured
trade: simple ROM now, a known 2× available later without a spec change.

### 7.2 Mode

**[N-7.4]** Mode 0 only: SCLK idles low, data is sampled on the rising edge and
launched on the falling edge.

**[N-7.5]** The wrapper never asserts the upstream quad-mode controls, so the
engine stays in single-bit mode (`SPI_STD`) and only `mosi` drives ([N-7.6]).

**[N-7.6]** The upstream lanes are quad-SPI pads, and single-bit mode uses **two
different lane numbers** for the two directions: `spi_master_tx` drives IO0
(`spi_sdo0` → `mosi`) and `spi_master_rx` shifts in IO1
(`data_int_next = {data_int[30:0], sdi1}`), which is where MISO sits on a
quad-capable flash. So the wrapper connects `miso` to **`spi_sdi1`**, not
`spi_sdi0`. `spi_sdo1..3`, `spi_sdi0`, `spi_sdi2..3` are tied off and `spi_mode`
is ignored: GARUDA has no pins for them (PHYS §3.1). Connecting MISO to `sdi0`
is a silent failure — the transfer runs, the chip select and SCLK look perfect
on a scope, and every word reads back as zero.

### 7.3 Interrupt

**[N-7.7]** `IRQSTAT[0]` captures transfer completion, `[1]`/`[2]` the upstream
RX/TX FIFO threshold events. All three are captured sticky by the shim, so a
one-cycle upstream pulse becomes the held level the CLIC requires (D-17, D-21).

### 7.4 DMA

**[N-7.8]** With `DMACTL[0]` set, `dma_req_o` asserts while the RX FIFO holds at
least one word, and drops for one `pclk` after each `dma_ack_i` — the one-beat
rule of D-21. `DMACTL[1]` does the same for TX space.

**[N-7.9]** DMA beats are 32-bit words, so channel 0 must be configured with
`CR.SIZE = word`. An IMU burst therefore moves four bytes per beat.

**[N-7.10]** The Boot ROM does not use DMA (ADR-0015).

---

## 8 Timing

### 8.1 Flash read, CLKDIV = 3

```
             │ cmd 0x03 (8 bits) │ addr (24 bits) │ data (32 bits) │
cs_flash_n ──┐_________________________________________________┌───
sclk       ───┐_┌─┐_┌─┐_ ... ┌─┐_┌─┐_ ... ┌─┐_┌─┐_ ...  ┌─┐_┌───────
               (15.6 MHz: pclk/8)
mosi       ───< 0 0 0 0 0 0 1 1 >< A23 ... A0 ><        0s        >
miso       ─────────────────────────────────────< D31 ... D0     >
STATUS[0]  ──┐_______________________________________________┌─────
             (busy)                                    (idle again)
```

Total 64 SCLK cycles ≈ 4.1 µs per word at 15.6 MHz. A 64 KiB image is
16,384 words ≈ 67 ms, consistent with the ≈45 ms figure in MEM §8 (which
assumes 20 MHz).

### 8.2 DMA request hold-off

```
rx fifo    ──┤ 1 word │ 1 word │ 1 word ├
dma_req    ──┌────────┐   ┌────┐   ┌────
dma_ack    ──────┌─┐──────────┌─┐───────   (1 pclk, from the DMA)
                 │            │
                 └── req drops here, for at least one pclk, or the
                     channel's taken_q latches and never re-arms (D-21)
```

---

## 9 Clock, reset and power

**[N-9.1]** One clock: `pclk`. `irq_o` and `dma_req_o` cross to `hclk`
synchronously (D-5), no synchroniser.

**[N-9.2]** `spim_miso_i` is asynchronous to `pclk` and is passed through the
shim's two-flop synchroniser before it reaches the engine.

**[N-9.3]** Reset state (R-8): `cs_flash_n = cs_imu_n = 1`, `sclk = 0`,
`mosi = 0`. A board must not see a chip select asserted before firmware runs.

**[N-9.4]** Power: the window's `PSEL` is the natural clock-gate enable
(AHB2APB [N-9.5]); no gating is implemented in this block.

---

## 10 Assertions

```systemverilog
// PREADY is never deasserted: the bridge would time out (R-5)
a_pready:   assert property (@(posedge pclk_i) psel_i |-> pready_o);

// chip selects are mutually exclusive and idle high when the engine is idle
a_cs_excl:  assert property (@(posedge pclk_i) disable iff (!preset_n_i)
              !(!spim_cs_flash_n_o && !spim_cs_imu_n_o));
a_cs_idle:  assert property (@(posedge pclk_i) disable iff (!preset_n_i)
              status_idle |-> (spim_cs_flash_n_o && spim_cs_imu_n_o));

// the selected chip select stays asserted for the whole transfer (R-2)
a_cs_held:  assert property (@(posedge pclk_i) disable iff (!preset_n_i)
              $fell(spim_cs_flash_n_o) |-> !spim_cs_flash_n_o throughout
              (##[1:$] status_idle));

// SCLK never exceeds 20 MHz: at least 3 pclk between edges (R-4)
a_sclk_rate: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
              $changed(spim_sclk_o) |=> !$changed(spim_sclk_o)[*3]);

// the DMA one-beat rule (D-21)
a_dma_drop: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
              dma_ack_i |=> !dma_req_o);
```

---

## 11 Verification plan

`make test_spim` — `tb/spi_master/tb_spim.sv`, 24 checks, 0 failures.

| Req | Test | Oracle | Status |
|---|---|---|---|
| R-1, R-2 | `t_spim_flash_read` | `spi_flash_model` returns the programmed bytes | pass |
| R-3 | `t_spim_cs` | only the selected CS falls; never both | pass |
| R-4 | `t_spim_sclk_rate` | measured SCLK period ≥ 8 `pclk` at CLKDIV=3 | pass |
| R-5 | `t_spim_pready` | `PREADY` high in every cycle of every access | pass |
| R-6 | `t_spim_irq` | held after a one-cycle event; cleared by W1C only | pass |
| R-7 | `t_spim_dma` | `dma_req_checker` sees no stuck request | pass |
| R-8 | `t_spim_reset` | pins at safe idle out of reset | pass |
| §7.1 | `test_chip_flash` | the real Boot ROM boots an image out of the flash model | pass |

**R-1 is the one that earns its keep.** Every other row above passed while MISO
was connected to the wrong upstream lane and every word read back as zero
(D-23). A register-level test cannot find that; only comparing bytes against a
flash programmed with a known pattern can.

---

## 12 Design decisions

| Decision | ADR / ruling |
|---|---|
| Adapt PULP IP rather than write or wait | D-22 |
| Uniform shim: held IRQ, DMA hold-off, word-only decode | D-21 |
| Two chip selects on one bus (flash + IMU) | ADR-0008, PHYS [N-3.5] |
| No DMA in the boot path | ADR-0015 |

---

## 13 Not implemented

| Feature | Why not |
|---|---|
| Quad / dual SPI | No pins (PHYS §3.1). The upstream engine supports it; the wrapper does not expose it. |
| SPI slave mode | Block 14 was dropped for the pin budget (ADR-0020). |
| Automatic flash programming | Boot is read-only; programming is a debugger/JTAG job (DEBUG §7.6). |
| Per-byte CS toggling | Would break a flash read (R-2). |

---

## 14 Open items

**OPEN-13:** the IMU's SPI mode and maximum SCLK are a board decision; `CLKDIV`
for the IMU is firmware's to set. Nothing in this block depends on the answer.

---

## 15 Errata

None. First revision.
