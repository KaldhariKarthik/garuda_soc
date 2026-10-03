# GARUDA

**A 28nm RISC-V SoC, built from bare gates, racing a December tapeout.**

## The Chip, In One Breath

250MHz core domain, 125MHz peripheral domain (from a 500MHz reference), 1.45mm die, 40 pins, 28nm. A custom Harvard-architecture pipeline with dual AHB-Lite master ports feeding instruction and data paths independently. A CLIC interrupt controller. A 6-channel DMA engine. An AHB-to-APB bridge gating a standard peripheral set — SPI, I2C, UART, PWM, GPIO — sourced from the VLSI Society so the team's silicon-original effort goes where it matters: the core and the accelerator, not a UART state machine that's been solved a thousand times.

384KB of TCM sits close to the core, sized for control-loop firmware that cannot afford to wait on a cache miss.

This is not a general-purpose application processor pretending to be embedded. It is an embedded processor that knows exactly what it is for.

---

## DSU: The Reason This Chip Exists

Strip away the bus fabric and the peripherals and you are left with the actual point of GARUDA — the **Digital Signal Unit**, a coprocessor bolted directly into the EX stage of the pipeline.

The DSU is a 3-MAC cluster: 16x16 signed multiply, 48-bit accumulators, a 2-cycle pipeline built on a CSA tree (CSA1, a pipeline register, CSA2, then a Kogge-Stone final adder). That structure is not incidental — it exists specifically so the accumulate path never has to chain 48-bit additions inside a single cycle. Collapse it into a behavioral one-liner and the timing closure at 250MHz disappears along with the three-operand MACDOT compression path that makes the cluster worth having.

Ten Custom-0 instructions expose this hardware to software, purpose-built for one job: real-time **artificial potential field (APF) collision avoidance** for autonomous swarm flight. This is a processor that does general-purpose RV32IM work in the morning and vector math for keeping drones from hitting each other in the afternoon, on the same silicon, in the same pipeline stage.

The DSU boundary is frozen. `dsu_top.v` takes the full 32-bit instruction word and returns a 5-bit destination register address — full stop. Everything upstream of that contract can change. The contract itself cannot, because the rest of the core has already been built against it.

---

## Built On a Boundary, Not a Guess

A chip like this lives or dies on whether the spec and the silicon agree. GARUDA's answer to that problem is a hard rule, stated once and enforced everywhere: **when the RTL and the document disagree, the RTL wins.** Diagrams get amended. Hardware does not get reinterpreted to match a drawing made before the hardware existed.

This shows up concretely in the core design document. The original EX-stage result mux specified DSU, then MUL, then ALU as the priority chain — and said nothing about CSR reads. That silence was not a stylistic gap; it was a contradiction, because CSRRW/S/C semantics require a read-modify-write through that exact mux. The fix wasn't a guess. It was tracing the actual read-modify-write requirement back through the spec and inserting `csr_rdata` as the highest-priority input, on the record, with the prior gap logged as a numbered erratum rather than quietly papered over.

That is the discipline this whole project runs on: ambiguity gets resolved and documented, not smoothed over. A spec that lies to its own RTL is worse than no spec at all.

The four block documents written in September put the same rule to work against each other rather than against RTL, and three of them came back with a released document to correct. The memory subsystem spec refused to inherit the claim — carried in both the TRM and the DMA spec — that CPU and DMA accesses to different Data SRAM banks proceed in parallel. Under the frozen interconnect they cannot: Block 6 serialises the masters before either reaches the memory, so the bank map is a locality convention and nothing more. An earlier draft had a bank arbiter inside the Data SRAM; it was deleted, because a block that cannot see two requests cannot arbitrate between them. The clock/reset spec killed a second one: the TRM describes the 100MHz fallback as inserting another divide-by-2 in the core clock path, which read literally would drag pclk down to 50MHz and silently halve every UART divisor, SPI divider and timer prescale on the chip. Fallback now halves the core clock and nothing else, frozen in writing. And the bridge spec replaced the TRM's loose "3-4 core cycles" for a peripheral access with the cycle-accurate figure the FSM actually produces — about 6 pclk, which is 12 core cycles, not 3.

None of those were RTL bugs. All three were a document promising something the hardware around it had already made impossible.

---

## What Is Actually Done

**Rev 4.0 (2026-09-19).** The RTL now implements the Rev 4.0 specification set
(`Design_Docs/garuda_system.yaml` + the `GARUDA-*-SPEC-001` documents); where
those documents contradicted each other the ruling is recorded in
`Docs/DECISIONS.md` (D-4..D-20).

**Provenance of the numbers in this section.** The per-block check counts are
the testbenches' own self-reported totals. Thirteen of them are reproducible
today with no licence at all — `make local_sim`, results and tool versions in
`Docs/VERIFICATION_LOG_2026-10-03.md`. The firmware-dependent rows (the ISA
regression, sanity, and `make test_chip`) need Xcelium and the RISC-V toolchain
and are **not** reproducible from this checkout; `sw/build/` is empty. Nothing
in this repository has been through gate-level simulation or static timing, and
no SDC exists.

| Block (SYS-001 #) | RTL | Verification (Xcelium) |
|---|---|---|
| 1 Core (RV32IM, CLIC mode, WFI clock gate) | complete, Rev 3.0 boundary | ISA 63/63 + Spike lockstep (incl. random wait states), sanity 10/10, unit TBs 0 fail |
| 2 DSU | complete, OVF-1 fixed | 400-vector model check + clamp walk 33 168/0, oracle sweep 0 disagreements |
| 3/4/5 ISRAM / Boot ROM / DSRAM | complete (sync-read macro wrapper, ILOCK) | `tb_mem` 18/18 |
| 6 AHB-Lite interconnect (4 masters) | complete | `tb_ahb_ic` 802/802 |
| 7/8 APB fabric + AHB2APB bridge (synchronous) | complete | `tb_bridge` 20/20 |
| 9 DMA (Rev 3.0, no CDC) | complete | `tb_dma` 25/25 |
| 10 CLIC (level-only, 32 IDs) | complete | `tb_clic` 15/15 |
| 11 Timers + watchdog | complete | `tb_timers` 23/23 (real watchdog reset through reset_ctrl) |
| 12 Debug (JTAG TAP, DTM, DMI CDC, DM, SBA) | complete | `tb_debug` 25/25 over the JTAG pins |
| 21/22 Clock divider + reset controller | complete | `tb_crg` 43/43 |
| Boot ROM firmware | complete (flash path waits on the SPI IP) | runs on every chip test |
| **SoC + chip integration** (`garuda_soc_top`, `garuda_chip_top`, 28-pin list) | **complete** | `make test_chip`: boot, interrupts (DMA/timer/WDT), real watchdog reset, JTAG load-and-run — all pass, zero AHB protocol violations |
| 13, 15–20 SPI-M, I²C, UART×3, GPIO, PWM (sourced IP) | **complete** — all seven are in `rtl/`, wired in `garuda_chip_top`, and the chip boots from SPI flash | `tb_i2c` 42/42, `tb_pwm` 26/26, `tb_spis` 32/32 reproducible locally; `tb_spim`, `tb_uart`, `tb_gpio` need xrun (Icarus cannot build the vendored PULP RTL — see the verification log) |

Not done: coverage closure, SDC/STA, gate-level
simulation, the foundry SRAM/ROM macros (behavioural models behind
`sram_wrapper.v`), the pad ring. Those are the path from here to GDSII.

> **Superseded.** A second, older status table and its headline numbers used to
> sit here, describing the Rev 2.0 chip: "six testbenches / 1,007 self-checking
> assertions", "50,535 cells with zero latches", DSU "unverified", Timers and
> Debug "Pending", the peripherals "integration notes only". All of it has been
> overtaken by the table above, and three of the figures were wrong rather than
> merely old:
>
> - **"1,007 self-checking assertions" cannot be reproduced.** It was
>   `27+37+33+25+796+89`, and the 89 came from `tb/soc/tb_soc_ahb.sv`, which was
>   deleted in `36e9630`. The current figure is **1,219** across 14
>   testbenches, and `make local_sim` regenerates it on demand.
> - **"50,535 cells" is stale.** It predates I²C, GPIO, PWM, the SPI slave and
>   `pipe_ctrl_sva`. The chip is now **71,819** cells and **7,029** flops.
> - **"Zero latches inferred" was never true.** There is exactly **one**, and it
>   is `core_clk_gate`'s ICG enable latch — which is the cell, not a mistake;
>   Genus reports the same one. The gate that printed "zero" was broken: it
>   grepped its own log for a pattern that never matched the text Yosys writes.
>   Fixed and given a negative control (`TOOL-7`).
>
> The one claim in that block that has held up exactly is the reason it is worth
> keeping the caveat: the testbenches were written by the same hand, at the same
> sitting, from the same reading of the specifications as the RTL, so a shared
> misreading would pass both. **The first run of every new testbench failed, and
> every one of those failures was a defect in the testbench, not the RTL.** That
> pattern continued on 2026-10-03: five more testbench defects and five more
> tooling defects, no new RTL defects. The tests remain the less trustworthy
> half, and independent verification is still owed.

---

## What's Left Before Silicon Stops Being Negotiable

The blocks that list called out as load-bearing — CSR file, M-mode privilege, trap and exception logic, CLIC trap entry, JAL/JALR, the M-extension, and DSU integration into the core pipeline — are now written and elaborating as one netlist. The three Rev 1.1 gaps flagged in `garuda_core_top.v` are closed: minstret counts real retirement through a dedicated retire tag, WFI is a drain-precise hold, and the machine timer has an actual takeable interrupt path. What has NOT happened is verification: six unit smokes and an elaboration are not a verified core. A bug in the DSU produces a wrong collision-avoidance vector. A bug in the trap path produces a chip that locks up in ways that don't reproduce the same way twice. That asymmetry is why the privilege infrastructure gets the most scrutiny before freeze, not the most lines of code.

After that: multi-master AHB arbitration, the AHB-to-APB bridge clock-domain crossing, riscv-arch-test compliance, a Python golden reference model, a directed test suite, and static timing closure at 250MHz.

The bridge, CLIC, memory and clock/reset blocks have moved from "unwritten" to "written, simulating and synthesising." Writing them surfaced two defects in released specifications that would each have reached silicon quietly — a bridge that drops every second back-to-back peripheral write, and a whole-chip reset asserted for 5ns — and both are fixed in RTL, logged, and now have tests that fail without the fix.

What is still missing is the part that decides a tapeout. The interrupt path **does** fire — `sw/chip/t_chip_irq.c` enables `mstatus.MIE`, sets `DMA_CR_IECOMP` and takes DMA-completion, machine-timer and watchdog-warning interrupts through a real trap handler, so the earlier "never fires" note here is obsolete. What has *not* happened is the rest: nothing in this repository has been through gate-level simulation or static timing, no SDC exists (`AUD-4`), and the one synthesis that can be run is generic structural synthesis with no library — so a **71,819**-cell netlist says the design is structurally sound and says nothing at all about closing 250 MHz. Coverage on all 15 Rev 4.0 blocks is still zero. GDSII is targeted for end of October. Tapeout is December 1.

There is no slack in that sentence.

---

## Why Build a Core From Scratch At All

Because the alternative teaches you how to write a wrapper. Forking Ibex would have produced a working chip faster and a team that understood almost none of it. The five-stage hazard detection, the CSR read-modify-write path, the exact cycle on which a CLIC vectored interrupt has to redirect fetch — none of that knowledge transfers from integrating someone else's core. It only comes from having stalled the pipeline yourself, watched it break, and fixed it.

GARUDA is slower to build and harder to defend in a review where "why didn't you just use Rocket" is a fair question. The answer is that this team didn't set out to integrate a processor. It set out to understand one, completely, by building it — and then to bolt a swarm-collision-avoidance coprocessor onto something it actually owns.

December will say whether that bet paid off.

---

## Team AeroSoC

Seven people, one chip, defined ownership across CPU RTL, the DSU, bus and peripherals, verification, synthesis, and physical design — with industry mentors carrying the physical design and verification methodology stages. Architecture sign-off runs through a single point so the spec stays one document instead of seven opinions.
