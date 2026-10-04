# =============================================================================
# t_hold_flush_matrix.S -- CORE-SPEC [N-11.2] / [N-7.23]: every hold cause
# against every flush cause, constructed deliberately (Docs/BUGS.md AUD-8).
#
#   holds  : H1 load-use, H2 D-port wait, H4 dsu_busy, H5 WFI
#   flushes: F1 branch/JALR redirect, F2 trap (exception or interrupt),
#            F3 MRET, F4 FENCE.I
#
# Every load and store costs at least two bus cycles (ERRATUM D-1), so the
# instruction DIRECTLY BEHIND a load or store is always in EX while H2 is
# asserted, with no +DWAIT needed; +DWAIT/+DRAND only stretch the window.
# Each sub-test therefore puts the flushing instruction straight behind the
# holding one and then checks architectural state, not timing.
#
# RESULT CONVENTION (differs from the other tests on purpose): sub-tests do
# not stop at the first failure. Each failing check sets ONE BIT in x26, and
# tohost is written with (x26 << 1) | 1, so "FAILED (test N)" in the log is a
# BITMASK of failed sub-tests -- one run reports every broken cell.
#
#   bit  0  H2 x F1   store/load, then a mispredicted branch / JALR in EX
#   bit  1  H2 x F2   store, then ECALL: one trap, mepc exact, MPIE/MIE exact
#   bit  2  H2 x F2   load, then an illegal instruction
#   bit  3  H1 x F2 / H1 x F1  misaligned load with a dependent behind it;
#                     load-use into a predicted-taken backward branch
#   bit  4  H2 x F2   store, then an unimplemented-CSR access
#   bit  5  H2 x F3   store, then MRET (in the handler) with MPIE = 0
#   bit  6  H2 x F4   store, then FENCE.I, then the instruction just stored
#   bit  7  H2        store, then CSRRW: rd must get the OLD CSR value
#   bit  8  H2        store, then a DSU MAC: must accumulate exactly once
#   bit  9  H4 x F2   illegal Custom-0 behind a MAC on the same accumulator
#                     (dsu_busy and a trap in one cycle); the older MAC must
#                     still accumulate
#   bit 10  F2        ECALL straight behind a MAC: the MAC is older than the
#                     trap and must complete ([N-7.13])
#   bit 11  H4 x F1   JAL in ID while a readback is held by dsu_busy
#   --- H5 column: needs a periodic interrupt to wake (+IRQ_EVERY=n). The
#       block is skipped, and the test still passes, when fewer than two
#       interrupts have been seen by the time it is reached. ---
#   bit 12  H5 x H1   WFI; load; dependent  (the canonical idle loop)
#   bit 13  H5 x F1   WFI; JALR with a link register
#   bit 14  H5        WFI; CSRRW
#   bit 15  H5        WFI; DSU MAC
#   bit 16  H5 x F2   WFI; ECALL
#   bit 17  H5 x F1   WFI; mispredicted branch
#   bit 18  H5        WFI; store; load
#
# Suggested runs (see the NEW FILES note in the worker report):
#   plain                                    -> bits 0..11
#   +DWAIT=3                                 -> wider H2 window
#   +IWAIT=8 +DWAIT=8 +IRAND=1 +DRAND=1 +SEED=n
#   +IRQ_EVERY=97 (and other periods)        -> bits 12..18 and F2-by-interrupt
#                                               landing on every cell
#   +IRQ_AT=<c> +IRQ_EVERY=4000, c swept     -> interrupt on the WFI entry and
#                                               on each following cycle
# =============================================================================

#define DSU_R(f5, acc, rd, rs1, rs2) .insn r 0x0b, 0, ((f5) << 2) | (acc), rd, rs1, rs2
#define DSU_SH(acc, dir, amt, rd)    .insn i 0x0b, 1, rd, x0, (((dir) << 8) | ((acc) << 6) | (amt))

#define F5_MAC_SEL  0
#define F5_MACCLEAR 5
#define F5_MACRD_LO 7

# record a failure of sub-test \bit unless \ra == \rb. Uses x7.
.macro CHK ra, rb, bit
    beq     \ra, \rb, 77f
    li      x7, (1 << \bit)
    or      x26, x26, x7
77:
.endm

    .section .text.init, "ax"
    .global _start
_start:
    lla     t0, trap_vector
    csrw    mtvec, t0
    li      x26, 0                      # failure bitmask
    li      x20, 0                      # exceptions taken
    li      x21, 0                      # last exception mcause
    li      x22, 0                      # last exception mtval
    li      x23, 0                      # last exception mepc
    li      x24, 0                      # mstatus as seen inside the handler
    li      x25, 0                      # interrupts taken
    lla     x10, scratch
    lla     x27, hscratch
    li      x11, 0x5a5a1234
    li      x16, 3
    li      x17, 5
    csrsi   mstatus, 8                  # MIE = 1 for the whole body

# ---------------------------------------------------------------------------
# bit 0 : H2 x F1
# ---------------------------------------------------------------------------
    li      x12, 0
    sw      x11, 0(x10)
    beq     x0, x0, 1f                  # forward, predicted not-taken: EX redirect
    li      x12, 1                      # wrong path
1:  lw      x13, 0(x10)
    CHK     x13, x11, 0                 # the store in MEM completed ([N-7.25])
    CHK     x12, x0, 0

    lla     x15, 2f
    li      x14, 0
    lw      x14, 0(x10)
    jalr    x1, 0(x15)                  # JALR in EX behind a load in MEM
b0r:
    li      x12, 1                      # wrong path
2:  lla     x5, b0r
    CHK     x1, x5, 0                   # link written
    CHK     x14, x11, 0                 # the load completed
    CHK     x12, x0, 0

3:  sw      x11, 4(x10)
    bne     x0, x0, 3b                  # backward, predicted taken, NOT taken
    lw      x13, 4(x10)
    CHK     x13, x11, 0

# ---------------------------------------------------------------------------
# bit 1 : H2 x F2 -- ECALL in EX while the store in front of it holds the bus
# ---------------------------------------------------------------------------
    li      x21, 0
    mv      x8, x20
    sw      x11, 8(x10)
b1e:
    ecall
    lla     x5, b1e
    li      x6, 11
    CHK     x21, x6, 1                  # mcause
    CHK     x23, x5, 1                  # mepc = the ECALL, [N-7.24]
    addi    x8, x8, 1
    CHK     x20, x8, 1                  # exactly one trap
    andi    x5, x24, 0x88
    li      x6, 0x80
    CHK     x5, x6, 1                   # in the handler: MPIE=1 (old MIE), MIE=0
    csrr    x5, mstatus
    andi    x5, x5, 0x88
    li      x6, 0x88
    CHK     x5, x6, 1                   # after MRET: MIE restored
    lw      x13, 8(x10)
    CHK     x13, x11, 1                 # the store completed

# ---------------------------------------------------------------------------
# bit 2 : H2 x F2 -- illegal instruction behind a load
# ---------------------------------------------------------------------------
    li      x21, 0
    mv      x8, x20
    li      x14, 0
    lw      x14, 8(x10)
b2i:
    .word   0xffffffff
    lla     x5, b2i
    li      x6, 2
    CHK     x21, x6, 2
    CHK     x23, x5, 2
    li      x6, -1
    CHK     x22, x6, 2                  # mtval = the instruction word
    addi    x8, x8, 1
    CHK     x20, x8, 2
    CHK     x14, x11, 2                 # the load in MEM still wrote back

# ---------------------------------------------------------------------------
# bit 3 : H1 x F2 -- a misaligned load (trap in EX) with its dependent in ID
#         H1 x F1 -- load-use into a predicted-taken backward branch (P-2)
# ---------------------------------------------------------------------------
    li      x21, 0
    mv      x8, x20
    li      x9, 0x77
    sw      x11, 12(x10)
b3m:
    lw      x9, 1(x10)                  # cause 4; the handler skips it
    addi    x12, x9, 1                  # load-use against the faulting load
    lla     x5, b3m
    li      x6, 4
    CHK     x21, x6, 3
    CHK     x23, x5, 3
    addi    x5, x10, 1
    CHK     x22, x5, 3                  # mtval = the address
    addi    x8, x8, 1
    CHK     x20, x8, 3
    li      x6, 0x77
    CHK     x9, x6, 3                   # a faulting load writes nothing
    li      x6, 0x78
    CHK     x12, x6, 3                  # the dependent ran once, after the trap

    li      x12, 0
    j       5f
4:  addi    x12, x12, 1
    j       6f
5:  lw      x5, 0(x10)
    beq     x5, x11, 4b                 # load-use + backward predicted-taken
    li      x12, 100
6:  li      x6, 1
    CHK     x12, x6, 3

# ---------------------------------------------------------------------------
# bit 4 : H2 x F2 -- unimplemented CSR behind a store
# ---------------------------------------------------------------------------
    li      x21, 0
    mv      x8, x20
    li      x9, 0x55
    sw      x11, 16(x10)
b4c:
    csrrw   x9, 0x7c0, x11
    lla     x5, b4c
    li      x6, 2
    CHK     x21, x6, 4
    CHK     x23, x5, 4
    addi    x8, x8, 1
    CHK     x20, x8, 4
    li      x6, 0x55
    CHK     x9, x6, 4

# ---------------------------------------------------------------------------
# bit 5 : H2 x F3 -- the handler stores and then MRETs, so MRET sits in EX
#         behind a store. Taken with MIE=0, so MPIE=0 at the MRET: a pop that
#         is applied on more than one cycle leaves MIE=1.
# ---------------------------------------------------------------------------
    csrci   mstatus, 8
    mv      x8, x20
    ecall
    csrr    x5, mstatus
    csrsi   mstatus, 8
    andi    x5, x5, 0x88
    li      x6, 0x80
    CHK     x5, x6, 5                   # MIE=0 (restored from MPIE=0), MPIE=1
    addi    x8, x8, 1
    CHK     x20, x8, 5

# ---------------------------------------------------------------------------
# bit 6 : H2 x F4 -- FENCE.I behind a store. The instruction after the
#         FENCE.I is the one the store rewrites, so it is refetched only if
#         FENCE.I really discards the prefetched copy AND the store is visible
#         to that refetch.
# ---------------------------------------------------------------------------
    lla     x15, b6p
    lla     x5, b6new
    lw      x5, 0(x5)
    li      x12, 0
    sw      x5, 0(x15)
    .word   0x0000100f                  # fence.i (the build has no zifencei)
b6p:
    addi    x12, x0, 11                 # rewritten to addi x12, x0, 77
    li      x6, 77
    CHK     x12, x6, 6

    li      x12, 0
    sw      x11, 20(x10)
    nop
    .word   0x0000100f                  # fence.i, in ID while the store is in MEM
    addi    x12, x12, 1
    lw      x13, 20(x10)
    li      x6, 1
    CHK     x12, x6, 6
    CHK     x13, x11, 6

# ---------------------------------------------------------------------------
# bit 7 : H2 -- CSRRW held in EX by the store in front of it. rd must be the
#         value the CSR had BEFORE this instruction.
# ---------------------------------------------------------------------------
    li      x5, 0x111
    csrw    mscratch, x5
    li      x6, 0x222
    li      x9, 0
    sw      x11, 24(x10)
    csrrw   x9, mscratch, x6
    CHK     x9, x5, 7
    csrr    x9, mscratch
    CHK     x9, x6, 7
    li      x9, 0
    lw      x13, 24(x10)
    csrrs   x9, mscratch, x5            # 0x222 | 0x111
    CHK     x9, x6, 7
    csrr    x9, mscratch
    li      x6, 0x333
    CHK     x9, x6, 7

# ---------------------------------------------------------------------------
# bit 8 : H2 -- a DSU compute op held in EX by a store must accumulate once
# ---------------------------------------------------------------------------
    DSU_R(F5_MACCLEAR, 1, x0, x0, x0)
    nop
    nop
    sw      x11, 28(x10)
    DSU_R(F5_MAC_SEL, 1, x0, x16, x17)
    nop
    nop
    nop
    DSU_R(F5_MACRD_LO, 1, x18, x0, x0)
    li      x5, 15
    CHK     x18, x5, 8

# ---------------------------------------------------------------------------
# bit 9 : H4 x F2 -- an illegal Custom-0 (shift amount 50) on the accumulator
#         the MAC in front of it is still writing: dsu_busy and the illegal
#         instruction trap in the same cycle. The trap wins; the MAC is older
#         and must still land.
# ---------------------------------------------------------------------------
    DSU_R(F5_MACCLEAR, 1, x0, x0, x0)
    nop
    nop
    li      x21, 0
    mv      x8, x20
    li      x18, 0
    DSU_R(F5_MAC_SEL, 1, x0, x16, x17)
b9i:
    DSU_SH(1, 0, 50, x18)
    nop
    nop
    DSU_R(F5_MACRD_LO, 1, x19, x0, x0)
    li      x5, 15
    CHK     x19, x5, 9
    CHK     x18, x0, 9
    lla     x5, b9i
    li      x6, 2
    CHK     x21, x6, 9
    CHK     x23, x5, 9
    addi    x8, x8, 1
    CHK     x20, x8, 9

# ---------------------------------------------------------------------------
# bit 10 : F2 straight behind a MAC
# ---------------------------------------------------------------------------
    DSU_R(F5_MACCLEAR, 0, x0, x0, x0)
    nop
    nop
    DSU_R(F5_MAC_SEL, 0, x0, x16, x17)
    ecall
    nop
    nop
    DSU_R(F5_MACRD_LO, 0, x19, x0, x0)
    li      x5, 15
    CHK     x19, x5, 10

# ---------------------------------------------------------------------------
# bit 11 : H4 x F1 -- JAL in ID while the readback in EX is held by dsu_busy
# ---------------------------------------------------------------------------
    li      x12, 0
    DSU_R(F5_MAC_SEL, 0, x0, x16, x17)
    DSU_R(F5_MACRD_LO, 0, x19, x0, x0)
    j       7f
    li      x12, 1
7:  li      x5, 30
    CHK     x19, x5, 11
    CHK     x12, x0, 11

# ---------------------------------------------------------------------------
# H5 column. Needs something to wake the hart; skipped without a periodic
# interrupt (see the header).
# ---------------------------------------------------------------------------
    li      x5, 2
    bltu    x25, x5, finish

    # bit 12 : WFI; load; dependent
    li      x5, 0
    li      x6, 0
    sw      x11, 32(x10)
    wfi
    lw      x5, 32(x10)
    addi    x6, x5, 1
    CHK     x5, x11, 12
    addi    x8, x11, 1
    CHK     x6, x8, 12

    # bit 13 : WFI; JALR with a link
    lla     x15, 8f
    li      x1, 0
    li      x12, 0
    wfi
    jalr    x1, 0(x15)
b13r:
    li      x12, 1
8:  lla     x5, b13r
    CHK     x1, x5, 13
    CHK     x12, x0, 13

    # bit 14 : WFI; CSRRW
    li      x5, 0x444
    csrw    mscratch, x5
    li      x6, 0x555
    li      x9, 0
    wfi
    csrrw   x9, mscratch, x6
    CHK     x9, x5, 14
    csrr    x9, mscratch
    CHK     x9, x6, 14

    # bit 15 : WFI; MAC
    DSU_R(F5_MACCLEAR, 2, x0, x0, x0)
    nop
    nop
    wfi
    DSU_R(F5_MAC_SEL, 2, x0, x16, x17)
    nop
    nop
    nop
    DSU_R(F5_MACRD_LO, 2, x18, x0, x0)
    li      x5, 15
    CHK     x18, x5, 15

    # bit 16 : WFI; ECALL
    li      x21, 0
    mv      x8, x20
    wfi
b16e:
    ecall
    lla     x5, b16e
    li      x6, 11
    CHK     x21, x6, 16
    CHK     x23, x5, 16
    addi    x8, x8, 1
    CHK     x20, x8, 16

    # bit 17 : WFI; mispredicted branch
    li      x12, 0
    wfi
    beq     x0, x0, 9f
    li      x12, 1
9:  CHK     x12, x0, 17

    # bit 18 : WFI; store; load
    li      x13, 0
    addi    x14, x11, 7
    wfi
    sw      x14, 36(x10)
    lw      x13, 36(x10)
    CHK     x13, x14, 18

finish:
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

    .align 2
b6new:
    addi    x12, x0, 77

# ---------------------------------------------------------------------------
# Trap handler. Interrupts only count; exceptions record cause/epc/tval and
# the mstatus they were entered with, then skip the instruction. Both paths
# store immediately before the MRET, which is what puts F3 behind H2.
# Uses x28/x29 only.
# ---------------------------------------------------------------------------
    .align 6
trap_vector:
    csrr    x28, mcause
    bltz    x28, irq
    addi    x20, x20, 1
    mv      x21, x28
    csrr    x23, mepc
    csrr    x24, mstatus
    csrr    x22, mtval
    addi    x29, x23, 4
    csrw    mepc, x29
    sw      x20, 0(x27)
    mret
irq:
    addi    x25, x25, 1
    sw      x25, 4(x27)
    mret

    .section .data
    .align 4
scratch:
    .fill 16, 4, 0
hscratch:
    .fill 4, 4, 0
