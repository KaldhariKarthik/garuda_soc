# GARUDA SoC — FPGA bring-up log (KV260)

**The evidence record for the KV260 prototype: what ran, on what, with what
result, and what that does and does not prove.** The flow itself is described
in `fpga/kv260/README.md`. This file holds the results. Raw logs live in
`fpga/kv260/evidence/` (captured by `fpga/kv260/capture_evidence.sh`).

---

## Session 2026-09-28/29 — first silicon run

Branch `fpga/kv260-bringup`, merged to `main`.

### 0. Status in one paragraph

The unmodified `garuda_chip_top` (109 RTL files, the same `rtl/soc/filelist_chip.f`
used by Xcelium and Genus) was implemented on the KV260's XCK26 PL at
hclk 50 MHz / pclk 25 MHz. Timing closed with no critical warnings. Loaded on
stock Kria Ubuntu, the chip-level programs were run through the real JTAG → DTM →
DM → SBA path, exactly the `tb_chip +MODE=jtag` flow. **6 of 7 programs pass.**
`t_chip_periph` fails at step 4, the I2C transaction, which needs a device at
0x48 that is not fitted. The build surfaced **one RTL defect** (an SV cast in a
Verilog-2001 file, fixed) and **one timing finding**: the interrupt-take path is
21–25 logic levels in a single cycle. It is flagged for ASIC check below.

### 1. Setup

| Item | Value |
|---|---|
| Board | AMD Kria KV260, K26 SOM, `xck26-sfvc784-2LV-c` |
| Board OS | Ubuntu 22.04.4 LTS, kernel `5.15.0-1027-xilinx-zynqmp` |
| Tools | Vivado 2025.2 (SW build 6299465) on cadence-ws |
| RTL base | `97622e6` + PWM fix (§5) |
| Clocks | PS pl_clk0 100 MHz → MMCM (VCO 1200) → hclk 50 MHz; BUFGCE_DIV /2 → pclk 25 MHz |
| Host path | A53 Linux → HPM0_FPD → AXI GPIO @0xA000_0000 (ctrl/stat) + UartLite @0xA001_0000 |
| Test path | `garuda_host.py`: reset (boot_sel=1) → JTAG halt → SBA load ISRAM → mailbox → resume → poll `tohost` over SBA |

### 2. Implementation results (`fpga/kv260/out/`)

```
GARUDA KV260 build done:  WNS = 0.955 ns   WHS = 0.014 ns
All user specified timing constraints are met.
checking unconstrained_internal_endpoints (0)
There are 0 register/latch pins with no clock.
CRITICAL WARNING count: vivado.log 0, impl_1/runme.log 0
```

| Resource | Used | Available | % |
|---|---|---|---|
| CLB LUTs | 9,665 | 117,120 | 8.25 |
| Block RAM tiles (RAMB36) | 17 | 144 | 11.81 |
| URAM288 | 4 | 64 | 6.25 |
| DSP48E2 | 10 | 1,248 | 0.80 |
| BUFGCE / BUFGCE_DIV | 6 / 2 | 112 / 16 | — |

Memory mapping: one 64 KiB SRAM → 4 URAM288 (4K×72, cascaded), the other →
16 RAMB36, BootROM → 1 RAMB36 (carries the `bootrom.hex` init; URAM cannot be
initialised, so it matters that the ROM landed in BRAM).

Per-clock timing (Intra/Inter Clock Tables, `timing.rpt`):

| Clock | Period | WNS | WHS |
|---|---|---|---|
| clk_pl_0 (PS/AXI) | 10 ns | 6.603 | 0.024 |
| refclk_raw (hclk) | 20 ns | 2.043 | 0.017 |
| pclk | 40 ns | 34.002 | 0.014 |
| tck | 100 ns | 48.570 | 0.016 |
| pclk → hclk | 20 ns | **0.955** | 0.061 |
| hclk → pclk | 20 ns | 13.100 | 0.022 |

### 3. Hardware results (Kria, 2026-09-29)

Load (`install_on_kria.sh`):
```
garuda: loaded to slot 0
stat      = 0x6a5d0c0a
signature = 0x6a5d  OK
mmcm lock = 1
heartbeat = toggling (hclk running)
pwm[3:0]  = 0000   gpio[1:0] = 00   scl/sda = 1/1   uart0_tx = 1
IDCODE = 0x00000db1  OK
```

Suite (`garuda_host.py suite --build images`):
```
t_chip_jtag     PASS    0.09s
t_chip_basic    PASS    0.18s
t_chip_irq      PASS    0.19s
t_chip_uart     PASS    0.19s
t_chip_wdt      PASS    0.11s
t_chip_periph   FAIL    0.17s program reported step 4   [expect: step 4 without an I2C slave at 0x48]
t_fpga_hello    PASS    0.51s
```

uart0 console (`t_fpga_hello --console`, received by the PL UartLite at 115200):
```
GARUDA alive on KV260
misa    = 0x40001100
mul     = 0x75CCA2ED  (exp 0x75CCA2ED)
divu    -> trap mcause=0x00000002  (exp 0x00000002, CORE 7.2)
RSTREAS = 0x00000001
done.
```

### 4. What each result proves — and the limits of the claim

| Claim | Evidence | Strength |
|---|---|---|
| JTAG TAP + DTM alive | IDCODE 0xDB1 | direct |
| DM halt/resume, SBA read/write, autoincrement stream, dmi_cdc tck→hclk | every test loads its image over SBA and reads back 4 words before resume | direct |
| Boot ROM from BRAM init, boot_sel strap, recovery mailbox, jump to ISRAM | every test enters this way | direct |
| Reset reason EXT, boot_sel visible, misa/mtvec CSR surface, ISRAM ILOCK, precise bus faults (unmapped, masked window, sub-word APB, misaligned), DMA refuses ISRAM dst | `t_chip_basic` PASS | direct |
| DMA M2M + completion IRQ → CLIC → core; mtime → MTIP trap; WDT early-warning (level IRQ, kick clears) | `t_chip_irq` PASS | direct |
| WFI sleep/wake | `t_chip_irq` PASS (race-free WFI loops) | direct for wake. **Gating itself not measured**: the BUFGCE is in circuit, but no gated-cycle counter was read on hardware |
| Whole-chip watchdog reset; RSTREASON=WDT; DSRAM `.noinit` survives; WDT restarts disabled | `t_chip_wdt` PASS (run 2 checks all three) | direct |
| 3 UARTs independent, no crosstalk; IRQ tail per instance | `t_chip_uart` PASS (fabric loopback) | direct |
| uart0 baud correct at 115200 from 25 MHz pclk, to an external receiver | hello banner | direct |
| All 8 APB windows answer with their own ID, none aliases | `t_chip_periph` step 1 | direct |
| GPIO drives and reads back through a real pad; pull-down input reads 0 | `t_chip_periph` step 2 | direct |
| PWM counter runs | `t_chip_periph` step 3 | direct for the counter. **Pin waveform not observed** |
| I2C transaction completes | `t_chip_periph` step 4 FAIL, no slave on the bus | **not proven** |
| MUL correct; DIV/DIVU traps as illegal | hello | direct |

**Not proven on the FPGA, by construction:** the real `clk_div` (ripple divider,
DIVSEL switching) and the latch ICG, which were substituted (FD-1..3); any
250/125 MHz timing; pads, pad ring and power; SPI master to a real flash and
flash boot; SPI slave; DSU instructions; DMA P2M/M2P with peripheral requests;
the full ISA; long-run stability (each test ran once).

### 5. Defects and findings

**RTL-FPGA-1 (fixed): SystemVerilog size cast in a Verilog-2001 file.**
`rtl/pwm/garuda_pwm_top.v:83,123`: `A_DUTY0 + 12'(4*k)` → `A_DUTY0 + 4*k`.
Vivado (strict Verilog parse) rejected it with `[Synth 8-2716] syntax error near '''`.
Xcelium and Verilator had both accepted it. The change is functionally
identical: 12-bit compare, k ≤ 3. A `iverilog -g2005` pass over every `.v` in
`filelist_chip.f` found no other instance. **Proposed:** a strict-Verilog lint
gate in CI.

**SPEC-FPGA-1 (open): `misa` advertises M; DIV/DIVU/REM/REMU trap.**
By design (CORE §7.2), but `-march=rv32im` C code will trap on `/` and `%`.
Decision needed: document it, or have the toolchain use `rv32i_zmmul`.

**TIMING-FPGA-1 (open, ASIC check required): interrupt-take path is one deep
combinational cycle.**
```
Source:  u_soc/u_dma/g_ch[4].u_ch/err_q_reg           (hclk)
         u_spim/u_shim/irqstat_q_reg[1]                (pclk)
Dest:    u_core/u_if/u_prefetch_buffer/fifo_pc_reg[*]/CE (gated core clock)
hclk→hclk : 20.213 ns, 21 levels (CARRY8=5 LUT6=8 …), 83% route, skew +1.791 ns
pclk→hclk : 21.104 ns, 25 levels (CARRY8=6 LUT6=8 …), 81% route, skew +1.593 ns
```
The chain runs from a registered interrupt source through the CLIC priority/level
compare (the CARRY8 chains) and the core's trap decision and PC redirect, to the
prefetch-buffer enable. The data path is longer than the 20 ns period. It
closes only because the destination sits on the gated clock (one BUFGCE
deeper), which arrives ~1.7 ns later. **Design Fmax on the KV260 is
therefore ≈ 50 MHz, set by this path.** ASIC impact is unknown until Tempus
reports the same path against 4 ns. The candidate fix is to register the CLIC's
selected {id, level, valid} (+1 cycle of interrupt latency). That is a spec
decision, and it may relate to OPEN-8 (`t_clic` timeout).

### 6. FPGA-only substitutions (the ASIC RTL is not modified)

| ID | Substitution | Reason |
|---|---|---|
| FD-1 | `rtl/fpga/clk_div_fpga.v` (MMCM out → BUFGCE_DIV /1, /2) replaces `clk_div.v`; aon_clk = hclk | the ripple divider generates clocks in fabric, which cannot be timed |
| FD-2 | DIVSEL echoed (`div_act = div_sel`, `busy = 0`) | same |
| FD-3 | `rtl/fpga/core_clk_gate_fpga.v` (BUFGCE CE_TYPE SYNC) replaces the latch+AND ICG | a LUT-gated clock glitches |
| FD-4 | 50/25 MHz instead of 250/125 | FPGA timing |
| FD-5 | UART tx→rx and SPIM mosi→miso looped in fabric; SPIS idle; I2C/GPIO/PWM on PMOD J2 | 8 pins; I2C and GPIO need real pulls |
| FD-6 | `*_sva.sv` excluded | bind-only assertions |

### 7. Next

1. I2C device at 0x48 on J2.1/J2.2 → `t_chip_periph` fully green.
2. riscv-tests / `sw/tests` ISA sweep through the same loader.
3. 1000× suite soak with logs captured (`capture_evidence.sh`).
4. Tempus report on TIMING-FPGA-1's path at 250 MHz.
5. Flash boot: SPI flash on the RPi header.
6. PWM pin on a scope; DSU and peripheral-DMA programs.
