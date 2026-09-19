# GARUDA SoC — Technical Reference Manual

## 0.1 Identity

| Field | Value |
|---|---|
| Document ID | GARUDA-TRM-001 |
| Revision | 4.0 |
| Date | 2026-09-18 |
| Status | Released |
| Owner | Team AeroSoC |
| Supersedes | GARUDA_TRM_v3_0 |

## 0.2 What this document is

The system-level view: what the chip is, how the blocks fit together, and what a firmware
engineer or a reviewer needs before opening a block specification.

It is **not** the authority on any number. Every shared value — addresses, block numbers,
interrupt IDs, DMA channels, clock frequencies, pins — comes from `GARUDA-SYS-001` and is
generated into the tables below. Every design choice comes from `GARUDA-ADR-001`. If this
document and one of those disagree, they win and this document is stale by construction.

That is a deliberate inversion of Rev 3.0, which restated shared values by hand and drifted
from nine other documents in eleven places.

## 0.3 Revision history

| Rev | Change |
|---|---|
| 1.0–3.0 | Initial through the 24-block system view; 200 then 250 MHz; multi-layer interconnect; six provisional block numbers; contradictory peripheral and DMA assignments |
| 4.0 | Rebuilt as a consolidation of ten settled block specs. All shared values generated. 22 blocks. Shared AHB layer. Debug is SBA-only. Peripheral assignment resolved. All ten open items closed. |

## 0.4 Document set

| Document | Rev | Covers |
|---|---|---|
| `GARUDA-SYS-001` | 4.0 | **System definition. Machine-readable. Authority on every shared value.** |
| `GARUDA-ADR-001` | 1.0 | **Architecture decisions, 21 records. Authority on every choice.** |
| `GARUDA-DOC-001` | 1.0 | Specification template and house rules |
| `GARUDA-CORE-SPEC-001` | 3.0 | Block 1 — RV32IM core |
| `GARUDA-DSU-SPEC-001` | 3.0 | Block 2 — DSP support unit |
| `GARUDA-MEM-SPEC-001` | 2.0 | Blocks 3–5 — ISRAM, Boot ROM, DSRAM, boot |
| `GARUDA-AHB-SPEC-001` | 4.0 | Block 6 — interconnect |
| `GARUDA-AHB2APB-SPEC-001` | 2.0 | Blocks 7–8 — APB bridge and fabric |
| `GARUDA-DMA-SPEC-001` | 3.0 | Block 9 — DMA controller |
| `GARUDA-CLIC-SPEC-001` | 2.0 | Block 10 — interrupt controller |
| `GARUDA-TIMERS-SPEC-001` | 2.0 | Block 11 — machine timer and watchdog |
| `GARUDA-DEBUG-SPEC-001` | 2.0 | Block 12 — JTAG, DTM, DM, SBA |
| `GARUDA-PHYS-SPEC-001` | 1.0 | Pin-out, floorplan, SDC, board requirements |
| `tools/garuda_gen.py` | — | Generator and consistency checker. **Runs in CI.** |

---

## 1 Overview

GARUDA is a single-hart RV32IM system-on-chip for a drone flight controller, in 28 nm, on a
1.45 mm die with 40 pads, targeting tape-out in December 2026.

It runs one job: a 1 kHz control loop comprising artificial-potential-field collision
avoidance, a 9-state extended Kalman filter, and PID output to four motor ESCs. At 250 MHz
that is 250,000 cycles per iteration, and measured bus utilisation is about 7%. The chip is
substantially idle, which is what shapes the power architecture and nothing else.

| Parameter | Value |
|---|---|
| ISA | RV32IM, M-mode only |
| Pipeline | 5-stage in-order, single issue, no cache |
| `hclk` | 250 MHz (500 MHz reference ÷ 2) |
| `pclk` | 125 MHz (`hclk` ÷ 2) |
| Memory | 64 KiB ISRAM, 64 KiB DSRAM, 4 KiB Boot ROM |
| Interconnect | Shared AHB-Lite, 4 masters, 4 slaves |
| Peripherals | 8, on APB3 |
| DMA | 6 channels |
| Interrupts | CLIC, 32 IDs |
| Debug | JTAG + System Bus Access |
| Signal pins | 28 (26 allocated, 2 spare) |
| Blocks | 22 |

---

## 2 System diagram

```
  ┌───────────────────────────────────────────────────────────────────────────┐
  │                                                                           │
  │  refclk ──▶[÷2]──┬─────────────────────── hclk 250 MHz ──────────────┐    │
  │  500 MHz         └──▶[÷2]──── pclk 125 MHz ─────────────────────┐    │    │
  │  (pad-adjacent)                                                  │    │    │
  │  ext_rst_n ─▶ reset_ctrl (1024-cycle stretch on refclk) ─────────┴────┤    │
  │                                                                       │    │
  │  ┌──────────────────────┐                                             │    │
  │  │  core (1)            │  ┌──────────┐                               │    │
  │  │  IF ID EX MEM WB     │  │ timers   │── mtip ──▶ core mip.MTIP      │    │
  │  │      └─ dsu (2)      │  │   (11)   │── warn ──▶ CLIC 22            │    │
  │  │  M0 I-port           │  │          │── rst ───▶ reset_ctrl         │    │
  │  │  M1 D-port           │  └──────────┘                               │    │
  │  └───┬──────┬───────────┘  ┌──────────┐                               │    │
  │      │      │              │ clic (10)│◀── 20 sources                 │    │
  │      │      │              └────┬─────┘                               │    │
  │      │      │                   └──▶ clic_ctrl (in core)              │    │
  │      ▼      ▼                                                          │   │
  │  ┌─────────────────────────────────────────────────────┐               │   │
  │  │        ahb_interconnect (6) — ONE shared layer      │               │   │
  │  │  fixed priority: DMA > SBA > D-port > I-port        │               │   │
  │  │  every master reaches every slave                   │               │   │
  │  └──┬─────────┬─────────┬──────────────┬───────────────┘               │   │
  │     │         │         │              │         ▲        ▲            │   │
  │     ▼         ▼         ▼              ▼         │ M2     │ M3         │   │
  │  ┌──────┐ ┌───────┐ ┌───────┐   ┌────────────┐  │        │            │   │
  │  │ISRAM │ │BootROM│ │ DSRAM │   │ ahb2apb (8)│  │        │            │   │
  │  │(3)   │ │ (4)   │ │ (5)   │   │ + fabric(7)│  │        │            │   │
  │  │64KiB │ │ 4KiB  │ │ 64KiB │   └──┬─────────┘  │        │            │   │
  │  │ILOCK │ │       │ │4×16   │      │            │        │            │   │
  │  └──────┘ └───────┘ └───────┘      │            │        │            │   │
  │                                     │            │        │            │   │
  │        ┌────────────────────────────┴────────┐   │   ┌────┴──────┐     │   │
  │        │ 11 APB windows, pclk 125 MHz        │   │   │  dma (9)  │     │   │
  │        │ spim(13) i2c(15) uart0(16)          │   │   │ 6 channels│     │   │
  │        │ uart1(17) uart2(18) gpio(19)        │   │   └───────────┘     │   │
  │        │ pwm(20) dma_cfg reset_ctrl(22)      │   │                     │   │
  │        │ clic_cfg timers_cfg                 │   │   ┌───────────┐     │   │
  │        └─────────────────────────────────────┘   └───│ debug (12)│     │   │
  │                                                      │ JTAG+SBA  │     │   │
  │                                                      └─────┬─────┘     │   │
  └────────────────────────────────────────────────────────────┼───────────┘   │
                                                          tck (async)          │
                                                                               │
  Clock domains: hclk, pclk (synchronous to each other), tck (asynchronous).
  The ONLY CDC in the chip is dmi_cdc.v, inside block 12.
```

---

## 3 Generated tables

**[N-3.1]** Everything in this section is generated by `tools/garuda_gen.py` from
`GARUDA-SYS-001`. Do not edit. The generator fails CI on any inconsistency.

### 3.1 Blocks

| Block | Name | Spec | RTL |
|---|---|---|---|
| 1 | `core` | GARUDA-CORE-SPEC-001 | exists |
| 2 | `dsu` | GARUDA-DSU-SPEC-001 | exists |
| 3 | `isram` | GARUDA-MEM-SPEC-001 | missing |
| 4 | `bootrom` | GARUDA-MEM-SPEC-001 | missing |
| 5 | `dsram` | GARUDA-MEM-SPEC-001 | missing |
| 6 | `ahb_ic` | GARUDA-AHB-SPEC-001 | exists |
| 7 | `apb_fabric` | GARUDA-AHB2APB-SPEC-001 | missing |
| 8 | `ahb2apb` | GARUDA-AHB2APB-SPEC-001 | missing |
| 9 | `dma` | GARUDA-DMA-SPEC-001 | exists |
| 10 | `clic` | GARUDA-CLIC-SPEC-001 | missing |
| 11 | `timers` | GARUDA-TIMERS-SPEC-001 | missing |
| 12 | `debug` | GARUDA-DEBUG-SPEC-001 | missing |
| 13 | `spi_master` | GARUDA-SPIM-SPEC-001 | sourced IP |
| 14 | `reserved_spi_slave` | — | not instantiated |
| 15 | `i2c` | GARUDA-I2C-SPEC-001 | sourced IP |
| 16 | `uart0` | GARUDA-UART-SPEC-001 | sourced IP |
| 17 | `uart1` | GARUDA-UART-SPEC-001 | sourced IP |
| 18 | `uart2` | GARUDA-UART-SPEC-001 | sourced IP |
| 19 | `gpio` | GARUDA-GPIO-SPEC-001 | sourced IP |
| 20 | `pwm` | GARUDA-PWM-SPEC-001 | sourced IP |
| 21 | `clk_div` | GARUDA-CLKRST-SPEC-001 | missing |
| 22 | `reset_ctrl` | GARUDA-CLKRST-SPEC-001 | missing |

**[N-3.2]** There are 22 blocks. Rev 3.0's 24-block table carried two reserved rows nothing
claimed and marked six numbers "Provisional" because three documents were assigning their own.
No block is provisional now.

### 3.2 Address map

| Region | Base | Size | Access | Waits |
|---|---|---|---|---|
| ISRAM | `0x0000_0000` | 64 KiB | RW | 0 |
| Boot ROM | `0x1000_0000` | 4 KiB | R | 0 |
| DSRAM | `0x2000_0000` | 64 KiB | RW | 0 |
| APB | `0x4000_0000` | 48 KiB | RW | 2..N |

Decode on `HADDR[31:28]`. Sizes in KiB = 1024 bytes.

### 3.3 APB windows

| Window | Base | Block | Peripheral |
|---|---|---|---|
| — | `0x4000_0000` | — | unmapped (SPI slave, ADR-0020) |
| 0 | `0x4000_1000` | 13 | `spi_master` |
| 1 | `0x4000_2000` | 15 | `i2c` |
| 2 | `0x4000_3000` | 16 | `uart0` |
| 3 | `0x4000_4000` | 17 | `uart1` |
| 4 | `0x4000_5000` | 9 | `dma_cfg` |
| 5 | `0x4000_6000` | 18 | `uart2` |
| 6 | `0x4000_7000` | 19 | `gpio` |
| 7 | `0x4000_8000` | 20 | `pwm` |
| 8 | `0x4000_9000` | 22 | `reset_ctrl` + `mem_ctl` |
| 9 | `0x4000_A000` | 10 | `clic_cfg` |
| 10 | `0x4000_B000` | 11 | `timers_cfg` |

### 3.4 AHB masters

| ID | Master | Source | Priority | Bursts | Access |
|---|---|---|---|---|---|
| 0 | `iport` | core | lowest | SINGLE, INCR | read |
| 1 | `dport` | core | | SINGLE | read, write |
| 2 | `sba` | debug | | SINGLE | read, write |
| 3 | `dma` | dma | **highest** | SINGLE | read, write |

Every master reaches every slave, except that the DMA has no Boot ROM or ISRAM path.

### 3.5 Peripheral function, DMA channel, CLIC ID

| Block | Peripheral | Function | DMA ch | CLIC ID |
|---|---|---|---|---|
| 13 | `spi_master` | IMU + boot flash (2 chip selects) | 0 | 15 |
| 15 | `i2c` | barometer, magnetometer, sonar | 1 | 16 |
| 16 | `uart0` | GPS | 2 | 17 |
| 17 | `uart1` | ground link (telemetry **or** LoRa) | 3 | 18 |
| 18 | `uart2` | debug console | 5 | 19 |
| 19 | `gpio` | discrete IO, pin-change aggregate | — | 20 |
| 20 | `pwm` | 4 motor ESC outputs | — | 21 |

**[N-3.3]** One table. Rev 3.0 had three that disagreed — §13 and §14 of the TRM itself
contradicted each other on where LoRa lived, and both contradicted the DMA spec.

### 3.6 CLIC interrupt map

| ID | Source |
|---|---|
| 0 | permanently unassigned sentinel |
| 1–6 | DMA channel 0–5 complete |
| 7–12 | DMA channel 0–5 error |
| 13 | reserved (freed — `mtip` does not use the CLIC) |
| 14 | reserved (freed — SPI slave removed) |
| 15–21 | `spi_master`, `i2c`, `uart0`, `uart1`, `uart2`, `gpio`, `pwm` fault |
| 22 | watchdog early warning |
| 23–31 | reserved, unenableable |

### 3.7 DMA channels

| Channel | Peripheral | Function | Priority |
|---|---|---|---|
| 0 | `spi_master` | IMU | 5 (highest) |
| 4 | — | spare | 4 |
| 1 | `i2c` | baro, mag, sonar | 3 |
| 3 | `uart1` | ground link | 2 |
| 2 | `uart0` | GPS | 1 |
| 5 | `uart2` | console | 0 (lowest) |

### 3.8 Clocks and reset

| Item | Value |
|---|---|
| `refclk` | 500 MHz, external driven reference, 1 pin |
| `hclk` | 250 MHz, `refclk` ÷ 2, DIV parameter 2/4/8/16 |
| `pclk` | 125 MHz, `hclk` ÷ 2, toggle flop, 50% duty |
| `tck` | ≤20 MHz, asynchronous |
| Domains | 3: `hclk`, `pclk` (synchronous pair), `tck` |
| Reset sources | `ext_rst_n`, watchdog, `ndmreset`, software |
| Reset stretch | 1024 `refclk` cycles (≈2.05 µs) |

### 3.9 Pins — 28-pin baseline

| Function | Pins |
|---|---|
| `refclk` | 1 |
| `ext_rst_n` | 1 |
| JTAG | 4 |
| SPI master | 5 |
| I²C | 2 |
| UART ×3 | 6 |
| PWM | 4 |
| GPIO | 2 |
| `boot_sel` | 1 |
| **allocated** | **26** |
| **spare** | **2** |
| **budget** | **28** |

---

## 4 Boot

```
reset ──▶ PC = 0x1000_0000
            │
            ├─ boot_sel = 1 ──▶ spin, ISRAM unlocked, wait for JTAG
            │
            ├─ install a trap handler (before touching SPI)
            ├─ configure SPI master, cs_flash_n
            ├─ read a 32-byte header: MAGIC "GARD", lengths, entry, 2× CRC-32
            ├─ MAGIC or bounds fail ──▶ BOOTFAIL, spin for JTAG
            ├─ copy text image flash ──▶ ISRAM     (polled PIO)
            ├─ copy .data image flash ──▶ DSRAM    (polled PIO)
            ├─ CRC-32 both regions, compare
            ├─ mismatch ──▶ BOOTFAIL, spin for JTAG
            ├─ set MEMCTL.ILOCK
            └─ jump to ENTRY
```

**[N-4.1]** Boot takes roughly 45 ms: about 26 ms of SPI wire time and 17 ms of bitwise
CRC-32. Once, at power-on. Polled PIO was chosen over DMA because the DMA path depended on
unverified behaviour of a sourced SPI IP, and boot is the one path with no in-system
recovery from a wrong guess.

**[N-4.2]** A boot failure spins with ISRAM unlocked rather than halting, so a probe can read
`RSTREASON` to see why and load a working image without a reset. Bricking a board is not
possible.

**[N-4.3]** Full detail: `GARUDA-MEM-SPEC-001` §8.

---

## 5 Programming model

### 5.1 Memory and privilege

M-mode only. No PMP, no MPU, no virtual memory. Flat physical address space.

**[N-5.1]** The consequence, stated plainly: a wild pointer can write any peripheral
register, including PWM, which means a firmware bug can command the motors. `MEMCTL.ILOCK`
protects instruction memory after boot and nothing else. This is the weakest safety property
in the chip and it is accepted for v1.

### 5.2 Interrupts

**[N-5.2]** Two mechanisms, deliberately:

| Source | Path | Priority control |
|---|---|---|
| 20 peripheral and DMA sources | CLIC → `clic_ctrl` | 8-bit level, `mintthresh`, `mintstatus.mil` |
| Machine timer | `mtip` → `mip.MTIP` | `mstatus.MIE`, `mie.MTIE` |

**[N-5.3]** All CLIC sources are level-triggered in hardware. **A handler must clear the
condition in its peripheral before `mret`,** or it re-enters immediately.

**[N-5.4]** Both level comparisons are strictly greater, so an equal level never preempts.

### 5.3 Firmware requirements

**[N-5.5]** Things the hardware requires of firmware, which will otherwise fail subtly:

| # | Requirement | Reference |
|---|---|---|
| F-1 | Install the divide trap handler before any `DIV`/`REM` executes. | CORE §7.2 |
| F-2 | Write `mtimecmp` with the three-step sequence, or get spurious `mtip`. | TIMERS §7.4 |
| F-3 | Read `MTIME_LO` before `MTIME_HI`, or get a stale shadow. | TIMERS §7.2 |
| F-4 | Clear a peripheral's condition before `mret`. | CLIC §7.2 |
| F-5 | Scale DSU operands into Q1.15; the hardware does not check. | DSU §6.2 |
| F-6 | Zero `.bss` in crt0; the bootloader does not. | MEM §7.16 |
| F-7 | Enable an interrupt only after configuring its peripheral. | CLIC §6.2 |
| F-8 | Dump GPRs, `mepc`, `mcause`, `mtval` to a fixed DSRAM struct in the trap handler — **from day one.** With SBA-only debug this is the only way to see register state. | DEBUG §7.11 |
| F-9 | Break large M2M DMA transfers into chunks; the DMA is the highest-priority master and has no rate limiting. | DMA §7.6 |
| F-10 | Once `WDTCTL.EN` is set it cannot be cleared. Kick forever. | TIMERS §6.2 |
| F-11 | Measure the loop duty cycle with `mcycle` and `mtime`. No document asserts a figure. | CORE §6.2 |

**[N-5.6]** F-8 is the one that will hurt most if skipped, and the moment it is needed is the
moment it is too late to add.

### 5.4 Linker

| Section | VMA | LMA |
|---|---|---|
| `.text`, `.rodata` | ISRAM | flash + 0x20 |
| `.data` | DSRAM | flash, after the text image |
| `.bss` | DSRAM, after `.data` | — |
| stack | top of DSRAM, growing down | — |

**[N-5.7]** `.rodata` lives in ISRAM and is read by the data port. This is possible because
every master reaches every slave (ADR-0005); the withdrawn multi-layer proposal would have
made it impossible.

---

## 6 Power

**[N-6.1]** One mechanism — stop the clock when nothing is happening — at three levels.

| Level | Mechanism | Covers |
|---|---|---|
| 1 | WFI root gate on core + DSU, enabled by `pipe_ctrl.quiescent` | the majority of the chip's flops |
| 2 | Per-block gates: `dsu_idle`, DMA per-channel `EN`, per-window `PSEL` | most of the rest |
| 3 | `pclk` at half `hclk` | the entire peripheral clock tree and every peripheral flop |

**[N-6.2]** Level 3 is why `pclk` is a real divided clock rather than an access-rate trick. An
enable scheme would deliver the same APB interface rate while leaving every peripheral flop
toggling at 250 MHz, saving nothing.

**[N-6.3]** No power domains, no isolation cells, no level shifters, no retention flops, no
voltage scaling, no low-power oscillator. `DIVSEL` gives coarse frequency scaling as a
timing fallback, not as a power-management mechanism.

**[N-6.4]** What always runs: `mtime`, the watchdog, the CLIC's selection logic (it must be
able to wake WFI), and the `refclk` divider. Roughly 100 flops.

**[N-6.5]** The chip's power is a rounding error against the motors. The reason to do this is
that it is nearly free, cuts dynamic power by a large factor, and a tape-out programme will
ask.

---

## 7 Debug

**[N-7.1]** JTAG TAP + DTM + Debug Module with System Bus Access as AHB master M2. No abstract
register access, no program buffer, no breakpoints, no single-step.

**[N-7.2]** What you get:

- Load firmware into ISRAM over JTAG — no SPI reflash in the development loop.
- Read and write all of DSRAM and every peripheral register at any time.
- Stop the core (`hartreset`) so inspection is not racing it.
- Read the three 48-bit DSU accumulators live, without stopping the core.
- Recover a chip whose ISRAM is locked, since SBA bypasses the lock.

**[N-7.3]** What you do not get: GPR and CSR inspection, breakpoints, single-step, and resume
from the stop point — `hartreset` resume restarts from the reset vector.

**[N-7.4]** This is a loader and a memory inspector, not a source-level debugger. It is the
honest weakest point in the chip's bring-up story, and it exists because the alternative was
adding a fourth pipeline control mode to the core's hold/flush logic — the source of 4 of its
27 errata — and re-verifying it in six weeks. An unverified debugger is the worst thing to be
holding when diagnosing first silicon.

**[N-7.5]** The mitigation is F-8: firmware dumps register state to DSRAM, SBA reads it. About
40 instructions.

**[N-7.6]** The v2 path is additive: add `dcsr`, `dpc`, `dscratch0/1` and a halt-drain
sequence as a fifth hold source, extending the core's §7.23 matrix. SBA remains the load path.

---

## 8 Development loop

```
  boot_sel = 1  (board strap or jumper)
      │
      ├─ ROM spins, ISRAM unlocked
      ├─ OpenOCD: TAP reset, IDCODE, dmactive = 1
      ├─ sbaddress0 = 0x0000_0000, sbautoincrement = 1
      ├─ stream the image through sbdata0        (~41 ms for 64 KiB)
      ├─ clear hartreset
      └─ firmware runs
```

**[N-8.1]** No flash programming, no board handling, under a second per iteration. This is
the single largest practical benefit of the debug architecture, and it is why the capability
trade of [N-7.3] is worth making.

---

## 9 Implementation status

### 9.1 RTL

| Built and verified | Not yet written |
|---|---|
| core (1), dsu (2) — 63/63 lockstep vs. Spike, 27 errata fixed | isram (3), bootrom (4), dsram (5) |
| ahb_ic (6) — shared layer, zero protocol violations | apb_fabric (7), ahb2apb (8) |
| dma (9) — errata D-1, D-2 fixed | clic (10), timers (11), debug (12) |
| | clk_div (21), reset_ctrl (22) |
| | 8 peripheral integrations |

### 9.2 RTL deltas on what exists

| # | Change | Files | Size |
|---|---|---|---|
| R1 | Delete `pclk`/`preset_n` from the DMA's core logic; config port stays on `pclk` with no synchronisers | `dma_top.v`, `dma_apb_slave.v`, `garuda_soc_top.v` | small |
| R2 | Delete the three DMA CDC modules | `dma_cdc_*.v` | deletion |
| R3 | Add SBA as AHB master M2 | `ahb_interconnect.v`, `ahb_arbiter.v`, `ahb_master_mux.v` | medium |
| R4 | Replace `mtime_i`/`mtimecmp_i` with `mtip_i`; delete the in-core comparator | `garuda_core_top.v`, `csr_file.v` | small |
| R5 | Add `hartreset_n_i` | `garuda_core_top.v`, `pipe_ctrl.v` | small |
| R6 | ISRAM write lock | new `mem_ctl.v`, `ahb_decoder.v` | small |
| R7 | Delete the orphan `clic_mintthresh_o` | `garuda_core_top.v`, `csr_file.v` | small |
| R10 | `clk_div`: DIV parameter, divider reset by raw `ext_rst_n` only | new `clk_div_top.v` | small |
| R11 | `core_clk_gate`, enabled by `pipe_ctrl.quiescent` | new `core_clk_gate.v`, `pipe_ctrl.v` | small |

**[N-9.1]** R11 is the only delta touching verified pipeline control logic. `GARUDA-CORE-SPEC-001`
[N-7.29] constrains it to consume the existing quiescence term rather than forming a second
opinion about pipeline state, for exactly that reason.

### 9.3 Build order

| Week | Work |
|---|---|
| 1 | `clk_div`, `reset_ctrl`, memories. All unwritten, so the reset and boot fixes cost nothing. |
| 2 | `ahb2apb` + bridge integration. In parallel: **diagnose `t_clic`.** |
| 3 | `clic`, `timers`, `debug`. |
| 4 | R1–R11 deltas, peripheral integration, `GARUDA-PHYS-SPEC-001` handoff package. |
| 5 | Top-level integration and regression. |
| 6 | Slack. |

### 9.4 The three tests that matter most

**[N-9.2]** Out of everything in the eleven verification plans:

| Test | Why |
|---|---|
| `t_core_hold_flush_matrix` | All 20 hold/flush combinations. Four errata came from this cross product and all four were found by someone happening to think of the case. One day, closes the class. |
| `t_wdt_req_survives` | The watchdog reset request must survive the reset it causes. The failure mode is a runt pulse that RTL simulation hides, because reset is modelled as instantaneous. |
| `t_ahb_reachability` | Four cover properties proving every master reaches every slave. The regression guard against re-introducing the restriction that broke boot, `.rodata` and JTAG load. |

**[N-9.3]** If there is time for formal on exactly one block, it is `pipe_ctrl`. Small,
bounded, and the highest remaining probability of a silicon bug in the chip.

---

## 10 Known limitations

**[N-10.1]** Stated here, in one place, so no reviewer has to find them:

| # | Limitation | Consequence | Why accepted |
|---|---|---|---|
| L-1 | No PMP or MPU | A wild pointer can write any peripheral register, including PWM | M-mode-only v1; out of scope in the time available |
| L-2 | No GPR/CSR inspection, no breakpoints | Debug is a loader and memory inspector | Alternative was an unverified fourth pipeline mode in the most errata-prone logic |
| L-3 | No ECC or parity | An SRAM soft error is undetected | 132 KiB, short-duration research vehicle; boot CRC covers the realistic case |
| L-4 | No hardware divider | Division costs 150–250 cycles | A few thousand cycles of 250,000, against area and a new stall condition |
| L-5 | DSU cannot hold EKF covariance | Covariance propagation and Kalman gain are RV32IM firmware | Q1.15 dynamic range. Stated in DSU §7.5 rather than claimed away |
| L-6 | No ESP-NOW mesh in the 28-pin build | No mesh link | Pin budget; §3.2 of PHYS restores it if supply pads are outside the 40 |
| L-7 | Watchdog runs during debug halt | A long debug session resets the chip | A watchdog that stops for one reason will be stopped for another. Use `boot_sel` = 1 |
| L-8 | 250 MHz closure not asserted | May need DIV=4 | Fallback documented in advance, so a miss is a parameter change |
| L-9 | No redundancy | Single point of failure throughout | Research vehicle, not certified flight hardware |
| L-10 | Loop duty cycle unmeasured | No power or utilisation figure asserted | Measurable with `mcycle`; asserting an unverified number is worse |

---

## 11 Open items

**[N-11.1]** One of the original ten remains, and it is the only irreversible decision in the
project:

| ID | Item | Closed as | Recoverable? |
|---|---|---|---|
| OPEN-2 | Are the 40 pads inclusive of supply pads? | Assume yes. 28-signal-pin baseline, additively expandable to 36. | **No** — the pad ring is physical. Closed pessimistically for that reason. |

The other nine are closed in `GARUDA-ADR-001` "Open items — all closed." Two remain as tasks
rather than decisions: diagnose the `t_clic` timeout (OPEN-8), and confirm `u_csa2`'s width in
`mac_unit.v` (OPEN-9).

---

## 12 What changed from Rev 3.0, and why it matters

**[N-12.1]** Eleven documents were rewritten or revised. The changes fall into three groups.

**Things that would not have worked in silicon:**

| Defect | Consequence |
|---|---|
| The boot CRC had no master that could read ISRAM | The verification step was unimplementable |
| The `.data` copy was missing from the boot sequence | Every initialised global would hold garbage at `main()` |
| Watchdog and debug resets were self-cancelling runt pulses | A watchdog timeout would not have reset the chip |
| The Debug spec required eight core features that do not exist | No debug at all |
| `pclk` was specified as 50% duty from a mechanism producing 25% | Halved setup window across the peripheral domain |
| `hreadyout` reset high across a staggered reset release | An AHB access acknowledged by a bridge whose APB side was in reset |
| `mtimecmp` reset to zero | `mtip` asserted before any handler existed |

**Things that contradicted each other across documents:**

| Contradiction | Resolution |
|---|---|
| Three different UART and DMA channel assignments | One generated table |
| Two mechanisms for the machine timer | `mip.MTIP`; CLIC ID 13 freed |
| "No CDC needed" alongside a full CDC implementation | A proof, and the synchronisers deleted |
| Six provisional block numbers; CLIC at 10 and 16 | 22 blocks, generated |
| An orphan `clic_mintthresh_o` with no consumer | Port deleted |

**Things that were simply too much:**

| Over-design | Replaced by |
|---|---|
| Six-layer interconnect at 7% utilisation | One shared layer, already built and verified |
| Four DSRAM slave ports with no reachable concurrency | One port, contiguous region |
| A DMA boot copy depending on unverified IP behaviour | ~26 ms of polled PIO |

**[N-12.2]** The single structural change that prevents the second group from recurring is
`GARUDA-SYS-001` plus the generator in CI. Every one of those contradictions was a shared
value maintained by hand in three or more places. There is now exactly one place, and a
document that restates a value by hand fails the build.

**[N-12.3]** And the group that mattered most was the first. Five of those seven were found by
reading two documents against each other, not by reading either one carefully. That is what
the eleven-document rewrite was for.
