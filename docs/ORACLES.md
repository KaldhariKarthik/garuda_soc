# Independent oracles — what they are, and what they found

Added 2026-08-12, after an audit found four defects in blocks that had passed
every existing test. This document explains the two oracles built in response,
because the *reason* they were built matters more than the bugs they found.

---

## The problem they solve

The first verification round found 23 RTL bugs using **one** oracle: Spike, via
instruction-by-instruction lockstep. Spike is an excellent oracle for the thing
it knows about — the architectural ISA — and it found essentially everything
findable there.

It knows nothing about bus protocol, and nothing about the DSU.

So coverage of *oracles* was one, while code coverage was chased from 62% to
73%. That was the wrong axis to optimise. Two blind spots existed, each one a
place where the design could misbehave arbitrarily and every test would still
pass:

| blind spot | how it stayed invisible |
|---|---|
| AHB-Lite protocol | `ahb_mem_slave.v` has no HBURST port at all — `grep -c -i hburst` returns **0**. It services every transfer as an independent SINGLE, so a master can violate burst rules forever and still get correct data back. |
| DSU overflow flag | `DSU_Golden.py`'s `DSUModel` was written by reading the RTL, and reproduces its arithmetic *structure*. Its own header says "where this file and the RTL disagree, the RTL wins". 645/645 therefore measured self-consistency. |

Both are the same mistake in different clothes: **a functional model is not a
checker, and a model derived from the design cannot judge the design.**

---

## Oracle 1 — `tb/ahb/ahb_lite_checker.v`

A passive AMBA 3 AHB-Lite protocol monitor. One instance per master port,
tapping the wires between master and slave, driving nothing.

Written in **Verilog-2001, no SVA**, deliberately: it must build under both
`xrun` 22.09 (regression) and `irun` 15.20 (coverage), needs no assertion
licence, and lives in the **plain** filelist — so every test in the suite now
checks bus protocol as well as its own result, at zero extra stimulus cost.

Checks address-phase stability across wait states, burst legality (HBURST
constant and presented with NONSEQ, SEQ only inside an open burst, INCR address
sequencing, fixed-length beat counts, 1 KB boundary), HSIZE alignment,
write-data hold, and two-cycle ERROR responses. Each has its own counter so a
hit is diagnosable.

It states in its own header what it does **not** check — WRAP address wrapping
is counted, not verified, so its silence never implies more than it should.

### What it found, first run

`add.hex`, no wait states, one test:

```
AHB-LITE CHECKER tb_boot.u_ichk
  address phases observed : 526
  VIOLATIONS              : 494
     SEQ following a SINGLE burst     : 494
```

All three suspected bus defects reproduced independently:

| erratum | evidence | condition |
|---|---|---|
| **BUS-A** — `i_hburst_o` derived from `i_htrans_o`, so the opening beat says SINGLE and every following beat says INCR | 461–494 per run | every configuration |
| **BUS-B** — `after_redirect` never clears on an IDLE gap, so a burst broken by a full prefetch buffer resumes with SEQ instead of NONSEQ | 2 per run (`t_dsu +DWAIT=7`) | needs a D-side stall long enough to fill the prefetch buffer |
| **BUS-C** — an unaccepted address phase is retracted to IDLE on redirect; AHB-Lite has no cancel | 1–115 per run | needs I-port wait states |

### A fourth, found while fixing the first three — BUS-D

Writing the fix for BUS-A raised the question the checker had not been asked:
if this port emits INCR bursts, **what ends one?** AHB-Lite's answer includes a
rule neither the RTL nor the checker had: *a burst must not cross a 1 KB
address boundary* (IHI 0033, 3.5).

Nothing enforced it and nothing looked for it. Against a single flat memory
model it is harmless, which is why it had never mattered — and it stops being
harmless the moment an address decoder exists, because **1 KB is the minimum
AHB slave window**. A burst allowed to run past the boundary is a burst that
can cross from one slave into another while the decoder still believes it is
mid-burst on the first.

BUS-D is therefore the same class of latent defect as BUS-A/B/C, found the same
way — by asking what the protocol requires rather than what the current
testbench happens to notice. It is fixed in the RTL and the rule is now
**checked** (`v_1k_cross`), so the fix is verified rather than asserted.

### Status — all four closed, 2026-09-02

| erratum | fix |
|---|---|
| **BUS-A** | `i_hburst_o` is now the constant `3'b001` (INCR). This port only ever issues undefined-length incrementing bursts; INCR is legal for a run of any length including one, so a lone fetch needs no special case, and a constant cannot vary across beats or across a wait state. |
| **BUS-B** | `after_redirect` is replaced by `need_nonseq`, set on **every** path that emits IDLE rather than only the redirect path. The flag is now named for what it means instead of for the one event that used to set it. |
| **BUS-C** | The redirect branch no longer retracts unconditionally. If an address phase is presented but not yet accepted it is **held** until HREADY, and `drop_cnt` counts it so its data is discarded when it lands. |
| **BUS-D** | Burst continuation is now derived from the bus state — `seq_contiguous` (address is previous + 4) and `seq_within_1k` — instead of inferred from "a redirect is the only thing that can move the PC non-sequentially". That inference held, but it is a premise about another module, and the interconnect being built on top of this port has to be able to trust HTRANS/HBURST locally. |

**Verification of the fix.** 0 violations on both ports across: the ISA
regression (63/63), the fixed-wait and randomised-wait variants (63/63 each),
the sanity suite (all 9 tests report `iport=0 dport=0`), and a dedicated
20-configuration sweep over deep D-side stalls, randomised I-port waits,
interrupts under wait states and bus errors under wait states.

The checker was confirmed still live by a **negative control**: re-running the
sanity suite against the *unfixed* RTL with the *new* checker reproduces the
violations (36 on `t_loadbranch` alone — 32 SEQ-after-SINGLE, 4 SEQ-after-IDLE).
A clean report from a checker that has not been shown to fail is worth nothing.

**The D-port is clean in every configuration tested.** Only the I-port bursts.

BUS-B is the one worth noting: it needs a *specific* stall shape to appear, and
would have been missed by any amount of additional random ISA stimulus. It was
found on the second configuration tried, because the checker sees every cycle
of every test rather than the end result of a few.

### Verdict policy

The checkers **always** run and always report — that is not switchable, because
"nobody was looking" is the entire reason these survived. Whether a violation
*fails* the test is `+AHBCHK_FATAL`, currently defaulting to advisory for one
reason: while BUS-A/B/C are open, a fatal default turns the whole regression red
and makes a genuine new regression indistinguishable from known protocol noise.

**Flipped 2026-09-02, when BUS-A/B/C/D were fixed.** Protocol violations now
**fail** the test by default; `+NO_AHBCHK_FATAL` demotes them again for a
bring-up that genuinely needs to run against a known-dirty bus. A checker whose
failures are permanently advisory decays back into decoration, which is how we
got here.

---

## Oracle 2 — `ArchDSU`, restored as an independent check

`ArchDSU` already existed in `tools/golden/DSU_Golden.py` — timeless, written
from what the DSU is *supposed* to compute, with a real range check:

```python
if not (-(1 << 47) <= raw <= (1 << 47) - 1):
    self.overflow_sticky = True
```

`DSU_gen.py` had been migrated off it, onto `DSUModel` alone. That migration is
what removed the only opinion in the system not derived from the RTL.

Both models now run in lockstep in `DSU_gen.py`. `DSUModel` still supplies the
expected vectors — it is the only one that can, since it alone knows *when* a
result appears — but `ArchDSU` now contradicts it, on every generation, with no
switch to forget.

### Why ordinary stimulus could never find this

The first cross-check came back **clean on 90 tests**. That is not the oracle
failing; it is the stimulus never reaching the defect. Measured, not assumed:

- the largest contribution any single DSU instruction can make to an
  accumulator is **2³¹** (a MACDOT of two `0x8000` lanes)
- `MACLOAD` tops out at ±2³¹ from a 32-bit register
- `MACSHIFT` does not write the accumulator back

So reaching `|acc| ≥ 2⁴⁶` takes a **~32,768-instruction ramp**. Random tests
will never stumble into it. The overflow logic was not under-tested — it was
*unreachable* from the test suite as constructed.

Two things were added:

1. **`clamp_region_sweep()`** — runs on every generation. Seeds both oracles to
   the same accumulator value, then drives real instructions. The seeding is
   applied identically to both, so it cannot bias the comparison; it only skips
   32k cycles of ramp that prove nothing.
2. **`--clamp-walk N`** — emits the real ramp as vectors, so the finding can be
   confirmed against **actual RTL** rather than model against model.
   `MAX_TESTS` in `tb_dsu_top.sv` was raised from 4096 to 40960 to hold it.

### What it found — ERRATUM OVF-1

`mac_unit.v` detects overflow by sign-extending the two halves of a carry-save
pair and adding them:

```verilog
wire [48:0] s_ext = {csa2_sum[47],   csa2_sum};
wire [48:0] c_ext = {csa2_carry[47], csa2_carry};
...
wire accum_ovf = result_ext[48] ^ result_ext[47];
```

`csa2_carry` is not a signed number. And `csa_3to2.v` is:

```verilog
assign carry = ((a&b)|(b&c)|(a&c)) << 1;
```

That shift **discards `maj[47]`** — the carry belonging in bit 48. The redundant
pair reconstructs the true value only *modulo 2⁴⁸*. The low 48 bits are exactly
right, which is why every accumulator value ever compared has matched. But
`result_ext[48]` is a function of two bits that carry no sign information, so
the overflow flag is unrelated to overflow.

Measured, sweeping accumulator magnitude with both oracles:

| \|acc\| / 2⁴⁷ | overflow-flag disagreement | accumulator values |
|---|---|---|
| 0.05 – 0.49 | 0 / 2000 | agree |
| **0.50** | **845 / 2000** | agree |
| 0.60 | 1009 / 2000 | agree |
| 0.75 | 1023 / 2000 | agree |
| 0.90 | 1012 / 2000 | agree |
| 0.99 | 979 / 2000 | agree |
| −0.50 … −0.99 | 961–1008 / 2000 | agree |

The onset is sharp. Below `2⁴⁶` the flag is correct. **At or above `2⁴⁶` — the
top quarter of the accumulator's range — roughly half of all MACs get a wrong
overflow flag**, overwhelmingly false positives. That is precisely the region
the flag exists to warn about.

### Confirmed against real RTL, not just model-to-model

```
$ python3 tools/gen/DSU_gen.py --seed 4 --clamp-walk 1200
wrote 33968 tests
  *** INDEPENDENT-ORACLE DISAGREEMENT: 1200 of 33968 tests ***
      accumulator 0   rd_data 0   overflow 1200

$ xrun ... +STIM=.../dsu_stim.mem +EXP=.../dsu_expected.mem
  tests compared : 33968
  mismatches     : 0
  RESULT         : PASSED
```

The chain closes:

1. **RTL == DSUModel** on all 33,968 vectors — measured against real hardware,
   including the 1200 in the broken region.
2. **DSUModel ≠ ArchDSU** on the overflow flag for all 1200 — measured by the
   independent oracle.
3. Therefore **the RTL's overflow flag is wrong on all 1200**, while the
   accumulator values are right.

This is not an inference from a model. Both legs were run.

### Note on the fix

This is not a tweak. Overflow **cannot** be detected from a carry-save pair by
sign-extending each half — the information needed was discarded by the `<< 1`
in the CSA. Either the CSA chain widens so no carry is lost, or the detection
moves after the adder and derives from operand signs versus result sign.

`DSUModel` must be corrected in the same change, or `tb_dsu_top` will fail by
construction. `ArchDSU` is already right and must not be touched — it is the
only file in the DSU flow that does not describe the hardware.

---

## Reproducing

```bash
source scripts/setup_env.sh

# Oracle 1 -- runs on every test automatically. To see it alone:
xrun -f tb/soc/filelist_boot.f -top tb_boot -elaborate -snapshot ahbchk \
     -xmlibdirname sim/ahbchk/xcelium.d
xrun -R -xmlibdirname sim/ahbchk/xcelium.d -snapshot ahbchk \
     +HEX=sw/riscv-tests/build/add.hex +COMMIT=/dev/null +QUIET
# BUS-B needs a prefetch-buffer stall:
xrun -R -xmlibdirname sim/ahbchk/xcelium.d -snapshot ahbchk \
     +HEX=sw/build/t_dsu.hex +COMMIT=/dev/null +QUIET +DWAIT=7

# Oracle 2 -- the sweep runs on every generation
python3 tools/gen/DSU_gen.py --seed 1 --outdir sim/dsu

# RTL-level confirmation (takes ~30s to generate, ~15s to run)
python3 tools/gen/DSU_gen.py --seed 4 --clamp-walk 1200 --outdir sim/dsuclamp
xrun -f tb/dsu/filelist_dsu_top.f -top tb_dsu_top -elaborate -snapshot dsuclamp \
     -xmlibdirname sim/dsuclamp/xcelium.d
xrun -R -xmlibdirname sim/dsuclamp/xcelium.d -snapshot dsuclamp \
     +STIM=sim/dsuclamp/dsu_stim.mem +EXP=sim/dsuclamp/dsu_expected.mem
```

---

## The claim that has to change

`docs/COVERAGE.md` and `docs/MEETING_CHEATSHEET.md` present "645/645 against a
cycle-accurate model" as a strong result. It is a real result — the DSU's
*timing and values* are checked hard, and 9 DSU bugs were found that way — but
it does not mean what it sounds like, because until now the model and the design
shared an author and a formula. Those documents should say so.

The AHB functional-coverage figure (88.54%) is also inflated: `cg_ahb` bins SEQ
transfers with no cross against HBURST, so coverage went *up* because of BUS-A.
That covergroup should cross HTRANS with HBURST, at which point the bin
structure itself will show the illegal combination.
