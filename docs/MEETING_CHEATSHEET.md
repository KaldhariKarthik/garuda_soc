# Meeting cheat sheet — one page

## Before you start

```bash
cd ~/garuda_soc
source scripts/setup_env.sh      # MUST be first in every new terminal
make regress                     # run once beforehand so it's warm (~8 min)
```

Have `docs/ENGINEERING_LOG.md` open in a second window.

---

## The 60-second story

> The RTL was complete but had never executed a single instruction — every test drove
> pipeline-stage inputs by hand. I built the boot infrastructure, the C runtime, and
> instruction-by-instruction lockstep against Spike. That found **23 real RTL bugs**.
> Four of them would have produced wrong collision-avoidance vectors rather than crashes,
> which is the failure mode you cannot see in flight. It now passes 63/63 ISA tests
> including under randomised memory timing, 9/9 directed corner cases, and 645/645 DSU
> tests against a cycle-accurate model.

---

## Demo order (stop anywhere, each stands alone)

| # | command | what to say |
|---|---|---|
| 1 | `make test_boot` | "Six instructions. This is the first program that ever ran on this chip." |
| 2 | `make test_c` | "Real C — stack, function calls, .bss, all load/store widths, multiply." |
| 3 | `make regress` | "Every test twice: its own self-check, **and** every instruction compared against Spike." |
| 4 | `make regress_rand SEED=1` | "Randomised memory timing. Three of the bugs only appear under specific stall timing." |
| 5 | `make test_dsu` | "645 randomised DSU tests against a cycle-accurate model." |

**Show the proof, not just the PASS:**
```bash
head -6 sim/regress/add.commit.log        # pc, rd, value per retired instruction
```

---

## The four bugs worth leading with

**1. The core could not execute a single instruction (I-1).**
The I-port sampled read data one cycle early — during the *address* phase. Every
instruction was paired with the previous bus cycle's data. AHB-Lite is pipelined; the old
code used one flag where two are needed.

**2. Every store wrote zero (D-1).**
Same mistake, data side. Write data was driven during the address phase and collapsed to
zero in the cycle the memory actually samples it.

**3. A branch deleted by its own predictor (P-2) — the timing-sensitive one.**
`ma_addr` **failed with fast memory and passed with slow memory**. A load-use stall holds
a branch in the fetch buffer; the predictor redirects for that same branch, and the
redirect flushes the buffer — destroying the branch. It never executes, never resolves,
and the prediction stands unchallenged. *That's the kind that ships and reproduces once a
month.*

**4. Any interrupt in a branch shadow destroyed the return address (T-4).**
Interrupt entry wasn't gated on a valid instruction in EX. Landing on a pipeline bubble
latched `mepc = 0`, so `mret` jumped to address 0. Only found by asserting interrupts at
*many different offsets* — a fixed injection point misses it forever.

---

## Numbers

| | |
|---|---|
| ISA tests (self-check + Spike lockstep) | **63/63** |
| — with fixed and randomised memory waits | 63/63 |
| Directed corner cases | **9/9** |
| DSU vs cycle-accurate model | **645/645**, five seeds — see caveat below |
| Block-level unit TB checks | **14,359, zero failures** |
| RTL bugs found and fixed | **23** |
| Code coverage: statement / branch / toggle | **98.5% / 96.1% / 86.0%** |

---

## Caveat you should state before anyone finds it

> "645/645 checks the DSU's timing and values hard, and it found 9 DSU bugs. But
> the model it checks against was written by reading the RTL, so for the
> *overflow flag* it reproduced the hardware's formula rather than the intent —
> it measured self-consistency. I've since put an independent oracle back in the
> loop, and it found a real defect: **the overflow flag is wrong roughly half
> the time once the accumulator passes 2⁴⁶**, the top quarter of its range.
> Values are correct everywhere. Confirmed against RTL, not just model-to-model.
> Details in `docs/ORACLES.md`."

Same for the AHB number: 88.54% went up *because of* a protocol bug the
covergroup rewarded. Both are now fixed in the measurement, not just the docs.

## If they push on coverage

> "Statement is 98.5% and branch 96.1% — both above the 95% bar. Toggle is 86%. Every
> module below 95% overall is at **100% statement coverage** — `clic_ctrl`,
> `if_stage_top`, `pc_gen`, `trap_ctrl` have zero uncovered blocks. The gap is individual
> bits of 32-bit buses that never change state, not logic that never ran. Some are
> unreachable in principle — `mcycleh` needs 2³² cycles to flip its low bit. My
> recommendation is to meet the bar on statement and branch, and waive toggle per module
> with written reasons."

## If they ask what isn't covered

> "Only the core and the DSU exist. `rtl/clic`, `dma`, `debug`, `isram`, `dsram`,
> `ahb2apb` and every peripheral are empty directories. There's no interconnect and no
> TCM — my memory model stands in for both, and its header says explicitly it verifies
> nothing about arbitration, address decoding or the bridge. This says the core and DSU
> work. It says nothing about the SoC."

## Three things to raise proactively

1. **A teammate's coverage numbers (~97%) measured a stale DUT snapshot.** Their
   testbenches inline a copy of the design that predates two decode fixes, and two of
   their reference models were wrong against real RTL. Both corrected; their numbers need
   regenerating.
2. **FLAG-2 is closed** — as an RTL interlock, not a software ordering contract. A
   contract nothing in the toolchain enforces would outlive everyone who knows about it.
3. **The SHV question in `clic_ctrl.v` is settled by evidence**, not by decision: the RTL
   implements the jump-instruction table interpretation and it works end to end.

---

## Honest answers to hard questions

**"Did you verify the whole SoC?"** No — see above. Core and DSU only.

**"Is 23 bugs a lot?"** For RTL that had never run an instruction, it's what you'd expect.
Three of them were unreachable until a fourth was fixed — fixing one bug makes others
findable.

**"How confident are you?"** High on the ISA and the DSU: every instruction is compared
against an independent reference model, and the DSU against a cycle-accurate one. Lower
on anything involving blocks that don't exist yet.

**"What would you do next?"** Directed CSR sweep for `csr_file`, prefetch-buffer corners
for `if_stage_top`, and an exception-priority matrix for `trap_ctrl` — those three are the
largest genuine gaps. Then the SoC, once there's an interconnect to verify.
