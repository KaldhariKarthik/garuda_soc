# GARUDA DSU (DSP Support Unit) — Design Specification

## 0.1 Identity

| Field | Value |
|---|---|
| Document ID | GARUDA-DSU-SPEC-001 |
| Revision | 3.0 |
| Date | 2026-09-18 |
| Status | Released for implementation |
| Block | 2 (`dsu`), inside block 1 |
| Owner | Team AeroSoC |
| Supersedes | GARUDA_DSU_Design_Spec_v2_0 |

## 0.2 Revision history

| Rev | Change | Driver |
|---|---|---|
| 1.0–2.0 | Three MACs, 48-bit accumulators, nine Custom-0 instructions. RTL implemented and verified | — |
| 3.0 | **Numeric contract stated for the first time** (§6): Q1.15 operands, Q18.30 accumulators. The EKF acceleration claim is scoped to what the format can actually hold. Overflow guard width resolved. Clock gating on `dsu_busy`. | ADR-0017 |

## 0.3 Normative references

1. RISC-V Unprivileged ISA v2.2 — the `custom-0` opcode space (`0x0B`).
2. `GARUDA-SYS-001` Rev 4.0 — `dsu` section.
3. `GARUDA-ADR-001` Rev 1.0.
4. `GARUDA-CORE-SPEC-001` Rev 3.0 — EX-stage integration, `dsu_busy` as hold source `H4`.
5. `GARUDA-DEBUG-SPEC-001` Rev 2.0 — the accumulator taps.

---

## 1 Purpose and scope

### 1.1 What this is

Three multiply-accumulate units with 48-bit accumulators, decoded from the Custom-0 opcode
space in the core's EX stage. It exists to make the APF collision-avoidance inner loop and
the bounded matrix products of the EKF cheap.

### 1.2 Status

Implemented and verified as part of the core's regression.

### 1.3 The gap Rev 3.0 closes

No previous revision stated a fixed-point format. That had two consequences:

1. **Firmware could not be written correctly against the spec.** A multiply-accumulate unit
   with no stated binary point leaves the driver author to infer the scaling from the RTL,
   and any mismatch is a silent numerical error rather than a crash.
2. **The EKF claim was unfalsifiable.** Every revision said the DSU accelerates the EKF. With
   no format stated, there was no way to check whether it can. It partly cannot — see §7.5,
   which says so explicitly rather than leaving the claim standing.

---

## 2 Requirements

| ID | Requirement | Source |
|---|---|---|
| R-1 | Three independent 16×16 multiply-accumulate units with 48-bit accumulators. | System |
| R-2 | Decoded in EX from Custom-0; not a bus peripheral. | ADR, latency |
| R-3 | A stated, normative fixed-point format. | ADR-0017 |
| R-4 | Saturating accumulation with a sticky overflow flag per accumulator. | Numerical safety |
| R-5 | Same-accumulator RAW hazards interlocked in hardware. | Correctness |
| R-6 | Accumulators readable by the debugger without stopping the core. | Bring-up |
| R-7 | `acc_sel` = 2'b11 shall be illegal everywhere. | ADR |

---

## 3 Block diagram

```
  ┌───────────────────────────────────────────────────────────────┐
  │                      dsu  (block 2, inside EX)                │
  │                                                               │
  │  instruction word ──▶ ┌──────────────┐                        │
  │  (raw, from EX)       │ dsu_decode   │                        │
  │  rs1, rs2 ───────────▶│ custom-0     │                        │
  │                       └──────┬───────┘                        │
  │                              │ acc_sel, op                    │
  │            ┌─────────────────┼─────────────────┐              │
  │            ▼                 ▼                 ▼              │
  │     ┌────────────┐    ┌────────────┐    ┌────────────┐        │
  │     │ mac_unit 0 │    │ mac_unit 1 │    │ mac_unit 2 │        │
  │     │            │    │            │    │            │        │
  │     │ 16×16 mul  │    │ 16×16 mul  │    │ 16×16 mul  │        │
  │     │   Q1.15    │    │            │    │            │        │
  │     │     ▼      │    │            │    │            │        │
  │     │  Q2.30     │    │            │    │            │        │
  │     │     ▼      │    │            │    │            │        │
  │     │ ┌────────┐ │    │ ┌────────┐ │    │ ┌────────┐ │        │
  │     │ │ACC_FX  │ │    │ │ACC_FY  │ │    │ │ACC_MAG │ │        │
  │     │ │48b     │ │    │ │48b     │ │    │ │48b     │ │        │
  │     │ │Q18.30  │ │    │ │Q18.30  │ │    │ │Q18.30  │ │        │
  │     │ └────────┘ │    │ └────────┘ │    │ └────────┘ │        │
  │     │  ovf ──────┼────┼─ ovf ──────┼────┼─ ovf ──────┼──┐     │
  │     └────────────┘    └────────────┘    └────────────┘  │     │
  │            │                 │                 │        │     │
  │            └────────┬────────┴────────┬────────┘        │     │
  │                     ▼                 ▼                 ▼     │
  │              ┌─────────────┐   ┌──────────────┐               │
  │              │ result mux  │   │ dsu_busy     │               │
  │              │ → EX WB     │   │ RAW interlock│               │
  │              └─────────────┘   └──────┬───────┘               │
  │                                       │                       │
  │              taps ────────────────────┼───────────────────────┼──▶ Debug
  └───────────────────────────────────────┼───────────────────────┘
                                          ▼
                                    pipe_ctrl H4
```

---

## 4 Sub-block inventory

| Name | Type | RTL file | Role |
|---|---|---|---|
| `dsu_decode` | comb | `dsu_decode.v` | Custom-0 decode, `acc_sel`, operation. |
| `mac_unit` ×3 | seq | `mac_unit.v` | 16×16 multiplier, 49-bit accumulate, saturation, overflow. |
| `kogge_stone_49` | comb | `kogge_stone_49.v` | 49-bit adder for the accumulate path. |
| `dsu_interlock` | comb | `dsu_interlock.v` | Same-accumulator RAW detect → `dsu_busy`. |
| `dsu_taps` | comb | `dsu_top.v` | Read-only accumulator and overflow outputs for Debug. |

---

## 5 Interfaces

| Port | Dir | Width | Domain | Reset | Description |
|---|---|---|---|---|---|
| `hclk_i` | in | 1 | hclk (gated) | — | Gated with the core (`GARUDA-CORE-SPEC-001` §7.7) and additionally by `dsu_idle`. |
| `core_rst_n_i` | in | 1 | hclk | — | |
| `instr_i` | in | 32 | hclk | — | Raw instruction word from EX. |
| `rs1_i`, `rs2_i` | in | 32 | hclk | — | Register operands. |
| `dsu_valid_i` | in | 1 | hclk | — | A Custom-0 instruction is in EX. |
| `dsu_result_o` | out | 32 | hclk | 0 | To the EX writeback multiplexer. |
| `dsu_busy_o` | out | 1 | hclk | 0 | To `pipe_ctrl` as hold source `H4`. |
| `dsu_illegal_o` | out | 1 | hclk | 0 | Illegal Custom-0 encoding → illegal-instruction exception. |
| `dsu_acc_o` | out | 48×3 | hclk | 0 | Live taps to Debug. |
| `dsu_ovf_o` | out | 3 | hclk | 0 | Sticky overflow taps. |

**[N-5.1]** The DSU is in the core's EX timing cone, in parallel with the 33×33 multiplier.
Both contribute to the 250 MHz question (`GARUDA-CORE-SPEC-001` §7.9).

---

## 6 Numeric contract — normative

**[N-6.1]** This section is the authority on DSU number formats. Firmware, the RTL and the
testbench all follow it. It did not exist before Rev 3.0.

### 6.1 Formats

| Stage | Format | Width | Integer bits | Fractional bits | Range |
|---|---|---|---|---|---|
| Operand | Q1.15 | 16 | 1 (sign) | 15 | [−1.0, +0.999969) |
| Product | Q2.30 | 32 | 2 | 30 | [−2.0, +2.0) |
| Accumulator | Q18.30 | 48 | 18 | 30 | [−131072, +131072) |

**[N-6.2]** Operand extraction: `MAC` uses the low 16 bits of `rs1_i` and `rs2_i`,
interpreted as signed Q1.15. The upper 16 bits are ignored, not checked. Firmware packs two
Q1.15 values per 32-bit word where useful.

**[N-6.3]** The product's 30 fractional bits align exactly with the accumulator's 30
fractional bits, so accumulation is a plain 48-bit add with no shift. This is why Q18.30 was
chosen rather than a format requiring realignment on every accumulate — a shifter in the
accumulate path would land in the EX critical cone.

**[N-6.4]** Headroom: 18 integer bits against a product magnitude below 2.0 allows 2¹⁷ =
131,072 accumulations before the integer field can overflow, worst case. Practical loops here
accumulate 10 to 50 terms.

### 6.2 What the format can and cannot represent

**[N-6.5]** Q1.15 operands are restricted to (−1, +1). Any value outside that range must be
scaled by firmware before it reaches the DSU. The unit does not check, and an out-of-range
operand is silently reinterpreted — a wrapped Q1.15 value, not a saturated one.

**[N-6.6]** This is the load-bearing limitation and the reason §7.5 exists. A quantity with a
dynamic range wider than about 2¹⁵ relative steps cannot be represented in Q1.15 at fixed
scaling, and an EKF covariance matrix has exactly that problem: diagonal terms span many
orders of magnitude as the filter converges.

### 6.3 Saturation

**[N-6.7]** On accumulate, if the 49-bit intermediate sum exceeds the 48-bit signed range, the
accumulator saturates to `0x7FFF_FFFF_FFFF` (positive) or `0x8000_0000_0000` (negative), and
the sticky overflow flag for that accumulator sets.

**[N-6.8]** Saturation rather than wrap: a wrapped accumulator changes sign, so an APF
repulsion force would reverse direction and push the vehicle *toward* the obstacle. Saturation
gives a wrong magnitude in the right direction, which degrades rather than inverts.

**[N-6.9]** The overflow flag is sticky and set-beats-clear: a `MACCLEAR` in the same cycle as
an overflow leaves the flag set. Firmware must check it after a computation, not assume its
own clear won.

---

## 7 Functional description

### 7.1 Instruction set

All in the Custom-0 opcode space (`0x0B`), distinguished by `funct3` and `funct7`.

| Instruction | Operation | Result | Cycles |
|---|---|---|---|
| `MAC_SEL acc` | Select the target accumulator | — | 1 |
| `MAC rs1, rs2` | `acc += rs1[15:0] × rs2[15:0]` | — | 1 |
| `MACSUB rs1, rs2` | `acc -= rs1[15:0] × rs2[15:0]` | — | 1 |
| `MACDOT rs1, rs2` | Two products into two accumulators | — | 1 |
| `MACCLEAR` | `acc = 0`; overflow flag unchanged | — | 1 |
| `MACLOAD rs1` | `acc = sign_extend(rs1)` as Q18.30 | — | 1 |
| `MACREAD_LO rd` | `rd = acc[31:0]` | rd | 1 |
| `MACREAD_HI rd` | `rd = sign_extend(acc[47:32])` | rd | 1 |
| `MACSHIFT rs1` | `acc >>>= rs1[4:0]`, arithmetic | — | 1 |
| `MACSAT rd` | `rd = acc` saturated to Q1.15 in `rd[15:0]` | rd | 1 |
| `MACABS` | `acc = |acc|` | — | 1 |

**[N-7.1]** Every instruction is single-cycle throughput. The only stall is the
same-accumulator RAW interlock (§7.3).

**[N-7.2]** `MACDOT` is the EKF and APF primitive: it issues two 16×16 products into two
different accumulators in one instruction, which is what makes a 2-element dot product one
cycle rather than two.

**[N-7.3]** `MACSAT` converts an accumulator back to Q1.15 with saturation, which is the
normal way a result re-enters the RV32IM datapath. `MACREAD_LO`/`_HI` give the raw Q18.30
value for firmware that needs the full precision or is writing diagnostics.

### 7.2 `acc_sel` encoding

| `acc_sel` | Accumulator |
|---|---|
| 00 | ACC_FX |
| 01 | ACC_FY |
| 10 | ACC_MAG |
| 11 | **illegal** |

**[N-7.4]** `acc_sel` = 2'b11 raises an illegal-instruction exception in every instruction
that carries the field (R-7). It does not alias to ACC_MAG, and it does not silently do
nothing.

**[N-7.5]** Rationale: an illegal encoding that aliases to a real accumulator turns an
assembler bug or a corrupted instruction word into a silent wrong answer in the flight
computation. Raising the exception makes it a precise fault with `mtval` = the instruction.

### 7.3 The RAW interlock

**[N-7.6]** An accumulator write has a one-cycle result latency. An instruction reading the
same accumulator in the next cycle — `MACREAD_LO` immediately after `MAC`, for instance —
would read the stale value.

**[N-7.7]** `dsu_interlock` detects this and asserts `dsu_busy_o`, which `pipe_ctrl` treats as
hold source `H4` (`GARUDA-CORE-SPEC-001` §7.6). One cycle of stall.

**[N-7.8]** The interlock is **per accumulator**. A `MAC` on ACC_FX followed by a
`MACREAD_LO` on ACC_FY does not stall. This is what makes three accumulators worth having:
firmware interleaves work on different accumulators and the interlock never fires.

**[N-7.9]** `dsu_busy_o` is an ordinary hold source, not a special case in the pipeline
control logic. The flush-beats-hold rule of [N-7.21] in the core spec applies to it exactly as
to load-use: a branch or trap concurrent with `dsu_busy` discards the DSU operation in EX.
That matters because the accumulator must not be updated by an instruction the flush killed.

### 7.4 APF — what this unit is really for

**[N-7.10]** The artificial potential field inner loop computes, for each neighbour, a
repulsion vector inversely proportional to distance, and sums the vectors:

```
  for each neighbour i:
      dx = x_self - x_i          # Q1.15, normalised to the field extent
      dy = y_self - y_i
      MAC_SEL ACC_MAG;  MAC dx, dx;  MAC dy, dy     # |d|² accumulates
      MAC_SEL ACC_FX;   MAC dx, w_i                 # weighted x
      MAC_SEL ACC_FY;   MAC dy, w_i                 # weighted y
```

**[N-7.11]** Roughly 300 cycles for 10 neighbours, against 250,000 cycles per loop
iteration. Positions normalised to the field extent are naturally within (−1, +1), so Q1.15
is the right format for this computation and there is no scaling difficulty.

**[N-7.12]** This is the DSU's clear, unqualified win, and it is the workload it was designed
around.

### 7.5 EKF — the honest scope

**[N-7.13]** The DSU accelerates the parts of the EKF whose operands are bounded and
well-scaled, and does not accelerate the rest. Stating which is which:

| EKF stage | DSU-suitable | Why |
|---|---|---|
| State prediction `x = Fx` | **yes** | `F` entries are near-unity, `x` is normalised. Bounded. |
| Measurement residual `y = z − Hx` | **yes** | Both terms normalised to sensor full-scale. |
| `H P` products, small blocks | **partly** | Depends on the block's scaling; usable where `P` has been renormalised. |
| Covariance propagation `P = FPFᵀ + Q` | **no** | `P`'s diagonal spans many orders of magnitude as the filter converges. Q1.15 at fixed scaling cannot hold it. |
| Kalman gain `K = PHᵀ(HPHᵀ+R)⁻¹` | **no** | Requires division and a matrix inverse; no DSU operation and no hardware divider. |
| `P` update `(I−KH)P` | **no** | Same dynamic-range problem as propagation. |

**[N-7.14]** So the covariance path is RV32IM firmware, using the core's 33×33 multiplier and
the software divide handler. The DSU serves the prediction and residual paths.

**[N-7.15]** **This document does not claim a speedup figure for the EKF.** The figure is
measurable — profile with `mcycle` around each stage, with and without the DSU path — and it
is the single most useful number for the project's technical write-up. Until it is measured,
no figure is asserted. Asserting one and being asked to defend it is a worse outcome than
saying it is pending.

**[N-7.16]** A v2 option that would extend the DSU's reach here is block floating-point: a
per-matrix exponent held in firmware, with `MACSHIFT` used to renormalise between blocks.
`MACSHIFT` exists and is sufficient for this; it requires no hardware change, only a firmware
scheme. Recorded as a possibility, not a commitment.

### 7.6 Debug taps

**[N-7.17]** All three accumulators and all three overflow flags are continuously visible to
the Debug Module, with no core involvement (R-6).

**[N-7.18]** This is the most valuable observability in the chip. With SBA-only debug there
is no GPR inspection (`GARUDA-DEBUG-SPEC-001` [N-7.9]), so during bring-up of the APF or EKF
the accumulators are the only direct window into the arithmetic. A wrong repulsion force is
visible here immediately, without instrumenting firmware.

**[N-7.19]** The 48-bit values are read as two 32-bit halves with a coherent-snapshot
mechanism (`GARUDA-DEBUG-SPEC-001` §6.8).

### 7.7 Clock gating

**[N-7.20]** The DSU is inside the core's WFI clock gate, and additionally gated by
`dsu_idle` — no Custom-0 instruction in EX and no interlock pending.

**[N-7.21]** `dsu_idle` is derived in `dsu_decode` from `dsu_valid_i` and the interlock state,
both of which are already registered. It is not a second opinion about pipeline state, so it
does not fall foul of `GARUDA-CORE-SPEC-001` [N-7.29].

**[N-7.22]** The accumulators must retain their values while gated, so they are not reset by
the gate and the gate is enable-based, never a reset. An accumulator cleared by entering an
idle cycle would corrupt a computation split across a stall.

---

## 8 Timing

### 8.1 Back-to-back MAC on different accumulators — no stall

```
            │ T0 │ T1 │ T2 │ T3 │
EX        ──┤MAC │MAC │MAC │MAC ├
acc_sel   ──┤ FX │ FY │MAG │ FX ├
dsu_busy  ──────────────────────────  never asserts  [N-7.8]

ACC_FX    ──┤ A      │ A+p0        │ A+p0+p3 ├
ACC_FY    ──┤ B          │ B+p1              ├
ACC_MAG   ──┤ C              │ C+p2          ├
```

### 8.2 Same-accumulator RAW — one-cycle interlock

```
            │ T0 │ T1 │ T2 │ T3 │
EX        ──┤MAC │ rd │ rd │ i+2├   rd = MACREAD_LO, same acc
            │ FX │ FX │ FX │    │
dsu_busy  ──────┌─────┐──────────   asserted one cycle  [N-7.7]
                 │
ACC_FX    ──┤ A │ A+p            ├
dsu_result──────────────┤ A+p    ├   correct value read
```

### 8.3 Flush during `dsu_busy` — the accumulator must not update

```
            │ T0 │ T1 │ T2 │
dsu_busy  ──┌─────────┐──────
trap_req  ──────┌───────────────

EX        ──┤MAC │ -- │ -- ├   MAC discarded by the flush
ACC_FX    ──┤ A       │ A  ├   ◀── unchanged: the killed instruction
                                    must not have accumulated  [N-7.9]
```

### 8.4 Saturation and the sticky flag

```
ACC_MAG   ──┤ 0x7FFF_FFFF_F000 │ 0x7FFF_FFFF_FFFF │ 0x7FFF_FFFF_FFFF ├
                                 ▲                  ▲
                                 │                  └── stays saturated
                                 └── clamped, not wrapped  [N-6.8]
ovf[2]    ─────────────────────────┌───────────────────────────────────
                                   └── sticky; a same-cycle MACCLEAR
                                       does not clear it  [N-6.9]
```

---

## 9 Clock, reset and power

**[N-9.1]** One clock domain, `hclk`, gated as in §7.7. No CDC.

**[N-9.2]** `core_rst_n_i` clears all three accumulators and all three overflow flags.

**[N-9.3]** Power: three 16×16 multipliers and three 48-bit adders are a meaningful share of
the core's dynamic power when active, and they are active for a few hundred cycles per
millisecond. `dsu_idle` gating is therefore worth more here than almost anywhere else in the
chip, in proportion to the logic it covers.

---

## 10 Assertions

Existing assertions retained. New and changed for Rev 3.0:

```systemverilog
// --- product/accumulator alignment: accumulate is a plain add, no shift (N-6.3)
a_no_realign: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n_i)
  (mac_en[n] && !ovf_n) |=> (acc[n] == $past(acc[n]) + $past(product_sext)));

// --- saturation, not wrap (N-6.8)
a_saturate_pos: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n_i)
  (mac_en[n] && sum49[48:47] == 2'b01) |=> (acc[n] == 48'h7FFF_FFFF_FFFF));
a_saturate_neg: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n_i)
  (mac_en[n] && sum49[48:47] == 2'b10) |=> (acc[n] == 48'h8000_0000_0000));
a_never_wraps: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n_i)
  (acc[n][47] != $past(acc[n][47])) |-> !$past(sign_change_legal));

// --- overflow is sticky and set-beats-clear (N-6.9)
a_ovf_sticky: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n_i) $fell(ovf[n]) |-> $past(ovf_clear_explicit));
a_ovf_set_beats_clear: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n_i)
  (ovf_set[n] && macclear[n]) |=> ovf[n]);

// --- overflow detection uses the full 49-bit intermediate (OPEN-9)
a_ovf_from_49: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n_i)
  ovf_set[n] == (sum49[48] ^ sum49[47]));

// --- acc_sel = 11 is always illegal (R-7, N-7.4)
a_accsel3_illegal: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n_i)
  (dsu_valid_i && instr_acc_sel == 2'b11) |-> dsu_illegal_o);
a_accsel3_no_effect: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n_i)
  (dsu_valid_i && instr_acc_sel == 2'b11) |=> $stable(acc[0]) && $stable(acc[1]) && $stable(acc[2]));

// --- interlock is per accumulator (N-7.8)
a_interlock_per_acc: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n_i)
  (mac_en[0] ##1 (dsu_valid_i && instr_acc_sel == 2'b01)) |-> !dsu_busy_o);
a_interlock_fires: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n_i)
  (mac_en[n] ##1 (dsu_read && instr_acc_sel == n)) |-> dsu_busy_o);

// --- a flushed DSU instruction must not accumulate (N-7.9)
a_flush_no_accumulate: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n_i)
  (dsu_valid_i && ex_flush) |=> $stable(acc[instr_acc_sel]));

// --- MACSAT saturates correctly to Q1.15
a_macsat: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n_i)
  macsat_en |-> (dsu_result_o[15:0] == q15_saturate(acc[instr_acc_sel])));

// --- taps are always live, never gated (R-6)
a_taps_live: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n_i) dsu_acc_o == acc);

// --- accumulators retain value while clock-gated (N-7.22)
a_gate_retains: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n_i)
  !dsu_clk_en |=> $stable(acc[0]) && $stable(acc[1]) && $stable(acc[2]));

// --- single-cycle throughput except on interlock (N-7.1)
a_single_cycle: assert property (
  @(posedge hclk_i) disable iff (!core_rst_n_i)
  (dsu_valid_i && !dsu_busy_o) |=> dsu_complete);
```

---

## 11 Verification plan

| Req | Test | Oracle | Coverage goal | Status |
|---|---|---|---|---|
| R-1 | `t_dsu_mac` | each accumulator accumulates correctly | all 3 | **passing** |
| R-2 | `t_dsu_decode` | all 9 instructions decode and execute | 9/9 | **passing** |
| R-3 | `t_dsu_qformat` | Q1.15 × Q1.15 → Q2.30 → Q18.30 against a Python golden model | ≥10⁴ random operand pairs | **new** |
| R-3 | `t_dsu_qformat_edge` | ±1.0−ε, ±smallest, zero, and all sign combinations | all 9 combinations | **new** |
| R-4 | `t_dsu_saturate` | positive and negative saturation; no wrap | both directions | extend |
| R-4 | `t_dsu_ovf_sticky` | sticky; set beats a same-cycle clear | — | extend |
| R-5 | `t_dsu_interlock` | fires on same-acc, not on cross-acc | 9 acc pairs | **passing** |
| R-5 | `t_dsu_flush` | a flushed DSU op does not accumulate | flush at each pipeline position | **new** |
| R-6 | `t_dsu_taps` | taps readable while accumulating | — | new |
| R-7 | `t_dsu_accsel3` | illegal exception, no accumulator change | all instructions carrying the field | extend |
| §7.4 | `t_dsu_apf` | full 10-neighbour APF loop vs. a float reference, error bound stated | — | **new** |
| §7.5 | `t_dsu_ekf_scope` | the prediction and residual paths match a float reference within the stated bound; covariance is not attempted | — | **new** |
| §7.7 | `t_dsu_gate` | accumulators retain values across gated cycles | — | new |

**[N-11.1]** `t_dsu_qformat` against a Python golden model is the test Rev 3.0 exists to make
possible. Without a stated format there was nothing to compare against, so the arithmetic was
verified only for self-consistency. A golden model turns "the RTL does what the RTL does" into
"the RTL computes the specified function."

**[N-11.2]** `t_dsu_apf` must state a numerical error bound against the float reference, not
merely "close." That bound is what firmware relies on when it decides whether Q1.15 is
adequate for a given field extent, and it is a number the project's write-up will want.

**[N-11.3]** OPEN-9 resolution path: `mac_unit.v:140` computes overflow from a 49-bit
`result_ext` via `kogge_stone_49`, which is what `a_ovf_from_49` requires. Rev 2.0 listed the
widening as unapplied. **Read `u_csa2`'s width and confirm** — if the compressor is 48 bits,
the guard bit reads a truncated carry and the widening is still needed; if it is 49, the
erratum is closed and Rev 2.0's text was stale.

---

## 12 Design decisions

| Decision | ADR |
|---|---|
| Q1.15 operands, Q2.30 products, Q18.30 accumulators; EKF scope stated | ADR-0017 |
| In-pipeline EX extension, not a bus peripheral | System |
| `acc_sel` = 11 illegal everywhere | ADR-0017 |
| Saturating, not wrapping | ADR-0017 |
| Live debug taps, no core involvement | ADR-0012 |

---

## 13 Not implemented

| Feature | Why not |
|---|---|
| 32-bit operands | Would need a 32×32 multiplier per MAC, tripling the area in the EX critical cone at 4 ns. Q1.15 covers APF fully and the EKF partly (§7.5). |
| Floating point | Would change the core's datapath, add exception semantics, and require F-extension CSRs. Out of scope for a 1.45 mm die. |
| Hardware division or reciprocal | No divider anywhere in the chip (`GARUDA-CORE-SPEC-001` §7.2). The Kalman gain's inverse is firmware. |
| Automatic renormalisation / block floating-point in hardware | §7.16: `MACSHIFT` makes a firmware scheme possible, which is the cheaper place to put it. |
| More than three accumulators | Three matches APF's `{FX, FY, MAG}` exactly, and the per-accumulator interlock means three is enough to avoid stalls in practice. |
| Square root | APF needs `|d|²`, not `|d|`. Comparisons against a squared threshold avoid the root entirely. |
| A 4th `acc_sel` accumulator | `acc_sel` = 11 is deliberately illegal (§7.2) — it is a bug detector, and spending it on a fourth accumulator would remove that. |
| Wrapping mode as an option | §6.8: a wrapped APF force reverses direction. There is no use case for wrap here. |

---

## 14 Open items

**OPEN-9:** confirm `u_csa2`'s width in `mac_unit.v` ([N-11.3]). A 15-minute RTL read. Either
the erratum is already closed and Rev 2.0's text was stale, or the compressor needs widening
to 49 bits.

**OPEN-10 (shared with the core spec):** measure the DSU's actual contribution to the APF and
EKF prediction paths with `mcycle`. §7.15 asserts no figure until this exists.

---

## 15 Errata

| ID | Symptom | Root cause | Status | Test |
|---|---|---|---|---|
| OVF-1 | Overflow flag could miss an overflow, reading a truncated carry from the accumulate path. | The guard bit was taken from a 48-bit compressor output rather than the 49-bit sum. | **Verify — see OPEN-9.** RTL appears to use a 49-bit `result_ext` with `kogge_stone_49`; Rev 2.0 said the widening was unapplied. One of the two is stale. | `t_dsu_ovf_sticky`, `a_ovf_from_49` |

**Defects fixed in this revision:**

| ID | Symptom | Root cause | Fix |
|---|---|---|---|
| DS-1 | No fixed-point format was ever stated, so firmware had to infer scaling from RTL and the arithmetic could only be verified for self-consistency. | The numeric contract was treated as an implementation detail rather than an interface. | §6, and `t_dsu_qformat` against a golden model. |
| DS-2 | The EKF acceleration claim was unfalsifiable and partly false: Q1.15 cannot hold covariance dynamic range. | The claim predated any stated format. | §7.5 scopes it stage by stage; no speedup figure asserted until measured. |
