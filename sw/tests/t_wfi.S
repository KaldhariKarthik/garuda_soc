# =============================================================================
# t_wfi.S -- Core Sanity TB row 20: WFI sleeps, an interrupt wakes it.
#
# pipe_ctrl documents WFI as a DRAIN-PRECISE hold: the WFI parks in EX while
# everything older drains through MEM/WB, and the instruction behind it stays
# in ID rather than executing during the sleep. Both halves are checked:
#   - nothing past the WFI executes before the wake
#   - after the wake the following instruction executes exactly once
#
# Run with: +IRQ_AT=<cycle late enough to reach the WFI>
# With no interrupt armed this test deliberately TIMES OUT, which is the
# correct behaviour for a core that is genuinely asleep - so a timeout is only
# meaningful here if an interrupt was actually asserted.
# =============================================================================
    .section .text.init, "ax"
    .global _start
_start:
    lla     t0, trap_vector
    csrw    mtvec, t0
    li      x3, 0
    li      x20, 0                      # wake count
    li      x22, 0                      # set only after the WFI retires

    li      t0, 8
    csrs    mstatus, t0
    li      t0, -1
    csrs    mie, t0

    li      x3, 1
    wfi
    addi    x22, x22, 1                 # must execute exactly once, after wake

    li      x3, 2
    li      x6, 1
    bne     x22, x6, fail
    li      x3, 3
    beqz    x20, fail                   # a wake must actually have happened

    li      a0, 1
    j       done
fail:
    slli    a0, x3, 1
    ori     a0, a0, 1
done:
    lla     t0, tohost
    sw      a0, 0(t0)
1:  j 1b

    .align 6
trap_vector:
    addi    x20, x20, 1
    csrr    t1, mcause
    bltz    t1, 2f
    csrr    t1, mepc                    # exception: skip it
    addi    t1, t1, 4
    csrw    mepc, t1
2:  mret
