# =============================================================================
# t_dsu_macsat_rd.S -- MACSAT as the DSU specification defines it (DSU vPlan F06,
# spec section 7 table: "MACSAT rd: rd = acc saturated to Q1.15 in rd[15:0],
# writes rd"; [N-7.3]: "the normal way a result re-enters the RV32IM datapath").
# Reproducer of DSU-15 (Track A wrap-up, 2026-10-12): the RTL does not write rd
# for MACSAT (dsu_decoder.v writes_regfile = RD_LO | RD_HI | MACSHIFT only) and
# clamps the accumulator in place to the int32 range (+-2.0 in Q18.30), not to
# Q1.15 (+-1.0). Expected to FAIL until the ruling (xfail DSU-15).
#   bit 0  acc = 0.5   (MACLOAD 0x2000_0000) -> rd[15:0] = 0x4000
#   bit 1  acc = +1.5  (MACLOAD 0x6000_0000) -> rd[15:0] = 0x7FFF (saturated)
#   bit 2  acc = -1.5  (MACLOAD 0xA000_0000) -> rd[15:0] = 0x8000 (saturated)
# Result: tohost = (bitmask << 1) | 1; 0 bits set = PASS.
# =============================================================================
#define DSU_R(f5, acc, rd, rs1, rs2) .insn r 0x0b, 0, ((f5) << 2) | (acc), rd, rs1, rs2
#define F5_MACLOAD  4
#define F5_MACSAT   6

.macro CASE val, want, bit
    li      x10, \val
    DSU_R(F5_MACLOAD, 0, x0, x10, x0)
    nop
    nop
    li      x5, 0x0000DEAD
    DSU_R(F5_MACSAT, 0, x5, x0, x0)
    nop
    nop
    li      x6, 0xFFFF
    and     x5, x5, x6
    li      x7, \want
    beq     x5, x7, 77f
    li      x7, (1 << \bit)
    or      x26, x26, x7
77:
.endm

    .section .text.init, "ax"
    .global _start
_start:
    li      x26, 0
    CASE    0x20000000, 0x4000, 0
    CASE    0x60000000, 0x7FFF, 1
    CASE    0xA0000000, 0x8000, 2
    lla     t0, tohost
    beqz    x26, 1f
    slli    a0, x26, 1
    ori     a0, a0, 1
    sw      a0, 0(t0)
2:  j       2b
1:  li      a0, 1
    sw      a0, 0(t0)
3:  j       3b
