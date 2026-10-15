# =============================================================================
# t_cov_fault.S -- access faults at patterned addresses (Track A coverage
# closure, 2026-10-11). Every address below lies outside tb_boot's memory
# (0x1000_0000 + 256 KB), so the model answers with the two-cycle AHB ERROR.
# For each address:
#   1  fetch (jalr there)          -> instruction access fault, cause 1,
#                                     mepc = mtval = the address
#   2  lw / sw                      -> load / store access fault, cause 5 / 7,
#                                     mtval = the address, rd not written
#   3  lb / lbu at +1, lh / lhu / sh at +2, sb at +3
#                                   -> the same with byte and halfword sizes
# The address patterns toggle every upper address bit both ways, and the fetch
# faults are the first test of the I-port ERROR path (cause 1 was never taken
# by any suite before; cg_trap.instr_fault, i_hresp_i).
# Fail codes: 3 wrong mcause, 5 wrong mtval, 7 wrong mepc on a fetch fault,
# 9 a faulting load wrote rd, 11 interrupt or unexpected trap, 13 trap count.
# =============================================================================
#define NPAT 12
    .section .text.init, "ax"
    .global _start
_start:
    lla     sp, stack_top
    lla     t0, trap_vector
    csrw    mtvec, t0
    lla     s5, pats                    # s5 = next pattern
    li      s6, NPAT                    # s6 = patterns left
    li      s7, 0                       # s7 = traps taken

next:
    lw      s2, 0(s5)                   # s2 = expected mtval (the address)

    li      s4, 1                       # 1: fetch fault
    lla     s3, 1f                      # s3 = where the handler resumes
    jalr    zero, 0(s2)
1:
    li      s4, 5                       # 2: word load / store faults
    li      a1, 0x600DF00D
    lw      a1, 0(s2)
    li      a2, 0x600DF00D
    li      a0, 9
    bne     a1, a2, fail                # a faulting load must not write rd
    li      s4, 7
    sw      a2, 0(s2)

    addi    s2, s2, 1                   # 3: byte / halfword sizes
    li      s4, 5
    lb      a1, 0(s2)
    lbu     a1, 0(s2)
    li      s4, 7
    addi    s2, s2, 2                   # +3
    sb      a2, 0(s2)
    addi    s2, s2, -1                  # +2
    li      s4, 5
    lh      a1, 0(s2)
    lhu     a1, 0(s2)
    li      s4, 7
    sh      a2, 0(s2)

    addi    s5, s5, 4
    addi    s6, s6, -1
    bnez    s6, next

    li      t0, NPAT * 9                # 9 traps per pattern
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
    bne     t2, s2, fail                # mtval = the faulting address / fetch PC
    li      t3, 1
    beq     t0, t3, fetch_fault
    addi    t1, t1, 4                   # load / store: skip the instruction
    csrw    mepc, t1
    addi    s7, s7, 1
    mret
fetch_fault:
    li      a0, 7
    bne     t1, s2, fail                # mepc = the target that faulted
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
pats:
    .word 0xFFFFFFFC, 0x00000000, 0xAAAAAAA8, 0x55555554
    .word 0x80000000, 0x7FFFFFFC, 0xF0F0F0F0, 0x0F0F0F0C
    .word 0xCCCCCCCC, 0x33333330, 0xEFFFFFFC, 0x10040000
    .align 4
stack:  .space 256
stack_top:
