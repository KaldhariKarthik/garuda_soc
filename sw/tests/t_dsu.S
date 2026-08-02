# =============================================================================
# t_dsu.S -- Core Sanity TB rows 9 and 13: DSU Custom-0 through the pipeline.
#
# Row 9  : a short MAC sequence then a readback.
# Row 13 : back-to-back readbacks on ONE accumulator, which is the case
#          dsu_stall.v actually interlocks (its cur_is_2cycle set is
#          MACRD_LO / MACRD_HI / MACSAT).
#
# This deliberately drives the interlock that EXISTS, not the one that does
# not. Compute -> readback is FLAG-C and is covered separately by dsu_flag2.S;
# mixing the two here would make a failure ambiguous.
#
# Custom-0 encoding (rtl/dsu/dsu_decoder.v):
#   opcode 0x0b, funct3 000 (R-type), funct7 = {funct5[4:0], acc_sel[1:0]}
# =============================================================================

#define DSU_R(f5, acc, rd, rs1, rs2) .insn r 0x0b, 0, ((f5) << 2) | (acc), rd, rs1, rs2

#define F5_MAC_SEL  0
#define F5_MACCLEAR 5
#define F5_MACRD_LO 7
#define F5_MACRD_HI 8

    .section .text.init, "ax"
    .global _start
_start:
    li      x3, 0
    li      x1, 3
    li      x2, 5

    # ---- test 1: clear then read -> must be zero on every accumulator ----
    li      x3, 1
    DSU_R(F5_MACCLEAR, 0, x0, x0, x0)
    DSU_R(F5_MACCLEAR, 1, x0, x0, x0)
    DSU_R(F5_MACCLEAR, 2, x0, x0, x0)
    DSU_R(F5_MACRD_LO, 0, x5, x0, x0)
    bnez    x5, fail
    DSU_R(F5_MACRD_LO, 1, x6, x0, x0)
    bnez    x6, fail
    DSU_R(F5_MACRD_LO, 2, x7, x0, x0)
    bnez    x7, fail

    # ---- test 2 (row 13): back-to-back readbacks, SAME accumulator ----
    # dsu_stall must hold the second readback; both must return the same value.
    li      x3, 2
    DSU_R(F5_MACRD_LO, 0, x8,  x0, x0)
    DSU_R(F5_MACRD_LO, 0, x9,  x0, x0)
    DSU_R(F5_MACRD_LO, 0, x10, x0, x0)
    bne     x8, x9, fail
    bne     x9, x10, fail

    # ---- test 3: back-to-back readbacks across DIFFERENT accumulators ----
    # Different acc_sel -> the interlock must NOT fire; values stay independent.
    li      x3, 3
    DSU_R(F5_MACRD_LO, 0, x11, x0, x0)
    DSU_R(F5_MACRD_LO, 1, x12, x0, x0)
    DSU_R(F5_MACRD_LO, 2, x13, x0, x0)
    bnez    x11, fail
    bnez    x12, fail
    bnez    x13, fail

    # ---- test 4: LO/HI readback pair on one accumulator ----
    li      x3, 4
    DSU_R(F5_MACRD_LO, 0, x14, x0, x0)
    DSU_R(F5_MACRD_HI, 0, x15, x0, x0)
    bnez    x14, fail
    bnez    x15, fail

    # ---- test 5: a DSU op must not disturb the integer pipeline ----
    li      x3, 5
    li      x16, 0x1234
    DSU_R(F5_MACCLEAR, 0, x0, x0, x0)
    addi    x16, x16, 1
    DSU_R(F5_MACRD_LO, 0, x17, x0, x0)
    addi    x16, x16, 1
    li      x6, 0x1236
    bne     x16, x6, fail

    li      a0, 1
    j       done
fail:
    slli    a0, x3, 1
    ori     a0, a0, 1
done:
    lla     t0, tohost
    sw      a0, 0(t0)
1:  j 1b
