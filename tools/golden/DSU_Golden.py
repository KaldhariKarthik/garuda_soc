"""
DSU_Golden.py  --  reference ("golden") models for the GARUDA DSU.

RTL source of truth: rtl/dsu  (dsu_top, dsu_decoder, mac_cluster, mac_unit,
operand_router, saturation_unit, barrel_shifter, readback_mux, result_selector,
overflow_flag, dsu_stall).  Where this file and the RTL disagree, the RTL wins
and this file is the bug -- same rule the rest of the project runs on.

THERE ARE TWO MODELS IN HERE, ON PURPOSE
========================================

  ArchDSU   -- "what should the answer be?"  Timeless. acc += a*b lands
               immediately. Good for reasoning about the maths and for
               generating expected VALUES. Cannot answer any question about
               when a value appears, and will disagree with the RTL if you
               sample at the wrong cycle. This is the original model.

  DSUModel  -- "what do the wires actually do, cycle by cycle?"  Models the
               real 2-stage MAC pipeline, the pending-product registers, flush,
               reset, dsu_en, and the dsu_stall interlock. Bit-literal: the CSA
               compressors and the 49-bit final add are implemented as the
               hardware builds them, not idealised to a+b+c, so overflow
               detection matches the RTL exactly.

Use DSUModel for RTL comparison. Use ArchDSU only to sanity-check the maths.

WHY THE CYCLE-ACCURATE MODEL EXISTS (read this before trusting a passing test)
==============================================================================
In mac_unit.v, `sum_reg`/`carry_reg` and `acc` are written on the SAME edge,
both gated by `write_en`. `acc_next` is computed from the PREVIOUS contents of
sum_reg/carry_reg. So a multiply issued in cycle K does not reach `acc` in
cycle K+1 -- it reaches acc on the next cycle that has write_en asserted for
that accumulator, which may never come.

Three consequences that a timeless model cannot express:

  1. The last product of a sequence is stranded in sum_reg/carry_reg and never
     commits until another op touches that accumulator. (The generator hides
     this today by appending a "settle" MAC_SEL 0*0.)

  2. MACLOAD / MACCLEAR / MACSAT also assert write_en, so they ALSO latch
     sum_reg/carry_reg with the products of THEIR OWN rs1/rs2 operands, even
     though those operands are architecturally meaningless for those ops. The
     next accumulate to that accumulator then adds that stale product in.
     This is masked today only because the generator drives rs1=rs2=0 for
     clear/load. See FLAG-A.

  3. MACSAT saturates `cluster_out`, which is `acc` -- NOT including a pending
     product. Saturating straight after a multiply clamps a stale value and
     then adds the pending product afterwards. See FLAG-C.

FLAGS -- open questions where the RTL's behaviour should be confirmed as
intended (or fixed) before tapeout. These are modelled AS THE RTL BEHAVES.
=========================================================================
  FLAG-A  MACLOAD/MACCLEAR/MACSAT poison the pending-product registers with
          products of their own operand fields. Probably unintended.
  FLAG-B  flush zeroes sum_reg/carry_reg but leaves `acc` intact. This is
          almost certainly CORRECT (a trap must not destroy committed
          accumulator state) -- but DSU_Verification_Plan row 31 currently
          expects "acc = 0", which contradicts the RTL. The plan row is wrong.
  FLAG-C  dsu_stall interlocks readback-after-readback (RD_LO/RD_HI/MACSAT),
          but NOT readback-after-multiply -- which, given the pending-product
          structure, is the hazard that actually loses data.
  FLAG-D  RESOLVED 2026-08-02 (ERRATUM DSU-6). Shift amounts 48..63 now raise
          illegal_instr. The accumulator is 48 bits, so 0..47 is the whole
          meaningful range; making it an encoding rule means the hardware
          enforces it instead of an ABI note nothing checks.
  FLAG-E  RESOLVED 2026-08-02 (ERRATUM DSU-8). A csr_clear coinciding with an
          overflow no longer discards it: the clear resets the accumulated
          flag but a same-cycle overflow is still recorded, as RISC-V W1C bits
          behave. Previously a poll-and-clear loop dropped such overflows.
"""

# ---------------------------------------------------------------------------
# funct5 opcodes -- must match dsu_defs.vh exactly
# ---------------------------------------------------------------------------
MAC_SEL, MACSUB, MACABS, MACDOT, MACLOAD = 0, 1, 2, 3, 4
MACCLEAR, MACSAT, MACRD_LO, MACRD_HI, MACSHIFT = 5, 6, 7, 8, 9

ACC_FX, ACC_FY, ACC_MAG = 0, 1, 2          # acc_sel values (3 = illegal)

OPCODE_CUSTOM0 = 0x0B

MASK16, MASK32, MASK48 = 0xFFFF, 0xFFFFFFFF, (1 << 48) - 1
MASK49 = (1 << 49) - 1


# ---------------------------------------------------------------------------
# tiny bit helpers
# ---------------------------------------------------------------------------
def s16(x):                                # read 16 bits as signed
    x &= MASK16
    return x - (1 << 16) if x & 0x8000 else x

def s32(x):
    x &= MASK32
    return x - (1 << 32) if x & 0x80000000 else x

def s48(x):                                # read 48 bits as signed
    x &= MASK48
    return x - (1 << 48) if x & (1 << 47) else x

def wrap48(x):                             # force back into 48-bit signed range
    return s48(x & MASK48)

def sext(value, from_bits, to_bits=32):    # sign-extend, returns unsigned bits
    sign = 1 << (from_bits - 1)
    value &= (1 << from_bits) - 1
    return ((value ^ sign) - sign) & ((1 << to_bits) - 1)


def abs16(x):
    """abs() of a 16-bit signed value. -32768 has no positive twin in 16 bits,
    so it clamps to +32767 rather than wrapping back negative.
    Mirrors the abs16 function in operand_router.v."""
    x &= MASK16
    if x == 0x8000:
        return 0x7FFF
    if x & 0x8000:
        return (~x + 1) & MASK16
    return x


# ---------------------------------------------------------------------------
# hardware primitives, built the way the RTL builds them
#
# These are deliberately NOT shortcut to plain arithmetic. A 3:2 compressor
# followed by a truncated add is not identically a+b+c once the carry's top bit
# falls off the end of the 48-bit word, and the overflow flag is derived from
# exactly that truncation. Modelling it literally is what makes this model
# trustworthy for the overflow tests.
# ---------------------------------------------------------------------------
def csa_3to2(a, b, c, width=48):
    """carry-save adder, mirrors csa_3to2.v"""
    mask = (1 << width) - 1
    a &= mask; b &= mask; c &= mask
    s = a ^ b ^ c
    carry = (((a & b) | (a & c) | (b & c)) << 1) & mask
    return s, carry


def kogge_stone_49(a49, b49):
    """49-bit add, mirrors kogge_stone_49.v (cin tied 0 in mac_unit)"""
    return (a49 + b49) & MASK49


def _sext49(x48):
    """{x[47], x[47:0]} -- the 49-bit sign extension mac_unit feeds the adder"""
    x48 &= MASK48
    return ((x48 >> 47) << 48) | x48


# ---------------------------------------------------------------------------
# decode -- mirrors dsu_decoder.v
# ---------------------------------------------------------------------------
class Decoded:
    __slots__ = ("is_custom0", "is_rtype", "is_itype", "funct3", "funct5",
                 "rd_addr", "acc_sel", "shift_amt", "shift_dir",
                 "illegal", "mac_en", "add_sub", "clear", "load", "abs_en",
                 "dot_en", "sat_op", "shift_op", "rd_lo_op", "rd_hi_op",
                 "result_src", "writes_regfile")


def decode(instr, dsu_en=1):
    """Combinational decode. dsu_en gates every enable AND illegal_instr,
    exactly as dsu_decoder.v does -- with dsu_en low the DSU is fully inert."""
    d = Decoded()
    opcode = instr & 0x7F
    d.funct3 = (instr >> 12) & 0x7
    d.funct5 = (instr >> 27) & 0x1F
    d.rd_addr = (instr >> 7) & 0x1F
    imm_i = (instr >> 20) & 0xFFF
    acc_sel_r = (instr >> 25) & 0x3

    d.is_custom0 = (opcode == OPCODE_CUSTOM0)
    d.is_rtype = d.is_custom0 and d.funct3 == 0
    d.is_itype = d.is_custom0 and d.funct3 == 1

    # I-type (MACSHIFT) takes acc_sel from imm_i[7:6]; R-type from instr[26:25]
    d.acc_sel = ((imm_i >> 6) & 0x3) if d.is_itype else acc_sel_r
    d.shift_amt = imm_i & 0x3F
    d.shift_dir = (imm_i >> 8) & 0x1          # 1 = left, 0 = arithmetic right

    def rop(f5):
        return d.is_rtype and d.funct5 == f5

    op_mac_sel = rop(MAC_SEL);   op_macsub = rop(MACSUB)
    op_macabs = rop(MACABS);     op_macdot = rop(MACDOT)
    op_macload = rop(MACLOAD);   op_macclear = rop(MACCLEAR)
    op_macsat = rop(MACSAT)
    op_rd_lo = rop(MACRD_LO);    op_rd_hi = rop(MACRD_HI)
    op_macshift = d.is_itype                  # I-type carries no funct5 field

    any_legal = (op_mac_sel or op_macsub or op_macabs or op_macdot or
                 op_macload or op_macclear or op_macsat or op_rd_lo or
                 op_rd_hi or op_macshift)
    bad_acc_sel = (d.acc_sel == 3)
    bad_funct3 = d.is_custom0 and not (d.is_rtype or d.is_itype)

    # ERRATUM DSU-6 (FLAG-D): the accumulator is 48 bits, so shift amounts
    # 48..63 are out of range and now raise illegal rather than being an
    # undefined-but-well-behaved corner.
    bad_shift_amt = d.is_itype and d.shift_amt >= 48
    # ERRATUM DSU-7: imm_i[11:9] are reserved and must be zero, keeping the
    # rest of the I-type encoding space available for future instructions.
    bad_shift_rsvd = d.is_itype and ((imm_i >> 9) & 0x7) != 0

    d.illegal = bool(d.is_custom0 and dsu_en and
                     ((not any_legal) or bad_acc_sel or bad_funct3 or
                      bad_shift_amt or bad_shift_rsvd))

    ok = dsu_en and not d.illegal
    compute = (op_mac_sel or op_macsub or op_macabs or op_macdot or
               op_macload or op_macclear)

    d.mac_en = bool(compute and ok)
    d.add_sub = bool(op_macsub)               # cluster-wide control bits: these
    d.clear = bool(op_macclear)               # are NOT gated by dsu_en in the
    d.load = bool(op_macload)                 # RTL, only the per-MAC enable is
    d.abs_en = bool(op_macabs)
    d.dot_en = bool(op_macdot)

    d.sat_op = bool(op_macsat and ok)
    d.shift_op = bool(op_macshift and ok)
    d.rd_lo_op = bool(op_rd_lo and ok)
    d.rd_hi_op = bool(op_rd_hi and ok)

    d.result_src = 1 if op_rd_lo else 2 if op_rd_hi else 3 if op_macshift else 0
    d.writes_regfile = bool((op_rd_lo or op_rd_hi or op_macshift) and ok)
    return d


# ---------------------------------------------------------------------------
# cycle-accurate model
# ---------------------------------------------------------------------------
class DSUModel:
    """Cycle-accurate reference for dsu_top.

    Usage mirrors hardware: call tick() once per clock. It returns the
    COMBINATIONAL outputs valid during that cycle (computed from the state as
    it was BEFORE the edge, which is what a testbench sampling just before
    posedge would see), and then advances the registered state.

        m = DSUModel()
        out = m.tick(instr=..., rs1=..., rs2=..., dsu_en=1)

    Registered state: acc[3], sum_reg[3], carry_reg[3], overflow_sticky,
    and the dsu_stall interlock registers.
    """

    def __init__(self):
        self.reset()

    def reset(self):
        """Async reset: mirrors every `if (!rst_n)` branch in rtl/dsu."""
        self.acc = [0, 0, 0]                  # 48-bit unsigned bit patterns
        self.sum_reg = [0, 0, 0]              # pending product, CSA form
        self.carry_reg = [0, 0, 0]
        self.overflow_sticky = 0
        self.prev_was_2cycle = 0              # dsu_stall.v
        self.prev_acc_sel = 0
        self.stalled_once = 0                 # dsu_stall.v one-shot (DSU-1)
        self.pending = [0, 0, 0]              # mac_unit.v stage-2 drain (DSU-4)

    # -- dsu_stall.v ------------------------------------------------------
    def _stall(self, d, dsu_en=1):
        # ERRATUM DSU-3 (FLAG-C): the compute ops are 2-cycle producers too, so
        # compute -> readback now interlocks. Previously only readback ops were
        # listed and compute -> readback sailed through onto a stale value.
        # ERRATUM DSU-9: dsu_busy is gated by dsu_en. is_custom0 is a bare
        # opcode compare, so without this the interlock could stall on a
        # Custom-0 word the DSU was not even enabled for.
        if not dsu_en:
            return False, False
        cur_is_compute = d.is_rtype and d.funct5 in (MAC_SEL, MACSUB, MACABS, MACDOT)
        cur_is_readback = d.is_rtype and d.funct5 in (MACRD_LO, MACRD_HI, MACSAT)
        cur_is_2cycle = cur_is_readback or cur_is_compute
        cur_reads_acc = cur_is_readback or d.is_itype
        # ERRATUM DSU-1: one-shot. Holding ID/EX re-presents the SAME
        # instruction, so without this the condition sustains itself and
        # dsu_busy never clears.
        stall_now = bool(self.prev_was_2cycle and cur_reads_acc and
                         d.acc_sel == self.prev_acc_sel and
                         not self.stalled_once)
        return stall_now, cur_is_2cycle

    def tick(self, instr=0, rs1=0, rs2=0, dsu_en=1,
             csr_clear_overflow=0, flush=0, rst_n=1):
        """Advance one clock. Returns the dsu_top outputs for this cycle."""
        if not rst_n:
            self.reset()
            return {"dsu_busy": 0, "dsu_rd_data": 0, "dsu_rd_valid": 0,
                    "dsu_rd_addr": 0, "dsu_overflow": 0, "illegal_instr": 0,
                    "acc": list(self.acc)}

        rs1 &= MASK32
        rs2 &= MASK32
        d = decode(instr, dsu_en)
        stall_now, cur_is_2cycle = self._stall(d, dsu_en)

        # ---- operand_router.v -------------------------------------------
        dot_active = d.dot_en and not d.abs_en
        a0 = abs16(rs1 & MASK16) if d.abs_en else (rs1 & MASK16)
        b0 = abs16(rs2 & MASK16) if d.abs_en else (rs2 & MASK16)
        a1 = (rs1 >> 16) & MASK16 if dot_active else 0
        b1 = (rs2 >> 16) & MASK16 if dot_active else 0

        # ---- mult_16x16 + sign-extend to 48 ------------------------------
        pa = (s16(a0) * s16(b0)) & MASK32
        pb = (s16(a1) * s16(b1)) & MASK32
        pa_ext = sext(pa, 32, 48)
        pb_ext = sext(pb, 32, 48)

        # ---- subtract trick: invert both products, add +2 correction -----
        # Valid only because pb == 0 whenever add_sub is set (MACSUB is not a
        # dot product, so the high lane is forced to zero by operand_router).
        inv = MASK48 if d.add_sub else 0
        pa_eff = pa_ext ^ inv
        pb_eff = pb_ext ^ inv
        sub_k = 2 if d.add_sub else 0
        csa1_sum, csa1_carry = csa_3to2(pa_eff, pb_eff, sub_k)

        # ---- saturation_unit.v (combinational, reads the SELECTED acc) ---
        # NOTE: cluster_out is `acc`, so this does NOT see a pending product.
        cluster_out = self.acc[d.acc_sel] if d.acc_sel < 3 else 0
        upper = (cluster_out >> 31) & 0x1FFFF
        in_range = (upper == 0) or (upper == 0x1FFFF)
        is_neg = (cluster_out >> 47) & 1
        if in_range:
            sat_result = sext(cluster_out & MASK32, 32, 48)
        elif is_neg:
            sat_result = 0xFFFF80000000
        else:
            sat_result = 0x00007FFFFFFF
        sat_writeback_en = d.sat_op
        sat_overflow = 1 if (d.sat_op and not in_range) else 0

        # ---- per-MAC evaluation (mac_cluster.v one-hot enables) ----------
        mac_overflow = 0
        next_acc = list(self.acc)
        next_sum = list(self.sum_reg)
        next_carry = list(self.carry_reg)
        next_pending = list(self.pending)

        for i in range(3):
            en_i = d.mac_en and d.acc_sel == i
            sat_we_i = sat_writeback_en and d.acc_sel == i
            write_en = (en_i or sat_we_i) and not flush

            # stage 2: CSA2(acc, sum_reg, carry_reg) -> 49-bit Kogge-Stone
            csa2_sum, csa2_carry = csa_3to2(self.acc[i], self.sum_reg[i],
                                            self.carry_reg[i])
            result_ext = kogge_stone_49(_sext49(csa2_sum), _sext49(csa2_carry))
            adder_result = result_ext & MASK48
            accum_ovf = ((result_ext >> 48) & 1) ^ ((result_ext >> 47) & 1)

            # acc_next priority, mirrors mac_unit.v exactly
            if sat_we_i:
                acc_next = sat_result
            elif d.load:
                acc_next = sext(rs1, 32, 48)
            elif d.clear:
                acc_next = 0
            else:
                acc_next = adder_result

            is_accum = not (d.load or d.clear or sat_we_i)
            # Overflow is a property of the COMMIT (DSU-4), not of an
            # instruction arriving: the fold that overflows may happen on a
            # cycle with no instruction at all.
            if accum_ovf and (self.pending[i] and not flush) and is_accum:
                mac_overflow = 1

            # ERRATUM DSU-2 (FLAG-A): only a genuine multiply may latch a new
            # pending product, and clear/load/saturate must DISCARD any pending
            # product because they replace the accumulator outright.
            prod_en_i = bool(en_i and not d.load and not d.clear
                             and not sat_we_i and not flush)
            pend_clr_i = bool((d.clear or d.load or sat_we_i) and not flush)

            # ERRATUM DSU-4: stage 2 self-drains. A product latched last cycle
            # commits this cycle whether or not a new instruction arrived;
            # previously acc moved only when write_en was asserted, so the last
            # product of a sequence was stranded indefinitely.
            acc_we_i = bool((sat_we_i or ((d.load or d.clear) and en_i)
                             or self.pending[i]) and not flush)

            if flush:
                # FLAG-B: flush clears the PENDING product only. `acc` keeps
                # its committed value -- a trap must not destroy accumulator
                # state. DSU_Verification_Plan row 31 disagrees; it is wrong.
                next_sum[i] = 0
                next_carry[i] = 0
                next_pending[i] = 0
            else:
                next_pending[i] = 1 if prod_en_i else 0
                if acc_we_i:
                    next_acc[i] = acc_next & MASK48
                if pend_clr_i:
                    next_sum[i] = 0
                    next_carry[i] = 0
                elif prod_en_i:
                    next_sum[i] = csa1_sum
                    next_carry[i] = csa1_carry

        # ---- readback_mux / barrel_shifter / result_selector -------------
        rd_lo_data = cluster_out & MASK32
        rd_hi_data = sext((cluster_out >> 32) & MASK16, 16, 32)

        shift_src = self.acc[d.acc_sel] if d.acc_sel < 3 else 0
        if d.shift_dir:                        # logical left
            shifted = (shift_src << d.shift_amt) & MASK48
        else:                                  # arithmetic right
            shifted = (s48(shift_src) >> d.shift_amt) & MASK48
        shift_result = shifted & MASK32

        rd_data = {1: rd_lo_data, 2: rd_hi_data,
                   3: shift_result}.get(d.result_src, 0)

        # ---- overflow_flag.v (registered; clear beats set -- FLAG-E) -----
        any_ovf = mac_overflow or sat_overflow
        overflow_now = self.overflow_sticky     # value visible THIS cycle
        if csr_clear_overflow:
            # ERRATUM DSU-8 (FLAG-E): clear the ACCUMULATED flag but keep an
            # overflow occurring in this same cycle, or a poll-and-clear loop
            # drops it silently.
            next_ovf = 1 if any_ovf else 0
        elif any_ovf:
            next_ovf = 1
        else:
            next_ovf = self.overflow_sticky

        out = {
            "dsu_busy": int(stall_now),
            "dsu_rd_data": rd_data,
            "dsu_rd_valid": int(d.writes_regfile and not stall_now),
            "dsu_rd_addr": d.rd_addr,
            "dsu_overflow": int(overflow_now),
            "illegal_instr": int(d.illegal),
            "acc": list(self.acc),              # pre-edge, as sampled
        }

        # ---- commit registered state ------------------------------------
        self.acc = next_acc
        self.sum_reg = next_sum
        self.carry_reg = next_carry
        self.pending = next_pending
        self.overflow_sticky = next_ovf
        if flush:
            self.prev_was_2cycle = 0
            self.prev_acc_sel = 0
            self.stalled_once = 0
        else:
            # ERRATUM DSU-1: stalled_once records that this instruction has
            # already been held, so the interlock is a one-shot.
            self.stalled_once = int(stall_now)
            if not stall_now:
                self.prev_was_2cycle = int(cur_is_2cycle)
                self.prev_acc_sel = d.acc_sel
        return out

    # -- convenience ------------------------------------------------------
    def settle(self, acc_sel):
        """OBSOLETE as of ERRATUM DSU-4. Stage 2 now self-drains, so a pending
        product commits on the next cycle with no instruction required. Kept
        only so older callers still work; issuing an idle tick is the correct
        way to advance a cycle now, and DSU_gen.py no longer inserts a settle.
        Retained rather than deleted because deleting it would silently change
        the cycle count of any sequence that still calls it."""
        return self.tick(0, 0, 0, dsu_en=0)

    def acc_signed(self, i):
        return s48(self.acc[i])


# ---------------------------------------------------------------------------
# architectural model (the original) -- timeless, values only
# ---------------------------------------------------------------------------
class ArchDSU:
    """Timeless "what should the answer be" model.

    Kept because it is genuinely useful for reasoning about the maths and for
    generating expected VALUES. It does NOT model the MAC pipeline, dsu_en,
    flush, dsu_busy or reset, so it cannot be used to check WHEN anything
    appears -- for that use DSUModel. Named ArchDSU (was DSU) to make the
    distinction impossible to miss at the call site.
    """

    def __init__(self):
        self.acc = [0, 0, 0]
        self.overflow_sticky = False

    def _accumulate(self, sel, addend):
        raw = self.acc[sel] + addend
        if not (-(1 << 47) <= raw <= (1 << 47) - 1):
            self.overflow_sticky = True
        self.acc[sel] = wrap48(raw)

    def step(self, instr, rs1=0, rs2=0, csr_clear_overflow=0, dsu_en=1):
        rs1 &= MASK32
        rs2 &= MASK32
        d = decode(instr, dsu_en)

        out = {"rd_data": 0, "rd_valid": False, "rd_addr": d.rd_addr,
               "illegal": False, "overflow": self.overflow_sticky}

        if csr_clear_overflow:
            self.overflow_sticky = False

        if not d.is_custom0 or not dsu_en:
            out["overflow"] = self.overflow_sticky
            return out

        if d.illegal:
            out["illegal"] = True
            out["overflow"] = self.overflow_sticky
            return out

        a_lo, b_lo = rs1 & MASK16, rs2 & MASK16
        a_hi, b_hi = (rs1 >> 16) & MASK16, (rs2 >> 16) & MASK16
        sel = d.acc_sel

        if d.is_itype:                                        # MACSHIFT
            if d.shift_dir:
                shifted = (self.acc[sel] & MASK48) << d.shift_amt
            else:
                shifted = s48(self.acc[sel]) >> d.shift_amt
            out["rd_data"] = shifted & MASK32
            out["rd_valid"] = True
        elif d.funct5 == MAC_SEL:
            self._accumulate(sel, s16(a_lo) * s16(b_lo))
        elif d.funct5 == MACSUB:
            self._accumulate(sel, -(s16(a_lo) * s16(b_lo)))
        elif d.funct5 == MACABS:
            self._accumulate(sel, abs16(a_lo) * abs16(b_lo))
        elif d.funct5 == MACDOT:
            self._accumulate(sel, s16(a_lo) * s16(b_lo) + s16(a_hi) * s16(b_hi))
        elif d.funct5 == MACLOAD:
            self.acc[sel] = wrap48(sext(rs1, 32, 48))
        elif d.funct5 == MACCLEAR:
            self.acc[sel] = 0
        elif d.funct5 == MACSAT:
            v = s48(self.acc[sel])
            if not (-(1 << 31) <= v <= (1 << 31) - 1):
                self.overflow_sticky = True
                self.acc[sel] = wrap48((1 << 31) - 1 if v > 0 else -(1 << 31))
        elif d.funct5 == MACRD_LO:
            out["rd_data"] = self.acc[sel] & MASK32
            out["rd_valid"] = True
        elif d.funct5 == MACRD_HI:
            out["rd_data"] = sext((self.acc[sel] & MASK48) >> 32, 16, 32)
            out["rd_valid"] = True

        out["overflow"] = self.overflow_sticky
        return out


DSU = ArchDSU          # backwards compatibility for tools/gen/DSU_gen.py


# ---------------------------------------------------------------------------
# instruction assembler -- documents the encoding in one place
# ---------------------------------------------------------------------------
def asm(funct5, acc_sel=0, rd=0, rs1_n=0, rs2_n=0):
    """R-type Custom-0 (compute / readback / sat)."""
    return (funct5 << 27) | (acc_sel << 25) | (rs2_n << 20) \
           | (rs1_n << 15) | (0 << 12) | (rd << 7) | OPCODE_CUSTOM0

def asm_shift(acc_sel=0, amt=0, left=0, rd=0):
    """I-type Custom-0 (MACSHIFT)."""
    imm = (left << 8) | (acc_sel << 6) | (amt & 0x3F)
    return (imm << 20) | (0 << 15) | (1 << 12) | (rd << 7) | OPCODE_CUSTOM0


# ---------------------------------------------------------------------------
# self-check -- `python3 DSU_Golden.py`
# demonstrates the two models agreeing on values and disagreeing on timing,
# which is the whole point of having both.
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print("=== ArchDSU: timeless values ===")
    a = ArchDSU()
    a.step(asm(MAC_SEL, ACC_FX), 3, 4)
    a.step(asm(MAC_SEL, ACC_FX), 5, 6)
    print(f"  3*4 then 5*6 -> FX = {s48(a.acc[ACC_FX])}  (expect 42)")

    print("\n=== DSUModel: the same two ops, cycle by cycle ===")
    m = DSUModel()
    m.tick(asm(MAC_SEL, ACC_FX), 3, 4)
    print(f"  after cycle 1: FX = {m.acc_signed(ACC_FX)}  (product still pending)")
    m.tick(asm(MAC_SEL, ACC_FX), 5, 6)
    print(f"  after cycle 2: FX = {m.acc_signed(ACC_FX)}  (12 committed, 30 pending)")
    m.settle(ACC_FX)
    print(f"  after settle : FX = {m.acc_signed(ACC_FX)}  (expect 42)")

    print("\n=== FLAG-A: MACCLEAR with non-zero operands poisons the next MAC ===")
    m = DSUModel()
    m.tick(asm(MACCLEAR, ACC_FY), rs1=7, rs2=9)   # operands are meaningless...
    m.tick(asm(MAC_SEL, ACC_FY), rs1=0, rs2=0)    # ...but 7*9 lands here
    m.settle(ACC_FY)
    print(f"  FY = {m.acc_signed(ACC_FY)}  (architecturally should be 0)")

    print("\n=== FLAG-B: flush keeps committed acc, drops pending ===")
    m = DSUModel()
    m.tick(asm(MAC_SEL, ACC_FX), 3, 4)
    m.tick(asm(MAC_SEL, ACC_FX), 5, 6)            # commits 12, pends 30
    m.tick(asm(MAC_SEL, ACC_FX), 0, 0, flush=1)   # drop the pending 30
    m.settle(ACC_FX)
    print(f"  FX = {m.acc_signed(ACC_FX)}  (12 kept, 30 discarded)")

    print("\n=== dsu_en = 0 : DSU must be completely inert ===")
    m = DSUModel()
    o = m.tick(asm(MAC_SEL, ACC_FX), 3, 4, dsu_en=0)
    m.settle(ACC_FX)
    print(f"  FX = {m.acc_signed(ACC_FX)}  illegal={o['illegal_instr']}  (expect 0, 0)")

    print("\n=== dsu_busy interlock: MACRD_LO back-to-back, same acc ===")
    m = DSUModel()
    o1 = m.tick(asm(MACRD_LO, ACC_MAG, rd=10))
    o2 = m.tick(asm(MACRD_LO, ACC_MAG, rd=11))
    print(f"  cycle1 busy={o1['dsu_busy']} valid={o1['dsu_rd_valid']}")
    print(f"  cycle2 busy={o2['dsu_busy']} valid={o2['dsu_rd_valid']}  (stalled)")
