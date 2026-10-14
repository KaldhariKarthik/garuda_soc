# GARUDA

**A RISC-V SoC with a signal-processing coprocessor, for TSMC 28 nm. Tapeout target: 2026-12-01.**

Status at 2026-10-14. The RTL is complete and passes its regression. Physical design is the
critical path.

---

## The chip

| Item | Value |
|---|---|
| Core | In-house RV32IM, five-stage pipeline, Harvard: separate AHB-Lite master ports for instruction and data. No hardware divider (DIV/REM are emulated in a trap handler) |
| Coprocessor | DSU in the EX stage: three 16×16 MACs, 48-bit accumulators, ten Custom-0 instructions |
| Clocks | 500 MHz reference → `aon_clk` 250 MHz (always on), `hclk` 250 MHz (÷2, 4, 8 or 16 by DIVSEL), `pclk` 125 MHz. JTAG `tck` is the only asynchronous clock |
| Memory | 64 KiB instruction SRAM, 64 KiB data SRAM (4 × 16 KiB), 4 KiB boot ROM. Zero wait states |
| Bus | AHB-Lite interconnect, 4 masters (I-port, D-port, debug SBA, DMA). AHB-to-APB bridge, 12 windows |
| System blocks | CLIC (32 IDs, level only), 6-channel DMA, timers and watchdog, RISC-V debug (JTAG, DM, SBA), clock divider, reset controller |
| Peripherals | SPI master (flash + IMU), SPI slave, I²C, 3 × UART, 2 GPIO, 4 PWM. SPI master, UART and GPIO are vendored PULP IP; the I²C controller is OpenCores; PWM, SPI slave and the I²C register layer are in-house |
| Die and pins | 1.45 mm die edge, 40-pad ring, 28 signal pins (26 allocated). The SPI slave adds 4 pins if OPEN-2 allows |
| Boot | From SPI flash with a CRC check, or JTAG recovery (`boot_sel`) |

The system description is `Design_Docs/garuda_system.yaml`. The specifications are
`Design_Docs/GARUDA-*-SPEC-001.md`. Start with `Design_Docs/GARUDA-TRM-001.md`.

## The DSU

The DSU is the reason for the chip. It calculates artificial potential fields for real-time
collision avoidance in a drone swarm. The MAC uses a CSA tree with a pipeline register and a
Kogge-Stone final adder, so the 48-bit accumulate does not chain additions in one 4 ns cycle.

The core-to-DSU interface is frozen: `dsu_top.v` takes the 32-bit instruction and returns a
5-bit destination register address. Do not change this interface. The core is built on it.

## Rules of the project

1. **When the RTL and a document disagree, the RTL wins,** and the document is corrected on
   the record. Rulings are in `Docs/DECISIONS.md`. Do not leave a difference silent.
2. **The yaml is normative for cross-block facts.** A spec that disagrees with it is stale.
3. **Every defect goes in `Docs/BUGS.md`,** with the mechanism that found it. A FIXED entry
   has a test that fails without the fix.
4. **Third-party RTL is never edited.** Changes go in the GARUDA wrapper, or in a recorded
   patch (`rtl/third_party/README.md`, D-22).

---

## Status

### Verification

The full flow ran on Cadence tools on 2026-10-04. Details: `Docs/HANDOFF.md`.

| Area | Result |
|---|---|
| Core | 64 ISA tests (58 in Spike lockstep, also with random bus waits), 12 directed programs, 20 unit testbenches: pass. 200 riscv-dv random programs match Spike (2.46 million instructions) |
| DSU | Against its cycle-accurate model and an independent oracle: pass |
| Blocks | 15 block testbenches: pass. UVM environments for CLIC, timers, PWM, GPIO and clock/reset, each checked with planted defects |
| Chip | 8 programs from the pins (boot, interrupts, watchdog reset, SPI-flash boot, UART, peripherals, integration, JTAG load-and-run): pass, 0 AHB protocol violations |
| Formal | `pipe_ctrl` proved in SymbiYosys (8 of 9 properties; the 9th needs the whole core) |
| Static | HAL lint: 5 errors, each waived with a reason. Clock-domain and reset-domain reviews done |
| Coverage | Collected on the whole SoC (`Docs/COVERAGE.md`). Not closed |
| FPGA | Ran on a KV260 on 2026-09-29 (`Docs/FPGA_BRINGUP_LOG.md`). That bitstream predates the RTL fixes of 2026-10-04 |

Changes made after 2026-10-04 (T-13, T-14, UART vendor patches, the P1–P3 physical-design
hooks) are checked on free tools and wait for the lab xrun run (`Docs/HANDOFF.md` §2).

### Physical design

| Item | State |
|---|---|
| Constraints | `flow/constraints/garuda.sdc`: 28 nm draft, four DIVSEL scenarios. `flow/constraints/asap7/`: validated on ASAP7 |
| RTL hooks | Library ICG (P1), pin-level top over a core without tri-states (P2), named memory macros (P3). Applied, D-28 |
| Exploratory flow | OpenROAD-flow-scripts on ASAP7, mock memories, 320 × 300 µm die: to GDS with DRC 0, LEC identical, setup and hold met in all four modes (`Docs/PD_LOG_2026-10-14.md`) |
| 28 nm | No library and no memory compiler yet. No ASAP7 figure is a 28 nm figure (D-26) |

### Not done

- Owner decisions on open defects, T-12 (P1) first (`Docs/HANDOFF.md` §3).
- Coverage closure; the 27 planned tests that do not exist (AUD-11).
- 28 nm synthesis, memories, pad ring and STA at 250 MHz.
- DFT. No document defines it yet.
- Gate-level simulation.

---

## Repository map

| Path | Contents |
|---|---|
| `rtl/` | Design RTL. `rtl/third_party/` is vendored IP |
| `tb/` | Testbenches, vPlans (`tb/<block>/GARUDA_<BLOCK>_vplan.csv`), UVM environments |
| `sw/` | Boot ROM, chip programs, directed tests, riscv-tests environments |
| `tools/` | Generators, lockstep comparator, DSU model, doc and vendor checks |
| `flow/` | Sign-off criteria, static checks, coverage, regression, constraints, physical design |
| `fpga/kv260/` | KV260 FPGA prototype |
| `Design_Docs/` | Specifications. The `.md` is normative (`Design_Docs/README.md`) |
| `Docs/` | Handoffs, bug register, decision record, dated logs |

To run anything, read `Docs/HOWTO_RUN.md`.

---

## Why build the core from scratch

A forked core gives a working chip faster and a team that does not understand it. The
hazard logic, the CSR read-modify-write path and the cycle on which a CLIC interrupt
redirects fetch are learned only by building them. The team chose to understand one
processor completely, and to attach a coprocessor to a core it owns.

## Team AeroSoC

Seven people, with defined ownership of CPU RTL, the DSU, bus and peripherals, verification,
synthesis and physical design. Industry mentors guide physical design and verification
methodology. Architecture sign-off goes through one person, so the specification stays one
document.
