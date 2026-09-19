# GARUDA verification — engineering log

Complete record: what was done, in what order, every bug found, how it was found, and
how it was fixed. Companion to `docs/HANDOFF.md` (reference) and `docs/HOWTO_RUN.md`
(command reference).

---

## PART 0 — Live demo script

Every command verified working. **Do the first line in any new terminal or nothing works.**

```bash
cd ~/garuda_soc
source scripts/setup_env.sh          # six OK lines
```

| # | demo | command | expected | time |
|---|---|---|---|---|
| 1 | Boot | `make test_boot` | `TOHOST=1 -> PASSED (5 instructions retired)` | ~30 s |
| 2 | C program | `make test_c` | `TOHOST=1 -> PASSED (98 instructions retired)` | ~1 min |
| 3 | ISA + Spike lockstep | `make regress` | `PASS=63 FAIL=0` | ~8 min |
| 4 | Slow memory | `make regress_wait` | `PASS=63 FAIL=0` | ~10 min |
| 5 | Random memory timing | `make regress_rand SEED=1` | `PASS=63 FAIL=0` | ~12 min |
| 6 | Directed corner cases | `MAXCYC=400000 make test_sanity` | `PASS=9 FAIL=0` | ~3 min |
| 7 | DSU vs golden model | `make test_dsu` | `mismatches : 0` | ~2 min |
| 8 | Block-level unit TBs | `make test_units` | 6 lines, all `FAIL=0` | ~4 min |
| 9 | Coverage | `./scripts/run_coverage.sh` | merged report | ~15 min |

**Run #3 before the meeting** so the databases are warm. If time is short, demo 1, 2, 3, 7.

### Showing a bug rather than just claiming it

The commit log is the proof the pipeline is really executing:

```bash
head -6 sim/regress/add.commit.log     # pc, rd, value per retired instruction
```

Show the boot test's golden reference — `sw/tests/boot6.S` documents the expected log in
its header, and instruction 3 (`add x3,x1,x2 -> 0xc`) can only be right if **both** EX
forwarding paths work. A core with broken forwarding produces 0 there and still "runs".

Show a lockstep divergence report format:
```bash
cat sim/regress/*.lockstep.txt 2>/dev/null | head -12    # empty now: everything matches
```

---

## PART 1 — Starting position

The RTL was complete for the core (`rtl/core`, 34 files) and the DSU (`rtl/dsu`, 19), with
six unit smoke tests and an elaboration. **No testbench had ever run a real instruction
stream** — every existing test drove pipeline-stage inputs by hand.

Empty directories, then and now: `rtl/ahb`, `rtl/clic`, `rtl/dma`, `rtl/debug`,
`rtl/isram`, `rtl/dsram`, `rtl/ahb2apb`, and every peripheral. **There is no interconnect
and no TCM.** That shapes everything below.

### Decision 1 — build a dual-port memory model, not a fake fabric

`garuda_core_top` exposes two independent AHB-Lite masters (I-port, D-port) and there is
no arbiter or decoder to connect them to. Options were: write a fake interconnect, or
attach both masters directly to one memory image through two ports.

**Chose two ports.** A fake arbiter would have been unverified RTL pretending to be
verified, and any bug in it would masquerade as a core bug. `rtl/ahb/ahb_mem_slave.v`
states in its header exactly what it therefore does **not** verify: arbitration, address
decoding, bridge CDC. Nothing about a passing run should be read as evidence about the
interconnect.

---

## PART 2 — Booting (mentor item 1)

### Built
| file | purpose |
|---|---|
| `rtl/ahb/ahb_mem_slave.v` | dual-port AHB-Lite memory, wait-state and error injection |
| `tb/soc/tb_boot.v` | loads `+HEX`, runs, records a commit log, reports via `tohost` |
| `sw/tests/boot6.S` | 6 instructions, hand-checked golden reference in its header |
| `tools/elf2hex.py` | binary → `$readmemh` image |

### Decision 2 — how to get a PC onto the commit log

The core carries no PC past EX/MEM, so WB has a retire tag but nothing to attach it to.
Options: add a trace port to `mem_wb_reg` (touches RTL), or shadow it in the testbench.

**Chose the shadow.** `mem_wb_reg` has no hold path — it bubbles on wait, never holds —
so one TB register clocked with the identical flush term tracks `em_pc` exactly. **Plus
an assertion**: if a retirement ever arrives while the shadow believes no instruction is
there, the TB stops rather than emit a commit log that silently lies about PCs. Adding a
trace port would have meant modifying the RTL under test to observe it.

### First run: 0 instructions retired in 2000 cycles

---

### 🐛 BUG 1 — ERRATUM I-1, `garuda_iport_ahb_master.v`

**Symptom.** Core executed nothing. Redirected to `0x00000000` on instruction one and
spun forever.

**How found.** Added `+DBGBUS` (fetch path) → fetch looked healthy for 4 instructions,
then a redirect to address 0. Added `+DBGTRAP` → `id_illegal=1`, cause 2, on
`addi x1,x0,5` — the simplest instruction in the ISA. The `OP_IMM` decode is correct, so
the *instruction word* was suspect. Printed it per stage: IF/ID held
`pc=0x10000000, instr=0x00000000` while the real instruction arrived that same cycle.

**Root cause.** `fetch_outstanding` was set on the same edge that drove `i_haddr_o`/
`i_htrans_o`. Because those are **registered**, that cycle *is* the address phase, so
`data_phase_done = fetch_outstanding & i_hready_i` fired one cycle early and sampled
HRDATA before the slave drove it. Every instruction was paired with the previous bus
cycle's data — correct PC tag, stale instruction word.

**Fix.** AHB-Lite is pipelined: the address phase of transfer N+1 overlaps the data phase
of N. One flag cannot express that. Split into `addr_outstanding` and `data_outstanding`,
with `drop_cnt[1:0]` replacing `drop_pending` because up to **two** transfers can now be
in flight across a redirect.

**Result.** Commit log matched the hand-written golden reference exactly — including
`x3=0000000c`, proving both EX forwarding paths.

---

### 🐛 BUG 2 — ERRATUM D-1, `d_port_ahb_master.v`

**Symptom.** Instructions retired correctly, but `tohost` never fired — the test hung.

**How found.** `+DBGD` showed the store reaching the bus with the right address and data
(`addr=1000f000 wdata=00000001`) — but that was the **address** phase.

**Root cause.** Same conflation, data side. `d_hwdata_o` came from the same combinational
block as HADDR/HTRANS, so once the address phase completed the pipeline advanced,
`start_i` fell, and HWDATA collapsed to 0 in the very cycle the slave samples it.
**Every store wrote zero.** Loads had the mirror defect: `ok_done_o`/`mem_stall_o`
released on the address phase, so `load_formatter` sampled HRDATA a cycle early.

**Fix.** Two-state FSM (`S_ADDR` → `S_DATA`). HWDATA registered at address-phase
acceptance, held across wait states. Completion is now a data-phase event.

**Note for the meeting:** the module's old header claimed the upstream pipeline hold kept
operands stable so the FSM "does not need to latch its own copy." True for HADDR/HSIZE,
**false for HWDATA** — because the hold is released by the very event that starts the
data phase.

**Result.** `boot6` passed. **First program ever executed on GARUDA.**

---

## PART 3 — C verification (mentor item 2)

### Built
`sw/common/crt0.S` (stack, `.bss` zeroing, `main()`, tohost handshake),
`sw/common/link.ld` (memory map at `0x1000_0000`), `sw/tests/ctest1.c` (10 checks:
`.data` survival, sign/zero-extending loads, `.bss` zeroing, all store widths, calls and
stack, M-extension including negative multiply), `sw/Makefile`.

### ⚠️ TRAP 1 — the PIC/GOT problem (NOT an RTL bug)

**Symptom.** C test reached crt0's exit path, then wrote to address 0.

**How found.** Disassembled the ELF: `la t0, tohost` had compiled to
`auipc t0,0x0 ; lw t0,640(t0)` — a **GOT load**.

**Root cause.** The Vitis GCC defaults to PIC. On bare metal nothing populates the GOT,
so `t0` loaded as **zero**. The core executed the sequence perfectly.

**Fix.** `lla` instead of `la` (always PC-relative, never GOT), `-fno-pic` in CFLAGS,
`-no-pie -static` in LDFLAGS. All three needed. Documented at length in `crt0.S` because
it reads exactly like a broken load unit and will cost the next person an afternoon.

### ⚠️ TRAP 2 — linker script section placement

`tohost` landed right after `.data` instead of `0x1000F000`. A section with an explicit
`. = addr;` **and** a `> RAM` region assignment lands wherever the region pointer is —
the region allocator wins. Fixed by putting the address on the section itself:
`.tohost _tohost_addr (NOLOAD) : {...}` with no region.

**Result.** `ctest1` passed, 98 instructions.

---

## PART 4 — Spike lockstep (mentor items 3 + 6)

### Decision 3 — normalise before comparing

Spike's `--log-commits` output and our commit log describe the same events in different
alphabets. Diffing raw produces thousands of mismatches, all formatting, with the real
bug invisible inside.

**`tools/lockstep.py` reduces both sides to `(pc, rd, value)`** and deliberately discards:
disassembly lines, the instruction word (PC + image determines it), CSR write
side-effects, memory write records, and x0 writes. It reports **only the first
divergence** — everything after is downstream of the same bug.

### ⚠️ TRAP 3 — Spike's UART sits on our reset vector

`spike -m0x10000000:0x40000` fails with `devices ... overlap`: Spike's NS16550 is
hard-wired at `0x1000_0000`, exactly GARUDA's reset vector. Working invocation needs
`--disable-dtb --pc=0x10000000`. Side effect: HTIF can no longer terminate on the tohost
write, so Spike runs into the post-tohost spin loop — handled by truncating both logs at
the terminal self-branch.

### Decision 4 — a custom riscv-tests environment

Upstream's `p` env links at `0x8000_0000` and reports through an ECALL trap handler.
**Wrote `sw/riscv-tests/env/riscv_test.h`** that reports by direct `tohost` store, so an
ADD failure is reported by ADD, not by the trap unit. The trap paths get their own suite
later. First run: **39/44**, all five failures stores.

---

### 🐛 BUG 3 — ERRATUM F-1, `id_ex.v` + `ex_stage.v`

**How found.** Lockstep pointed at one instruction: a load returned `0x00000617`, which
is the *instruction word* at `0x10000230` — the pre-`addi` value of `a2`.

```
10000234: addi a2,a2,784   -> a2 = 0x10000540
10000238: sw   a3,0(a2)    -> used 0x10000540   (correct)
1000023c: lw   a4,0(a2)    -> used 0x10000230   (STALE)
```

**Root cause.** The store stalls MEM for its two-phase AHB access. While `lw` is held in
EX, the producing `addi` drains out of MEM/WB — and `pipe_ctrl` **bubbles** MEM/WB every
wait-state cycle by design. The forward mux is combinational, so when the producer
disappears the operand silently reverts to the stale register-file value read in ID.

**Fix.** Expose the post-forward operands from `ex_stage`; `id_ex` **captures** them while
held. Idempotent: on the first held cycle the producer is still visible; on later cycles
the select is already `FWD_NONE`, so the mux returns this register's own now-correct value.

---

### 🐛 BUG 4 — ERRATUM P-1, `pipe_ctrl.v`

**How found.** One test left (`ld_st`): a load never retired, a later read returned `X`,
one PC retired twice. `+DBGM` showed the load vanish from the pipeline entirely.

**Root cause.** The load-use interlock bubbles ID/EX so a gap opens *behind* a load that
has already advanced into EX/MEM. During a D-port wait that premise is false — EX/MEM is
held — so flushing ID/EX **destroys the load parked there**. Flush outranks stall inside
`id_ex`, so the hold does not save it.

**Fix.** Gate `load_use_stall_i` by `~mem_stall_i` — exactly as redirects were already
gated on line 24 of the same file. One term.

**Result: 44/44**, self-check and lockstep, at zero wait states and with
`+IWAIT=2 +DWAIT=3`.

> **Important pattern for the meeting:** F-1 and P-1 were **unreachable until D-1 was
> fixed**. With a one-cycle D-port there was never a multi-cycle MEM stall to expose them.
> Any wait-stated memory would have triggered both in silicon.

---

## PART 5 — Trap handler environment (unlocks items 3, 6, 7)

### Decision 5 — a second env, alongside the first

**Created `sw/riscv-tests/env/p/riscv_test.h`** rather than replacing the tohost env.
Keeping the trap unit out of base ISA tests is a property worth keeping. Three
GARUDA-specific deviations from upstream, all documented in its header:

1. **`trap_vector` must be 64-byte aligned** — `trap_ctrl` masked `mtvec[5:0]`. Upstream
   uses `.align 2`; on GARUDA that silently relocates the handler backwards.
2. **No `fence`** — it trapped as illegal at the time, and upstream's `RVTEST_PASS`
   opens with one, so every *passing* test would have trapped on its way out.
3. **No supervisor mode** — GARUDA is M-only.

### Decision 6 — write the divide emulator

`decode_control` deliberately raises illegal for DIV/DIVU/REM/REMU (Sec. 7.2): no hardware
divider, software emulates from the trap. **That software did not exist**, so div/rem
simply did not work. Wrote `sw/riscv-tests/env/p/divrem_emu.S`: saves all 31 registers
(needed for indexed rs1/rs2/rd access), decodes the faulting instruction, does a
restoring shift-subtract divide, writes the result back into the saved context, advances
`mepc`, returns. Later extended to misaligned load/store emulation via a shared
cause dispatcher.

### ⚠️ TRAPS 4 & 5 — two Spike misconfigurations that looked like RTL bugs

- **`--isa=rv32im` does not imply Zicsr.** Every CSR instruction decoded as illegal in the
  golden model. The rv32ui/um tests never touched a CSR, so it stayed hidden until the
  trap suite.
- **Spike defaults to MSU privilege.** The env's `csrwi mstatus,0` + `mret` dropped it to
  **User mode**, so M-mode CSR accesses correctly trapped — against a core that never left
  M-mode. Fixed with `--priv=m`.

Both produced confident-looking "divergences" against perfectly correct RTL.

---

### 🐛 BUG 5 — ERRATUM C-1, `decode_control.v`

**How found.** `rv32mi/shamt`. Spike trapped; GARUDA did not.

**Root cause.** SLLI/SRLI/SRAI examined only `funct7[5]` and ignored the other six bits.
RV32 requires `instr[31:25]` to be exactly `0000000` (or `0100000` for SRAI). So
`slli x1,x1,32` — encoded with `instr[25]` set — executed as a shift by **zero** instead
of raising illegal.

**Fix.** Full `funct7` comparison on both shift-immediate forms.

---

### Decision 7 — separate "not applicable" from "waived"

Four tests pass their own self-check but cannot match Spike instruction-for-instruction:

- **`p-div/divu/rem/remu`** — GARUDA emulates in ~100 instructions where Spike's hardware
  divider retires one. **It would be wrong if they matched.**
- **`p-csr`, `p-mcsr`, `p-ma_fetch`** — `misa` bit 23 ("X", non-standard extension) is set
  by `csr_file.v` because of the DSU. GARUDA reports `0x40801100`; Spike says
  `0x40001100`. **GARUDA is right and Spike cannot know about the DSU.**

These are in a `NO_LOCKSTEP` list in `run_regression.sh` **with the reason written next to
each**, and each still must pass its own check. Not waivers.

---

### 🐛 BUG 6 — ERRATUM P-2, `pipe_ctrl.v` — the timing-sensitive one

**Symptom.** `rv32mi/ma_addr` **failed with fast memory and passed with slow memory.**

**How found.** From the commit log: `lb t0,0(t0)` retired with `t0 = 0xffffffcc`, then the
very next retirement was `fail` — the `beqz` in between **never retired at all**, yet the
branch was taken.

**Root cause.** A load-use stall holds the branch in IF/ID. The ID-stage branch predictor
fires a redirect for that same branch in the same cycle, and `if_id_flush_o = redirect`
**flushes the branch itself out of existence**. It never reaches EX, is never resolved,
and the predicted target stands unchallenged.

**Fix.** An ID-stage redirect is only meaningful if the branch actually *issues* into
ID/EX. Gated `id_redirect_valid_i` by `~load_use_stall & ~dsu_busy & ~wfi_hold` — the
same reasoning that already gated redirects by `~mem_stall`.

**Why this one matters most:** a bug that depends on memory timing is exactly the kind
that survives to silicon and reproduces once a month.

---

### 🐛 BUG 7 — ERRATUM T-1, `branch_unit.v`

**How found.** `rv32mi/ma_fetch`. Spike trapped, GARUDA continued.

**Root cause.** **Cause 0 (instruction-address-misaligned) was not implemented at all.**
Without the C extension, a jump to an address with bits[1:0] ≠ 0 must trap. GARUDA
fetched from it and carried on.

**Fix — with a correction worth mentioning.** First attempt hung the check off
`ex_redirect`, which **missed JAL entirely** — JAL and predicted-taken branches redirect
from **ID**, not EX. Moved the check into `branch_unit`, which computes every target and
sees all three transfer types.

---

### 🐛 BUG 8 — ERRATUM T-2, `csr_file.v`

**How found.** Same test, next failure. Cause 2 at `csrsi misa,4`.

**Root cause.** `misa` was in the read-only list. It is **WARL**: a write selecting an
unsupported extension must be *ignored*, not trap. `csrsi misa,4` is the standard way
software probes for the C extension — so a correct probe was answered with a trap.

**Fix.** Removed MISA from `is_ro`. It was already absent from the write-enable decode, so
writes had no effect anyway; it only had to stop being *reported* as illegal.

---

### 🐛 BUG 9 — ERRATUM T-3, `trap_ctrl.v`

**How found.** `rv32mi/breakpoint` timed out. The trace looped over the handler's setup
code forever.

**Root cause.** `mtvec_base = {mtvec_i[31:6], 6'b0}` — masked to a **64-byte** boundary.
The spec requires only 4-byte alignment for `mtvec`; the 64-byte rule belongs to `mtvt`
(the CLIC vector table), which is a separate CSR this design already has. The test set
`mtvec = 0x100003d8`; GARUDA vectored to `0x100003c0`, mid-setup, and re-trapped forever.

**Fix.** `{mtvec_i[31:2], 2'b0}`. This is also *why* the p-env had to force `.align 6` —
that workaround is now belt-and-braces rather than load-bearing.

---

## PART 6 — Core Sanity TB (mentor item 3)

Worked the 22 P0 rows of the verification plan's Phase-2 sheet. Seven rows needed
capability the testbench did not have: CLIC interrupt injection, bus-error injection,
randomised per-access wait states.

### Decision 8 — extend `tb_boot`, don't write a second TB

It already had the memory model, commit-log probe and tohost handshake, and rows 1, 2, 3,
5, 6, 10, 11, 12 were already satisfied by existing work. Added: CLIC injection (held
until acknowledged — a one-cycle pulse would be legal to drop and prove nothing),
bus-error address window, seeded random wait states.

Six directed tests: `t_flush` (row 22 — the highest-value row, aimed straight at the
`drop_cnt` logic rewritten in I-1), `t_buserr`, `t_irq`, `t_wfi`, `t_dsu`, `t_loadbranch`.

---

### 🐛 BUG 10 — ERRATUM P-3, `pipe_ctrl.v`

**How found.** `t_wfi` reported `x22 = 0x17d` — the instruction after WFI executed **381
times** instead of once. `t_dsu` hung.

**Root cause.** `dsu_busy` and `wfi_hold` hold ID/EX but `hold_ex_mem` covers only
`mem_stall`, so EX/MEM kept latching the outputs of the very instruction parked in ID/EX
— re-committing it every held cycle.

The existing comment claimed re-presenting was harmless "because WFI writes no
architectural state." True only if the WFI is what's parked — but `wfi_active` is a
**registered** latch, so by the time the hold rises the WFI has already advanced and the
instruction *behind* it is sitting there.

**Fix.** `ex_mem_flush_o` now includes `dsu_busy | wfi_hold`, excluding `mem_stall` where
EX/MEM is genuinely held rather than advancing.

---

### 🐛 BUG 11 — ERRATUM DSU-1, `dsu_stall.v`

**How found.** `t_dsu` spun on one PC until timeout; `dsu_busy` latched high permanently.

**Root cause.** `stall_now` compares the current EX instruction against
`prev_was_2cycle` — but asserting `dsu_busy` **holds ID/EX**, so next cycle the "current"
instruction is the *same one*: still a 2-cycle readback, same accumulator. And
`prev_was_2cycle` only updated when `~stall_now`, so it never cleared. Self-sustaining.

**Fix.** One-shot: `stalled_once` records that this instruction has already been held, so
the interlock inserts exactly one bubble and cannot re-deadlock.

> This confirmed a deadlock I had earlier flagged as *suspected* but could not prove.

---

## PART 7 — DSU verification (mentor item 5)

### Decision 9 — reuse the existing golden model, write no second one

`tools/golden/DSU_Golden.py` already had `DSUModel`, cycle-accurate and validated against
RTL; `tools/gen/DSU_gen.py` already generated stimulus and expected vectors. Only
`tb/dsu/tb_dsu_top.sv` was missing — the file the DSU plan's Infrastructure sheet row 4
lists as NOT WRITTEN. **Wrote only that.** A second model would be a second thing to keep
in sync, and the two would drift.

### Correction I had to make

I earlier told the team "the DSU never computes — the accumulators never change." **That
was wrong.** `DSU_Golden.py` already documented the real behaviour: a product issued in
cycle K reaches `acc` only on the next cycle asserting `write_en` for that accumulator, so
the final product of a sequence is **stranded**. My repro (`MACCLEAR, MAC_SEL, MACRD_LO`
with nothing else touching acc0) hit precisely that. It is FLAG-C, already in the plan.

---

### 🐛 BUG 12 — ERRATUM DSU-2 (FLAG-A), `mac_unit.v`

`write_en` gated **both** the pending-product registers and `acc`, so MACLOAD, MACCLEAR
and MACSAT each latched the CSA1 output — the product of their own *architecturally
meaningless* operand fields — and the next accumulate added that garbage in. Masked only
because the generator drove `rs1=rs2=0` for clear/load.

**Fix.** Separated two obligations the old code conflated: `prod_en` (only a genuine
multiply may latch a new pending product) and `pend_clr` (clear/load/saturate replace the
accumulator outright, so any pending product is stale and must be **discarded**). The
second is a case the plan did not list — a product from *before* a MACCLEAR would
otherwise land in the accumulator *after* it.

### 🐛 BUG 13 — ERRATUM DSU-3 (FLAG-C), `dsu_stall.v`

`cur_is_2cycle` listed only readback ops, so compute→readback was not interlocked.

**Fix.** Compute ops (`MAC_SEL`, `MACSUB`, `MACABS`, `MACDOT`) now count as 2-cycle
producers.

**Decision 10 — RTL interlock, not a software ordering contract.** The contract would be
free today and permanent afterwards: nothing in the assembler, the compiler or the ISA
encoding could enforce "do not read an accumulator in the cycle after you write it," so
every future DSU programmer would have to know it. One cycle on a readback — not in the
MAC inner loop — is the cheaper side of that trade.

### 🐛 BUG 14 — ERRATUM DSU-4, `mac_unit.v` — the one that actually mattered

**The interlock alone did not fix FLAG-2.** After DSU-3, `dsu_flag2.S` still read 0.

**Root cause.** `acc` was written only when `write_en` was asserted — i.e. only when a
**new instruction arrived**. The multiply is a two-stage pipeline: stage 1 latches the
product, stage 2 folds it into `acc` the following cycle. With no instruction on that
cycle, **stage 2 never clocked** and the product sat in `sum_reg`/`carry_reg`
indefinitely. Stalling cannot help when the commit needs an instruction that never comes.

**Fix.** A `pending` flag makes stage 2 self-draining: a product latched this cycle
commits on the next, instruction or not. Back-to-back computes still chain correctly.
FLAG-B preserved — flush clears the *pending* product but leaves `acc` intact, because a
trap must not destroy committed accumulator state.

**Result.** `dsu_flag2.S` returned 15 (3×5) on all three reads. **FLAG-2 closed.**

### 🐛 BUG 15 — ERRATUM DSU-5, `barrel_shifter.v` — a classic Verilog trap

**How found.** `tb_dsu_top` vs the model: `acc >> 45` returned `0x00000007` instead of
`0xffffffff`.

**Root cause.**
```verilog
shift_dir ? (cluster_out << shift_amt) : (acc_signed >>> shift_amt)
```
Verilog takes a conditional expression's signedness from **both** arms. The left-shift arm
is unsigned, so the whole expression evaluated unsigned and `>>>` silently degraded to a
**logical** shift. Sign extension simply never happened.

Shift amount 45 is inside the *defined* 0..47 range, so this is not FLAG-D — just a wrong
answer. Hidden until now because nothing had put a negative value into a shifted
accumulator; the FLAG-A fix changed which values reach them.

**Fix.** Each shift gets its own wire, so the signed operand keeps its signed context.

### ⚠️ My own mistake, worth owning

**286 of the initial 429 mismatches were a testbench race**, not RTL: I drove DUT inputs
*at* the clock edge, so the TB and the DUT disagreed about what was on the wire. It
presented as a `csr_clear_overflow` pulse the RTL appeared to ignore. Fixed by driving
`#1` after the edge. I nearly went hunting for a bug that did not exist.

**Result: 429/429, then 645/645 across four seeds.**

---

## PART 8 — Closing the four DSU open questions

The DSU plan's Open Questions sheet had four items marked "confirm the RTL's behaviour is
intended." **Three wanted an RTL change, and one turned out to be a bug.**

| | decision | erratum |
|---|---|---|
| FLAG-D — MACSHIFT amounts 48..63 | **make illegal in RTL**, not documented | DSU-6 |
| FLAG-E — overflow lost on its own clear | **fix**: clear the old, keep the new | DSU-8 |
| I-type `imm[11:9]` ignored | **reserve**: require 0, else illegal | DSU-7 |
| `dsu_en = 0` "untested" | **it was a real hole** | DSU-9 |

**Decision 11 — the principle behind all four:** prefer a rule the hardware enforces over
a rule software is asked to obey. An unenforceable contract is free today and permanent
afterwards. FLAG-D as an ABI note would never be checked by any assembler; as an illegal
encoding it is real.

### 🐛 BUG 16 — ERRATUM DSU-9, `dsu_top.v`
`dsu_busy` was the **only** DSU output not gated by `dsu_en` — `dsu_stall` receives
`is_custom0` straight from the decoder, a bare opcode compare. Every other output carries
`& dsu_en`. It meant the DSU could **stall the pipeline while doing nothing**. Not
reachable today (a bubble writes a NOP, never a Custom-0 word), but reachable the moment
anything presents Custom-0 with `dsu_en` low.

### 🐛 BUGS 17-19 — DSU-6, DSU-7, DSU-8
As decided above. DSU-8 is the one with real consequences: **a poll-and-clear loop
silently dropped any overflow landing on the clear cycle** — a data-integrity hole for APF
code, which is exactly the software that reads that flag.

**Ordering that mattered:** RTL → model → regenerate vectors → compare. The plan warned
the first run would fail because the new illegal terms change what the random generator
produces. It passed **445/445 first try** because the model was updated *before*
regenerating. Regenerating first would have meant debugging a self-inflicted disagreement.

---

## PART 9 — Adopting the teammate's unit testbenches

A teammate pushed six constrained-random block TBs plus VCS coverage reports (~97%).

### 🔍 Finding worth raising carefully

**Their TBs inline a copy of the DUT** (`module decode_control` at line 46, `tb_top` at
860). That copy is a **snapshot** and had already drifted — it predates the shamt fix and
the FENCE decode. So their coverage measured code that is not what ships.

**Fix, designed not to break their flow.** Guarded the inlined copies behind
`` `ifndef GARUDA_REAL_RTL ``, and added `tb/core/filelist_*.f` that define the macro and
compile the **real** `rtl/core` sources. Their standalone VCS build is untouched — it
simply does not define the macro.

Against real RTL, **two of their reference models were wrong** (still expecting the
pre-C-1/C-2 behaviour). Corrected both. Now **14,359 checks, 0 failures.**

**Their ~97% figures need regenerating before anyone quotes them.**

---

## PART 10 — Coverage (mentor item 4)

### The blocker, and how it was actually solved

IMC on this machine is **Incisive 15.20** and **cannot read an Xcelium 22.09 database**:
`*E,DBERR: serialization exception`. No format-downgrade option in `xrun`, no UCIS XML
export, no newer IMC.

**I initially reported this as blocked pending VCS. That was wrong** — I had only looked
for a newer *reader*. The answer was an older **writer**: `irun` 15.20 is installed in the
same tree, matches IMC's vintage, and the design builds and runs under it unchanged.

**Decision 12 — two simulators on purpose.** `xrun` for regression (fast; every bug was
found there), `irun` for coverage collection. Both consume the **same filelists**, and the
functional percentages cross-checked between them agree exactly — an independent check on
the covergroups themselves.

### Two IMC traps that silently produce wrong answers

1. **`-initial_model union_all` is mandatory.** The default (`primary_run`) builds the
   merged model from the *first run only* and **discards every run with a different top
   module** — all seven unit databases contributed **nothing**, and the merge reported
   **no error**. The DSU internals sat unchanged and looked like a genuine gap.
2. **`report -summary` shows `n/a` for functional coverage** even when covergroups are
   populated. Use `report -detail -metrics covergroup`.

### 🐛 BUG 20 — ERRATUM T-4, `trap_ctrl.v` — found while chasing coverage

`clic_ctrl` sat at **5.58%**. Wrote `t_clic.S` (id/level/threshold sweep, both arms of
every take condition) — and it hung.

**Root cause.** `trap_ctrl` had **no `idex_valid` input at all**. `trap_pc_o` uses
`idex_pc_i` for interrupts, and `id_ex.set_bubble` writes `pc_o <= 0`. So **any interrupt
arriving on a pipeline bubble latched `mepc = 0`** — the return address destroyed, `mret`
jumping to address 0, endless instruction-access-fault storm.

Interrupts are architecturally taken *between* instructions, so requiring a valid
instruction in EX is the correct condition, not a workaround. The CLIC holds its request
until acknowledged, so deferring a cycle loses nothing.

**Why `t_irq` never caught it:** it injects at one fixed offset. Plan row 18 says
*"assert CLIC irq at many different offsets into a loop"* — the row I had previously
ticked off with a single-configuration test.

### 🔄 A correction I had to make publicly

I told the team **SHV vectoring was blocked on an unresolved design decision**, based on
interrupts returning `mepc = 0`. After fixing T-4 I re-tested: **SHV passes.** The
corruption was T-4 all along — SHV merely hit that window far more often, arriving at
arbitrary points rather than one fixed offset.

That also **settles `clic_ctrl.v`'s open question by evidence**: the RTL implements the
jump-instruction table interpretation, demonstrated end to end with a 4096-entry table.
`docs/COVERAGE.md` has been corrected.

### 🐛 BUGS 21-23 — C-2, C-3, C-4

- **C-2, FENCE trapped.** No `OP_MISC_MEM` case existed, so FENCE fell through to
  `default: illegal`. RV32I permits FENCE to be a no-op but **not** to trap.
- **C-3, FENCE.I implemented.** I had listed this as "needs a design decision — the
  prefetch buffer has no flush path." **It already had one:** the buffer invalidates
  entirely on *any* redirect. So FENCE.I became an ID-stage redirect to PC+4 —
  architecturally a no-op that discards everything fetched behind it, exactly Zifencei's
  requirement. **No new flush path, no new state.** `riscv-tests fence_i` now passes with
  full lockstep — self-modifying code works.
- **C-4, Zicntr shadows.** `cycle`/`instret`/`cycleh`/`instreth` added as read-only
  aliases. `time` (0xC01) deliberately **not** aliased — it is defined as memory-mapped
  mtime, not a copy of mcycle, and faking it would be wrong.

### The coverage number, stated honestly

DUT **73.24%**; **24 of 44** modules ≥95%. Split by metric:

| metric | mean |
|---|---|
| block (statement) | **98.5%** |
| expression (branch) | **96.1%** |
| toggle | **86.0%** |

**Every module below 95% is at 100% statement coverage.** `clic_ctrl`,
`garuda_if_stage_top`, `garuda_pc_gen`, `trap_ctrl` have **zero uncovered blocks**. The
shortfall is entirely **toggle** — individual bits of wide buses that never change state.
More tests that exercise *logic* cannot move these numbers. Some bits are unreachable in
principle: `mcycleh` needs 2³² cycles to flip its low bit.

**Recommendation to put to the team:** meet the bar on statement/branch, report toggle
separately with per-module written waivers. Chasing toggle bits on buses software cannot
drive produces tests that exist only to move a number.

---

## PART 11 — Final state

| suite | result |
|---|---|
| ISA (rv32ui + rv32um + rv32mi), self-check **and** Spike lockstep | **63/63** |
| — fixed wait states | 63/63 |
| — randomised waits, multiple seeds | 63/63 |
| Core Sanity directed | **9/9** |
| DSU vs golden model | **645/645**, seeds 1,2,3,5,7 |
| Block-level unit TBs | **14,359 checks, 0 fail** |
| Legacy unit smokes | 7/7 |
| Boot / C | pass |

**23 numbered errata fixed. Zero known RTL defects outstanding.**

### The pattern behind four of them

**F-1, P-1, P-2, P-3 are the same shape:** *a flush or hold whose premise is that an
instruction has already advanced, firing while a stall holds it in place.* Anyone touching
`pipe_ctrl` should check every flush term against every hold source.

And **three of them were unreachable until D-1 was fixed.** Fixing one bug made three more
findable — normal, and worth expecting.

### Testbench faults that looked like RTL bugs

Worth saying out loud, because it happened repeatedly:
- driving DUT inputs *at* the clock edge (286 false mismatches)
- a trap handler clobbering a register the test held an expected value in
- a test writing data over its own far-linked code
- Spike misconfigured three separate ways (Zicsr, privilege mode, ISA string)

When RTL and model disagree, **the model is a suspect too.**

---

## PART 12 — Likely questions

**"Why two simulators?"** IMC 15.20 can't read an Xcelium 22.09 database. Moving the
writer back to `irun` 15.20 was cheaper than waiting for a tool. Both use the same
filelists, and the numbers cross-check.

**"Why isn't coverage 95%?"** It is on statement (98.5%) and branch (96.1%). Toggle is
86% and every module below the line is at 100% statement — the gap is bus bits that never
flip, not logic that never ran.

**"Are the excluded tests failures?"** No. `breakpoint` needs a debug module that does
not exist; `pmpaddr` needs PMP, absent by design; `instret_overflow` needs a counter
mechanism to confirm against Sec. 13. Each carries a written reason in the Makefile.

**"How do you know the DSU is right?"** 645 randomised tests per seed against a
cycle-accurate model that is bit-literal about the CSA tree and the 49-bit adder — not an
idealised `a+b+c`. Five DSU bugs came out of that comparison.

**"What's left?"** Reconcile the two `.xlsx` plans' Done columns; agree the coverage
signoff position; tell the teammate their coverage numbers measured a stale DUT snapshot.
No RTL work outstanding.

**"What would you do next?"** The SoC is unverified by construction — no interconnect, no
TCM, no CLIC block, no peripherals. Everything here says the **core and DSU** work. It
says nothing about the chip.

---

## Addendum, 2026-09-02 — starting the interconnect

Work began on the AHB-Lite fabric and APB subsystem. The first thing done was **not**
fabric RTL; it was closing **BUS-A/B/C/D**, the four AHB-Lite protocol errata the checker
had found and reported but which had been left open (see `docs/ORACLES.md` §Oracle 1, and
`docs/HANDOFF.md` §11).

The sequencing argument is worth recording, because the tempting order is the wrong one.
The interconnect is the **first consumer in this project that actually reads HBURST** —
`ahb_mem_slave.v` has never had an HBURST port. So:

1. A decoder must know when a burst is open to know whether it may re-decode between
   beats. Fed a master that opens with SINGLE and continues with SEQ (BUS-A), it is
   entitled to switch slave selection mid-stream.
2. BUS-C is worse with a fabric than without one. Retracting a presented address phase
   desynchronises the master from a slave that has already committed — and with a decoder
   in front, committed to *a particular slave*.
3. BUS-D is invisible without a fabric and a decode defect with one: 1 KB is the minimum
   AHB slave window, so a burst that crosses the boundary crosses between slaves.
4. Debuggability. Build fabric on a mis-signalling master and every new failure is
   ambiguous between the two layers. Worse, `+AHBCHK_FATAL` was **advisory by default**
   precisely because BUS-A/B/C were open — so the fabric's own protocol violations would
   have landed in existing known noise and gone unread.

Point 4 is the one that generalises: **an open known-failure suppresses the oracle that
would catch the next failure.** Leaving BUS-A/B/C open was not a deferred cosmetic fix,
it was a disabled checker.

The default is now fatal (`+NO_AHBCHK_FATAL` demotes it), verified clean across the ISA
regression, both wait-state variants, the sanity suite and a 20-configuration stall and
redirect sweep — and the checker was confirmed still able to fail by re-running the
unfixed RTL against it.
