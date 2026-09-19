# GARUDA Debug Subsystem — Design Specification

## 0.1 Identity

| Field | Value |
|---|---|
| Document ID | GARUDA-DEBUG-SPEC-001 |
| Revision | 2.0 |
| Date | 2026-09-18 |
| Status | Released for implementation |
| Block | 12 (`debug`) |
| Owner | Team AeroSoC |
| Supersedes | GARUDA_Debug_Design_Spec_v1_0 |

## 0.2 Revision history

| Rev | Change | Driver |
|---|---|---|
| 1.0 | Abstract Access Register commands plus a Program Buffer; no bus presence | — |
| 2.0 | Complete rewrite as System Bus Access only. Abstract register access and the program buffer are removed because the core implements none of the features they require. The DM becomes AHB master 2. | ADR-0012, 0005, 0006 |

## 0.3 Normative references

1. RISC-V External Debug Support, version 0.13.2.
2. IEEE 1149.1-2013 (JTAG), for the TAP state machine.
3. `GARUDA-SYS-001` Rev 4.0 — System Definition.
4. `GARUDA-ADR-001` Rev 1.0 — Architecture Decision Record.
5. `GARUDA-AHB-SPEC-001` Rev 4.0 — SBA is master M2.
6. `GARUDA-MEM-SPEC-001` Rev 2.0 — the ISRAM lock bypass and the boot recovery path.
7. `GARUDA-CLKRST-SPEC-001` Rev 2.0 — `ndmreset` and `hartreset` domains.

---

## 1 Purpose and scope

### 1.1 In scope

A 4-wire JTAG TAP, a Debug Transport Module, and a Debug Module whose sole memory-access
mechanism is System Bus Access as AHB master M2. Also: `ndmreset`, `hartreset`, and
always-live read-only taps on the three DSU accumulators.

### 1.2 Out of scope

- The external probe and its software (OpenOCD configuration is a deliverable of the
  firmware effort, not this document).
- Boundary scan. See §13.

### 1.3 Why Rev 1.0 is withdrawn entirely

Rev 1.0 specified the conventional RISC-V debug architecture: the debugger halts the hart,
then either issues Abstract Access Register commands or writes instructions into a Program
Buffer for the hart to execute, reading results back through `data0`. Section 1 of that
document stated that the core specification "already commits to" the hooks this needs.

It does not, and the RTL does not implement them. Checked against `rtl/core`:

| Required by Rev 1.0 | Present in the core |
|---|---|
| `dcsr` (0x7B0) | absent |
| `dpc` (0x7B1) | absent |
| `dscratch0/1` (0x7B2/0x7B3) | absent |
| Halt request input and halt acknowledge | absent |
| Pipeline halt-drain sequence | absent |
| Fetch redirection to a program buffer | absent |
| Debug-mode entry on `ebreak` | absent |
| Resume with `dret` | absent |

Building them means adding a fourth pipeline control mode — alongside stall, flush and
trap — to the block that produced most of this project's errata, and then re-verifying the
hold/flush cross product. That is not a six-week task with any confidence, and a debug
subsystem that is unverified is worse than a simple one, because you rely on it precisely
when everything else has failed.

Rev 1.0 also justified having no bus presence as robustness: debug would work even if the
bus were broken. That reasoning does not hold, because the program-buffer mechanism
requires the hart to fetch and execute. A broken core or a broken fetch path breaks debug
either way. The design took on a real constraint for a benefit it did not deliver.

System Bus Access inverts the trade: the debugger drives the bus directly instead of
puppeting the core. It requires **zero core changes**, and it delivers the capability that
matters most day to day — loading firmware into ISRAM over JTAG instead of reflashing SPI
for every iteration.

---

## 2 Requirements

| ID | Requirement | Source |
|---|---|---|
| R-1 | 4-wire JTAG interface: `TCK`, `TMS`, `TDI`, `TDO`. No `TRST_n`. | ADR-0013 pin budget |
| R-2 | The Debug Module shall access memory and peripherals without any core involvement. | ADR-0012 |
| R-3 | The debugger shall be able to write firmware into ISRAM, including when `ILOCK` is set. | ADR-0006, 0014 |
| R-4 | The debugger shall be able to hold the core stopped and release it. | ADR-0012 |
| R-5 | `ndmreset` shall reset the system without resetting the Debug Module or the TAP. | Debug 0.13 §3.2 |
| R-6 | The three DSU accumulators shall be readable without stopping the core. | System |
| R-7 | The debug subsystem shall require no modification to the core RTL. | ADR-0012 |
| R-8 | A debug session shall survive a system reset. | Debug 0.13 §3.2 |

---

## 3 Block diagram

```
   probe
     │  TCK TMS TDI TDO
     ▼
  ┌────────────────────────────────────────────────────────────┐
  │  ── tck domain ────────────┼── hclk domain ──────────────  │
  │                            │                               │
  │  ┌──────────┐   ┌────────┐ │ ┌──────────┐                  │
  │  │ jtag_tap │──▶│  dtm   │─┼▶│  dmi_cdc │                  │
  │  │ IEEE1149 │   │ DMI    │ │ │ 2ff req/ │                  │
  │  │ state m/c│◀──│ shift  │◀┼─│ ack      │                  │
  │  └──────────┘   └────────┘ │ └────┬─────┘                  │
  │                            │      │                        │
  │   ── the ONLY async ───────┘      ▼                        │
  │      boundary in the chip   ┌──────────────┐               │
  │                             │ debug_module │               │
  │                             │              │               │
  │                             │ dmcontrol    ├──▶ ndmreset   │
  │                             │ dmstatus     ├──▶ hartreset  │
  │                             │ sbcs/sbaddr  │               │
  │                             │ sbdata       │               │
  │                             │ dsuacc0..2   │◀── DSU taps   │
  │                             └──────┬───────┘               │
  │                                    │                       │
  │                             ┌──────▼───────┐               │
  │                             │  sba_master  ├──▶ AHB M2     │
  │                             │  AHB-Lite    │               │
  │                             └──────────────┘               │
  └────────────────────────────────────────────────────────────┘
```

---

## 4 Sub-block inventory

| Name | Type | RTL file | Role |
|---|---|---|---|
| `jtag_tap` | seq (tck) | `jtag_tap.v` | IEEE 1149.1 TAP controller, IR and DR shift. |
| `dtm` | seq (tck) | `dtm.v` | DMI register (`dtmcs`, `dmi`), address/data/op shift. |
| `dmi_cdc` | seq (tck+hclk) | `dmi_cdc.v` | Two-flop request/acknowledge handshake. The one real CDC in the chip. |
| `debug_module` | seq (hclk) | `debug_module.v` | DM register file, reset control, DSU tap capture. |
| `sba_master` | seq (hclk) | `sba_master.v` | AHB-Lite master M2. Single 32-bit transfers. |

---

## 5 Interfaces

### 5.1 JTAG (chip pins)

| Pin | Dir | Description |
|---|---|---|
| `tck` | in | Test clock, ≤20 MHz. Asynchronous to `hclk`. |
| `tms` | in | Mode select. |
| `tdi` | in | Data in. |
| `tdo` | out | Data out. Tri-stated outside Shift-DR/Shift-IR. |

**[N-5.1]** `TRST_n` is not implemented. The TAP is reset by holding `TMS` high for five
`TCK` cycles, which IEEE 1149.1 requires every compliant TAP to support. This saves a pin
(ADR-0020) and every probe and OpenOCD support it.

**[N-5.2]** The TAP has no power-on reset of its own. Its state machine reaches Test-Logic-Reset
from any state within five `TCK` cycles of `TMS` high, and OpenOCD begins every session that
way. The TAP is therefore usable without `hreset_n` ever having deasserted, which is what
makes debugging a chip stuck in reset possible.

### 5.2 To the rest of the chip (`hclk`)

| Port | Dir | Width | Description |
|---|---|---|---|
| `ndmreset_o` | out | 1 | To `reset_ctrl`. Resets everything except the DM and TAP. |
| `hartreset_o` | out | 1 | To `reset_ctrl`. Resets core + DSU only. |
| `dsu_acc_i` | in | 48×3 | Live DSU accumulator values. |
| `dsu_ovf_i` | in | 3 | Live DSU sticky overflow flags. |
| AHB M2 | — | — | Per `GARUDA-AHB-SPEC-001` §5.1. |

**[N-5.3]** There is no connection to the core's pipeline, register file or CSRs. That
absence is the point of Rev 2.0 and the reason R-7 is satisfiable.

---

## 6 Register map

### 6.1 JTAG instruction register (5 bits)

| IR | Name | DR width | Description |
|---|---|---|---|
| 0x01 | `IDCODE` | 32 | Device identification. |
| 0x10 | `DTMCS` | 32 | DTM control and status. |
| 0x11 | `DMI` | 41 | Debug Module Interface access. |
| 0x1F | `BYPASS` | 1 | Mandatory. |
| others | → `BYPASS` | 1 | Unimplemented instructions decode to BYPASS, per IEEE 1149.1. |

**[N-6.1]** `IDCODE` = `0x0000_0DB1`. Bits 11:1 are the JEDEC manufacturer ID, left as zero
pending an assignment; bits 31:12 are the part number `0x00000`; bit 0 is 1 as IEEE 1149.1
requires. A probe uses `IDCODE` to confirm the chain is alive, which is the first thing to
check at bring-up.

### 6.2 `DTMCS` (IR 0x10)

| Bits | Name | Access | Value | Description |
|---|---|---|---|---|
| 3:0 | `version` | R | `1` | Debug spec 0.13. |
| 9:4 | `abits` | R | `7` | DMI address width. |
| 11:10 | `dmistat` | R | — | 0 none, 2 op failed, 3 busy. |
| 14:12 | `idle` | R | `5` | Cycles the debugger should spend in Run-Test/Idle between DMI accesses. |
| 16 | `dmireset` | W1 | — | Clears a sticky error. |
| 17 | `dmihardreset` | W1 | — | Resets the DTM. |

**[N-6.2]** `idle` = 5 rather than 0. The DMI crossing takes a `tck`→`hclk`→`tck` round trip
through a two-flop handshake; telling the debugger to wait removes most retries and makes
sessions markedly faster. This is a real, measurable difference at bring-up and costs
nothing.

### 6.3 `DMI` (IR 0x11, 41 bits)

| Bits | Field |
|---|---|
| 40:34 | `address` (7 bits) |
| 33:2 | `data` (32 bits) |
| 1:0 | `op` — 0 nop, 1 read, 2 write |

### 6.4 Debug Module registers (DMI address space)

| Addr | Name | Description |
|---|---|---|
| 0x10 | `dmcontrol` | DM active, reset control. |
| 0x11 | `dmstatus` | DM and hart status. |
| 0x38 | `sbcs` | System bus access control and status. |
| 0x39 | `sbaddress0` | System bus address. |
| 0x3C | `sbdata0` | System bus data. |
| 0x60 | `dsuacc0_lo` | DSU ACC_FX bits 31:0. |
| 0x61 | `dsuacc0_hi` | DSU ACC_FX bits 47:32. |
| 0x62 | `dsuacc1_lo` | DSU ACC_FY bits 31:0. |
| 0x63 | `dsuacc1_hi` | DSU ACC_FY bits 47:32. |
| 0x64 | `dsuacc2_lo` | DSU ACC_MAG bits 31:0. |
| 0x65 | `dsuacc2_hi` | DSU ACC_MAG bits 47:32. |
| 0x66 | `dsuovf` | Three sticky overflow flags. |

**[N-6.3]** Addresses `0x04` (`data0`), `0x16` (`abstractcs`), `0x17` (`command`) and
`0x20`–`0x2F` (`progbuf`) are **not implemented** and read as zero. A debugger discovers
this through `abstractcs.progbufsize` = 0 and `abstractcs.datacount` = 0, which is the
standard discovery mechanism: OpenOCD then uses SBA for memory access without needing a
custom configuration.

### 6.5 `dmcontrol` (0x10)

| Bit | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0 | `dmactive` | RW | 0 | 0 holds the DM in reset. Must be written 1 to begin. |
| 1 | `ndmreset` | RW | 0 | Resets the system, not the DM. |
| 29 | `hartreset` | RW | 0 | Resets the core and DSU only. |
| 30 | `resumereq` | W1 | — | Alias for clearing `hartreset`. See [N-7.8]. |
| 31 | `haltreq` | W1 | — | Alias for setting `hartreset`. See [N-7.8]. |

**[N-6.4]** `dmactive` resets to 0 and is reset only by `tck`-domain TAP reset — never by
`hreset_n`, `ndmreset` or `hartreset`. This is what satisfies R-8: a system reset in the
middle of a debug session leaves the session intact.

### 6.6 `dmstatus` (0x11)

| Bit | Name | Value | Description |
|---|---|---|---|
| 3:0 | `version` | 2 | Debug 0.13. |
| 7 | `authenticated` | 1 | No authentication. |
| 8 | `anyhalted` | — | Mirrors `hartreset`. See [N-7.9]. |
| 9 | `allhalted` | — | Same. |
| 10 | `anyrunning` | — | `!hartreset`. |
| 11 | `allrunning` | — | Same. |
| 19 | `impebreak` | 0 | No program buffer. |

### 6.7 `sbcs` (0x38)

| Bits | Name | Access | Reset | Description |
|---|---|---|---|---|
| 31:29 | `sbversion` | R | 1 | |
| 22 | `sbbusyerror` | R/W1C | 0 | Access attempted while busy. |
| 21 | `sbbusy` | R | 0 | Transfer in progress. |
| 20 | `sbreadonaddr` | RW | 0 | Start a read when `sbaddress0` is written. |
| 19:17 | `sbaccess` | RW | 2 | Access size. Only 2 (32-bit) is supported. |
| 16 | `sbautoincrement` | RW | 0 | Increment `sbaddress0` by 4 after each access. |
| 15 | `sbreadondata` | RW | 0 | Start another read after `sbdata0` is read. |
| 14:12 | `sberror` | R/W1C | 0 | 0 none, 2 alignment, 3 unsupported size, 4 bus error. |
| 11:5 | `sbasize` | R | 32 | |
| 4 | `sbaccess128` … | R | 0 | Unsupported sizes read 0. |
| 2 | `sbaccess32` | R | 1 | The only supported size. |
| 1:0 | `sbaccess16/8` | R | 0 | Unsupported. |

**[N-6.5]** `sbautoincrement` with `sbreadondata` is what makes bulk transfer usable: the
debugger sets the address once, then reads `sbdata0` repeatedly, each read returning the
next word and starting the fetch of the one after. One DMI access per word instead of
three. `sbreadonaddr` does the same for the first word. Without these, loading 64 KiB would
take three times as long, and the JTAG round trip is the bottleneck in the development
loop.

**[N-6.6]** Only 32-bit access is supported. `sbaccess8` and `sbaccess16` read 0 so the
debugger knows not to attempt them; an attempt sets `sberror` = 3. Rationale: byte access
would require byte-enable generation in the SBA master for no use case — firmware images
are word-aligned, and peripheral registers are word-only anyway
(`GARUDA-AHB2APB-SPEC-001` §7.4).

### 6.8 DSU accumulator taps (0x60–0x66)

**[N-6.7]** Read-only, captured from the live DSU outputs into an `hclk` register on every
DMI read. The core need not be stopped.

**[N-6.8]** A 48-bit value read as two 32-bit halves can tear if the accumulator changes
between the two reads. Reading `_lo` captures **both** halves into a holding register
simultaneously, and the subsequent `_hi` read returns the captured upper half rather than
the live value. So the sequence read-`_lo` then read-`_hi` returns a coherent 48-bit
snapshot; reading `_hi` alone returns whatever was last captured. This is the same shadow
technique the machine timer uses (`GARUDA-TIMERS-SPEC-001` §7).

---

## 7 Functional description

### 7.1 Session start

**[N-7.1]** The debugger: holds `TMS` high for five `TCK` cycles to reset the TAP; reads
`IDCODE` to confirm the chain; reads `DTMCS` for `abits` and `idle`; writes `dmactive` = 1;
polls `dmstatus` until the DM responds. No system reset is required, and the core continues
running throughout.

### 7.2 System Bus Access

**[N-7.2]** A read: write `sbaddress0`; if `sbreadonaddr` is set the transfer starts
immediately, otherwise it starts when `sbdata0` is read. `sbbusy` is high during the AHB
transfer. Read `sbdata0` for the result.

**[N-7.3]** A write: write `sbaddress0`, then write `sbdata0`. The write to `sbdata0`
triggers the AHB transfer.

**[N-7.4]** Accessing `sbdata0` or `sbaddress0` while `sbbusy` is high sets `sbbusyerror`
and the access is discarded. The debugger must poll or respect the `idle` hint.

**[N-7.5]** The SBA master issues single 32-bit AHB transfers as M2. It reaches ISRAM, Boot
ROM, DSRAM and the entire APB region (`GARUDA-SYS-001` `ahb.master_reachability`).

**[N-7.6]** An AHB ERROR response sets `sberror` = 4. A misaligned `sbaddress0` sets
`sberror` = 2 and no transfer is issued. `sberror` is sticky and must be cleared by W1C
before further accesses succeed, so a failure cannot be silently overwritten by the next
access.

**[N-7.7]** SBA writes to ISRAM bypass `MEMCTL.ILOCK` (`GARUDA-MEM-SPEC-001` [N-7.9]). This
is what makes recovery possible on a chip that has locked ISRAM and then hung: the
debugger can replace the firmware image without a reset, preserving the DSRAM state you
want to inspect.

### 7.3 Halt and resume

**[N-7.8]** "Halt" in this design means holding the core in `hartreset`. `haltreq` sets
`hartreset`; `resumereq` clears it. The aliases exist so that an unmodified OpenOCD flow
works.

**[N-7.9]** The semantics differ from Debug 0.13 in a way that must be understood, because
the difference is not cosmetic:

| | Standard halt | `hartreset` halt |
|---|---|---|
| Core state preserved | yes | **no** |
| GPRs readable | yes | no |
| CSRs readable | yes | no |
| `dpc` shows where it stopped | yes | no |
| Resume continues from the stop point | yes | **no — restarts from the reset vector** |
| Memory readable while stopped | yes | yes |
| Peripherals readable while stopped | yes | yes |

**[N-7.10]** So this is not a debugger in the breakpoint-and-inspect sense. It is a
loader plus a memory and peripheral inspector, with the ability to stop the core so that
inspection is not racing against it. The honest description: you can see all of memory and
every peripheral register at any time, and you can load and start code, but you cannot ask
the core where it is.

**[N-7.11]** The practical technique for register-level debugging is for firmware to write
its state to a known DSRAM location — a trap handler that dumps all 31 GPRs, `mepc`,
`mcause` and `mtval` to a fixed struct — which SBA then reads. This makes an exception fully
diagnosable, and it costs about 40 instructions in the firmware's trap handler. This
technique should be in the firmware from day one, not added after the first hang.

### 7.4 Resets

**[N-7.12]** `ndmreset` resets the system but not the DM or the TAP
(`GARUDA-CLKRST-SPEC-001` §7.3). If it reset the DM, `dmcontrol.ndmreset` would clear
itself and the debugger would lose the session it just used — the failure mode Debug 0.13
§3.2 exists to prevent.

**[N-7.13]** `hartreset` resets the core and DSU only. The bus, memories and peripherals
stay live, which is exactly what SBA needs while the core is stopped.

**[N-7.14]** `ndmreset` is a level, not a pulse: it is held until the debugger clears it.
It does not pass through `reset_ctrl`'s stretch counter, which exists for the self-cancelling
sources ([N-7.9] of the ClkRst spec); a debugger-held level has no such problem.

### 7.5 The DMI clock crossing

**[N-7.15]** `tck` is a genuinely asynchronous clock: it comes from the probe, at an
unrelated frequency, and may stop entirely between accesses. The DMI crossing is therefore a
real CDC and uses a two-flop request/acknowledge handshake in each direction.

**[N-7.16]** This is the only asynchronous crossing in the chip. The `hclk`↔`pclk`
boundary is synchronous (`GARUDA-AHB2APB-SPEC-001` §7.2). Stating this here means any future
reviewer knows exactly where to look for CDC review: one module, `dmi_cdc.v`.

**[N-7.17]** `tck` may stop mid-handshake. The `hclk` side therefore never waits on `tck`
progress to complete an AHB transfer: the transfer runs to completion and the result waits
in `sbdata0` for whenever `tck` resumes. An `hclk`-side state machine that waited on `tck`
could hold the bus indefinitely when a probe is unplugged.

### 7.6 Development loop this enables

**[N-7.18]** With `boot_sel` = 1 (`GARUDA-MEM-SPEC-001` §8.2 step 12) the ROM spins with
ISRAM unlocked. The loop is then: build, `sbaddress0` = `ISRAM_BASE`, stream 64 KiB through
`sbdata0` with autoincrement, clear `hartreset`, run. No SPI flash programming, no board
handling. This is the single largest practical benefit of Rev 2.0 and the reason the
capability trade in [N-7.9] is worth making.

---

## 8 Timing

### 8.1 DMI access across the clock crossing

```
tck      ──┘‾‾‾┐___┌‾‾‾┐___┌‾‾‾┐___┌‾‾‾┐___┌‾‾‾┐___
              (≤20 MHz, unrelated to hclk, may stop)

Shift-DR ──┌────────────────┐──────────────────────
           │  41 bits in/out │
Update-DR ─────────────────┌─┐─────────────────────
                            │
dmi_req   ──────────────────┌────────────┐─────────  tck domain
                                          
           ═══ 2ff synchroniser ═══
                                
req_sync  ─────────────────────┌──────────┐────────  hclk domain
hclk      ──┘‾┐_┌‾┐_┌‾┐_┌‾┐_┌‾┐_┌‾┐_┌‾┐_┌‾┐_┌
                               ▲
                               └── AHB transfer issued here

dmi_ack   ─────────────────────────┌──────┐────────  hclk domain
           ═══ 2ff synchroniser ═══
ack_sync  ────────────────────────────┌───────┐────  tck domain
                                       ▲
                                       └── debugger may shift again
```

### 8.2 Bulk ISRAM load with autoincrement

```
sbcs: sbautoincrement=1, sbreadondata=0, sbaccess=2

write sbaddress0 = 0x0000_0000
  │
  ├─ write sbdata0 = word0 ──▶ AHB write to 0x0000_0000, addr → 0x04
  ├─ write sbdata0 = word1 ──▶ AHB write to 0x0000_0004, addr → 0x08
  ├─ write sbdata0 = word2 ──▶ AHB write to 0x0000_0008, addr → 0x0C
  │   ...
  └─ 16384 words, one DMI write each

sbbusy   ──┌──┐  ┌──┐  ┌──┐  ┌──┐          ~5 hclk per AHB transfer
           └──┘  └──┘  └──┘  └──┘          (the JTAG shift dominates)
```

**[N-8.1]** At 20 MHz `TCK`, a 41-bit DMI write plus TAP overhead is roughly 50 `TCK`
cycles ≈ 2.5 µs. 16,384 words ≈ 41 ms. A full firmware load over JTAG takes well under a
second, against tens of seconds for an SPI flash program-and-verify cycle plus board
handling.

### 8.3 Coherent 48-bit accumulator read

```
DMI read dsuacc0_lo
  │
  ├─▶ capture: {acc_hold_hi, acc_hold_lo} <= dsu_acc_i[0]   (both halves, one cycle)
  └─▶ return acc_hold_lo

DMI read dsuacc0_hi
  └─▶ return acc_hold_hi   (the captured value, not the live one)

  ┌── DSU keeps accumulating throughout; the snapshot is coherent
```

---

## 9 Clock, reset and power

| Domain | Contents |
|---|---|
| `tck` | `jtag_tap`, `dtm`, the `tck` half of `dmi_cdc`. |
| `hclk` | `debug_module`, `sba_master`, the `hclk` half of `dmi_cdc`. |

**[N-9.1]** `dmactive` is in the `tck` domain and is reset only by TAP reset. Everything
else in the `hclk` half is reset by `hreset_n` **excluding** `ndmreset` — that is, the DM's
`hclk` logic is reset by external, watchdog and software resets, but not by the debug reset
it generates itself.

**[N-9.2]** The TAP works with `hclk` stopped and `hreset_n` asserted. The `hclk` half does
not, so SBA requires the system to be out of reset. A chip stuck in reset can still be
identified over JTAG (`IDCODE`, `DTMCS`) even if its memory cannot be read, which is enough
to distinguish "dead chip" from "chip held in reset" at bring-up — the first question you
ask when nothing works.

**[N-9.3]** Power: the `tck` domain is inert with no probe attached, since `tck` does not
toggle. The `hclk` half is gated by `dmactive` — with no debug session, the DM's `hclk`
logic receives no clock. The DSU tap registers are the exception, being combinational
capture only.

---

## 10 Assertions

```systemverilog
// --- dmactive survives every system reset (R-8, N-6.4)
a_dmactive_survives: assert property (
  @(posedge hclk_i) (dmactive && !hreset_n_i) |=> dmactive);
a_dmactive_survives_ndm: assert property (
  @(posedge hclk_i) (dmactive && ndmreset_o) |=> dmactive);

// --- ndmreset does not reset the DM's own registers (R-5)
a_ndmreset_dm_alive: assert property (
  @(posedge hclk_i) $rose(ndmreset_o) |=> $stable(sbcs_q[19:17]));

// --- SBA: only 32-bit access is ever issued
a_sba_word_only: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  sba_htrans != IDLE |-> (sba_hsize == 3'b010));

// --- SBA: misaligned address is rejected before any transfer
a_sba_align: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (sb_start && |sbaddress0[1:0]) |-> (sberror == 3'd2) && (sba_htrans == IDLE));

// --- SBA: AHB error becomes sberror 4
a_sba_bus_error: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (sba_hresp && sba_hready) |=> (sberror == 3'd4));

// --- sberror is sticky until W1C
a_sberror_sticky: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (sberror != 0 && !sberror_w1c) |=> $stable(sberror));

// --- sbbusy asserted for the whole transfer, and access while busy errors
a_sbbusy: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  sb_start |=> sbbusy until_with (sba_hready && sba_htrans == IDLE));
a_sbbusyerror: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (sbbusy && sb_access_attempt) |=> sbbusyerror);

// --- autoincrement advances by exactly 4
a_sba_autoinc: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (sbautoincrement && sb_complete) |=> (sbaddress0 == $past(sbaddress0) + 4));

// --- the hclk side never waits on tck progress (N-7.17)
a_hclk_independent: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  sb_start |-> ##[1:40] !sbbusy);

// --- hartreset holds the core without disturbing the bus
a_hartreset_bus_alive: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  hartreset_o |-> (sba_htrans != IDLE || sba_hready));

// --- DSU 48-bit snapshot is coherent (N-6.8)
a_dsu_snapshot: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  dmi_read_acc_lo |=> $stable(acc_hold_hi) throughout (!dmi_read_acc_lo)[*1:$]);

// --- unimplemented DM registers read zero, never X (N-6.3)
a_unimpl_zero: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i)
  (dmi_addr inside {7'h04, 7'h16, 7'h17, [7'h20:7'h2F]} && dmi_read)
    |-> (dmi_rdata == 32'h0));

// --- DMI CDC: request and acknowledge never both high (handshake integrity)
a_dmi_handshake: assert property (
  @(posedge hclk_i) disable iff (!hreset_n_i) !(req_sync && ack_out));
```

---

## 11 Verification plan

| Req | Test | Oracle | Coverage goal | Status |
|---|---|---|---|---|
| R-1 | `t_jtag_tap` | full IEEE 1149.1 state machine traversal | all 16 states | new |
| R-1 | `t_jtag_tms_reset` | 5×TMS high reaches Test-Logic-Reset from every state | all 16 start states | new |
| R-1 | `t_jtag_idcode` | `IDCODE` shifts out correctly | — | new |
| R-1 | `t_jtag_bypass` | unimplemented IR values behave as BYPASS | — | new |
| R-2 | `t_sba_rw` | read and write every slave region | all 4 regions | new |
| R-2 | `t_sba_no_core` | SBA works with the core in `hartreset` | — | new |
| R-3 | `t_sba_isram_locked` | SBA writes ISRAM with `ILOCK` set | — | new |
| R-3 | `t_sba_bulk_load` | 64 KiB image loaded and verified | — | new |
| R-4 | `t_halt_resume` | `haltreq`/`resumereq` stop and restart the core | — | new |
| R-5 | `t_ndmreset` | system resets, DM and TAP survive, session continues | — | new |
| R-6 | `t_dsu_taps` | all three accumulators read while the core runs | all 3 | new |
| R-6 | `t_dsu_snapshot` | `_lo` then `_hi` is coherent while the DSU accumulates | — | new |
| R-7 | — | `git diff` on `rtl/core` shows only the `hartreset` input | — | review gate |
| R-8 | `t_session_survives_reset` | `dmactive` holds through external, watchdog and software reset | all 3 | new |
| §7.2 | `t_sba_errors` | alignment, unsupported size, bus error; sticky; W1C | all 3 codes | new |
| §7.2 | `t_sba_autoinc` | autoincrement and `sbreadondata` bulk paths | both | new |
| §7.5 | `t_dmi_cdc` | random `tck`/`hclk` ratios from 1:2 to 1:100 | — | new |
| §7.5 | `t_tck_stops` | `tck` stops mid-handshake; `hclk` side completes and recovers | stop in each handshake phase | new |
| §7.6 | `t_jtag_dev_loop` | `boot_sel`=1 → load → release → firmware runs | — | new |

**[N-11.1]** `t_tck_stops` is the test most likely to catch a real bug, because a probe
being unplugged mid-access is routine at bring-up and an `hclk`-side machine that waits on
`tck` would hold the bus forever. It must cover a stop in every phase of the handshake, not
just the idle state.

**[N-11.2]** Formal is recommended for `dmi_cdc.v`. It is the only asynchronous crossing in
the chip, it is small, and a CDC bug there is intermittent and extremely hard to diagnose
from a waveform.

---

## 12 Design decisions

| Decision | ADR |
|---|---|
| SBA-only; no abstract register access, no program buffer; zero core changes | ADR-0012 |
| SBA as AHB master M2 with full reachability | ADR-0005, 0012 |
| SBA bypasses the ISRAM write lock | ADR-0006 |
| `boot_sel` gives a JTAG recovery and load path | ADR-0014 |
| 4-wire JTAG, no `TRST_n` | ADR-0020 |

---

## 13 Not implemented

| Feature | Why not | v2 path |
|---|---|---|
| Abstract Access Register | Requires `dcsr`, `dpc`, `dscratch`, halt-drain and a fourth pipeline control mode in the core. §1.3. | Add the CSRs and a halt-drain sequence; SBA remains the load path. |
| Program Buffer | Same core dependencies. | Same. |
| Hardware breakpoints / triggers (`tdata1/2`) | Needs debug-mode entry in the core. | Additive, after debug mode exists. |
| Single-step | Needs `dcsr.step`. | Additive. |
| GPR and CSR inspection | No path without abstract access. Use the firmware state dump of [N-7.11]. | Additive. |
| Hart array / multi-hart | One hart. |  |
| `abstractauto` | No abstract commands to automate. |  |
| Authentication | No security requirement, and it would add a bring-up failure mode. |  |
| Boundary scan | The 28-pin ring does not justify a separate boundary-scan chain, and the programme's test strategy does not require one. |  |
| 8/16-bit SBA | [N-6.6]. |  |
| `TRST_n` | Pin budget; 5×TMS is universally supported. |  |

**[N-13.1]** The honest summary of this table: v1 gives you a loader and a memory inspector,
not a source-level debugger. The capability gap is real and it is the weakest point in the
chip's bring-up story. It is accepted because the alternative was an unverified fourth
control mode in the core's hold/flush logic, and an unverified debugger is the worst
possible thing to be holding when you are trying to diagnose first silicon.

---

## 14 Open items

None.

---

## 15 Errata

No RTL yet.

**Defects fixed in this revision:**

| ID | Symptom | Root cause | Fix |
|---|---|---|---|
| DBG-1 | The entire specified mechanism depended on eight core features that do not exist in RTL, while §1 asserted the core "already commits" to them. | Two documents written independently with no check that one's assumption matched the other's content. | Rewritten as SBA-only, §1.3. |
| DBG-2 | JTAG firmware load was impossible: progbuf writes need a data-port path to ISRAM, which the Rev 3.1 interconnect removed. | Interacting restrictions in two documents. | ADR-0005 plus SBA as a first-class master. |
| DBG-3 | A debug-initiated reset would have reset the DM, clearing `dmcontrol.ndmreset` and killing the session. | DM inside the `ndmreset` domain. | [N-7.12], `GARUDA-CLKRST-SPEC-001` §7.3. |
| DBG-4 | "No bus presence for robustness" did not deliver robustness, since the program-buffer path still required the core to fetch and execute. | Rationale not tested against the mechanism. | §1.3; SBA is bus-resident by design. |
