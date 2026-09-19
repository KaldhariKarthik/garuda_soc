# GARUDA Memory Subsystem — Design Specification

## 0.1 Identity

| Field | Value |
|---|---|
| Document ID | GARUDA-MEM-SPEC-001 |
| Revision | 2.0 |
| Date | 2026-09-18 |
| Status | Released for implementation |
| Blocks | 3 (`isram`), 4 (`bootrom`), 5 (`dsram`) |
| Owner | Team AeroSoC |
| Supersedes | GARUDA_Memory_Subsystem_Design_Spec_v1_2 |

## 0.2 Revision history

| Rev | Change | Driver |
|---|---|---|
| 1.0–1.2 | Initial; four DSRAM slave ports; DMA-based boot copy; CRC-16; halt on CRC failure | — |
| 2.0 | DSRAM collapsed to one AHB slave port. Boot rewritten as polled PIO with the missing `.data` copy added. CRC-32. `boot_sel` recovery path replaces the dead halt. ISRAM write lock added. Macro interface reduced to plain single-port SRAM. | ADR-0005, 0006, 0007, 0014, 0015, 0016, 0021 |

## 0.3 Normative references

1. `GARUDA-SYS-001` Rev 4.0 — System Definition. All addresses and sizes are generated from it.
2. `GARUDA-ADR-001` Rev 1.0 — Architecture Decision Record.
3. `GARUDA-AHB-SPEC-001` Rev 4.0 — slave protocol, reachability, ERROR response.
4. `GARUDA-DEBUG-SPEC-001` Rev 2.0 — System Bus Access, which bypasses the ISRAM lock.
5. `GARUDA-SPIM-SPEC-001` — SPI master register interface used by the bootloader.

---

## 1 Purpose and scope

### 1.1 In scope

Three memory blocks and the boot process that fills them.

| Block | Name | Size | Contents |
|---|---|---|---|
| 3 | ISRAM | 64 KiB | Instruction memory. Firmware `.text` and, via ADR-0005, `.rodata` reachable by the data port. |
| 4 | Boot ROM | 4 KiB | The bootloader. Mask-programmed, read-only. |
| 5 | DSRAM | 64 KiB | Data memory. `.data`, `.bss`, heap, stack. |

Also in scope: the AHB slave wrappers, the SRAM macro interface, the ISRAM write lock, and
the boot sequence.

### 1.2 Out of scope

- The SRAM macro internals and the memory compiler run (foundry/PD).
- The SPI master peripheral (`GARUDA-SPIM-SPEC-001`); this document specifies only how the bootloader drives it.
- The external SPI flash part selection (board).
- The linker script, though §8.7 states the constraints it must satisfy.

### 1.3 Why boot is most of this document

Everything else here is a thin AHB wrapper around a compiler macro. Boot is the one
sequence in the chip with no recovery: if it is wrong, the chip does not run, and on a
first tape-out you cannot patch it. §8 is therefore specified step by step, with the
failure path given equal weight to the success path.

---

## 2 Requirements

| ID | Requirement | Source |
|---|---|---|
| R-1 | 64 KiB instruction memory at `ISRAM_BASE`, readable by the instruction port. | System |
| R-2 | ISRAM shall be writable by the data port and by Debug SBA, so that boot and JTAG can load it. | ADR-0005 |
| R-3 | ISRAM shall be write-protectable after boot, so flight code cannot corrupt its own instructions. | ADR-0006 |
| R-4 | 4 KiB read-only Boot ROM at `BOOTROM_BASE`, containing the reset vector. | System |
| R-5 | 64 KiB data memory at `DSRAM_BASE`, contiguous, as a single AHB slave. | ADR-0007 |
| R-6 | All three shall be zero-wait-state at 250 MHz. | System |
| R-7 | The bootloader shall copy firmware from SPI flash to ISRAM without using the DMA. | ADR-0015 |
| R-8 | The bootloader shall copy the `.data` initialisation image to DSRAM. | ADR-0015 |
| R-9 | The bootloader shall verify the image with CRC-32 before executing it. | ADR-0016 |
| R-10 | A verification failure shall leave the chip recoverable over JTAG, not halted. | ADR-0016 |
| R-11 | A `boot_sel` pin shall select JTAG load instead of flash boot. | ADR-0014 |
| R-12 | The design shall assume SRAM macros with no sleep, retention or ECC pins. | ADR-0021 |

---

## 3 Block diagram

```
                    AHB-Lite shared layer (from ahb_interconnect)
     ┌──────────────┬──────────────────┬──────────────────┐
     │ hsel_isram   │ hsel_bootrom     │ hsel_dsram       │
     ▼              ▼                  ▼
┌──────────┐   ┌──────────┐      ┌──────────────┐
│ isram_   │   │ bootrom_ │      │ dsram_slave  │
│ slave    │   │ slave    │      │              │
│          │   │          │      │  bank decode │
│ ┌──────┐ │   │ ┌──────┐ │      │  haddr[15:14]│
│ │ILOCK │ │   │ │ ROM  │ │      │              │
│ │check │ │   │ │ 4KiB │ │      └──┬──┬──┬──┬──┘
│ └──────┘ │   │ └──────┘ │         │  │  │  │
│    │     │   └──────────┘      ┌──▼┐┌▼─┐┌▼─┐┌▼─┐
│    ▼     │                     │B0 ││B1││B2││B3│  16 KiB each
│ ┌──────┐ │                     └───┘└──┘└──┘└──┘
│ │SRAM  │ │                     one 64 KiB region, contiguous
│ │64KiB │ │
│ └──────┘ │
└──────────┘
     ▲
     │ sba_write (bypasses ILOCK — see N-7.9)
     └── from Debug Module
```

---

## 4 Sub-block inventory

| Name | Type | RTL file | Role |
|---|---|---|---|
| `isram_slave` | seq | `isram_slave.v` | AHB slave wrapper, byte-enable generation, ILOCK enforcement. |
| `mem_ctl` | seq | `mem_ctl.v` | Holds `ILOCK`. One flop plus decode. |
| `bootrom_slave` | comb + seq | `bootrom_slave.v` | AHB slave wrapper, read-only, ERROR on write. |
| `dsram_slave` | seq | `dsram_slave.v` | AHB slave wrapper, bank decode across four macros. |
| `sram_wrapper` | wrapper | `sram_wrapper.v` | Single place where the compiler macro is instantiated (§4.1). |

### 4.1 Macro abstraction

**[N-4.1]** All macro instantiations are confined to `sram_wrapper.v`, with this interface
and no other:

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | `hclk` |
| `addr` | in | `A` | Word address |
| `wdata` | in | 32 | Write data |
| `rdata` | out | 32 | Read data, valid the cycle after `addr` |
| `we` | in | 1 | Write enable |
| `be` | in | 4 | Byte enables |

**[N-4.2]** No sleep, retain, light-sleep, ECC, redundancy-repair or test-mode pin is
assumed to exist. If the chosen compiler provides them, they are tied to their inactive
state inside `sram_wrapper.v` and nowhere else. Rationale: the design must not be blocked
on which macro options the compiler run produces, and a power saving that cannot be
guaranteed must not appear in any timing or power budget elsewhere in the project.

**[N-4.3]** `sram_wrapper.v` has a behavioural model for simulation, selected by
`` `ifdef SIM_SRAM ``. It is byte-enable accurate and drives X on an uninitialised read, so
firmware that reads uninitialised memory fails in simulation rather than passing by luck.

---

## 5 Interfaces

### 5.1 `isram_slave`

| Port | Dir | Width | Domain | Reset | Description |
|---|---|---|---|---|---|
| `hclk_i`, `hreset_n_i` | in | 1 | hclk | — | |
| `hsel_i` | in | 1 | hclk | 0 | Region select from the decoder. |
| `haddr_i` | in | 32 | hclk | — | |
| `hwrite_i`, `hsize_i`, `htrans_i` | in | 1/3/2 | hclk | — | |
| `hwdata_i` | in | 32 | hclk | — | |
| `hmaster_is_sba_i` | in | 1 | hclk | 0 | Asserted by the interconnect when the granted master is SBA. Used only for the ILOCK bypass, [N-7.9]. |
| `hrdata_o` | out | 32 | hclk | 0 | |
| `hreadyout_o` | out | 1 | hclk | 1 | |
| `hresp_o` | out | 1 | hclk | 0 | ERROR on a locked write. |

### 5.2 `dsram_slave`

Same AHB signals, without `hmaster_is_sba_i`. Adds internal bank decode on
`haddr_i[15:14]`.

### 5.3 `bootrom_slave`

Same AHB signals, read-only. No `hwdata_i` consumption.

### 5.4 `mem_ctl` — APB, part of window 8's address space

| Port | Dir | Description |
|---|---|---|
| `ilock_o` | out | To `isram_slave`. |

---

## 6 Register map — `mem_ctl`

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x20 | `MEMCTL` | RW | 0x0000_0000 | ISRAM write lock. |

### 6.1 `MEMCTL` (0x20)

| Bit | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0 | `ILOCK` | RW1S | 0 | 1 = ISRAM writes rejected. Write 1 to set. **Cannot be cleared by software.** |
| 31:1 | reserved | — | 0 | |

**[N-6.1]** `ILOCK` is write-1-to-set and sticky. There is no software path to clear it. It
clears only on `hreset_n` deassertion.

**[N-6.2]** Rationale for no software clear: the bit exists to make instruction memory
immutable during flight. A bit that firmware can clear is a bit that a wild pointer can
clear, which defeats the purpose. Legitimate reasons to write ISRAM again — reflashing,
recovery — all involve a reset, and reset clears it.

---

## 7 Functional description

### 7.1 Address decode

**[N-7.1]** Region decode is performed by `ahb_decoder` on `HADDR[31:28]` per
`GARUDA-AHB-SPEC-001`. Within a region, each slave decodes the low bits of its own size and
ignores the rest. Values from `GARUDA-SYS-001`:

| Region | Base | Size | In-region bits |
|---|---|---|---|
| ISRAM | `0x0000_0000` | 64 KiB | `haddr[15:2]` |
| Boot ROM | `0x1000_0000` | 4 KiB | `haddr[11:2]` |
| DSRAM | `0x2000_0000` | 64 KiB | `haddr[15:2]` |

**[N-7.2]** Addresses above a region's size but inside its 256 MiB decode granule alias
down (the high bits are ignored). This is deliberate: alias-free decode would need a range
comparator per slave for no benefit, and the linker never emits such an address. An
out-of-region address produces ERROR from the default slave instead.

### 7.2 Access sizes

**[N-7.3]** All three memories support word, halfword and byte accesses. `hsize_i` and
`haddr_i[1:0]` generate byte enables:

| `hsize` | `haddr[1:0]` | `be[3:0]` |
|---|---|---|
| WORD (10) | 00 | 1111 |
| HALF (01) | 00 | 0011 |
| HALF (01) | 10 | 1100 |
| BYTE (00) | 00 | 0001 |
| BYTE (00) | 01 | 0010 |
| BYTE (00) | 10 | 0100 |
| BYTE (00) | 11 | 1000 |

**[N-7.4]** Misaligned accesses (WORD with `haddr[1:0] != 00`, HALF with `haddr[0] != 0`)
never reach the slaves: the core detects them and raises a precise misaligned exception
before the transfer is issued. A slave that nevertheless sees one responds ERROR, as a
backstop against a defective master.

**[N-7.5]** Sub-word accesses to Boot ROM are permitted and read the containing word with
the appropriate bytes selected, because `.rodata` in the ROM may be byte-addressed.

### 7.3 Timing

**[N-7.6]** All three memories are zero-wait-state: `hreadyout_o` is held high
continuously. The macro's read data arrives one cycle after the address, which lines up
exactly with the AHB address-phase/data-phase split — the address is registered in the
address phase and the data appears in the data phase with no stall inserted.

**[N-7.7]** This is only achievable if the macros meet the 4 ns cycle with the AHB address
multiplexing in front of them. If the compiler run shows they do not, the recovery is
`DIVSEL=1` (125 MHz) per ADR-0001, not a wait state, because a wait state on instruction
fetch costs performance on every cycle of the flight loop.

### 7.4 ISRAM write lock

**[N-7.8]** When `ILOCK` is set, a write transfer to the ISRAM region with `hsel_i`
asserted produces a two-cycle ERROR response, and no data is written to the macro.

**[N-7.9]** The lock is bypassed when `hmaster_is_sba_i` is asserted — that is, when the
Debug Module is the granted master. Rationale: the lock's purpose is to protect against a
firmware bug, and the debugger is outside that threat model. Without the bypass, a chip
that has locked ISRAM and then hung could not be recovered over JTAG without a reset,
which would destroy the state you are trying to inspect.

**[N-7.10]** Reads are never affected by `ILOCK`.

### 7.5 DSRAM banking

**[N-7.11]** Four 16 KiB macros, selected by `haddr[15:14]`, behind one AHB slave port. The
region is contiguous: `0x2000_0000`–`0x2000_FFFF`.

**[N-7.12]** There is no bank-level concurrency. With a single shared AHB layer (ADR-0004)
only one master holds the bus at a time, so concurrent bank access is unreachable and four
separate slave ports would only add three sets of `hrdata`/`hreadyout` to multiplex.

**[N-7.13]** Bank selection is combinational from the registered address. All four macros
receive the same address and write data; only the selected macro's write enable is
asserted, and the read multiplex selects the corresponding `rdata`.

**[N-7.14]** Contiguity is a linker requirement, not a preference: a single heap growing up
and a single stack growing down cannot span a fragmented region.

### 7.6 Reset behaviour

**[N-7.15]** SRAM contents are undefined after reset. Macros do not reset their arrays.

**[N-7.16]** Consequently, `.bss` zeroing is firmware's job (crt0), not the bootloader's.
The bootloader copies only what has an initial value; zeroing 64 KiB in the boot ROM would
waste boot time on memory the firmware may not all use.

---

## 8 Boot

### 8.1 Image format in SPI flash

| Offset | Size | Field | Description |
|---|---|---|---|
| 0x00 | 4 | `MAGIC` | `0x47415244` ("GARD"). Distinguishes a programmed flash from an erased one. |
| 0x04 | 4 | `TEXT_LEN` | Byte length of the `.text`+`.rodata` image. Must be ≤ 64 KiB and word-aligned. |
| 0x08 | 4 | `DATA_LEN` | Byte length of the `.data` initialisation image. Word-aligned. |
| 0x0C | 4 | `ENTRY` | Entry point, an absolute address inside ISRAM. |
| 0x10 | 4 | `TEXT_CRC` | CRC-32 over the `TEXT_LEN` bytes of the text image. |
| 0x14 | 4 | `DATA_CRC` | CRC-32 over the `DATA_LEN` bytes of the data image. |
| 0x18 | 8 | reserved | Must be zero. |
| 0x20 | `TEXT_LEN` | text image | Loaded to `ISRAM_BASE`. |
| 0x20+`TEXT_LEN` | `DATA_LEN` | data image | Loaded to `DSRAM_BASE`. |

**[N-8.1]** `MAGIC` is checked first. An erased flash reads `0xFFFFFFFF`, so a blank board
takes the recovery path rather than attempting to execute erased memory.

### 8.2 Sequence

```
 1. Reset. PC = BOOTROM_BASE (0x1000_0000).
 2. Sample boot_sel.
      boot_sel == 1  ──▶ go to step 12 (JTAG recovery).
 3. Configure SPI master: mode 0, CS = cs_flash_n, divider for ≤20 MHz SCLK.
 4. Read 32-byte header by polled PIO (§8.3).
 5. Check MAGIC. Mismatch ──▶ set RSTREASON.BOOTFAIL, go to step 12.
 6. Check TEXT_LEN ≤ 64 KiB, DATA_LEN ≤ 64 KiB, both word-aligned,
    ENTRY inside ISRAM. Any failure ──▶ BOOTFAIL, step 12.
 7. Copy TEXT_LEN bytes: flash ──▶ ISRAM_BASE, polled, word at a time.
 8. Copy DATA_LEN bytes: flash ──▶ DSRAM_BASE, polled, word at a time.
 9. CRC-32 over ISRAM_BASE..+TEXT_LEN, compare to TEXT_CRC.
    CRC-32 over DSRAM_BASE..+DATA_LEN, compare to DATA_CRC.
    Either mismatch ──▶ BOOTFAIL, step 12.
10. Set MEMCTL.ILOCK.
11. Jump to ENTRY. Boot complete.

12. RECOVERY: leave ILOCK clear. Spin in a tight loop in ROM:
      loop: nop; nop; j loop
    ISRAM and DSRAM are writable by Debug SBA. The debugger loads an
    image, then releases hartreset to start it. The reason register
    tells the operator why boot failed.
```

**[N-8.2]** Step 9 is executable because the core's data port can read ISRAM (ADR-0005). In
the Rev 1.2 design it was not: the data port had no path to ISRAM, so no master in the chip
could perform that read, and the CRC step could not have been implemented.

**[N-8.3]** Step 8 was absent from Rev 1.2 entirely. Without it, every initialised global
variable in the firmware holds undefined data at `main()`.

**[N-8.4]** The recovery loop at step 12 is `nop; nop; j loop` rather than a `wfi` or a
halt, so the core is fetching and the bus is quiet but alive, which is the state SBA needs.

### 8.3 Why polled PIO and not DMA

**[N-8.5]** Each flash word is read by: write the command byte to the SPI data register,
poll the status register for completion, write the address bytes, poll, then write four
dummy bytes and read four received bytes, polling each. Roughly 20 instructions per word.

**[N-8.6]** 64 KiB is 16,384 words, so about 330,000 instructions, plus SPI wire time at
20 MHz SCLK: about 8 bits × 4 bytes per word × 16,384 = 524,288 bit times ≈ 26 ms. Boot
takes tens of milliseconds, once, at power-on. Nothing in the system cares.

**[N-8.7]** The DMA alternative was rejected because a P2M transfer from the SPI master
requires that peripheral's data register to produce a new byte per read without a per-byte
command sequence, and no document in this project has verified that the sourced IP behaves
that way. Boot is the one path where an unverified assumption is unrecoverable: if it is
wrong, the chip never reaches firmware, and there is no in-system fix. Spending 26 ms to
remove that risk is the right trade. It also removes DMA, its arbiter path and its
interrupt from the boot dependency set entirely — boot depends only on the core, the ROM,
the bus, the SPI master and ISRAM.

### 8.4 CRC-32

**[N-8.8]** CRC-32/IEEE-802.3: polynomial `0x04C11DB7`, initial value `0xFFFFFFFF`,
reflected input and output, final XOR `0xFFFFFFFF`. Computed bitwise, no lookup table —
a 256-entry table would consume a quarter of the 4 KiB ROM.

**[N-8.9]** CRC-32 rather than CRC-16: the loop is the same shape and the same ROM cost,
and over a 64 KiB image the undetected-error probability goes from 2⁻¹⁶ to 2⁻³².

**[N-8.10]** Bitwise CRC-32 over 64 KiB is roughly 8 cycles per bit × 524,288 bits ≈ 4 M
cycles ≈ 17 ms at 250 MHz. Acceptable for the same reason as [N-8.6].

### 8.5 ROM budget

| Item | Estimate |
|---|---|
| SPI init and polled read primitive | ~120 bytes |
| Header read and validation | ~100 bytes |
| Copy loops (×2) | ~120 bytes |
| CRC-32 bitwise | ~80 bytes |
| Recovery path and `boot_sel` | ~40 bytes |
| Reset vector and trap stub | ~40 bytes |
| **Total** | **~500 bytes of 4096** |

**[N-8.11]** The remaining ROM is filled with an illegal-instruction pattern
(`0x00000000`), so a jump into unused ROM raises an illegal-instruction exception rather
than executing whatever the mask happens to contain.

### 8.6 Boot-time trap handling

**[N-8.12]** The ROM installs a minimal trap handler at a fixed ROM address and points
`mtvec` at it before touching the SPI. Any exception during boot sets
`RSTREASON.BOOTFAIL` and branches to the recovery loop. Without this, a bus ERROR from a
misconfigured SPI access during boot would vector to an uninitialised `mtvec` and the chip
would be unrecoverable for a reason nobody could diagnose.

### 8.7 Linker constraints

**[N-8.13]** The linker script shall satisfy:

| Constraint | Reason |
|---|---|
| `.text` and `.rodata` at VMA `ISRAM_BASE`, contiguous | One copy, one CRC region. |
| `.rodata` in ISRAM, not DSRAM | It is read by the data port, which ADR-0005 permits. Keeps `.data` small. |
| `.data` VMA in DSRAM, LMA in flash after the text image | Step 8's copy. |
| `.bss` after `.data` in DSRAM, zeroed by crt0 | [N-7.16]. |
| Stack top at `DSRAM_BASE + 64 KiB`, growing down | Contiguity, [N-7.14]. |
| `ENTRY` word-aligned and inside ISRAM | Step 6's check. |

**[N-8.14]** `.rodata` placement in ISRAM is a deliberate consequence of ADR-0005. With the
Rev 3.1 reachability restriction, `.rodata` could not have been in ISRAM at all, and every
constant, jump table and string in the firmware would have had to be copied to DSRAM,
consuming data memory and boot time.

---

## 9 Clock, reset and power

**[N-9.1]** All three memories and `mem_ctl`'s enforcement logic are in the `hclk` domain.
`mem_ctl`'s APB register interface is in the `pclk` domain. No CDC: see
`GARUDA-CLKRST-SPEC-001` §7.4.

**[N-9.2]** `ILOCK` is reset by `hreset_n`. It is therefore cleared by external, watchdog,
debug and software resets alike — every path that leads to the bootloader running again.

**[N-9.3]** Macro arrays are not reset ([N-7.15]).

**[N-9.4]** Power: the macros are clock-gated by their own enable — a macro whose bank is
not selected receives no clock edge that matters, and the compiler's own enable pin handles
this. No retention or sleep is used ([N-4.2]). Leakage on 132 KiB is accepted as-is.

**[N-9.5]** ISRAM after boot is read-only in practice, so no write power is consumed there
during flight.

---

## 10 Assertions

```systemverilog
// --- zero wait states: hreadyout is never deasserted
a_isram_zero_wait: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i) hreadyout_o);
a_dsram_zero_wait: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i) dsram_hreadyout_o);

// --- ILOCK: no write reaches the macro while locked, unless SBA
a_ilock_blocks_write: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (ilock && hsel_q && hwrite_q && !hmaster_is_sba_q) |-> !sram_we);

// --- ILOCK: a locked write gets a two-cycle ERROR
a_ilock_error: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (ilock && hsel_q && hwrite_q && !hmaster_is_sba_q)
    |-> hresp_o ##1 hresp_o);

// --- ILOCK: SBA writes are never blocked
a_sba_bypass: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (hsel_q && hwrite_q && hmaster_is_sba_q) |-> !hresp_o);

// --- ILOCK is sticky: never falls except at reset
a_ilock_sticky: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i) $fell(ilock) |-> 1'b0);

// --- reads are never blocked by the lock
a_ilock_reads_ok: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (hsel_q && !hwrite_q) |-> !hresp_o);

// --- Boot ROM rejects every write
a_rom_write_error: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (rom_hsel_q && rom_hwrite_q) |-> rom_hresp_o);

// --- byte enables match hsize and address
a_be_correct: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  hsel_q && hwrite_q |-> (sram_be == expected_be(hsize_q, haddr_q[1:0])));

// --- DSRAM: exactly one bank write-enabled per write
a_dsram_onehot_we: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (dsram_hsel_q && dsram_hwrite_q) |-> $onehot(bank_we));

// --- DSRAM read mux matches the bank decode
a_dsram_rmux: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  dsram_hsel_q && !dsram_hwrite_q |-> (dsram_hrdata_o == bank_rdata[haddr_q[15:14]]));

// --- misaligned backstop
a_misaligned_error: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (hsel_q && ((hsize_q == WORD && haddr_q[1:0] != 2'b00) ||
              (hsize_q == HALF && haddr_q[0] != 1'b0))) |-> hresp_o);
```

---

## 11 Verification plan

| Req | Test | Oracle | Coverage goal | Status |
|---|---|---|---|---|
| R-1 | `t_isram_rw` | write/read every word via D-port | all 4 banks-equivalent ranges | new |
| R-1 | `t_isram_fetch` | execute from ISRAM via I-port | — | new |
| R-2 | `t_isram_dport_write` | D-port write lands; the Rev 1.2 failure is gone | — | new |
| R-2 | `t_isram_sba_write` | SBA write lands | — | new |
| R-3 | `t_ilock` | set, then writes ERROR, reads pass, SBA passes | all 4 combinations of {locked,unlocked}×{sba,not} | new |
| R-3 | `t_ilock_sticky` | no software clear succeeds; reset clears | — | new |
| R-4 | `t_rom_read` | every ROM word readable; writes ERROR | — | new |
| R-5 | `t_dsram_contiguous` | walk all 64 KiB across bank boundaries | all 3 boundaries | new |
| R-6 | `t_zero_wait` | `hreadyout` never low, back-to-back transfers | — | new |
| R-7 | `t_boot_pio` | full boot from a modelled SPI flash | — | new |
| R-8 | `t_boot_data_copy` | `.data` present in DSRAM at entry | — | new |
| R-9 | `t_boot_crc_pass` | correct image boots | — | new |
| R-9 | `t_boot_crc_fail` | single-bit corruption is caught | bit flips in text and data images | new |
| R-10 | `t_boot_recovery` | CRC fail → spin, ILOCK clear, SBA load works, release runs | — | new |
| R-11 | `t_boot_sel` | `boot_sel=1` skips flash entirely | — | new |
| R-11 | `t_boot_blank_flash` | erased flash (`0xFFFFFFFF`) takes recovery | — | new |
| §7.2 | `t_mem_sizes` | all 7 legal size/offset combinations | all 7 | new |
| §8.6 | `t_boot_trap` | an exception during boot reaches recovery | — | new |

**[N-11.1]** `t_boot_*` requires a behavioural SPI flash model with the command/address/dummy
sequence of the actual part. This model is the single most valuable piece of the memory
testbench, because it is the only way to verify the sequence that has no recovery on
silicon. It shall be written before the bootloader assembly.

---

## 12 Design decisions

| Decision | ADR |
|---|---|
| Every master reaches ISRAM; decode is the only gate | ADR-0005 |
| ISRAM write lock, sticky, SBA-bypassed | ADR-0006 |
| DSRAM: four macros, one slave port, contiguous | ADR-0007 |
| `boot_sel` pin for JTAG recovery | ADR-0014 |
| Polled-PIO bootloader, no DMA | ADR-0015 |
| CRC-32; spin-with-recovery instead of halt | ADR-0016 |
| Plain single-port SRAM macros assumed | ADR-0021 |

---

## 13 Not implemented

| Feature | Why not |
|---|---|
| ECC or parity | 132 KiB on a short-duration research vehicle. The boot CRC covers the one realistic corruption case, which is a bad flash image. Adds a cycle of latency and a diagnosis path nobody would use. |
| PMP or an MPU | Out of scope for v1, and honestly the weakest point in the design: a wild pointer can write any peripheral register, including PWM. `ILOCK` closes the instruction-memory case only. |
| Instruction or data cache | No external memory. Everything is already single-cycle on-chip SRAM; a cache would add latency, area and coherency questions for nothing. |
| DMA access to Boot ROM | Nothing needs it, so it is not wired (`GARUDA-SYS-001` `ahb.master_reachability`). |
| Four independent DSRAM slave ports | ADR-0007: unreachable concurrency with one shared bus layer. |
| SRAM retention or sleep modes | ADR-0021: cannot be assumed present. |
| A software-clearable `ILOCK` | Defeats the purpose ([N-6.2]). |
| Scrambling, encryption or secure boot | No threat model on this vehicle, and secure boot needs key storage the chip does not have. |

---

## 14 Open items

None. Previous opens closed as follows:

| Was open | Closed as | ADR |
|---|---|---|
| Memory compiler retain/sleep pins | Assume none; tie off in `sram_wrapper.v` if present. | ADR-0021 |
| 'KB' vs 'KiB' ambiguity in sizes | KiB = 1024 bytes throughout, generated from `GARUDA-SYS-001`. | — |

---

## 15 Errata

None; no RTL yet.

**Defects fixed in this revision:**

| ID | Symptom | Root cause | Fix |
|---|---|---|---|
| MEM-1 | Boot CRC step could not be implemented — no master could read ISRAM. | Interconnect Rev 3.1 removed the D-port→ISRAM path while this spec assumed it. | ADR-0005; §8 step 9. |
| MEM-2 | Every initialised global variable would hold garbage at `main()`. | The `.data` copy was missing from the boot sequence. | §8 step 8. |
| MEM-3 | A bad flash image would brick the board with no diagnosis. | Boot failure halted the core. | §8 step 12. |
| MEM-4 | Boot depended on unverified SPI-master DMA semantics. | DMA P2M copy in the boot path. | §8.3, polled PIO. |
| MEM-5 | `.rodata` had nowhere to live. | D-port could not reach ISRAM; DSRAM placement was never specified. | §8.7. |
| MEM-6 | Four DSRAM slave ports with no reachable concurrency. | Carried over from the multi-layer interconnect. | §7.5. |
| MEM-7 | An exception during boot vectored to an uninitialised `mtvec`. | No boot-time trap handler. | §8.6. |
