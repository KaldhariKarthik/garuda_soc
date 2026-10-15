# =============================================================================
# t_dsu_gate.S -- the DSU accumulators keep their values while the core clock is
# gated (DSU vPlan F24; Track A wrap-up 2026-10-12). Three accumulators are given
# distinct values (acc2 is pushed past 32 bits by real MACs), all six halves and
# the sticky overflow flag are read, the core sleeps in WFI (the clock gate closes;
# tb_boot +IRQ_AT wakes it), and everything is read again and compared.
# Run with +IRQ_AT=<a cycle well after the WFI is reached>.
# Fail codes: 3 no wake happened, 5+2k half k changed (k = 0..5), 17 flag changed.
# =============================================================================
#define DSU_R(f5, acc, rd, rs1, rs2) .insn r 0x0b, 0, ((f5) << 2) | (acc), rd, rs1, rs2
#define F5_MAC_SEL  0
#define F5_MACLOAD  4
#define F5_MACRD_LO 7
#define F5_MACRD_HI 8

.macro READALL base
    DSU_R(F5_MACRD_LO, 0, x10, x0, x0)
    DSU_R(F5_MACRD_HI, 0, x11, x0, x0)
    DSU_R(F5_MACRD_LO, 1, x12, x0, x0)
    DSU_R(F5_MACRD_HI, 1, x13, x0, x0)
    DSU_R(F5_MACRD_LO, 2, x14, x0, x0)
    DSU_R(F5_MACRD_HI, 2, x15, x0, x0)
    csrr    x16, 0xbc0
    lla     t0, \base
    sw      x10, 0(t0)
    sw      x11, 4(t0)
    sw      x12, 8(t0)
    sw      x13, 12(t0)
    sw      x14, 16(t0)
    sw      x15, 20(t0)
    sw      x16, 24(t0)
.endm

    .section .text.init, "ax"
    .global _start
_start:
    lla     t0, trap_vector
    csrw    mtvec, t0
    li      x20, 0                      # wakes
    li      x5, 0x12345678
    DSU_R(F5_MACLOAD, 0, x0, x5, x0)
    li      x5, 0x87654321
    DSU_R(F5_MACLOAD, 1, x0, x5, x0)
    li      x5, 0x7FFFFFFF
    DSU_R(F5_MACLOAD, 2, x0, x5, x0)
    li      x6, 0x7FFF
    DSU_R(F5_MAC_SEL, 2, x0, x6, x6)     # acc2 grows past 2^31: the high half moves
    DSU_R(F5_MAC_SEL, 2, x0, x6, x6)
    DSU_R(F5_MAC_SEL, 2, x0, x6, x6)
    DSU_R(F5_MAC_SEL, 2, x0, x6, x6)
    nop
    nop
    READALL before
    li      t0, 8
    csrs    mstatus, t0
    li      t0, -1
    csrs    mie, t0
    wfi
    READALL after
    li      a0, 3
    beqz    x20, fail
    lla     t1, before
    lla     t2, after
    li      t3, 0                       # k
cmp:
    lw      t4, 0(t1)
    lw      t5, 0(t2)
    slli    a0, t3, 1
    addi    a0, a0, 5
    bne     t4, t5, fail
    addi    t1, t1, 4
    addi    t2, t2, 4
    addi    t3, t3, 1
    li      t6, 7
    blt     t3, t6, cmp
    li      a0, 1
    j       done
fail:
    slli    a0, a0, 1
    ori     a0, a0, 1
done:
    lla     t0, tohost
    sw      a0, 0(t0)
1:  j 1b
    .align 6
trap_vector:
    addi    x20, x20, 1
    li      t0, 8
    csrc    mstatus, t0                 # one wake is enough
    li      t0, 8
    slli    t0, t0, 4
    csrc    mstatus, t0                 # and MPIE: no re-entry after mret
    mret

    .section .data
    .align 4
before: .space 28
after:  .space 28
