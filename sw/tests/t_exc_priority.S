# =============================================================================
# t_exc_priority.S -- one instruction, two causes: the privileged specification's
# order (core vPlan F15, Track A wrap-up 2026-10-12). Every pair that can coincide
# on GARUDA (no MMU, no C extension, no debug triggers in tb_boot):
#   A  lw / lh / lhu at an address both misaligned and outside memory
#      -> load address misaligned (4) beats load access fault (5); no bus access
#   B  sw / sh at an address both misaligned and outside memory
#      -> store address misaligned (6) beats store access fault (7)
#   C  jalr to a target both misaligned (bit 1) and outside memory
#      -> instruction address misaligned (0) beats instruction access fault (1);
#         mepc = the jalr, mtval = the target, nothing fetched there
#   D  jalr to an aligned target outside memory, whose returned word decodes as an
#      illegal instruction (the model answers ERROR with rdata 0)
#      -> instruction access fault (1) beats illegal instruction (2)
# Each case runs at three unmapped addresses. tb_boot's memory is 0x1000_0000 +
# 256 KB; everything else answers the two-cycle AHB ERROR.
# Fail codes: 3 wrong mcause, 5 wrong mtval, 7 wrong mepc, 9 a faulting load
# wrote rd, 11 interrupt, 13 trap count.
# =============================================================================
#define NPAT 3
    .section .text.init, "ax"
    .global _start
_start:
    lla     sp, stack_top
    lla     t0, trap_vector
    csrw    mtvec, t0
    lla     s5, pats
    li      s6, NPAT
    li      s7, 0                       # traps taken

next:
    lw      s8, 0(s5)                   # s8 = an unmapped, word-aligned address

    # A: load misaligned + access fault -> 4
    li      s4, 4
    addi    s2, s8, 1
    li      a1, 0x600DF00D
    lw      a1, 0(s2)
    lh      a1, 0(s2)
    lhu     a1, 0(s2)
    li      a2, 0x600DF00D
    li      a0, 9
    bne     a1, a2, fail
    addi    s2, s8, 2                   # lw at +2: misaligned for a word
    lw      a1, 0(s2)

    # B: store misaligned + access fault -> 6
    li      s4, 6
    addi    s2, s8, 3
    sw      a2, 0(s2)
    sh      a2, 0(s2)
    addi    s2, s8, 2
    sw      a2, 0(s2)

    # C: fetch misaligned + access fault -> 0 (mepc = the jalr, mtval = target)
    li      s4, 0
    addi    s2, s8, 2
    lla     s3, 1f
    lla     s9, 2f
2:  jalr    zero, 0(s2)
1:
    # D: fetch access fault, garbage word -> 1 (mepc = mtval = target)
    li      s4, 1
    mv      s2, s8
    lla     s3, 3f
    jalr    zero, 0(s2)
3:
    addi    s5, s5, 4
    addi    s6, s6, -1
    bnez    s6, next

    li      t0, NPAT * 9                # 4 loads + 3 stores + 2 fetches per address
    li      a0, 13
    bne     s7, t0, fail
    li      a0, 1
    j       done

    .align 6
trap_vector:
    csrr    t0, mcause
    li      a0, 11
    bltz    t0, fail                    # no interrupts in this test
    li      a0, 3
    bne     t0, s4, fail
    csrr    t1, mepc
    csrr    t2, mtval
    li      a0, 5
    bne     t2, s2, fail                # mtval = the address / the target
    addi    s7, s7, 1
    beqz    t0, misfetch
    li      t3, 1
    beq     t0, t3, fetch_fault
    addi    t1, t1, 4                   # load / store: skip it
    csrw    mepc, t1
    mret
misfetch:
    li      a0, 7
    bne     t1, s9, fail                # mepc = the jalr itself
    csrw    mepc, s3
    mret
fetch_fault:
    li      a0, 7
    bne     t1, s2, fail                # mepc = the target that faulted
    csrw    mepc, s3
    mret

fail:
done:
    lla     t0, tohost
    li      t1, 1
    beq     a0, t1, 4f
    slli    a0, a0, 1
    ori     a0, a0, 1
4:  sw      a0, 0(t0)
5:  j       5b

    .section .data
    .align 4
pats:
    .word 0x00000000, 0xAAAAAAA8, 0x7FFFFFFC
    .align 4
stack:  .space 256
stack_top:
