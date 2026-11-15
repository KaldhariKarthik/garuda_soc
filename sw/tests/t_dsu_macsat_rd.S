# =============================================================================
# t_dsu_macsat_rd.S -- MACSAT as the DSU specification rules it (DSU spec Rev 3.1
# [N-7.3], ruling D-32 on DSU-15): MACSAT clamps the selected accumulator IN PLACE
# to the int32 range (sign-extended back to 48 bits), raises the sticky overflow
# flag dsu_ovf when it had to clamp, and writes NO register; firmware reads the
# result with MACREAD_LO / MACREAD_HI.
# Until 2026-11-15 this program checked the pre-D-32 text (MACSAT rd = Q1.15 in rd)
# and failed by design (xfail DSU-15); rewritten for 1-TOPS G5.
# Each case: rd of the MACSAT (x5) is preset to 0xDEAD and must still hold it;
# dsu_ovf (0xBC0, read clears) is read before (must be 0) and after the MACSAT.
#   case 0  acc = 0x2000_0000 (in range)       -> unchanged, LO 0x2000_0000, HI 0, ovf 0
#   case 1  acc = 0x7FFF_FFFF + 0x7FFF*0x7FFF  -> clamped to 0x0000_7FFF_FFFF, ovf 1
#   case 2  acc = -2^31 - 0x7FFF*0x7FFF        -> clamped to 0xFFFF_8000_0000, ovf 1
# The three accumulators are used in turn (FX, FY, MAG).
# Fail code (tohost >> 1) = 1 + 8*case + check: check 1 rd written, 2 LO, 3 HI,
# 4 ovf before, 5 ovf after.
# =============================================================================
#define F5_MAC      0
#define F5_MACSUB   1
#define F5_MACLOAD  4
#define F5_MACSAT   6
#define F5_RD_LO    7
#define F5_RD_HI    8
#define DSU(f5, acc, rd, rs1, rs2) .insn r 0x0b, 0, ((f5) << 2) | (acc), rd, rs1, rs2

.macro EXPECT reg, want, code
    li      t6, \want
    li      a0, \code
    bne     \reg, t6, fail
.endm

# CASE n, acc, load, op (F5_MAC / F5_MACSUB / -1 none), lo, hi, ovf
.macro CASE n, acc, load, op, lo, hi, ovf
    li      a1, \load
    DSU(F5_MACLOAD, \acc, x0, a1, x0)
    .if \op >= 0
    li      a1, 0x7FFF
    li      a2, 0x7FFF
    DSU(\op, \acc, x0, a1, a2)
    .endif
    nop
    nop
    csrr    t0, 0xBC0                   # clears any earlier overflow
    EXPECT  t0, 0, (1 + 8*\n + 4)
    li      x5, 0xDEAD
    DSU(F5_MACSAT, \acc, x5, x0, x0)    # rd field = x5: must not be written
    nop
    nop
    EXPECT  x5, 0xDEAD, (1 + 8*\n + 1)
    DSU(F5_RD_LO, \acc, t0, x0, x0)
    EXPECT  t0, \lo, (1 + 8*\n + 2)
    DSU(F5_RD_HI, \acc, t0, x0, x0)
    EXPECT  t0, \hi, (1 + 8*\n + 3)
    csrr    t0, 0xBC0
    EXPECT  t0, \ovf, (1 + 8*\n + 5)
.endm

    .section .text.init, "ax"
    .global _start
_start:
    csrr    t0, 0xBC0                   # start with the flag clear
    CASE    0, 0, 0x20000000, -1,         0x20000000, 0x00000000, 0
    CASE    1, 1, 0x7FFFFFFF, F5_MAC,     0x7FFFFFFF, 0x00000000, 1
    CASE    2, 2, 0x80000000, F5_MACSUB,  0x80000000, 0xFFFFFFFF, 1
    li      a0, 0                       # pass: tohost = 1

fail:
    lla     t0, tohost
    slli    a0, a0, 1
    ori     a0, a0, 1
    sw      a0, 0(t0)
1:  j       1b
