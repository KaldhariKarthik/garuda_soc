# GARUDA DMA Controller — RTL implementation and verification log

**Block 9 of 24 — 6-channel DMA, AHB-Lite master / APB slave**
Spec: `Design_Docs/DMA/GARUDA_DMA_Controller_Design_Spec_v2.0.docx` (GARUDA-DMA-SPEC-001 Rev 2.0)
Session date: 2026-08-09 · Branch: `main` · **Nothing committed**

---

> **Where to look:** every bug in this document is also in `docs/BUGS.md`, which
> is the project-wide register and the one list to read if you only read one.
> Interconnect and SoC-integration work is logged in `docs/SOC_RTL_LOG.md`.
> The latest DMA work is in §16 at the end of this file.

## 0. Status in one paragraph — read this before anything else

The DMA RTL is **written, compiles, lints, synthesises, and passes a 72-run
self-checking block-level regression (48,012 checks, 0 failures)** under Icarus
Verilog. One real RTL bug was found by simulation and fixed. That is a
meaningful result, but it is **not** a verified block. It has never been
compiled by Xcelium or VCS, never run gate-level, never had coverage collected,
and has never seen the real AHB interconnect or APB bridge — none of which
exist in this repo yet. Sections 9–12 state precisely what is proven, what is
only lint/synthesis-clean, and what is untested. Please read those before
quoting any number from this document.

---

## 1. Files created

All 15 files are **new**. No pre-existing file in the repository was modified.

### RTL — `rtl/dma/` (all `.v` / `.vh`, Verilog-2001, per repo convention)

| File | Lines | Purpose |
|---|---:|---|
| `dma_defs.vh` | 100 | Single source of truth for CR/SR bit positions, FSM encodings, AHB constants. Producer/consumer contract between register bank and FSMs. |
| `dma_cdc_sync.v` | 65 | N-bit two-flop level synchroniser. Header states which instantiations are legitimate for WIDTH>1 (independent bits only). |
| `dma_cdc_pulse.v` | 77 | Destination half of a toggle (two-phase) event handshake. Source half is a single flop in the producer. |
| `dma_cdc_gray.v` | 93 | Gray-coded counter crossing for `SR.REMAINING`. |
| `dma_apb_slave.v` | 90 | APB3 protocol + address decode. Purely combinational (PREADY tied high ⇒ nothing to sequence). |
| `dma_reg_bank.v` | 252 | 30 registers (5×6). Owns the pclk side of every clock crossing. |
| `dma_arbiter.v` | 79 | Combinational 8-level fixed-priority encoder, lowest-index tiebreak. |
| `dma_channel_fsm.v` | 414 | 5-state per-channel controller ×6. Working registers, status flags, per-channel CDC. |
| `dma_ahb_master.v` | 350 | 6-state beat engine, data buffer, byte-lane alignment, AMBA error handling. |
| `dma_irq_agg.v` | 81 | 12 interrupt lines to the CLIC, registered outputs. |
| `dma_top.v` | 315 | Block boundary (port list frozen per spec §5.7) + beat-start handshake. |
| `filelist.f` | 28 | Synthesis file list, bottom-up. |

**Total RTL: 1,944 lines.** No verification-only code exists in `rtl/dma/`.

### Testbench — `tb/dma/` (`.sv`, per repo convention)

| File | Lines | Purpose |
|---|---:|---|
| `dma_ahb_slave_model.sv` | 306 | AHB-Lite slave: RAM region + FIFO ports (pop-on-read), wait-state injection, two-cycle ERROR injection. |
| `tb_dma_top.sv` | 1,366 | 20 directed tests + randomised soak, APB BFM, protocol monitors, `+DBGARB` probe. |
| `filelist_dma_top.f` | 26 | TB file list. |

### Documentation

| File | Purpose |
|---|---|
| `docs/DMA_RTL_LOG.md` | This report. |

> ⚠️ **Placement note:** I created this report in `docs/` because that is where
> the repo keeps `HANDOFF.md` and `VERIFICATION_LOG_2026-07-29.md`, and because
> `rtl/dma/dma_cdc_gray.v` already references `docs/DMA_RTL_LOG.md` by name.
> `docs/` is arguably outside the "RTL/testbench/simulation" areas you scoped —
> say the word and I will move it.

### Deliberately **not** done 

- **No `make test_dma` target was added.** That would mean editing the shared
  top-level `Makefile`. The exact commands used are in §3 so the target is a
  two-minute addition once you approve it. Suggested form is in §13.

---

## 2. Git status

Branch `main`, clean working tree apart from the new files. **No commits, no
staging, no pushes.**

```
?? rtl/dma/dma_ahb_master.v      ?? rtl/dma/dma_irq_agg.v
?? rtl/dma/dma_apb_slave.v       ?? rtl/dma/dma_reg_bank.v
?? rtl/dma/dma_arbiter.v         ?? rtl/dma/dma_top.v
?? rtl/dma/dma_cdc_gray.v        ?? rtl/dma/filelist.f
?? rtl/dma/dma_cdc_pulse.v       ?? tb/dma/dma_ahb_slave_model.sv
?? rtl/dma/dma_cdc_sync.v        ?? tb/dma/filelist_dma_top.f
?? rtl/dma/dma_channel_fsm.v     ?? tb/dma/tb_dma_top.sv
?? rtl/dma/dma_defs.vh
```

**Diff summary: 15 additions, 0 modifications, 0 deletions.** `rtl/dma/.gitkeep`
and `tb/dma/.gitkeep` remain in place and untouched. No file outside `rtl/dma/`,
`tb/dma/` and `docs/` was created or changed.

---

## 3. Toolchain

No EDA tools were on this machine at session start. `choco install iverilog`
failed (`lib-bad` access denied — needs Administrator). I installed the
**portable YosysHQ oss-cad-suite** into the session scratchpad instead; nothing
was installed system-wide and nothing outside the scratchpad was touched.

| Tool | Version | Role |
|---|---|---|
| Icarus Verilog | `14.0 (devel) s20260301-357-g72998c541-dirty` | compile + simulate |
| Verilator | `5.051 devel rev v5.050-153-gdde6aa34c (mod)` | lint only |
| Yosys | `0.68+40 (git sha1 0f2bcb94b-dirty)` | synthesis check |
| Bundle | `oss-cad-suite-windows-x64-20260809.tgz` (564 MB) | portable, scratchpad only |

**Exact commands**

```bash
# PATH (unix-style; lib/ must precede bin/ — see TOOL-3)
export PATH="$SCRATCH/oss-cad-suite/lib:$SCRATCH/oss-cad-suite/bin:$PATH"

# compile + simulate
iverilog -g2012 -I rtl/dma -o dma_tb.vvp -s tb_dma_top \
         rtl/dma/*.v tb/dma/dma_ahb_slave_model.sv tb/dma/tb_dma_top.sv
vvp dma_tb.vvp [+GWAIT=n] [+GRAND=1] [+SEED=n] [+DBGARB] [+WAVES]

# lint
VERILATOR_ROOT="$SCRATCH/oss-cad-suite/share/verilator" \
  verilator_bin --lint-only -Wall -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
                +incdir+rtl/dma --top-module dma_top rtl/dma/*.v

# synthesis check
yosys -s syn.ys     # read_verilog -I rtl/dma <11 files>; hierarchy -top dma_top;
                    # synth -top dma_top -flatten; stat
```

**Not run:** Xcelium (`xrun`), Vivado `xsim`, Synopsys VCS, Genus. None are
available on this Windows machine — the team's flow lives on the Linux box
described in `docs/HANDOFF.md` §2.

---

## 4. Compilation results

| Target | Result |
|---|---|
| `iverilog -g2012` full design + TB | **Clean, exit 0.** No errors, no warnings. |
| `iverilog -g2005` RTL only (`-s dma_top`) | **Clean, exit 0.** 4 informational notes only. |

The 4 notes are `@* is sensitive to all 6 words in array 'sar'/'dar'/'tcr'/'cr'`
in `dma_reg_bank.v`. These are informational — Icarus stating that an `always @(*)`
read mux over an unpacked array is sensitive to the whole array, which is the
correct and intended behaviour for a register-file read mux. Not suppressed:
suppressing them would hide a genuine sensitivity bug if one were ever
introduced there.

`-g2005` passing matters: it confirms the RTL is **Verilog-2001**, not
SystemVerilog, matching every other file in `rtl/`.

---

## 5. Lint results (Verilator `-Wall`)

### Fixed (2 real cleanups, both driven by lint)

| ID | Finding | Change | Required by spec? |
|---|---|---|---|
| LINT-1 | `UNUSEDPARAM: 'CH_ID'` in `dma_channel_fsm` | **Removed the parameter.** The six instances are genuinely identical, and the generate label `dma_top.g_ch[n].u_ch` already identifies the channel in waveforms and coverage paths. A parameter carried only for naming is dead logic. | No — style/lint hygiene. |
| LINT-2 | `UNUSEDSIGNAL: 'cfg_cr_i'` 66 dead bits in `dma_irq_agg` | **Narrowed the port** from the flattened 78-bit CR bus to `ie_i[5:0]` / `eie_i[5:0]`; extraction moved to `dma_top`. | No — interface hygiene, but it makes lint able to flag a genuinely unused input in future instead of shrugging at 66 dead bits. |

### Intentionally left (3 warnings, all legitimate design facts)

| Signal | Why it is correct |
|---|---|
| `dma_ahb_master.rd_lanes[31:16]` | Byte/halfword extraction uses only the low bits; the WORD case reads `hrdata_i` directly rather than the shifted copy. The upper bits of the shifted value are genuinely never needed. |
| `dma_apb_slave.paddr_i[1:0]` | Spec §5.2/§6.2 define all registers as word-addressed, byte offset always `00`. APB3 has no byte strobes, so a sub-word access cannot be honoured at this interface. Deliberately not decoded. |
| `dma_channel_fsm.cfg_cr_i[9:8]` | CR.IE/CR.EIE are consumed by `dma_irq_agg`, not by the channel FSM. Splitting the CR bus further would fragment a coherent register for no benefit. |

Also waived on the command line: one `PINCONNECTEMPTY` on `state_o`, which is
intentionally left unconnected in `dma_top`. It exists for coverage binding —
spec §14 requires "All 5 states visited per channel", and `tb/cov/` in this repo
collects coverage by `bind`, which reaches it hierarchically.

**Final lint state: 0 unexpected warnings.** The three above are stable and
documented; any *new* warning is a real regression signal.

---

## 6. Synthesis results (Yosys, generic mapping)

```
Checking module dma_top...  Found and reported 0 problems.   (×3 CHECK passes)

5205 wires · 6666 cells · 604 public wires
Flip-flops:  1220 $_DFFE_PN0P_ +  7 $_DFFE_PN1P_
              496 $_DFF_PN0_   +  8 $_DFF_PN1_    =  1731 total
Latches:     $_DLATCH_* = 0
```

**Key findings**

- **Zero inferred latches.** Every `always @(*)` block assigns all outputs on
  all paths.
- **Zero CHECK problems** — no combinational loops, no multiple drivers, no
  undriven nets.
- All flops are async-reset (`_PN0_` / `_PN1_`), matching spec §12's
  "asynchronous assert, synchronous deassert" requirement. The 7+8 `_PN1_` flops
  reset to 1 and are the toggle/gray CDC registers.
- **1,731 flip-flops.** Roughly: 558 register bank + ~570 channel working
  registers + ~350 CDC (gray coders dominate) + ~100 AHB master + misc.
- **~6,666 generic cells.** Mapped to a 28 nm standard-cell library this lands
  around **15–17k gate-equivalents**, inside the spec §15.1 estimate of
  14,000–18,000. Treat this as a sanity check, not an area signoff — that
  requires Genus with the real library.

> Synthesis proves the RTL is *synthesisable and structurally sound*. It says
> nothing about whether it is functionally correct, and nothing about timing.

---

## 7. Testbench architecture

```
tb_dma_top.sv
├── clock/reset      hclk 200 MHz; pclk 100 MHz, deliberately skewed 1.3 ns
│                    off hclk (a phase-aligned divided pclk is the EASY case
│                    for CDC — the skewed one is the case that finds bugs)
├── APB BFM          apb_write/apb_read, driven on NEGEDGE pclk so stimulus is
│                    stable across the DUT's posedge sampling window
├── dma_req driver   two modes:
│                      FORCED — TB dictates exact timing
│                      AUTO   — driven from modelled FIFO occupancy, which is
│                               what spec §5.4 actually describes
├── protocol monitors  · dma_ack must be exactly 1 hclk wide (spec §5.4)
│                      · HBURST always SINGLE (§5.3/§16.4)
│                      · HTRANS never BUSY/SEQ; HSIZE never 3'b011
├── +DBGARB probe    per-cycle FSM state / arbiter decision trace
├── PRNG             32-bit xorshift, NOT $random — see TOOL-4
└── scoreboard       chk / chk_eq, counts checks and failures

dma_ahb_slave_model.sv
├── RAM region       0x2000_0000, 8 KB, byte-enable writes
├── FIFO ports       0x4000_1000 + n*4, eight ports.
│                    READ POPS. This is the important part: against a plain
│                    memory a fixed-address source returns the same word every
│                    beat, so a DMA that read once and replayed 14 times would
│                    pass. Popping makes beat ordering and beat count
│                    observable at the source.
├── wait states      fixed or randomised, per access
└── error injection  mandatory AMBA two-cycle ERROR response
```

The protocol sequencer, wait-state draw and error response are modelled on
`rtl/ahb/ahb_mem_slave.v`, which is already proven against the core's two AHB
masters. Reusing a known-good structure means a protocol disagreement points at
the DMA rather than at a fresh bug in the model.

---

## 8. Simulation results — every test

**Final regression: 72 runs × 6 bus-timing configs × 12 seeds = 48,012 checks, 0 failures.**

| Config | Seeds | Result |
|---|---|---|
| `+GWAIT=0` (zero wait states) | 1–12 | 12/12 PASSED |
| `+GWAIT=1 +GRAND=1` | 1–12 | 12/12 PASSED |
| `+GWAIT=2 +GRAND=1` | 1–12 | 12/12 PASSED |
| `+GWAIT=4 +GRAND=1` | 1–12 | 12/12 PASSED |
| `+GWAIT=6 +GRAND=1` | 1–12 | 12/12 PASSED |
| `+GWAIT=10 +GRAND=1` | 1–12 | 12/12 PASSED |

### Per-test detail (all PASS in the final build)

| # | Test | What it actually checks | Spec §14 row |
|---|---|---|---|
| T1 | Register access | All 30 registers write/read; TCR[31:16] reads 0; CR[31:13] reads 0; SR reads 0 when idle; reserved channel 6 and reserved reg_sel 5 decode to nothing and do **not** alias onto channel 0; PREADY=1, PSLVERR=0 | Register access |
| T2 | P→M 14 bytes | The §13.2 IMU case. 14 bytes arrive **in order**; destination walks all 4 byte lanes while source lane is fixed; source FIFO popped exactly 14×; SR.COMPLETE set, SR.ERROR clear, REMAINING=0; `dma_irq[0]` asserts; `dma_ack` pulsed once per beat; CR.EN cleared by hardware | Single channel P→M |
| T3 | W1C semantics | Writing 0 to SR.COMPLETE does nothing; writing 1 clears it; `dma_irq[1]` follows the flag level | W1C semantics |
| T4 | Circular mode | 12 beats moved with TCR=4 and **zero CPU writes in between** ⇒ two automatic reloads; buffer holds the final lap's data; CR.EN stays set | Circular mode |
| T5 | FIFO runs dry | Channel parks in WAITING after 3 of 8 beats; no further beats; **SR.REMAINING reads exactly 5**; refill resumes and completes all 8 with data intact | FIFO deassert |
| T6a | Error on write | SR.ERROR set, SR.COMPLETE **not** set, `dma_err` asserts, `dma_irq` does not, CR.EN cleared | Error handling |
| T6b | Error on read | **Destination sentinel `0xCAFEF00D` unchanged** — proves the pipelined write address phase was retracted and no corrupt write landed | *(not in spec — added)* |
| T7 | Priority arbitration | CH0 (PRI 7) takes all 8 beats with CH3 (PRI 2) getting **exactly 0**; CH3 then completes (no deadlock); both data sets correct | Arbitration |
| T7b | Mid-stream preemption | CH3 streaming, CH0 arrives; CH3 advances **0 beats** while CH0 holds the bus; CH3 resumes and finishes all 20 with data intact | Preemption |
| T8 | Equal-PRI tiebreak | CH1 (lower index) takes all 6 beats before CH4 gets any, even though CH4 was armed first | Tiebreak |
| T9 | Memory-to-memory | 8 word beats complete with `dma_req` held **low throughout** (§9: M2M ignores the handshake) | *(mode coverage)* |
| T10 | M2P halfword | 4 halfword beats to a fixed FIFO; each halfword correctly right-justified on read and re-placed on write | *(mode coverage)* |
| T11 | Zero-length TCR=0 | SR.COMPLETE set immediately; **0 beats, 0 AHB reads issued** | *(spec §6.5)* |
| T12 | Wait states | Same 14-beat transfer against randomised 0–6 wait states; all data correct | *(implicit)* |
| T13 | Full sensor suite | All 6 channels concurrently at spec §8.4 priorities; every channel moves exactly 6 beats; no cross-channel corruption; no starvation | Full sensor suite |
| T14 | Software abort | Clearing CR.EN parks the channel; it does **not** wake on a later `dma_req`; it re-arms correctly afterwards | *(§6.6 "undefined")* |
| T15a | CIRC + bus error | Circular channel **halts** after the error instead of re-arming forever; CR.EN cleared | *(added guard)* |
| T15b | CIRC + TCR=0 | No livelock; SR.COMPLETE set once; 0 beats; channel disarms | *(added guard)* |
| T15c | Reserved SIZE=2'b11 | Degrades to WORD, steps address by 4, and never emits illegal HSIZE=3'b011 | *(added guard)* |
| T16 | Randomised soak | 10 rounds × random {active channels, size, count 1–8, direction P2M/M2M, priority} against randomised bus timing; every destination byte checked | *(beyond spec)* |

Reset behaviour (spec §12) is checked before any configuration: HTRANS=IDLE,
all `dma_irq`/`dma_err`/`dma_ack` deasserted.

---

## 9. Every bug, issue and ambiguity encountered

### 9.1 RTL bugs found by simulation — 1

#### **DMA-1 — Inconsistent `SR` snapshot across the clock-domain crossing**

- **Status:** FIXED and re-verified across all 6 wait-state configs.
- **Evidence:** `+GWAIT=8`, test T2 —
  `[FAIL] SR.REMAINING reads 0 after completion : got 0x1 expected 0x0`.
  Invisible at `GWAIT` 0–5.
- **Symptom:** A single APB read of SR could return `COMPLETE=1` together with
  `REMAINING=1` — a snapshot of a state the channel was never in, contradicting
  spec §6.7 ("Reads 0 when … transfer is complete").
- **Root cause (the hardware reason):** The two halves of one register reached
  the pclk domain by paths of **different depth**:

  | Field | Path | Depth |
  |---|---|---|
  | `SR.COMPLETE` | `dma_cdc_sync` | 2 pclk flops |
  | `SR.REMAINING` | `dma_cdc_gray` | **1 hclk flop** + 2 pclk flops |

  The gray coder registers binary→gray in the *source* domain — which is
  correct, so the synchroniser never samples settling combinational logic — but
  that extra stage delays REMAINING by up to one hclk (5 ns) relative to the
  flag. One hclk is enough to land on the far side of a pclk edge (10 ns), so
  for a one-pclk window the two fields describe different instants. Wait states
  shift the completion into that window, which is why only `GWAIT=8` exposed it.
  **This is the classic "passes a fixed-timing regression, fails silicon"
  defect shape.**
- **Fix:** Made the consistency **structural rather than a latency
  coincidence**. The counter is now exported raw, plus a `cnt_valid` level
  ("this count is meaningful"). The register bank pushes `cnt_valid` through the
  *same* `dma_cdc_sync` instance as the status flags — so it changes on the same
  pclk edge they do — and gates REMAINING to zero in the pclk domain.
  Latency-matching the two synchronisers would also work today and would break
  again the moment either path changed depth.
- **Side benefit:** the gray source no longer takes a multi-bit jump to zero on
  completion, so its one-bit-per-change property now holds for every transition
  except the TCR load.
- **Files:** `dma_channel_fsm.v` (marked `ERRATUM DMA-1`), `dma_reg_bank.v`,
  `dma_top.v`.
- **Architectural behaviour changed to pass a test?** No. The externally
  specified behaviour (§6.7) is unchanged — the fix makes the RTL *meet* it.

### 9.2 Testbench bugs — 8 (every one initially looked like an RTL bug)

| ID | Symptom | Root cause | Fix | Evidence |
|---|---|---|---|---|
| TB-1 | 6 × `DAR readback : got 0x5a5affff expected 0xffffffff5a5affff` | `chk_eq` formals are `[63:0]`; Verilog evaluates argument expressions at the **formal's width**, so `~pat` inverted a 64-bit zero-extension | Materialise the inversion in a 32-bit variable first | Expected value printed as 64-bit |
| TB-2 | T4 `circular lap data: got 0x44 expected 0x40`, `13 beats expected 12` | A circular channel is **free-running**; by the time an APB read of SR completes, the next lap is already overwriting the same buffer (DAR reloads every lap) | Load exactly 3 laps of source data and drive `dma_req` from FIFO occupancy so the channel stops itself at a deterministic point | Beat count was 12+1, i.e. one beat into lap 4 |
| TB-3 | T5 `no further beats: got 4 expected 3` | A TB watching a beat counter and then lowering a forced `dma_req` is always 1–2 beats late — the channel re-requests the cycle after each beat | Let the modelled FIFO run dry instead (zero reaction latency) | Off by exactly one beat |
| TB-4 | T7 `CH3 got zero beats` | **Precondition never established.** Arming crosses pclk→hclk through 3 flops plus a CONFIGURED cycle; raising `dma_req` immediately after the last APB write left a ~5 hclk window where CH3 was the *only* requester | `hclk_wait(30)` before asserting `dma_req` | `+DBGARB`: CH3 reached WAITING at t=6868000, CH0 only at t=6988000 |
| TB-5 | T7 still failing | Sampled `ack_count[3]` **after** `wait_flag`, which polls over APB and returns up to ~9 hclk after CH0 finished — counting beats CH3 took legitimately *after* CH0 was done | Sample on the hardware event `wait(ack_count[0]==8)` | `+DBGARB`: CH3 moved in the same cycle CH0 went COMPLETE→IDLE |
| TB-6 | T8 `CH4 got no beats first` (only at `GWAIT=2`) | Identical to TB-5 — I fixed T7 but did not propagate to T8 | Same precise-event sampling | `+DBGARB`: CH1 won all 6 arbitrations; CH4's first beat was in CH1's COMPLETE cycle |
| TB-7 | T7b off-by-one on 8 seeds | Closing sample taken after `wait_flag` again — included CH3's legitimate *resumption* | Bracket the window with two hardware events (`ack_count[0]==1` … `==6`) | Failure was consistently exactly +1 |
| TB-8 | `Scope index expression is not constant: kd` | A hierarchical reference cannot take a variable generate index | Flatten the six FSM states into one bus with a generate loop, index that | Compile error |

**Pattern worth internalising:** six of the eight are the same shape — *the
testbench observing a fast hardware event through a slow APB read*. In a design
with a 200 MHz core domain and a 100 MHz config port, any check of the form
"poll a status register, then sample a counter" is racing the DUT by tens of
nanoseconds. Every such check was converted to sample on a hardware event.

### 9.3 Toolchain / environment issues — 5

| ID | Issue | Resolution |
|---|---|---|
| TOOL-1 | `choco install iverilog` → `Access to 'C:\ProgramData\chocolatey\lib-bad' is denied` (needs Administrator) | Downloaded portable `oss-cad-suite` into the session scratchpad. Nothing installed system-wide. |
| TOOL-2 | Verilator: `Cannot find verilated_std_waiver.vlt … '/yosyshq/share/verilator'` — the portable bundle has a baked-in absolute path | Set `VERILATOR_ROOT` explicitly. Also: Verilator needs `+incdir+path`, not `-I path` (with a space it is parsed as a top-module name). |
| TOOL-3 | `yosys.exe: error while loading shared libraries: libreadline8.dll` | Add `oss-cad-suite/lib` to `PATH` **before** `bin`, and use **unix-style** paths (`/c/...`) — Git Bash mangles `C:/...` entries when converting PATH for a native exe. |
| **TOOL-4** | **Icarus Verilog 14 accepts `$random(seed)` and silently ignores the seed.** A 10-seed sweep produced byte-identical stimulus and reported 10 passes — one run counted ten times. | Verified with a 6-line standalone case (all seeds → `48, -99, -39, -9`). Replaced with a 32-bit xorshift PRNG in both the TB and the slave model. Check counts now vary per seed (743/755/730/682/576), and seeds reproduce identically on any simulator — which matters for replaying a failing seed under VCS. |
| TOOL-5 | No Cadence/Synopsys/Vivado tools on this Windows machine | Everything run under Icarus/Verilator/Yosys. **The team flow is unexercised** — see §12. |

> TOOL-4 is the most dangerous issue in this list. It did not produce a wrong
> answer; it produced a **falsely reassuring** one. Any randomised regression in
> this repo that relies on `$random(seed)` under Icarus is not actually
> randomised across seeds.

### 9.4 Specification ambiguities, contradictions and errata — 12

| ID | Spec location | Issue | Resolution taken | Type |
|---|---|---|---|---|
| SPEC-1 | §7.4 | The 6-state AHB FSM table is **self-contradictory**: it lists READ_DATA and WRITE_ADDR as separate states, but READ_DATA's "Drives" column says *"(address of next phase)"* and the note says they *"overlap by one cycle … a beat takes ~3 hclk cycles*". Two separate states cannot overlap; a beat would take 4 bus cycles and the §11.1 latency table would be wrong. | Merged into `S_RDATA_WADDR`, exactly as the spec's own Drives column describes. The freed encoding became `S_ERROR`. **State count stays at 6.** | Contradiction |
| SPEC-2 | §6.5 vs §7.1 | §6.5: TCR=0 ⇒ "channel enters COMPLETE immediately". §7.1: CONFIGURED "**always** transitions to WAITING_FOR_REQUEST". | Followed §6.5 (more specific). Critical: entering the request loop with TCR=0 would decrement from 0, wrap to 0xFFFF, and turn an empty descriptor into a **65,536-beat runaway**. | Contradiction |
| SPEC-3 | §3.1 vs §2/§8.3 | Arbiter "re-evaluates **every cycle**" vs "re-evaluates after every single **beat**". | Arbiter is combinational (per §3.1) but the grant is **latched for the beat** by `dma_ahb_master`, and a new beat starts only when it is idle. Per-beat granularity is delivered by the beat boundary. Without this, a higher-priority request mid-beat would swing HADDR under a live transaction and cross-corrupt two transfers with **no status bit set anywhere**. | Contradiction |
| SPEC-4 | §3.1 vs §7.5 | §3.1 puts SR in the pclk register bank; §7.5 lists `done_flag`/`err_flag` as coming *from the channel FSMs*, and §3.1 puts the IRQ aggregator in hclk. | Followed §7.5 — flags live in hclk where the events happen; the register bank synchronises them for readback. The alternative means synchronising every set event across, for the same result. | Contradiction |
| SPEC-5 | §15.3 | "The EN bit in CR is synchronized via a 2-flop synchronizer." **A synchronised level alone cannot safely start a channel** — EN has two writers in two domains (software sets from pclk, hardware clears from hclk). Rising-edge start ⇒ hang if firmware re-arms before the clear lands. Level start ⇒ the channel instantly re-runs the transfer it just finished. | Kept the 2-flop synchroniser (used for the abort check), **and** added an arm *event*: the register bank toggles `arm_tog` on any CR write with EN=1 — which is precisely the "set EN LAST" action §6.6 defines as the trigger. A toggle survives any clock ratio and any concurrent hardware clear. | **Ambiguity with a latent hang** |
| SPEC-6 | §7.1 | COMPLETE says "Checks CIRC bit … CIRC=1: go CONFIGURED", with **no exception for a bus error**. | Added guard: a circular channel that faults **stops** and reports. Restarting would hammer the faulting address forever and re-raise `dma_err` faster than firmware could clear it. Verified by T15a. | Gap — deviation |
| SPEC-7 | §6.6 / §7.1 | CIRC=1 with TCR=0 is unspecified — would spin CONFIGURED→COMPLETE→CONFIGURED forever. | Added guard: treated as single-shot, disarms. Verified by T15b. | Gap — deviation |
| SPEC-8 | §6.6 | CR.SIZE=2'b11 is "Reserved" with no behaviour defined. Passing it through gives HSIZE=3'b011 = **64-bit, illegal on a 32-bit AHB bus**. | Degrades to WORD in both `dma_ahb_master` (HSIZE) and `dma_channel_fsm` (address step) — the two **must** agree or the address would walk at a different rate than data moves. Verified by T15c. | Gap — deviation |
| SPEC-9 | §6.6 | "Writing 0 [to EN] while active is undefined behavior." | Defined it: a clean return to IDLE at a **beat boundary only** (never from TRANSFERRING, so no bus transaction is abandoned mid-flight). Undefined would otherwise mean a channel parked forever holding a request line. Verified by T14. | Gap — deviation |
| SPEC-10 | §5.3 | HRESP is described without stating that ERROR is the AMBA **two-cycle** response. | The design *depends* on it: the first HREADY=0/HRESP=1 cycle is what lets the master retract its pipelined write address phase. **This is a requirement on the interconnect**, documented in `dma_ahb_master.v`. A non-compliant single-cycle-ERROR slave could let one spurious write land. | Under-specified — **integration risk** |
| SPEC-11 | §5.6 | Signal-count table arithmetic is wrong. AHB-Lite outputs: 32+2+1+3+3+32 = **73**, not 71; AHB total 107, not 105; grand total 212, not 210. | Documentation only — no RTL impact. | Doc erratum |
| SPEC-12 | §15.1 | "Register Bank (30 regs × 32 bits) … 960 flip-flops". Actual is **558** (TCR is 16-bit, CR is 13-bit). | Documentation only — the gate estimate is conservative, which is fine. | Doc erratum |

### 9.5 Assumptions made where the spec was silent

1. **SAR/DAR/TCR reset value.** §12 calls them "undefined". They are reset to 0
   anyway, so no X can reach HADDR in simulation, where it would propagate
   through the interconnect and look like an address-decode failure. Costs
   reset routing on 96 flops; buys clean X-propagation debugging.
2. **CR.PRI to the arbiter** comes from each channel's **latched** working copy
   (captured in CONFIGURED), not a live CR read. Functionally identical —
   §16.5 states priority is set once at init and never changed mid-flight — but
   it keeps a pclk-domain register out of an hclk combinational path.
3. **`dma_ack` pulses for M2M too**, though there is no peripheral. §5.4 says
   "after the DMA completes one beat for that channel", without exception.
   Harmless.
4. **Byte-lane placement on writes uses replication** across all four lanes.
   AMBA leaves unused lanes don't-care, and replication means whichever lane the
   destination address selects already carries correct data — no second shifter
   and no dependence on the slave's lane-select style.
5. **A `DONE` state costs one extra cycle per beat** (beat = 4 hclk on the bus +
   arbitration, ≈5 hclk end-to-end, vs the spec's "~3 hclk"). Kept for spec
   fidelity and a clean 1-cycle `dma_ack`. Bus utilisation is <0.2% per §11.2,
   so this is not a bottleneck — but §11.1's latency table is optimistic.
6. **APB `prdata` is combinational**, gated by PSEL/PENABLE and the valid
   decode. Standard for a simple APB3 slave with PREADY tied high.

---

## 10. ✅ RTL proven by simulation

These behaviours were exercised and checked, across 6 bus-timing configurations
and 12 seeds:

- Register map: all 30 registers, reserved-bit masking, reserved channel and
  register decode, PREADY/PSLVERR tie-offs.
- P→M, M→P and M→M directions; byte, halfword and word beat sizes.
- **Byte-lane alignment** with differing source and destination lanes (the IMU
  case — 3 of every 4 beats have mismatched lanes).
- Fixed vs auto-increment source and destination addressing.
- Transfer counting, completion, and hardware CR.EN clear on single-shot.
- Circular mode auto-reload with no CPU intervention.
- Peripheral handshake: `dma_req` park/resume, `dma_ack` exactly 1 hclk wide.
- Fixed-priority arbitration, lowest-index tiebreak, and **mid-stream
  preemption at a beat boundary**.
- Six channels concurrently with no cross-channel corruption or starvation.
- Bus-error handling on both read and write, including **retraction of the
  pipelined write address phase** (no corrupt write reaches memory).
- W1C semantics and level-sensitive interrupt assert/deassert.
- Zero-length descriptors; CIRC+error and CIRC+TCR=0 livelock guards; reserved
  SIZE degradation.
- AHB protocol legality: SINGLE bursts only, no BUSY/SEQ, no illegal HSIZE.
- Operation under fixed and randomised wait states (0–10).
- Reset behaviour per §12.

## 11. ⚠️ Lint / synthesis clean only — NOT functionally verified

- **Synthesisability** — Yosys generic mapping only. Genus with the real 28 nm
  library has not been run. No timing, no area signoff, no DFT.
- **Gate count ≈15–17k GE** — an estimate from generic cell counts, not a
  synthesis report.
- **No inferred latches / no combinational loops** — structural, proves nothing
  functional.
- **Verilog-2001 conformance** — `-g2005` compile only.

## 12. ❌ NOT verified — known gaps and risks

| Area | Why it is unverified | Risk |
|---|---|---|
| **Metastability itself** | No simulator models it. The CDC *structures* are correct by inspection and the protocol works, but only STA with proper constraints proves the crossings close. | **High** — needs SDC false/multi-cycle paths on every `dma_cdc_*` and on the quasi-static config bus. |
| **STA / timing closure** | No synthesis with real library, no SDC written. §15.2 claims the arbiter chain is ~0.8–1.0 ns of a 5 ns period — unconfirmed. | High |
| **Team toolchain (Xcelium / VCS / xsim)** | Only Icarus was available. Different simulators disagree on unpacked arrays, variable part-selects and `automatic` tasks. | **Medium — likely to surface compile issues on first VCS run.** |
| **Gate-level simulation** | Not run. | Medium |
| **Coverage (code + functional)** | **None collected.** Spec §14 requires FSM state coverage, register coverage and >95% toggle. `state_o` is exposed for exactly this but no covergroups were written. | **Medium — this is a spec signoff requirement that is entirely unmet.** |
| **Real AHB interconnect** | No interconnect exists in this repo. The DMA has only ever talked to a single TB slave — no arbitration against the CPU's two masters, no address decoding, no multi-master handover. | **High** — §8.5 (DMA/CPU bus sharing) is completely unexercised. |
| **AHB-to-APB bridge** | Does not exist. All config accesses and peripheral FIFO accesses cross it in the real SoC. §11.1's bridge latency numbers are untested. | High |
| **CLIC integration** | 12 interrupt lines verified at the block boundary only. | Medium |
| **Real peripherals** | `dma_req`/`dma_ack` verified against a model, not against the actual SPI/I²C/UART blocks. Whether they pop their FIFO correctly on a 1-cycle `dma_ack` is unproven. | Medium |
| **Clock ratios other than 2:1** | Only 200/100 MHz tested. | Low |
| **Reset asserted mid-transfer** | Not tested. Reset is only applied at time 0. | **Medium** |
| **Max-size transfer (65,535 beats)** | Longest tested is 20 beats. Counter wrap at the boundary is untested. | Low–Medium |
| **SR.REMAINING during the TCR-load window** | Documented limitation: the gray code's one-bit-per-change property does not hold across the multi-bit load, so a read in that ~2 pclk window can return a mixture. Accepted — §16.7 makes the field advisory. Firmware needing exactness must read twice or use SR.COMPLETE. | Low |
| **Arm events faster than CDC latency** | `dma_cdc_pulse` merges two source events closer than ~3 destination clocks. Argued safe by protocol for all three users, **not proven by test.** | Low–Medium |
| **Simultaneous W1C clear and flag set** | The set-wins ordering is implemented (same shape as ERRATUM DSU-8) but was never deterministically forced in simulation. | **Medium** |
| **Reset-release skew between domains** | If `preset_n` releases well before `hreset_n`, a toggle raised in pclk could be seen as a spurious event when hclk leaves reset. Safe if the reset controller releases both together (§17.5) and because CR=0 out of reset makes arm events impossible — **but untested.** | Medium |

---

## 13. Recommended next steps for the team (VCS / Verdi)

**In priority order:**

1. **Compile under VCS first, before anything else.** Expect fixes — Icarus is
   permissive about unpacked arrays, variable part-selects (`[N*i +: N]`) and
   hierarchical function calls in the TB. Suggested:
   ```
   vcs -sverilog -full64 -debug_access+all -f tb/dma/filelist_dma_top.f \
       -top tb_dma_top -l comp.log
   ./simv +GWAIT=6 +GRAND=1 +SEED=1
   ```
   The design filelist (`rtl/dma/filelist.f`) and TB filelist compile the same
   RTL, so a pass under either is a statement about the same sources.

2. **Add the Makefile target** (needs your approval — I did not edit the shared
   `Makefile`):
   ```make
   test_dma:
   	$(call run_test,tb/dma/filelist_dma_top.f,tb_dma_top)

   regress_dma:
   	@for s in 1 2 3 4 5 6 7 8 9 10 11 12; do \
   	   $(XRUN) -f tb/dma/filelist_dma_top.f -top tb_dma_top \
   	     +GWAIT=6 +GRAND=1 +SEED=$$s | grep -E "RESULT"; done
   ```

3. **Write the SDC constraints** for the CDC paths — this is the single highest
   risk item. Every `dma_cdc_sync` / `dma_cdc_pulse` / `dma_cdc_gray` needs
   `set_false_path` (or `set_max_delay -datapath_only`), and the quasi-static
   config bus (SAR/DAR/TCR/CR → channel FSM) needs an explicit multi-cycle or
   false path. **Without these, STA will either fail spuriously or — worse —
   pass while the crossings are actually unconstrained.**

4. **Collect coverage.** Spec §14 requires FSM state coverage, register
   coverage and >95% toggle, and none exists. Follow the `tb/cov/garuda_cov.sv`
   pattern (`bind`, no RTL edits). `state_o` is exposed on every channel FSM for
   this. Note `docs/HANDOFF.md` §7's two IMC traps — `-initial_model union_all`
   is mandatory, and `report -summary` shows `n/a` for functional coverage.

5. **Force the untested races explicitly**, ideally with directed tests or
   formal:
   - W1C clear landing in the same cycle as a flag set (set must win).
   - Firmware re-arm in the same pclk cycle as the hardware EN clear.
   - Reset asserted mid-transfer.

6. **Consider formal for the AHB master.** `dma_ahb_master.v` is small,
   self-contained, and its correctness properties are easy to state — HTRANS
   never NONSEQ two cycles running without HREADY, HADDR/HSIZE stable while
   HREADY is low, write address always retracted after a read ERROR. JasperGold
   would close these exhaustively in a way 48,012 directed checks cannot.

7. **Re-run the whole regression once the interconnect and bridge exist.**
   Nothing here says anything about multi-master arbitration or the CDC in the
   AHB-to-APB bridge — the same caveat `rtl/ahb/ahb_mem_slave.v` carries in its
   own header.

---

## 14. Bottom line

**What was achieved:** a complete, spec-traceable, synthesisable 6-channel DMA
controller in `rtl/dma/` (11 RTL files + shared header, 1,944 lines), plus a
self-checking block-level testbench that found and closed one real
timing-dependent CDC bug and now passes 48,012 checks across 72 configurations.
Twelve spec ambiguities and contradictions were resolved on the record rather
than papered over, and four latent failure modes the spec never addressed
(circular-on-error loop, zero-length livelock, illegal HSIZE from a reserved
encoding, and the EN re-arm hang) were guarded in RTL.

---

## 15. Addendum — follow-up session (post-commit)

Small contained fixes only; no architectural change, no new features.

### DMA-2 — a write to any register of a channel swallowed that channel's `CR.EN` clear

- **Files:** `rtl/dma/dma_reg_bank.v` (fix), `tb/dma/tb_dma_top.sv` (new test T17).
- **Status:** FIXED, verified.
- **What was wrong:** the per-channel write block was one
  `if (write to channel c) case(reg_sel) … else if (en_clr_p[c])`. The `else if`
  is skipped whenever that channel is written *at all* — so an APB write to
  SAR, DAR, TCR or SR arriving in the same pclk cycle as the completion pulse
  took the write branch, matched a case arm that does not touch CR, and
  **dropped the clear**.
- **Why it matters:** `en_clr_p` is a one-shot recovered from a toggle
  handshake. A dropped one-shot never retries, so `CR.EN` reads 1 **forever** on
  a channel that has completed and gone idle. The transfer engine keeps working
  (arming is event-driven), which is what makes it nasty — the block behaves
  correctly while its status register lies. The collision is a normal software
  pattern: a completion ISR writes SR (W1C) and re-programs SAR/DAR right in
  that window.
- **Fix:** decode each register independently so **only a CR write** can
  pre-empt the clear — which was always the documented intent of the
  write-priority rule.
- **Evidence:** T17 sweeps the collision phase in 1-hclk steps across 14 trials;
  2 of 14 failed before the fix, 0 after.

### Lint cleanup — blocking assignment in a sequential process

- **File:** `rtl/dma/dma_reg_bank.v`.
- The DMA-2 fix initially used a blocking temp (`ch_hit`) inside the clocked
  block. Functionally correct, but Verilator flagged `BLKSEQ`. Replaced with an
  explicit continuous-assign per-channel write decode (`ch_wr[5:0]`) in a
  generate loop — same logic, no blocking assignment in sequential logic, and
  the one-hot channel select is now explicit.
- **Type:** tool/style improvement, not required by the spec.

### Post-fix results

| Check | Result |
|---|---|
| Lint | 3 warnings — the same three intentional ones from §5. No new warnings. |
| Synthesis (Yosys) | `Found and reported 0 problems`. Still no latches. |
| Regression | 24 runs (4 timing configs × 6 seeds), **16,812 checks, 0 failures** |
| Test count | 757 checks per nominal run (was 653; T17 adds 14 + soak variance) |

Everything in §10–§12 still applies unchanged — in particular, this block is
still **not** verified under the team's toolchain, still has **no coverage
collected**, and still has **no SDC constraints**.

---

**What this is not:** a verified block. It has never been compiled by the team's
simulator, has zero coverage collected, has no timing constraints written, and
has never been connected to the interconnect, bridge, CLIC or any real
peripheral. Simulation under one open-source simulator is evidence, not signoff
— and as TOOL-4 showed, even a green regression can be lying if the
infrastructure underneath it is broken.

---

## 16. Addendum — session 2026-09-12 (pre-integration verification + SoC wiring)

The DMA RTL was **not modified** in this session. The work was: re-verify the
block before wiring it into the SoC, review it line by line for defects the
existing regression cannot see, and then integrate it. This section records what
that found.

> **Bugs have moved.** Every bug in this document — and every bug in every other
> block — is now also registered in `docs/BUGS.md`, which is the single list to
> read. This log stays as the narrative for Block 9. The interconnect and SoC
> work is logged separately in `docs/SOC_RTL_LOG.md`.

### 16.1 Regression re-run — the numbers reproduce

Rebuilt from scratch on a fresh `oss-cad-suite` (the previous session's install
had been cleaned out of the temp directory) and re-run unchanged:

| Config | Seeds | Result |
|---|---|---|
| `+GWAIT=0` | 1–12 | 12/12 PASSED |
| `+GWAIT=1/2/4/6/10 +GRAND=1` | 1–12 each | 60/60 PASSED |

**72 runs, 49,020 checks, 0 failures.** (The check count differs from §8's
48,012 because T17 and the soak's seed-dependent variance were added in the
follow-up session; the per-run count is 757 at the nominal config, as §15
records.)

After the DMA-3 fix and its four new tests (T18, T19, T20a/b/c), the same sweep
runs **72 runs, 50,964 checks, 0 failures**.

### 16.2 Line-by-line review — one new finding

All 11 RTL files were read against the spec. One genuine defect was found, by
reading rather than by simulation — and subsequently fixed in this same session:

**DMA-3 — an arm event delivered outside IDLE was silently discarded.**
`dma_channel_fsm.v` tested `arm_pulse` only in `DMA_ST_IDLE`. An arm arriving in
CONFIGURED, WAITING, TRANSFERRING or COMPLETE was dropped with no record, while
the register bank had already accepted the CR write — so **CR.EN read 1 on a
channel that would never run.** Same failure shape as DMA-2 (the status register
lying) and worse, because the block genuinely did nothing.

It was initially recorded as OPEN with a recommendation, on the grounds that the
fix changes a behaviour §6.6 calls undefined. **That call was reversed and the
bug is now FIXED**, because the reasoning behind leaving it open did not survive
contact with the COMPLETE window: that state is a single hclk cycle, the arm
toggle takes three hclk flops to cross from pclk, and firmware therefore lands
in it on the luck of the clock phase with no way to avoid or detect it. In that
cycle the transfer **has** finished, so the request is legitimate and dropping
it is simply wrong. "Undefined" covers re-arming a running channel; it does not
cover a completion ISR doing exactly what §6.6 tells it to do.

**The fix is a deferred start** — the doorbell arrangement standard for a DMA
engine that takes work from a register write. The full derivation, the four
deliberate properties (one-bit coalescing, EN not cleared on restart, the `en_h`
qualifier, CIRC absorb) and the rejected PL330-style alternative are in DESIGN
NOTE 4 in `rtl/dma/dma_channel_fsm.v` and in `docs/BUGS.md` §3. The contract it
establishes is worth repeating here because it is a programming-model change:

> A CR write with EN=1 **always** starts a transfer. If the channel is busy, the
> transfer starts when the current one finishes. Ten such writes while busy
> queue **one** restart, and that restart uses the descriptor as it stands when
> it runs, not a stale copy.

**Two near-misses inside the fix**, both caught by tests written for it, both
recorded in `docs/BUGS.md` as DMA-3a: the deferred start initially had no `en_h`
qualifier (so a queued start fired on a channel software had already disabled),
and once qualified it did not clear the pending bit when it declined (so IDLE
consumed it on the next cycle and the channel ran anyway). The second is the
instructive one — the qualifier without the clear is worth nothing, and the
obvious "did it get disabled?" check passes in both cases because the extra
transfer still ends with EN=0.

**Cost:** 6 flip-flops, one per channel. The block goes from 1,731 to 1,737
flops; 6,819 cells, still zero latches, still `Found and reported 0 problems`.

Everything else reviewed as correct. Three things are worth recording as
*confirmed* rather than merely unexamined:

- **`DMA_ST_TRANSFER` has no abort path**, so a software `CR.EN` clear can never
  abandon a beat mid-flight. Exactly what SPEC-9 requires.
- **`dma_ahb_master` latches `src_r`/`dst_r`/`size_r` at beat start**, so an
  arbitrarily long external stall in `S_RADDR` — which the interconnect makes
  routine and which the block TB never produced — cannot let the channel's
  working registers move under a live address phase.
- **`S_RADDR` deliberately does not sample HRESP.** Under the interconnect this
  is now also guaranteed from the other side: `ahb_master_port` returns
  `HRESP=OKAY` to any master that does not own the current data phase.

### 16.2a Tests added for DMA-3

| Test | What it actually checks | Catches |
|---|---|---|
| T18 | Re-arm during TRANSFERRING with a **re-programmed destination**. Both laps must run, the second must land at the new DAR — which also proves the deferred start re-reads the descriptor rather than replaying a stale copy. | MUT-6 (10 failures) |
| T19 | The COMPLETE collision, swept in 1-hclk steps across 30 phases. The arm write is **launched before the transfer ends**, because a write issued afterwards always arrives once the channel is safely back in IDLE — where even the broken RTL worked. 16 of the 30 phases lose the arm without the fix. | MUT-6 |
| T20a | A disable overtaking a queued start. Uses a **40-beat** transfer: against a short one both APB writes land after the channel has already finished, which tests the ordinary arm-from-IDLE path and proves nothing. | MUT-7, MUT-8b |
| T20b | A queued start must not resurrect a **faulted circular** channel (spec §6 guard vs the §4 feature). The discriminating check is the **bus-error count**, not the beat count: a channel that restarts onto a faulting address moves no data at all, so `ack_count` and the destination memory look identical either way. Needed a new per-channel `err_count` probe. | MUT-9 |
| T20c | A disabled, **parked** channel must not wake and run a queued start. Runs the source FIFO dry so the channel sits in WAITING with no request — the only way to reach the abort branch, since a top-priority channel with a non-empty FIFO is granted the same cycle it enters WAITING. | *(nothing — see below)* |

T20c is reported honestly as non-discriminating. It checks a real requirement
and passes, but removing the line it was written for (MUT-8a) fails nothing:
with EN already low a retained request is consumed by IDLE and re-aborts on the
next pass, costing one pointless CONFIGURED→WAITING→IDLE lap that moves no data
and changes no status. The line is kept as defence in depth and the RTL comment
says plainly that it is not covered.

### 16.3 What the interconnect changes for this block

The DMA now sits on a real shared bus for the first time. Three interactions
were traced in detail before wiring (full derivations in
`rtl/ahb/ahb_arbiter.v` and `rtl/ahb/ahb_master_port.v`):

1. **HTRANS can rise while HREADY is low.** `dma_ahb_master` leaves `S_IDLE` on
   its *internal* beat-start handshake, which is not qualified with the external
   HREADY. It can therefore raise HTRANS from IDLE to NONSEQ in the middle of
   another master's wait state. The interconnect's arbiter freezes its grant
   from the first cycle an address phase is presented until the slave accepts
   it, precisely so that this cannot swing HADDR under a live transaction. **The
   DMA is the reason that freeze exists.**

2. **The read→write beat is never split.** During `S_RDATA_WADDR` the DMA is
   both the data-phase owner and a requester, and it is the highest-priority
   master, so it wins the arbitration for its own write address phase
   unconditionally. During `S_WDATA` it drives HTRANS=IDLE and the bus can be
   handed on — which is exactly why HWDATA must be muxed on the data-phase
   owner, not the grant (ERRATUM AHB-1 in `docs/BUGS.md`). Following the
   interconnect specification literally here would have written another master's
   store data into the DMA's destination, with every DMA status bit reading
   success.

3. **The write-address cancel survives the fabric.** Traced cycle by cycle: on
   ERROR cycle 1 the slave drives HREADY=0/HRESP=ERROR, the DMA's `hresp` is
   ungated because it *is* the data-phase owner, it jumps to `S_ERROR`, and the
   arbiter's freeze keeps the grant on the DMA — so on ERROR cycle 2 the DMA's
   HTRANS=IDLE is what reaches the slave and no write is accepted. SPEC-10's
   "requirement on the interconnect" is now normative in
   GARUDA-AHB-SPEC-001 §1.4 and honoured by the default slave, `ahb_lite_sram`
   and `ahb2apb_bridge_model`.

### 16.4 SoC-level results for the DMA

`tb/soc/tb_soc_ahb.sv` runs `sw/tests/soc_dma_smoke.S`: the CPU programs channel
0 over a real 200→100 MHz AHB-to-APB bridge and the DMA moves 64 words inside
Data SRAM while the I-Port fetches from Boot ROM and the D-Port polls `SR` over
that same bridge.

| Result | Value |
|---|---|
| DMA address phases observed | **128** — exactly 64 beats × (1 read + 1 write) |
| Destination buffer, checked through the memory backdoor | 64/64 words correct, in order |
| `SR.ERROR` | clear |
| `CR.EN` after completion | cleared by hardware |
| Longest request-to-grant wait | **12–13 hclk**, set by the bridge's data phase, not by arbitration |
| Configurations passed | 7 wait-state configs × 4 seeds, 2,296 checks, 0 failures |
| Re-run after the DMA-3 fix | unchanged: 28 runs, 2,296 checks, 0 failures |

This is the first time the DMA's configuration path has crossed a real clock
domain boundary in a system context — the block TB drove APB directly. It is
**not** the first exercise of the DMA's own CDC, which the block TB has always
stressed at 200/100 with a deliberate 1.3 ns skew.

### 16.5 What is still not verified about this block

Everything in §11 and §12 still applies unchanged. The SoC integration closes
exactly two of those rows and opens one:

| §12 row | Status after this session |
|---|---|
| *Real AHB interconnect* | **Partially closed.** The DMA has now arbitrated against the CPU's two masters, through a real decoder, with per-beat preemption measured. Still against modelled memories. |
| *AHB-to-APB bridge* | **Partially closed.** Configuration now crosses a real 200/100 handshake — but against `tb/ahb/ahb2apb_bridge_model.v`, which is a stand-in, not Block 8. |
| *Real peripherals* | Unchanged — and now the most important gap. |

**New gap opened by the integration:** the SoC test is memory-to-memory. A P2M
transfer whose *source* is a peripheral FIFO behind the bridge — the IMU case in
§13.2, the reason this DMA exists — has never run through the real path. The
block TB covers P2M against a direct slave only. `dma_req`/`dma_ack` are tied low
at SoC level. This is the single most valuable test still to write.

**Closed this session:** DMA-3 (§16.2). The block now has no open RTL defect —
what remains in `docs/BUGS.md` §3 for Block 9 is three *waived* limitations
(DMA-4 SR.REMAINING across the TCR load, DMA-5 event merging in
`dma_cdc_pulse`, DMA-6 the unforced W1C/set race) and the twelve specification
defects already resolved in RTL.

Coverage is still zero, no SDC exists, and none of this has been compiled by the
team's simulator.
