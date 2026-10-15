# =============================================================================
# t_cov_misfetch.S -- jumps and branches to misaligned targets (Track A
# coverage closure, 2026-10-11; T-1, no C extension: IALIGN = 32).
#   1  JAL ra, +6 / +0x7FE (target = 2 mod 4): instruction-address-misaligned,
#      cause 0, mepc = the JAL, mtval = the target, ra NOT written
#   1b J +6 (jal x0) with x6 != 0 (T-18): a JAL's imm[14:12] / rs1 / rs2 bit
#      fields are not operands, but before the fix the branch comparator read
#      them as "BEQ x0, x6" and mtval became pc+4 whenever x6 != 0 (the two
#      JALs above passed only because x6 / x30 happened to be 0)
#   2  BEQ x0, x0, -6 (taken, backward: predicted taken in ID): cause 0,
#      mepc = the branch, mtval = the target
#   3  BNE x0, x0, -6 / -10 (never taken, backward: PREDICTED taken, so ID
#      redirects fetch to the misaligned target first): NO trap, execution
#      continues after the branch -- the wrongly fetched slots are bubbles
# The redirects of 2 and 3 put a misaligned PC on the fetch path (IF / ID /
# EX bubbles; formal cov_const_sva.sv shows only bubbles can carry one).
# A load sits directly in front of every jump: run with D-port waits, the load
# holds MEM while the jump waits in EX (its trap / mispredict redirect waits for
# H2, T-9), and the already-redirected I-port fetches from the misaligned target
# -- the timing formal found (cover c_ihaddr_bit1).
# Fail codes: 3 wrong mcause, 5 wrong mepc, 7 wrong mtval, 9 ra written,
# 11 a not-taken branch trapped, 13 trap count (4 expected).
# =============================================================================
    .section .text.init, "ax"
    .global _start
_start:
    lla     sp, stack_top
    lla     t0, trap_vector
    csrw    mtvec, t0
    li      s7, 0                       # traps taken

    # ---- 1: JAL to a misaligned target ------------------------------------------
    li      ra, 0x0BADC0DE
    lla     s3, 1f
    lla     s2, jal6
    addi    s4, s2, 6                   # expected mtval
    lw      t5, 0(sp)
jal6:
    .word   0x006000ef                  # jal ra, +6
    nop
1:  li      t0, 0x0BADC0DE
    li      a0, 9
    bne     ra, t0, fail                # a trapping JAL must not write ra
    lla     s3, 1f
    lla     s2, jal7fe
    li      t0, 0x7FE
    add     s4, s2, t0
    lw      t5, 0(sp)
jal7fe:
    .word   0x7fe000ef                  # jal ra, +0x7FE
    nop
1:
    # ---- 1b: T-18, the bit fields of the JAL must not choose mtval -------------
    li      t1, 0x5A5A                  # x6 = the "rs2" field of 0x0060006F
    lla     s3, 1f
    lla     s2, j6
    addi    s4, s2, 6
    lw      t5, 0(sp)
j6:
    .word   0x0060006f                  # jal x0, +6
    nop
1:
    # ---- 2: taken backward branch to a misaligned target ------------------------
    lla     s3, 1f
    lla     s2, beq6
    addi    s4, s2, -6
    lw      t5, 0(sp)
beq6:
    .word   0xfe000de3                  # beq x0, x0, -6
    nop
1:
    # ---- 3: not-taken backward branches with misaligned targets -----------------
    li      s3, 0                       # any trap from here on is wrong
    li      s4, 0
    lw      t5, 0(sp)
    .word   0xfe001de3                  # bne x0, x0, -6   (never taken)
    nop
    lw      t5, 0(sp)
    .word   0xfe001be3                  # bne x0, x0, -10  (never taken)
    nop
    lw      t5, 0(sp)
    .word   0xfe001de3
    lw      t5, 0(sp)
    .word   0xfe001be3

    li      t0, 4
    li      a0, 13
    bne     s7, t0, fail
    li      a0, 1
    j       done

    .align 6
trap_vector:
    li      a0, 11
    beqz    s3, fail                    # no trap was expected here
    csrr    t0, mcause
    li      a0, 3
    bnez    t0, fail                    # cause 0: instruction address misaligned
    csrr    t1, mepc
    li      a0, 5
    bne     t1, s2, fail
    csrr    t2, mtval
    li      a0, 7
    bne     t2, s4, fail
    csrw    mepc, s3
    addi    s7, s7, 1
    mret

fail:
done:
    lla     t0, tohost
    li      t1, 1
    beq     a0, t1, 2f
    slli    a0, a0, 1
    ori     a0, a0, 1
2:  sw      a0, 0(t0)
1:  j       1b

    .section .data
    .align 4
stack:  .space 256
stack_top:
