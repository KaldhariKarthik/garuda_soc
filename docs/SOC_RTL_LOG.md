# GARUDA SoC — RTL implementation log

**Running log for SoC-level RTL: what was built, why it was built that way, and
what is still unproven.**

This is the counterpart to `docs/DMA_RTL_LOG.md` (Block 9) and the place where
Blocks 3/4/5/6/7/8 and the SoC top will be recorded as they are written. Bugs go
in `docs/BUGS.md`, not here — this file is the *reasoning*, that one is the
*register*.

---

## Session 2026-09-12 — Block 6 (AHB-Lite interconnect) and first SoC integration

Branch `main`. **Nothing committed.**

### 0. Status in one paragraph

The AHB-Lite interconnect (Block 6) is written, lints, synthesises, and passes a
72-run block-level regression (57,312 checks, 0 failures) with four AHB-Lite
protocol checkers clean — including one on the slave-side bus, which is the only
place a fabric bug is visible. The core (with the real DSU), the DMA and the
interconnect are wired together in `rtl/soc/garuda_soc_top.v` and boot a real
instruction stream that programs the DMA over an AHB-to-APB bridge and moves 64
words while all three masters contend; that passes across 28 timing
configurations. **Three defects in the interconnect specification were found and
fixed in RTL, one of which (AHB-2) silently starves the DMA and one of which
(AHB-4) deadlocks the SoC at reset.** Five mutation tests confirm the regression
actually catches each fix. None of this has been compiled by the team's
simulator, no coverage was collected, no SDC exists, and the memories and bridge
are testbench models. Sections 8–10 say precisely what is and is not proven.

### 1. What was asked, and what was delivered

| Asked | Delivered |
|---|---|
| Read the design docs | `Design_Docs/AHB_Int/GARUDA_AHB_Bus_Design_Spec_v2.0.docx` (GARUDA-AHB-SPEC-001 Rev 2.0) read in full; cross-read against the frozen core and DMA boundaries. |
| Do the AHB RTL | `rtl/ahb/` — 8 files, 1,212 lines, top `ahb_interconnect`. |
| Verify the DMA has no bugs **before** wiring | Full DMA regression re-run (72 runs, 49,020 checks, 0 failures) plus a line-by-line review of all 11 DMA RTL files. One new open finding (**DMA-3**). |
| Wire DMA + DSU + core with AHB | `rtl/soc/garuda_soc_top.v`, and a SoC testbench that runs a real program through all three masters. |
| A log for the DMA work | `docs/DMA_RTL_LOG.md` §16 (this session's addendum). |
| A bugs file for everyone, old and new | `docs/BUGS.md`. |
| A log for the AHB/SoC work | This file. |

### 2. Files created

**RTL — `rtl/ahb/` (Verilog-2001, per repo convention)**

| File | Lines | Purpose |
|---|---:|---|
| `ahb_defs.vh` | 86 | Master/slave indices, region decode, AHB constants. Single source of truth; the master index is a contract between the arbiter, the mux and the top. |
| `ahb_decoder.v` | 51 | Combinational `HADDR[31:28]` → one-hot HSEL. The default slave shares the vector so `$onehot(hsel)` holds for **every** address, with no exception for a consumer to handle. |
| `ahb_arbiter.v` | 200 | Fixed-priority encoder + grant freeze + data-phase tracking + burst-break flag. All the block's control state except the data-phase select. |
| `ahb_master_mux.v` | 149 | 3:1 address/control mux on the grant; **HWDATA mux on the data-phase owner** (ERRATUM AHB-1); HPROT substitution for the DMA; SEQ→NONSEQ rewrite (ERRATUM AHB-3). |
| `ahb_master_port.v` | 179 | Per-master HREADY gating and the one-deep response hold (ERRATUM AHB-2 / AHB-4). Instanced 3×. |
| `ahb_slave_mux.v` | 135 | Registered data-phase select + read-data/HREADY/HRESP return muxes. |
| `ahb_default_slave.v` | 104 | Two-cycle ERROR responder, 3-state Moore FSM. |
| `ahb_interconnect.v` | 308 | Block boundary and wiring. |
| `filelist.f` | 27 | Synthesis file list, bottom-up. |

**RTL — `rtl/soc/`**

| File | Lines | Purpose |
|---|---:|---|
| `garuda_soc_top.v` | 277 | Core (+DSU) + DMA + interconnect. Exposes the four slave-side AHB ports, the DMA APB port and the CLIC/timer interface, because Blocks 3/4/5/7/8/20 do not exist. |
| `filelist_soc.f` | 31 | Pulls `filelist_core_dsu.f` (real DSU, never the stub) + DMA + AHB. |

**Verification — `tb/ahb/`, `tb/soc/`**

| File | Lines | Purpose |
|---|---:|---|
| `tb/ahb/ahb_lite_sram.v` | 286 | AHB-Lite slave **model** with HSEL + global HREADY, byte enables, wait states, two-cycle ERROR, backdoor. Stands in for Blocks 3/4/5. |
| `tb/ahb/ahb_lite_master_bfm.sv` | 215 | Queue-driven compliant AHB-Lite master BFM with a tagged response queue. |
| `tb/ahb/ahb2apb_bridge_model.v` | 253 | Block 8 stand-in with a **real** 200→100 MHz toggle handshake. |
| `tb/ahb/tb_ahb_interconnect.sv` | 812 | 20 directed tests covering every row of spec §12, plus four for the errata. |
| `tb/soc/tb_soc_ahb.sv` | 462 | SoC integration testbench: boots a program, checks the DMA result independently, and asserts all three masters were actually on the bus. |
| `tb/soc/soc_dma_smoke.hex` | 83 | Generated boot image. |
| `tb/ahb/filelist_ahb_ic.f`, `tb/soc/filelist_soc_ahb.f` | 41 | TB file lists. |

**Software and tools**

| File | Lines | Purpose |
|---|---:|---|
| `sw/tests/soc_dma_smoke.S` | 175 | The SoC test program. Plain GNU as syntax, builds with the real toolchain too. |
| `tools/gen/mini_rv32_asm.py` | 302 | Stopgap RV32I assembler — see §7. |

**Nothing outside `rtl/ahb/`, `rtl/soc/`, `tb/`, `sw/tests/`, `tools/gen/` and
`docs/` was created or modified. The shared `Makefile` was deliberately not
edited** — see §11.

### 3. The three specification defects, and why each one matters

Full detail is in `docs/BUGS.md` §2. The short version, because these are the
design content of this block:

**AHB-1 — HWDATA is a data-phase signal.** Spec §3.1 lists HWDATA among the
signals the master mux steers from *the granted master*. It is sampled by the
slave one cycle after the address phase it belongs to. Following the spec
literally means every master hand-off writes the wrong master's data. The DMA is
the concrete victim: `dma_ahb_master` drives HTRANS=IDLE in `S_WDATA` precisely
so the bus can be handed on, so its destination buffer would silently receive the
D-Port's store data with every status bit reading success.

**AHB-2 — the prescribed arbitration rule starves the DMA.** §7.2 (re-sample the
grant every HREADY-high boundary) and §7.3 (hold ungranted masters with
HREADY=0) cannot both be applied literally, because an AHB-Lite master has no
HGRANT and therefore cannot distinguish "your data phase completed" from "your
address phase was accepted". The obvious safe resolution — never move the grant
off a master that is still requesting — starves the DMA, because
`garuda_iport_ahb_master` can request on every cycle indefinitely on
straight-line code. The lowest-priority master would hold an unbounded lock on
the bus, defeating the entire rationale for fixed priority in §7.1. Resolved
with a one-deep response hold per master. **This was found by tracing the
arbiter against the real I-Port RTL, not by simulation** — the first version of
`ahb_arbiter.v` contained the starving rule and passed everything written at the
time, because no test yet had a master that requested forever. T12 was written
afterwards to make it fail.

**AHB-4 — §7.3 applied to an idle master deadlocks the chip.** The I-Port needs
HREADY high to *present* the HTRANS the arbiter grants on. Gating an idle
master's HREADY means the reset-vector fetch never happens. Dead chip, no error
anywhere.

**AHB-3** (an interrupted INCR reaching the slave as an orphan SEQ) is smaller
but real; it is fixed on the interconnect side rather than by touching the frozen
core boundary.

### 4. Design decisions worth recording

**Grant freeze, not a combinational grant.** The priority pick is combinational
but `grant_o` is frozen from the first cycle an address phase is presented until
the slave accepts it. The DMA is the concrete threat: `dma_ahb_master` leaves
`S_IDLE` on its *internal* beat-start handshake, which is not qualified with the
external HREADY, so it can raise HTRANS from IDLE to NONSEQ **in the middle of
another master's wait state**. A combinational grant would swing HADDR/HSIZE
under a live, unaccepted address phase — the exact failure §7.2 warns about.

**The response hold is one entry deep, and that is provably enough.** A master
whose response has been captured is stalled with HREADY=0, so it cannot accept
its held address phase, cannot issue a new one, and has no further data phase in
flight. No second capture can occur before the first is delivered. The
testbench asserts it rather than trusting the argument.

**The default slave shares the one-hot HSEL vector.** A decoder whose output is
"one-hot unless nothing matched" needs the exception handled at every consumer.
This one does not.

**HRDATA and HRESP go only to the data-phase owner.** All three GARUDA masters
happen to qualify HRESP with their own outstanding-transfer flag, so broadcasting
it would be harmless *today* — which is precisely the kind of "harmless today"
that the next master added to this bus will not be.

**Memories and the bridge are in `tb/`, not `rtl/`.** Blocks 3/4/5/8 have design
specifications that have not been written. A guessed SRAM in `rtl/` would have to
be un-guessed later, and in the meantime every test would be quietly validating
the guess. `garuda_soc_top` exposes their ports instead; when the specs arrive,
each group moves inside and disappears from the port list, and nothing else about
that file needs to change.

**The bridge model does a real 200→100 MHz crossing.** Tying `pclk` to `hclk`
would have been far less work and would have turned the DMA's entire CDC design
into dead logic — every toggle handshake, every gray coder and the ERRATUM DMA-1
fix only do anything at a real clock ratio. A 1:1 "bridge" would make the SoC
test *look* like it covered the CDC while covering none of it. `pclk` is also
deliberately skewed 1.3 ns off `hclk`, for the same reason `tb_dma_top.sv` does
it: a phase-aligned divided clock is the easy case.

### 5. Toolchain

Same portable setup as the DMA session; nothing installed system-wide.

| Tool | Version | Role |
|---|---|---|
| Icarus Verilog | `14.0 (devel) s20260301-434-g79c42a156-dirty` | compile + simulate |
| Verilator | `5.053 devel rev v5.052-61-g4aeb3dbc5 (mod)` | lint only |
| Yosys | `0.69+24 (git sha1 d0e71cfb7-dirty)` | synthesis check |
| Bundle | `oss-cad-suite-windows-x64-20260912.tgz` (596 MB) | portable, scratchpad only |

**Exact commands**

```bash
export PATH="$SCRATCH/oss-cad-suite/lib:$SCRATCH/oss-cad-suite/bin:$PATH"
export VERILATOR_ROOT="$SCRATCH/oss-cad-suite/share/verilator"

AHB="rtl/ahb/ahb_decoder.v rtl/ahb/ahb_master_mux.v rtl/ahb/ahb_arbiter.v \
     rtl/ahb/ahb_master_port.v rtl/ahb/ahb_slave_mux.v \
     rtl/ahb/ahb_default_slave.v rtl/ahb/ahb_interconnect.v"

# Block 6 testbench
iverilog -g2012 -I rtl/ahb -o ic.vvp -s tb_ahb_interconnect \
         $AHB tb/ahb/ahb_lite_sram.v tb/ahb/ahb_lite_master_bfm.sv \
         tb/ahb/ahb_lite_checker.v tb/ahb/tb_ahb_interconnect.sv
vvp ic.vvp +GWAIT=6 +GRAND=1 +SEED=1 [+VERBOSE]

# SoC integration testbench
python tools/gen/mini_rv32_asm.py sw/tests/soc_dma_smoke.S \
       -o tb/soc/soc_dma_smoke.hex --base 0x10000000
iverilog -g2012 -I rtl/common -I rtl/core -I rtl/dsu -I rtl/dma -I rtl/ahb \
         -o soc.vvp -s tb_soc_ahb \
         $(grep -hE '^rtl/' rtl/core/filelist_core_dsu.f rtl/dma/filelist.f \
                             rtl/ahb/filelist.f) \
         rtl/soc/garuda_soc_top.v tb/ahb/ahb_lite_sram.v \
         tb/ahb/ahb2apb_bridge_model.v tb/ahb/ahb_lite_checker.v \
         tb/soc/tb_soc_ahb.sv
vvp soc.vvp +IWAIT=3 +DWAIT=6 +RANDW=1 +SEED=1

# lint
verilator_bin --lint-only -Wall -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
              +incdir+rtl/ahb --top-module ahb_interconnect $AHB

# synthesis
yosys -p "read_verilog -I rtl/ahb $AHB; hierarchy -top ahb_interconnect; \
          synth -top ahb_interconnect -flatten; stat"
```

**Not run:** Xcelium (`xrun`), VCS, Vivado `xsim`, Genus. None are available on
this Windows machine.

### 6. Results

#### 6.1 Simulation

| Testbench | Configurations | Checks | Failures |
|---|---|---:|---:|
| `tb_ahb_interconnect` | 6 wait configs × 12 seeds = **72 runs** | **57,312** | **0** |
| `tb_soc_ahb` | 7 wait configs × 4 seeds = **28 runs** | **2,296** | **0** |
| `tb_dma_top` (re-run, unchanged RTL) | 6 wait configs × 12 seeds = **72 runs** | **49,020** | **0** |

All four AHB-Lite protocol checkers report **0 violations** in every
configuration, including the slave-side one.

#### 6.2 Block 6 test list

| # | Test | What it actually checks | Spec §12 row |
|---|---|---|---|
| T0 | Reset | HTRANS=IDLE, no data phase, **HREADY high before any transfer** (without which the reset-vector fetch never starts) | Reset |
| T1 | Decode | One transfer to each of the four regions, correct data from each | Decode coverage |
| T1b | Boundaries | base and base+size−4 of ISRAM and DSRAM | Decode coverage |
| T2 | HSEL | One-hot on **every cycle** of the whole run, not just sampled | Decode coverage |
| T3 | Default slave | Unmapped read and write both return ERROR; the next mapped access is OKAY and correct; the master saw a compliant two-cycle response | Default slave |
| T3b | Back-to-back faults | Four consecutive unmapped accesses all retire (a runaway PC does not hang the bus) | Default slave |
| T4 | Priority | All three masters present simultaneously; accepted in order DMA → D-Port → I-Port; each gets **its own** data | Arbitration |
| T5 | Hold rule | Grant never moved while HREADY was low; the held I-Port's HADDR/HTRANS/control never moved and it never retracted | Per-master hold |
| T6 | Data-phase select | 32 transfers cycling ISRAM→DSRAM→BRIDGE→ROM; every word from the right slave **and** the right address | Data-phase select |
| T7 | Writes | Byte/halfword merge into a word; a write to ROM answers OKAY and changes nothing | *(added)* |
| T8 | Wait states | 16 transfers under randomised waits, all data correct | Wait-states |
| T9 | Injected ERROR | OKAY before, ERROR on, OKAY after; two-cycle at both the master and the slave bus | Two-cycle ERROR |
| T9b | ERROR not broadcast | Only the faulting master's response is ERROR; the other two stay OKAY in the same window | *(added)* |
| T10 | HPROT | I-Port's HPROT reaches the slave unchanged; `hprot_o == 0x3` on **every** DMA-granted cycle | HPROT pass-through |
| T11 | INCR burst | Uninterrupted 8-beat INCR, data in order, no orphan SEQ on the slave bus | Burst split |
| **T12** | **DMA starvation** | 64 back-to-back I-Port beats with gap 0 (a master that requests every cycle); DMA granted within **2 arbitration boundaries** of asking | *(ERRATUM AHB-2)* |
| **T13** | **Response hold** | All 64 preempted I-Port beats retire with **their own** data, in order | *(ERRATUM AHB-2)* |
| **T14** | **HWDATA ownership** | DMA writes survive a hand-off during their data phase | *(ERRATUM AHB-1)* |
| **T15** | **Burst split** | No orphan SEQ, no SEQ-after-IDLE, no address discontinuity on the slave bus | *(ERRATUM AHB-3)* |
| T16 | Soak | 8 rounds × 24 transfers × 3 masters, random slaves and gaps; every response matched against the addressed slave's memory | *(beyond spec)* |

#### 6.3 Mutation testing — do the tests actually catch the bugs?

A green regression proves nothing unless it goes red for the right reason. Each
fix was reverted in a scratch copy and the regression re-run:

| Mutation | Change | Result |
|---|---|---|
| MUT-1 | HWDATA muxed on `grant` (i.e. as spec §3.1 says) | **8 failures**, all T14 |
| MUT-2 | `force_owner` reinstated (spec §7.2 literally) | **1 failure**, T12 — DMA starved |
| MUT-3 | Response hold disabled | **39 failures**, T13 and the soak |
| MUT-4 | SEQ→NONSEQ rewrite removed | slave-side checker: **79** `SEQ following a SINGLE burst` |
| MUT-5 | Data-phase select bypassed (use address-phase HSEL) | **394 failures** across T1, T13, T16 |

5 of 5 caught, each by the test that claims to cover it.

#### 6.4 Lint

`rtl/ahb`: **5 warnings, all documented and stable**, all of the form "only bit 1
of this HTRANS is used" or "only the top nibble of this HADDR is decoded":

| Signal | Why it is correct |
|---|---|
| `ahb_decoder.haddr_i[27:0]` | Region decode is on `[31:28]` by spec §6. The rest is the slave's business. |
| `ahb_arbiter.req[0]` | The priority cascade falls through to the I-Port, whose HTRANS is IDLE when it is not requesting. Reading `req[0]` would add a gate and change nothing. |
| `ahb_arbiter.granted_htrans[0]` | Only HTRANS[1] distinguishes a transfer from IDLE/BUSY. |
| `ahb_master_port.htrans_i[0]` | Same. |
| `ahb_default_slave.htrans_i[0]` | Same. |

Any *new* warning is a real regression signal.

Across the **whole SoC** hierarchy the only warning categories at all are
`UNUSEDSIGNAL` and `UNUSEDPARAM` — no latches, no width problems, no
multiply-driven nets, no async/sync reset confusion flagged by Verilator.

#### 6.5 Synthesis (Yosys, generic mapping)

**Block 6 alone:**

```
Checking module ahb_interconnect...  Found and reported 0 problems.  (x3)
694 wires · 772 cells · 132 public wires
Flip-flops: 11 $_DFFE_PN0P_ + 5 $_DFF_PN0_ + 1 $_DFF_PN1_ = 17
Latches:    0
```

17 flops is the whole of the block's state: `grant_r` (2), `hold_r` (1),
`dph_valid`/`dph_master` (3), `last_owner` (3), `dph_sel` (5), default-slave
state (2), plus the response-hold flops inside each `ahb_master_port`. That is
consistent with spec §13.2's "~30 gates" claim for the arbiter itself.

**Whole SoC:** blocked by two **pre-existing** defects in the core and DSU
(`CORE-1` and `DSU-10` in `docs/BUGS.md`) — not by anything written this
session. With both fixes applied in a scratch copy, `garuda_soc_top`
synthesises:

```
Found and reported 0 problems.  (x3)
34,395 wires · 38,101 cells
Flip-flops: 4,371    Latches: 0
```

(992 of those flops are the register file, which correctly has no reset.)

### 7. The software problem, and how it was worked around

The SoC testbench needs the CPU to program the DMA, because that is the whole
point: a testbench that configures the DMA from a TB-side APB master proves the
DMA works, not that the CPU can reach it through the D-Port, the interconnect
and the bridge. The real flow is `sw/Makefile` + `tools/elf2hex.py` and needs
`riscv32-unknown-elf-gcc`, which is **not installed on this machine**.

`tools/gen/mini_rv32_asm.py` is a deliberately tiny stopgap: the RV32I subset the
test needs, `li`/`j`/`mv`/`nop`, labels, `.word`, one section, no relaxation, no
ELF. `sw/tests/soc_dma_smoke.S` is written in plain GNU as syntax so it builds
either way. **When `riscv-gcc` is available, build it with the real flow and
delete the generated `.hex`.**

The DSU sequence in the program is `.word` directives because the assembler has
no Custom-0 support and `gas` would need `.insn` anyway. The layout is
transcribed from `rtl/dsu/dsu_decoder.v` and commented in the `.S`.

### 8. ✅ Proven by simulation

- **Address decode** to all four regions plus the default slave, at region base
  and top, with HSEL one-hot on every cycle of every run.
- **Fixed priority** DMA > D-Port > I-Port, verified by acceptance order with
  all three masters presenting simultaneously.
- **Grant stability**: the grant never changed while HREADY was low, across
  every configuration.
- **Per-master hold**: a held master's HADDR, HTRANS, HSIZE, HBURST and HWRITE
  never moved, and no master ever retracted a transfer (master-side checkers).
- **Preemption of a continuously-requesting master** with no lost data, no lost
  ordering, and a bound of 2 arbitration boundaries.
- **Data-phase slave select** under back-to-back transfers to four different
  slaves, checked against both the slave *and* the address.
- **HWDATA ownership** across a master hand-off mid-data-phase.
- **Two-cycle ERROR** end to end: from a mapped slave, from the default slave,
  back-to-back, and not broadcast to masters that were not faulting.
- **HPROT** pass-through and the DMA's `0x3` substitution on every granted cycle.
- **Burst legality on the slave-side bus** — no orphan SEQ, no SEQ-after-IDLE,
  no address discontinuity, HBURST constant within each burst.
- **SoC integration**: a real instruction stream boots from ROM, exercises the
  **real DSU** through Custom-0 (confirmed independently via `dbg_acc_0`),
  programs the DMA across a 200/100 MHz bridge, and moves 64 words correctly
  while the I-Port fetches from ROM and the D-Port polls over the bridge.
  All three masters were verified to have actually been on the bus (grants
  I=1702, D=284, DMA=128 in the nominal run) — a SoC test that quietly never
  granted the DMA would otherwise look identical to one that did.
- **Bounded DMA latency on real traffic**: longest request-to-grant wait is
  12–13 hclk, set by the bridge's data phase rather than by arbitration.

### 9. ⚠️ Lint / synthesis clean only — NOT functionally verified

- **Synthesisability** — Yosys generic mapping only. No Genus, no real library,
  no timing, no area signoff, no DFT.
- **Zero latches / zero CHECK problems** — structural, proves nothing functional.
- **Verilog-2001 conformance** — `-g2005` compile only.
- **Whole-SoC synthesis** — only demonstrated with two pre-existing defects
  patched in a scratch copy; the repository as it stands does **not** synthesise
  end to end.

### 10. ❌ NOT verified — gaps and risks

| Area | Why it is unverified | Risk |
|---|---|---|
| **The real memories (Blocks 3/4/5)** | Do not exist. Everything here ran against `tb/ahb/ahb_lite_sram.v`. Bank arbitration inside the Data SRAM — spec §13.4's flagged open item — is entirely unmodelled. | **High** |
| **The real bridge (Block 8)** | Does not exist. `ahb2apb_bridge_model.v` is a plausible stand-in, not a specification-derived design; it has no write posting and no APB wait states. §9.1's latency numbers are wrong against it (AHB-5). | **High** |
| **Team toolchain (Xcelium / VCS / xsim)** | Only Icarus was available. Different simulators disagree on variable part-selects (`htrans_i[2*grant_o +: 2]` is used in `ahb_arbiter.v`), unpacked arrays and hierarchical references in testbenches. | **Medium — likely to surface compile issues on first VCS run.** |
| **Coverage (code + functional)** | **None collected.** Spec §12 requires decode, arbitration-FSM and data-phase-select coverage. `ahb_slave_mux.dph_sel_o` is exposed unconnected specifically so `tb/cov/` can bind to it. | **Medium — a signoff requirement that is entirely unmet.** |
| **STA / timing closure** | No synthesis with a real library, no SDC. §9.1 claims zero interconnect wait states and folded combinational delay; the decode→mux→slave path and the return mux are both combinational and unmeasured. | **High** |
| **CLIC integration (Block 7)** | `dma_irq`/`dma_err` and the core's CLIC port are exposed at the SoC boundary and driven to zero in the testbench. **No interrupt was ever delivered.** | **Medium** |
| **DMA interrupt-driven flow** | The SoC test polls `SR.COMPLETE`. `CR.IE`/`CR.EIE` and the ISR path are untested at SoC level. | Medium |
| **DMA peripheral transfers through the bridge** | The SoC test is M2M. A P2M transfer whose *source* is a peripheral FIFO behind the bridge — the flagship IMU case — has never run through the real path. The DMA block TB covers P2M against a direct slave only. | **Medium — this is the headline use case.** |
| **`dma_req`/`dma_ack` at SoC level** | Tied low. Never exercised through the integrated design. | Medium |
| **Reset asserted mid-transfer** | Reset is applied only at time 0 in every testbench. | **Medium** |
| **Reset-release skew between hclk and pclk** | Released together by the testbench, as §17.5 requires of Block 23. Behaviour when they are skewed is untested. | Medium |
| **Bus error reaching the CPU as a precise fault** | The default slave's ERROR is verified at the fabric boundary; that it lands as a correct `mepc`/`mcause` in the core has not been tested at SoC level. | Medium |
| **INCR bursts crossing a region boundary** | The I-Port enforces the 1 KB rule itself (ERRATUM BUS-D) and the decoder is per-transfer, so this should be safe by construction. Not directly tested. | Low |
| **More than 3 masters / 4 slaves** | The arbiter and muxes are hand-written for exactly this configuration. | Low |
| **The `v_retract` checker false positive** | `TB-15` in `docs/BUGS.md`: the protocol checker will flag the DMA's AMBA-legal error cancel the first time a SoC test injects a bus error into a DMA read. | Low |

### 11. Recommended next steps

**In priority order:**

1. **Apply `CORE-1` and `DSU-10`** (`docs/BUGS.md` §4, §5). Both are one-line
   classes of change, both are validated as unblocking full-SoC synthesis, and
   both should be applied by the block owner with that block's testbench re-run.
   Until then the SoC does not synthesise.

2. **Compile everything under VCS before anything else.** Expect fixes. The
   riskiest constructs are `htrans_i[2*grant_o +: 2]` in `ahb_arbiter.v` and the
   hierarchical references the testbenches use to reach BFM queues.
   ```
   vcs -sverilog -full64 -debug_access+all -f tb/ahb/filelist_ahb_ic.f \
       -top tb_ahb_interconnect -l comp.log
   ./simv +GWAIT=6 +GRAND=1 +SEED=1
   ```

3. **Add the Makefile targets** — *not done here; the shared `Makefile` was
   deliberately not edited, following the precedent set for the DMA.* Suggested:
   ```make
   test_ahb_ic:
   	$(call run_test,tb/ahb/filelist_ahb_ic.f,tb_ahb_interconnect)

   test_soc_ahb:
   	$(call run_test,tb/soc/filelist_soc_ahb.f,tb_soc_ahb)

   regress_ahb:
   	@for w in 0 1 2 4 6 10; do for s in 1 2 3 4 5 6 7 8 9 10 11 12; do \
   	   $(XRUN) -f tb/ahb/filelist_ahb_ic.f -top tb_ahb_interconnect \
   	     +GWAIT=$$w +GRAND=1 +SEED=$$s | grep -E "RESULT"; done; done
   ```

4. **Write the SDC.** The interconnect itself is single-domain and needs only
   normal constraints, but the SoC needs `set_false_path` on every `dma_cdc_*`
   and on the bridge's crossings, plus a multi-cycle or false path on the DMA's
   quasi-static config bus. Without these, STA either fails spuriously or —
   worse — passes while the crossings are unconstrained.

5. **Collect coverage.** Follow the `tb/cov/garuda_cov.sv` `bind` pattern.
   `ahb_slave_mux.dph_sel_o` and `ahb_arbiter.grant_o` are the two signals spec
   §12 actually needs.

6. **Write the P2M-through-the-bridge test.** The IMU case in DMA spec §13.2 is
   the reason this SoC exists and it has never run through the real path. It
   needs an APB FIFO peripheral model and `dma_req` driven from its occupancy —
   `tb/dma/dma_ahb_slave_model.sv` already has the pop-on-read FIFO logic to
   borrow.

7. **Deliver interrupts.** Even a trivial CLIC model would let the SoC test use
   `CR.IE` and an ISR instead of polling, which is how firmware will actually
   use this block.

8. **Fix the `v_retract` false positive** in `tb/ahb/ahb_lite_checker.v` before
   step 6, or step 6 will report a violation that is not one.

### 12. Bottom line

**What was achieved:** a complete, spec-traceable, synthesisable AHB-Lite
interconnect (`rtl/ahb/`, 8 files, 1,212 lines) with a 72-run self-checking
regression that is mutation-proven to catch every fix it claims; the first
integration of the CPU core, the DSU and the DMA onto one bus
(`rtl/soc/garuda_soc_top.v`); and a SoC testbench that boots real code, drives
all three masters concurrently against three different slaves, and checks the
result independently of the software's own verdict. Three defects in the
interconnect specification were found and resolved on the record — one of which
deadlocks the chip at reset and one of which silently starves the DMA — along
with two pre-existing synthesis blockers in the core and DSU.

**What this is not:** a verified SoC. It has never been compiled by the team's
simulator, has zero coverage, has no timing constraints, runs against modelled
memories and a modelled bridge, has never delivered an interrupt, and has never
moved a byte to or from a real peripheral. And as `TB-11` in `docs/BUGS.md`
records — a seed sweep in *this session* that silently was not varying anything —
a green regression is only as trustworthy as the infrastructure underneath it.
