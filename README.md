# GARUDA

**A 28nm RISC-V SoC, built from bare gates, racing a December tapeout.**

## The Chip, In One Breath

200MHz core domain, 100MHz peripheral domain, 1.45mm die, 40 pins, 28nm. A custom Harvard-architecture pipeline with dual AHB-Lite master ports feeding instruction and data paths independently. A CLIC interrupt controller. A 6-channel DMA engine. An AHB-to-APB bridge gating a standard peripheral set — SPI, I2C, UART, PWM, GPIO — sourced from the VLSI Society so the team's silicon-original effort goes where it matters: the core and the accelerator, not a UART state machine that's been solved a thousand times.

384KB of TCM sits close to the core, sized for control-loop firmware that cannot afford to wait on a cache miss.

This is not a general-purpose application processor pretending to be embedded. It is an embedded processor that knows exactly what it is for.

---

## DSU: The Reason This Chip Exists

Strip away the bus fabric and the peripherals and you are left with the actual point of GARUDA — the **Digital Signal Unit**, a coprocessor bolted directly into the EX stage of the pipeline.

The DSU is a 3-MAC cluster: 16x16 signed multiply, 48-bit accumulators, a 2-cycle pipeline built on a CSA tree (CSA1, a pipeline register, CSA2, then a Kogge-Stone final adder). That structure is not incidental — it exists specifically so the accumulate path never has to chain 48-bit additions inside a single cycle. Collapse it into a behavioral one-liner and the timing closure at 200MHz disappears along with the three-operand MACDOT compression path that makes the cluster worth having.

Ten Custom-0 instructions expose this hardware to software, purpose-built for one job: real-time **artificial potential field (APF) collision avoidance** for autonomous swarm flight. This is a processor that does general-purpose RV32IM work in the morning and vector math for keeping drones from hitting each other in the afternoon, on the same silicon, in the same pipeline stage.

The DSU boundary is frozen. `dsu_top.v` takes the full 32-bit instruction word and returns a 5-bit destination register address — full stop. Everything upstream of that contract can change. The contract itself cannot, because the rest of the core has already been built against it.

---

## Built On a Boundary, Not a Guess

A chip like this lives or dies on whether the spec and the silicon agree. GARUDA's answer to that problem is a hard rule, stated once and enforced everywhere: **when the RTL and the document disagree, the RTL wins.** Diagrams get amended. Hardware does not get reinterpreted to match a drawing made before the hardware existed.

This shows up concretely in the core design document. The original EX-stage result mux specified DSU, then MUL, then ALU as the priority chain — and said nothing about CSR reads. That silence was not a stylistic gap; it was a contradiction, because CSRRW/S/C semantics require a read-modify-write through that exact mux. The fix wasn't a guess. It was tracing the actual read-modify-write requirement back through the spec and inserting `csr_rdata` as the highest-priority input, on the record, with the prior gap logged as a numbered erratum rather than quietly papered over.

That is the discipline this whole project runs on: ambiguity gets resolved and documented, not smoothed over. A spec that lies to its own RTL is worse than no spec at all.

---

## What Is Actually Done

| Block | Status |
|---|---|
| DMA controller | Design doc complete, RTL complete |
| DSU (collision avoidance coprocessor) | Design doc complete, RTL complete, integrated into EX — unverified |
| Core pipeline | Design doc complete (Rev 1.1), RTL complete, elaborates with the real DSU |
| Bus / AHB interconnect + bridge | Pending |
| CLIC | Pending |
| Memory subsystem | Pending |
| Timers | Pending |
| Debug (RISC-V DM v0.13 + JTAG TAP) | Pending |
| VLSI Society peripherals (SPI/I2C/UART/PWM/GPIO) | Integration notes only — no full spec needed |

Five block documents stand between this project and a fully specified chip. None of them are glamorous. All of them are load-bearing.

---

## What's Left Before Silicon Stops Being Negotiable

The blocks that list called out as load-bearing — CSR file, M-mode privilege, trap and exception logic, CLIC trap entry, JAL/JALR, the M-extension, and DSU integration into the core pipeline — are now written and elaborating as one netlist. The three Rev 1.1 gaps flagged in `garuda_core_top.v` are closed: minstret counts real retirement through a dedicated retire tag, WFI is a drain-precise hold, and the machine timer has an actual takeable interrupt path. What has NOT happened is verification: six unit smokes and an elaboration are not a verified core. A bug in the DSU produces a wrong collision-avoidance vector. A bug in the trap path produces a chip that locks up in ways that don't reproduce the same way twice. That asymmetry is why the privilege infrastructure gets the most scrutiny before freeze, not the most lines of code.

After that: multi-master AHB arbitration, the AHB-to-APB bridge clock-domain crossing, riscv-arch-test compliance, a Python golden reference model, a directed test suite, and static timing closure at 200MHz. GDSII is targeted for end of October. Tapeout is December 1.

There is no slack in that sentence.

---

## Why Build a Core From Scratch At All

Because the alternative teaches you how to write a wrapper. Forking Ibex would have produced a working chip faster and a team that understood almost none of it. The five-stage hazard detection, the CSR read-modify-write path, the exact cycle on which a CLIC vectored interrupt has to redirect fetch — none of that knowledge transfers from integrating someone else's core. It only comes from having stalled the pipeline yourself, watched it break, and fixed it.

GARUDA is slower to build and harder to defend in a review where "why didn't you just use Rocket" is a fair question. The answer is that this team didn't set out to integrate a processor. It set out to understand one, completely, by building it — and then to bolt a swarm-collision-avoidance coprocessor onto something it actually owns.

December will say whether that bet paid off.

---

## Team AeroSoC

Seven people, one chip, defined ownership across CPU RTL, the DSU, bus and peripherals, verification, synthesis, and physical design — with industry mentors carrying the physical design and verification methodology stages. Architecture sign-off runs through a single point so the spec stays one document instead of seven opinions.
