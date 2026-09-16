# GARUDA SoC — architecture decision record

**Decisions that resolve a contradiction between two documents, or that close an
open item a specification left for the architecture owner.**

This file exists because `docs/BUGS.md` is the register for defects *found*, and
a defect that spans two released documents needs a recorded *ruling* as well as an
entry. One decision per section. Never renumber — other files reference these by ID.

Related: `docs/BUGS.md` (defect register), `docs/SOC_RTL_LOG.md` (interconnect and
SoC reasoning), `Design_Docs/` (the specifications themselves).

---

## D-1 — CPU/DMA access to the Data SRAM is serialised at the interconnect

**Decided 2026-09-16 · Raised by** `GARUDA-MEM-SPEC-001` Rev 2.0 §7.3 (FLAGGED, cross-block)

### The contradiction

The TRM and the DMA specification both state that CPU and DMA accesses to
*different* Data SRAM banks proceed in parallel, with only a same-bank collision
costing a cycle. Under the frozen Block 6 architecture that is not achievable.
The AHB-Lite interconnect grants exactly one master at a time and presents a
single transaction to slave S2 through one shared address/control bundle. The
Data SRAM sees one transaction per cycle and has no signal identifying which
master issued it. Accesses to different banks are serialised exactly as
same-bank accesses are.

### Decision

**Keep the frozen Block 6 topology. The architecture remains serialised at the
interconnect. Do NOT add a second Data SRAM slave port.**

Banking stays, and stays justified — it buys lower access energy and a shorter
array read, which is what keeps the array inside the 5 ns cycle. It does not buy
CPU/DMA concurrency, and the documents must stop implying that it does. The
functional bank map (DMA buffers in Bank 0, EKF in Bank 1, FreeRTOS in Bank 3)
is retained as a locality and ownership convention enforced by the linker script.

Genuine concurrency would require a second slave port on the Data SRAM fed by a
dedicated DMA path bypassing the shared bundle, with the bank arbiter living in
the memory. That changes both Block 4's interface and Block 6's topology. It is
explicitly rejected for this tapeout.

### Actions taken

| Document | Status |
|---|---|
| `GARUDA-MEM-SPEC-001` Rev 2.0 | Already correct — it follows Block 6 and deleted its own draft bank arbiter. No change. |
| `GARUDA-DMA-SPEC-001` Rev 2.0 (`.docx`) | **Patched**, three passages (below). |
| TRM (`GARUDA - Team AeroSoC`) | **Erratum recorded below — not yet applied.** See the note on the TRM source. |

**DMA specification — three passages corrected in the `.docx`:**

- **§8.5 DMA-CPU bus sharing** — the claim that different-bank accesses proceed
  in parallel, and the "less than 5% of cycles" figure that depended on it,
  replaced with the serialisation rule and the one-beat bound on the CPU's cost
  of losing an arbitration turn.
- **§14 verification plan** — the system-contention stimulus read "CPU and DMA
  access same DSRAM bank simultaneously", describing a condition that cannot
  occur. Now "CPU and DMA both request the Data SRAM in the same cycle (any bank
  combination)". The expected result was already correct and is unchanged: the
  CPU stalls one beat, the DMA completes, no corruption.
- **§17 integration table** — "Bank arbiter resolves DMA-CPU conflicts" was
  pointing at hardware that does not exist. Now attributes the resolution to the
  Block 6 arbiter and states the Data SRAM has no bank arbiter.

> Note on the cross-reference: the Memory spec cites this as "DMA §16". The
> claim is actually in **§8.5**, with the two consequential restatements in §14
> and §17. §16 is Design Decisions and contains no bank-parallelism wording.

### TRM erratum — NOT YET APPLIED

The TRM body could not be edited in this repository. `Design_Docs/GARUDA - Team
AeroSoC.docx` contains only the cover page and table of contents; the body exists
only in the exported `.pdf`. Whoever holds the editable source must apply these
three corrections:

| Location | Current text | Should read |
|---|---|---|
| §III.II AHB-Lite Bus | "When CPU and DMA target the same SRAM bank, DMA wins, CPU stalls one cycle. **Different banks -- zero stall.**" | Delete the final sentence. The interconnect serialises masters before either reaches the memory, so bank index has no bearing on stall behaviour. The DMA wins arbitration and the CPU stalls one beat, whatever banks are involved. |
| §VIII.III Data SRAM | "**Banking allows DMA and CPU to access different banks simultaneously with zero stall.**" | Replace: banking reduces access energy and shortens the array read; it does not permit concurrent CPU/DMA access, because the Block 6 interconnect grants one master at a time. |
| §III.III APB Bus | "Peripheral access cost from CPU: **~3-4 cycles** including bridge CDC latency." | Replace with the figure from D-3 below: ≈6 pclk = 12 hclk ≈ 60 ns, plus one pclk per peripheral wait-state. |

Until that is done the PDF remains the one document in the project still
asserting the rejected model. Nothing depends on it in RTL, but it is the
document most likely to be read by someone new.

---

## D-2 — Reset-cause reporting is out of scope for the first tapeout

**Decided 2026-09-16 · Raised by** `GARUDA-CRG-SPEC-001` Rev 2.0 §8.5

The clock/reset specification scoped reset-cause reporting out, conditionally:
"unless the system architect states otherwise before RTL". This is that
statement, and it confirms the scope as written.

**Decision: no firmware-visible reset-cause reporting in Rev 2.0. Block 23
contains no status register. Proceed with the RTL at the current scope.**

The consequence is accepted and should be stated plainly rather than discovered
later: after a reset, firmware cannot distinguish a watchdog reset from a
power-on reset. A watchdog reset in flight is a genuinely different event from a
cold boot and a later revision may well want to log it or enter a degraded mode.

It is deferred because implementing it is not a wording change. A reset-cause
register must survive the reset it records, which needs either a separate
always-on reset domain or a flop set by `wdt_reset_i` and cleared only by
`por_n_i` — and it raises the unanswered question of whether GARUDA has an
always-on domain at all. Building speculative infrastructure for an undecided
requirement is the wrong thing to put in a block this small. If the distinction
is later required it becomes its own design addition with its own reset-domain
specification.

---

## D-3 — Bridge §9.1 is the authoritative peripheral-access latency

**Decided 2026-09-16 · Closes** `AHB-5` in `docs/BUGS.md`

`GARUDA-BRG-SPEC-001` Rev 2.0 §9.1 is the single authoritative figure for the
cost of a peripheral access, superseding the TRM's loose "~3-4 cycles":

> **≈6 pclk = 12 hclk ≈ 60 ns** with no wait-states, plus one pclk (2 hclk) per
> PREADY wait-state the addressed peripheral inserts.

This agrees with the 12–13 hclk measured against `tb/ahb/ahb2apb_bridge_model.v`,
which is what raised AHB-5 in the first place. Units are the trap here and the
spec says so explicitly: a pclk cycle is 10 ns and an hclk cycle is 5 ns, so
6 pclk is 12 core cycles, not 3.

**No other block may re-count this latency.** The DMA spec's "config-write
latency ≈ 6 pclk" and its "~5–7 hclk per beat" for a peripheral-mapped source
both describe this same crossing, which is owned by the bridge.

Write posting was considered as the alternative fix and is rejected (BRG §13.3):
it would let a store retire before the APB access completed, which breaks the
in-order two-cycle-ERROR reporting the DMA beat engine depends on to cancel a
pipelined write. The latency is correct as measured; it was the documented
number that was wrong.

---

## Open — carried forward, not decided

These are recorded so they are not mistaken for settled. Neither blocks RTL.

- **Memory §13.6 — pre-PDK array budgets.** The ≈2.8 ns array read inside a 5 ns
  cycle is analytic, derived from TRM targets, not compiler output. When the
  foundry memory compiler lands, three things get revisited: whether
  single-cycle access at 200 MHz survives (if not, the memories gain a
  wait-state, which changes the **core's** timing model), the per-bank aspect
  ratio and therefore the bank count, and whether byte-write-enable is native or
  must be built around a word-write macro. Until then, RTL uses behavioural array
  models behind the specified interfaces so only the array instantiation changes.
- **CLIC §11.1 — genuinely asynchronous interrupt sources.** The
  no-synchroniser configuration path is sound for sources in either on-chip
  domain, because pclk is a ÷2 of hclk from one source. It does not cover a
  source asynchronous to clk, the clear candidate being a GPIO interrupt from an
  external pad. Such a source needs a two-flop synchroniser before the CLIC
  samples it, and an edge-triggered pad input needs the edge detected *after*
  the synchroniser. The GPIO specification must state whether it synchronises
  internally or delivers the pad interrupt raw.
- **Duplicate bridge specification.** `Design_Docs/ahb2apb/` holds two documents
  both numbered Rev 2.0: `AS-GRD-08_...` (2026-09-02, APB **v3**, crossing
  described as *mesochronous*) and `GARUDA_AHB2APB_...` (2026-09-14, APB**4**
  with PSTRB, and §13.4 explicitly rejects "mesochronous" as inaccurate). The
  newer supersedes the older on both points. The stale file should be deleted or
  moved to an archive folder — pending owner confirmation.
