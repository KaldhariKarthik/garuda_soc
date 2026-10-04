# =============================================================================
# t_dsu_b2b.S -- DSU instructions BACK TO BACK, through the real pipeline.
#
# tb_dsu_top drives one instruction, then one idle cycle "so stage 2 commits"
# (step 3 of its loop), and never asserts flush. So the unit bench cannot see
# anything that depends on what is in EX during the cycle a MAC's product is
# being folded into its accumulator. In the core that cycle is never idle: the
# next instruction is there. These are the cases.
#
# Result: a BITMASK, as in t_hold_flush_matrix.S -- tohost = (x26 << 1) | 1.
#   bit 0  MAC acc0 ; MACCLEAR acc1      acc0 must still get its product
#   bit 1  MAC acc0 ; MACLOAD  acc1      acc0 must get its product, not rs1
#   bit 2  MAC acc0 ; MACSAT   acc0      the saturate must see acc0 + product
#   bit 3  MAC acc0 ; MAC acc1 ; MAC acc0 ; MACRD acc0   chained computes
#   bit 4  MAC acc2 ; MACCLEAR acc2      the younger clear wins (acc2 = 0)
#   bit 5  the sticky overflow flag stays clear through all of the above
# =============================================================================

#define DSU_R(f5, acc, rd, rs1, rs2) .insn r 0x0b, 0, ((f5) << 2) | (acc), rd, rs1, rs2

#define F5_MAC_SEL  0
#define F5_MACLOAD  4
#define F5_MACCLEAR 5
#define F5_MACSAT   6
#define F5_MACRD_LO 7
#define F5_MACRD_HI 8

.macro CHK ra, rb, bit
    beq     \ra, \rb, 77f
    li      x7, (1 << \bit)
    or      x26, x26, x7
77:
.endm

    .section .text.init, "ax"
    .global _start
_start:
    li      x26, 0
    li      x16, 3
    li      x17, 5
    li      x13, 100
    csrr    x5, 0xbc0                   # read-clear the sticky overflow flag

    # ---- bit 0 ----
    DSU_R(F5_MACCLEAR, 0, x0, x0, x0)
    nop
    nop
    DSU_R(F5_MAC_SEL,  0, x0, x16, x17)
    DSU_R(F5_MACCLEAR, 1, x0, x0, x0)
    nop
    nop
    DSU_R(F5_MACRD_LO, 0, x18, x0, x0)
    li      x5, 15
    CHK     x18, x5, 0

    # ---- bit 1 ----
    DSU_R(F5_MACCLEAR, 0, x0, x0, x0)
    nop
    nop
    DSU_R(F5_MAC_SEL,  0, x0, x16, x17)
    DSU_R(F5_MACLOAD,  1, x0, x13, x0)
    nop
    nop
    DSU_R(F5_MACRD_LO, 0, x18, x0, x0)
    DSU_R(F5_MACRD_LO, 1, x19, x0, x0)
    li      x5, 15
    CHK     x18, x5, 1
    CHK     x19, x13, 1

    # ---- bit 2 ----
    # acc0 = 0x7fffffff + 0x4000*0x4000 = 0x8fffffff : above int32, so a
    # saturate of THIS value clamps. The next MAC adds -0x8000*0x4000 and
    # brings it to 0x6fffffff, in range; the MACSAT right behind it must
    # therefore change nothing and must not report an overflow.
    li      x5, 0x7fffffff
    li      x6, 0x4000
    li      x8, 0xffff8000
    DSU_R(F5_MACLOAD,  0, x0, x5, x0)
    nop
    nop
    DSU_R(F5_MAC_SEL,  0, x0, x6, x6)
    nop
    nop
    DSU_R(F5_MAC_SEL,  0, x0, x8, x6)
    DSU_R(F5_MACSAT,   0, x0, x0, x0)
    nop
    nop
    DSU_R(F5_MACRD_LO, 0, x18, x0, x0)
    DSU_R(F5_MACRD_HI, 0, x19, x0, x0)
    li      x5, 0x6fffffff
    CHK     x18, x5, 2
    CHK     x19, x0, 2

    # ---- bit 3 ----
    DSU_R(F5_MACCLEAR, 0, x0, x0, x0)
    DSU_R(F5_MACCLEAR, 1, x0, x0, x0)
    nop
    nop
    DSU_R(F5_MAC_SEL,  0, x0, x16, x17)
    DSU_R(F5_MAC_SEL,  1, x0, x16, x16)
    DSU_R(F5_MAC_SEL,  0, x0, x17, x17)
    DSU_R(F5_MACRD_LO, 0, x18, x0, x0)
    DSU_R(F5_MACRD_LO, 1, x19, x0, x0)
    li      x5, 40
    CHK     x18, x5, 3
    li      x5, 9
    CHK     x19, x5, 3

    # ---- bit 4 ----
    DSU_R(F5_MACLOAD,  2, x0, x13, x0)
    nop
    nop
    DSU_R(F5_MAC_SEL,  2, x0, x16, x17)
    DSU_R(F5_MACCLEAR, 2, x0, x0, x0)
    nop
    nop
    DSU_R(F5_MACRD_LO, 2, x18, x0, x0)
    CHK     x18, x0, 4

    # ---- bit 5 ----
    csrr    x5, 0xbc0
    CHK     x5, x0, 5

    beqz    x26, pass
    slli    a0, x26, 1
    ori     a0, a0, 1
    j       done
pass:
    li      a0, 1
done:
    lla     t0, tohost
    sw      a0, 0(t0)
1:  j 1b
