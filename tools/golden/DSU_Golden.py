"""
dsu_golden.py  --  reference ("golden") model for the GARUDA DSU.

WHAT THIS IS
------------
A plain-Python copy of what the DSU is *supposed* to compute. The testbench
runs the real RTL and this model on the same instructions, then compares.
If they disagree, either the RTL has a bug or this model is wrong -- and both
are things you want to know before tapeout.

This models the ARCHITECTURAL result: what value each accumulator and each
register write *should* hold. It does not model clock cycles. The real MAC has
a 2-stage pipeline, so the hardware value lands a cycle or two later -- the
testbench accounts for that timing when it samples. (See the note on FLAG-2 at
the bottom; that timing gap is exactly the open question in the plan.)

The three accumulators map to the drone math: FX (force-x), FY (force-y),
MAG (magnitude).  RTL source of truth: rtl/dsu @ 6a80780.
"""

# ---------------------------------------------------------------------------
# funct5 opcodes -- must match dsu_defs.vh exactly
# ---------------------------------------------------------------------------
MAC_SEL, MACSUB, MACABS, MACDOT, MACLOAD = 0, 1, 2, 3, 4
MACCLEAR, MACSAT, MACRD_LO, MACRD_HI, MACSHIFT = 5, 6, 7, 8, 9

ACC_FX, ACC_FY, ACC_MAG = 0, 1, 2          # acc_sel values (3 = illegal)

MASK16, MASK32, MASK48 = 0xFFFF, 0xFFFFFFFF, (1 << 48) - 1


# ---------------------------------------------------------------------------
# tiny bit helpers -- turn raw bit patterns into signed numbers and back
# ---------------------------------------------------------------------------
def s16(x):                                # read 16 bits as signed
    x &= MASK16
    return x - (1 << 16) if x & 0x8000 else x

def s48(x):                                # read 48 bits as signed
    x &= MASK48
    return x - (1 << 48) if x & (1 << 47) else x

def wrap48(x):                             # force a number back into 48-bit signed range
    return s48(x & MASK48)

def sext(value, from_bits, to_bits=32):    # sign-extend
    sign = 1 << (from_bits - 1)
    value &= (1 << from_bits) - 1
    return (value ^ sign) - sign & ((1 << to_bits) - 1)


def abs16(x):
    """Absolute value of a 16-bit signed number.
    The trap: -32768 (0x8000) has no positive twin in 16 bits, so we clamp it
    to +32767 (0x7FFF) instead of letting it wrap back to negative."""
    x &= MASK16
    if x == 0x8000:
        return 0x7FFF
    if x & 0x8000:
        return (~x + 1) & MASK16           # magnitude of a negative number
    return x


# ---------------------------------------------------------------------------
# the model
# ---------------------------------------------------------------------------
class DSU:
    def __init__(self):
        self.acc = [0, 0, 0]               # FX, FY, MAG  (48-bit signed)
        self.overflow_sticky = False       # the "check-engine light"

    # ----- helper: one 16x16 accumulate, with overflow detection ----------
    def _accumulate(self, sel, addend):
        raw = self.acc[sel] + addend
        # overflow = the true result no longer fits in 48-bit signed
        if not (-(1 << 47) <= raw <= (1 << 47) - 1):
            self.overflow_sticky = True
        self.acc[sel] = wrap48(raw)

    # ----- the main entry point -------------------------------------------
    def step(self, instr, rs1=0, rs2=0, csr_clear_overflow=0):
        """Execute one instruction word. Returns what the DSU drives back:
        rd_data / rd_valid / rd_addr (register writeback), plus illegal + the
        current sticky overflow flag."""
        rs1 &= MASK32
        rs2 &= MASK32

        # --- decode (mirrors dsu_decoder.v) -------------------------------
        opcode  = instr & 0x7F
        funct3  = (instr >> 12) & 0x7
        funct5  = (instr >> 27) & 0x1F
        rd_addr = (instr >> 7) & 0x1F
        imm_i   = (instr >> 20) & 0xFFF

        is_custom0 = (opcode == 0x0B)
        is_rtype   = is_custom0 and funct3 == 0
        is_itype   = is_custom0 and funct3 == 1                 # MACSHIFT

        acc_sel = ((imm_i >> 6) & 0x3) if is_itype else ((instr >> 25) & 0x3)

        out = {"rd_data": 0, "rd_valid": False, "rd_addr": rd_addr,
               "illegal": False, "overflow": self.overflow_sticky}

        # --- clear the sticky flag first; clear WINS over a set this step --
        # (this matches the RTL: csr_clear beats a simultaneous overflow)
        cleared_this_step = bool(csr_clear_overflow)
        if cleared_this_step:
            self.overflow_sticky = False

        # --- if it isn't ours, do nothing ---------------------------------
        if not is_custom0:
            out["overflow"] = self.overflow_sticky
            return out

        # --- illegal-instruction checks (dsu_decoder illegal_instr) -------
        legal_funct5 = funct5 <= MACSHIFT
        illegal = (not (is_rtype or is_itype)) \
                  or (is_rtype and not legal_funct5) \
                  or (acc_sel == 3)
        if illegal:
            out["illegal"] = True
            out["overflow"] = self.overflow_sticky           # state unchanged
            return out

        # --- operand slices ------------------------------------------------
        a_lo, b_lo = rs1 & MASK16, rs2 & MASK16
        a_hi, b_hi = (rs1 >> 16) & MASK16, (rs2 >> 16) & MASK16

        # --- the instructions ---------------------------------------------
        if is_itype:                                          # MACSHIFT
            amt   = imm_i & 0x3F                              # 6-bit amount
            left  = (imm_i >> 8) & 0x1                        # dir: 1=left,0=right
            if left:
                shifted = (self.acc[acc_sel] & MASK48) << amt
            else:
                shifted = s48(self.acc[acc_sel]) >> amt       # arithmetic (keeps sign)
            out["rd_data"] = shifted & MASK32
            out["rd_valid"] = True

        elif funct5 == MAC_SEL:                               # acc += a*b (low lane)
            self._accumulate(acc_sel, s16(a_lo) * s16(b_lo))

        elif funct5 == MACSUB:                                # acc -= a*b
            self._accumulate(acc_sel, -(s16(a_lo) * s16(b_lo)))

        elif funct5 == MACABS:                                # acc += |a|*|b|
            self._accumulate(acc_sel, abs16(a_lo) * abs16(b_lo))

        elif funct5 == MACDOT:                                # acc += a0*b0 + a1*b1
            self._accumulate(acc_sel, s16(a_lo) * s16(b_lo) + s16(a_hi) * s16(b_hi))

        elif funct5 == MACLOAD:                               # acc = rs1 (sign-extended 32->48)
            self.acc[acc_sel] = wrap48(sext(rs1, 32, 48))

        elif funct5 == MACCLEAR:                              # acc = 0
            self.acc[acc_sel] = 0

        elif funct5 == MACSAT:                                # clamp acc into signed-32
            v = s48(self.acc[acc_sel])
            if -(1 << 31) <= v <= (1 << 31) - 1:
                pass                                          # fits -> leave it
            else:
                self.overflow_sticky = True                  # clamping = data lost
                v = (1 << 31) - 1 if v > 0 else -(1 << 31)
                self.acc[acc_sel] = wrap48(v)

        elif funct5 == MACRD_LO:                              # rd = acc[31:0]
            out["rd_data"] = self.acc[acc_sel] & MASK32
            out["rd_valid"] = True

        elif funct5 == MACRD_HI:                              # rd = sign-ext(acc[47:32])
            hi16 = (self.acc[acc_sel] & MASK48) >> 32
            out["rd_data"] = sext(hi16, 16, 32)
            out["rd_valid"] = True

        out["overflow"] = self.overflow_sticky
        return out


# ---------------------------------------------------------------------------
# instruction assembler -- build the 32-bit word the DSU expects.
# handy for the test generator; also documents the encoding in one place.
# ---------------------------------------------------------------------------
def asm(funct5, acc_sel=0, rd=0, rs1_n=0, rs2_n=0):
    """R-type Custom-0 (compute / readback / sat)."""
    return (funct5 << 27) | (acc_sel << 25) | (rs2_n << 20) \
           | (rs1_n << 15) | (0 << 12) | (rd << 7) | 0x0B

def asm_shift(acc_sel=0, amt=0, left=0, rd=0):
    """I-type Custom-0 (MACSHIFT)."""
    imm = (left << 8) | (acc_sel << 6) | (amt & 0x3F)
    return (imm << 20) | (0 << 15) | (1 << 12) | (rd << 7) | 0x0B


# ---------------------------------------------------------------------------
# runnable demo -- `python dsu_golden.py` to see it compute
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    dsu = DSU()

    def show(msg): print(f"{msg:<34} FX={dsu.acc[0]:>8}  FY={dsu.acc[1]:>8}  ovf={int(dsu.overflow_sticky)}")

    # accumulate 3*4 then 5*6 into FX  ->  12 + 30 = 42
    dsu.step(asm(MAC_SEL, ACC_FX), rs1=3, rs2=4);  show("MAC_SEL 3*4 -> FX")
    dsu.step(asm(MAC_SEL, ACC_FX), rs1=5, rs2=6);  show("MAC_SEL 5*6 -> FX")

    # subtract 2*10 from FX  ->  42 - 20 = 22
    dsu.step(asm(MACSUB, ACC_FX), rs1=2, rs2=10);  show("MACSUB 2*10 -> FX")

    # the abs trap: |-32768| must clamp to +32767, times 1
    dsu.step(asm(MACABS, ACC_FY), rs1=0x8000, rs2=1); show("MACABS |0x8000|*1 -> FY")

    # read FX back to a register
    r = dsu.step(asm(MACRD_LO, ACC_FX, rd=10))
    print(f"MACRD_LO FX -> x10 = {r['rd_data']}  (valid={r['rd_valid']})")

    # an illegal one: acc_sel = 3 doesn't exist
    r = dsu.step(asm(MAC_SEL, acc_sel=3), rs1=1, rs2=1)
    print(f"MAC_SEL acc_sel=3 -> illegal={r['illegal']} (state untouched)")