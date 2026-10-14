# =============================================================================
# t_cov_wfi_mti.S -- WFI woken by the machine timer with MIE = 1: the wake takes
# the interrupt (core vPlan F31 cg_wfi x_wake_mie, the case t_mtip (MIE = 0) does
# not reach; Track A wrap-up 2026-10-12). The handler clears the tb_boot timer
# stand-in (store to 0x1000_F100) and returns to the instruction after the WFI.
# Run with: +MTIP_AT=<cycle after the WFI is reached>
# tohost: 1 = pass; 3 no interrupt taken, 5 cause not MTI, 7 resumed twice.
# =============================================================================
    .section .text.init, "ax"
    .global _start
_start:
    lla     t0, trap_vector
    csrw    mtvec, t0
    li      x20, 0                      # timer interrupts taken
    li      x21, 0
    li      t0, 0x80
    csrs    mie, t0                     # MTIE
    li      t0, 8
    csrs    mstatus, t0                 # MIE = 1
    wfi
    addi    x21, x21, 1
    li      a0, 3
    beqz    x20, fail
    li      a0, 7
    li      t1, 1
    bne     x21, t1, fail
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
    csrr    t1, mcause
    li      t2, 0x80000007
    li      a0, 5
    bne     t1, t2, fail
    addi    x20, x20, 1
    li      t1, 0x1000F100
    sw      zero, 0(t1)                 # clear the timer source
    li      t0, 0x80
    csrc    mie, t0
    mret
