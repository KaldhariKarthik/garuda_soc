# Meeting cheat sheet — one page

**Status at 2026-10-14.** Check each number against `Docs/handoff/HANDOFF.md` before a meeting.

## Before you start

```bash
cd ~/garuda_soc
source scripts/setup_env.sh      # first, in each new terminal
make regress                     # run once before the meeting (about 8 min)
```

Keep `Docs/bugs/archive/BUGS_HISTORY.md` and `Docs/handoff/HANDOFF.md` open.

---

## The 60-second story

> GARUDA is an RV32IM SoC with a DSU coprocessor for swarm collision avoidance, for TSMC 28 nm.
> All 22 blocks in the system description have RTL, and the chip boots from SPI flash.
> The full flow ran on Cadence tools on 2026-10-04: block, core, integration and chip
> tests all pass. Each instruction is compared with Spike, and 200 random programs
> (2.46 million instructions) match it. Five UVM environments catch nearly all of the
> defects we planted in the RTL. The open-source physical-design flow takes the chip to GDS
> on ASAP7, with timing met in all four clock modes. That proves the flow and the
> constraints. It does not prove 28 nm timing.

---

## Demo order (each step stands alone)

| # | Command | What to say |
|---|---|---|
| 1 | `make test_boot` | "Six instructions: the first program that ran on this core." |
| 2 | `make regress` | "Each ISA test checks itself, and Spike checks each instruction, store, trap and CSR value." |
| 3 | `make regress_rand SEED=1` | "Random bus wait states. Several defects appeared only with specific stall timing." |
| 4 | `make test_chip_flash` | "The boot ROM reads the image from the SPI pins, checks its CRC and jumps." |
| 5 | `make test_chip_jtag` | "A debugger loads a program over JTAG and runs it." |

To show the evidence, not only PASS: `head -6 sim/regress/add.commit.log`.

---

## Defects worth leading with

1. **I-1:** the instruction port sampled read data in the address phase. The core could not
   execute one instruction.
2. **P-2:** a predicted branch held by a load-use stall was flushed by its own redirect. It
   failed with fast memory and passed with slow memory.
3. **AHB-2:** the arbitration rule in the interconnect spec starved the DMA, the one master
   that must never wait.
4. **T-9:** a trap taken while a load or store waited on the bus lost its redirect. The core
   continued with its CSRs saying it was in the handler. Found by a chip program.
5. **PD-3:** synthesis turned the pin tri-states into plain drivers, so the I²C and GPIO
   inputs read the chip's own outputs. Found by tracing the netlist; fixed by P2.

---

## Numbers

| Item | Value | Source |
|---|---|---|
| ISA tests | 64, 58 of them in Spike lockstep | `make regress` |
| Random programs in lockstep | 200; 2,458,733 instructions | BUGS VER-3 |
| Block testbenches | 15, all pass | `make test_blocks` |
| Chip programs from the pins | 8, all pass, 0 AHB violations | `make test_chip` |
| UVM planted defects caught | CLIC 5/5, timers 22/23, PWM 20/21, GPIO 18/18, clock/reset 19/21 | BUGS VER-1..VER-6 |
| Yosys whole chip (2026-10-12) | 72,809 generic cells, 7,032 flops, 1 latch (the ICG) | `Docs/logs/verification/VERIFICATION_LOG_2026-10-12.md` |
| ASAP7 exploratory P&R (pnr_r7) | 320 × 300 µm, DRC 0, setup and hold met in 4 modes | `Docs/logs/pd/PD_LOG_2026-10-14.md` |

Every planted defect that was not caught has a stated reason in BUGS_HISTORY.md (for example, a
one-flop synchroniser that no RTL simulation can see).

---

## Say these before someone else finds them

- **Some fixes are not yet run on xrun.** T-13, T-14, two UART vendor patches and the
  physical-design top split were checked on free tools only (`Docs/handoff/HANDOFF.md` §2).
- **One P1 is open: T-12.** A second trap inside an interrupt handler leaves the interrupt
  level wrong. The fix changes what handlers read in `mcause`, so it is the owner's call.
- **Coverage is collected, not closed.** CLIC, the IF stage, the CSR file and GPIO are the
  gaps (`Docs/COVERAGE.md`).
- **ASAP7 is not 28 nm.** No 28 nm library or memory compiler is available. The memories in
  the ASAP7 run are mock blocks.
- **No DFT and no gate-level simulation yet.**
- **The KV260 bitstream (2026-09-29) predates the RTL changes of 2026-10-04.** Rebuild it
  before an FPGA demo.

---

## Hard questions

**"How do you know the tests test anything?"** Each UVM environment was run against planted
defects, and the results are in BUGS_HISTORY.md. The Spike lockstep has negative controls.

**"Why are so many first-run failures testbench defects?"** The same team wrote the tests and
the RTL from the same reading of the specs. That is why we use independent oracles: Spike,
protocol checkers, formal, and mutation runs.

**"What next?"** Lab run of the new fixes, the owner's rulings (T-12 first), coverage
closure, then 28 nm implementation when the library arrives.
