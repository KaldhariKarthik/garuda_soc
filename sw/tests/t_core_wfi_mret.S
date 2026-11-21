# t_core_wfi_mret.S -- an MRET directly behind a WFI (pipe_ctrl H5 vs trap redirect, cover
# c_h5_vs_trap; 2026-11-21, D-40 coverage closure). JasperGold's witness of the cover (fv_trap)
# is exactly this: WFI, then MRET, with the instruction port stalled.
# MIE = 0 and MTIE = 1, so the machine timer (+MTIP_AT) wakes the WFI without trapping there.
# mepc = `after`, MPIE = 1: the MRET jumps to `after` and sets MIE, and the pending timer
# interrupt is taken before `after` executes. Whatever the pipeline does with the MRET during
# the sleep, the architectural result must be: one MTI trap, mepc = after, then resume.
# tohost: 1 = pass; 3 no interrupt, 5 wrong mcause, 7 wrong mepc, 9 taken twice.
    .section .text.init, "ax"
    .global _start
_start:
    lla     t0, trap_vector
    csrw    mtvec, t0
    li      x20, 0                      # timer interrupts taken
    li      x22, 0                      # mepc seen by the handler
    csrci   mstatus, 8                  # MIE = 0
    li      t0, 0x80
    csrs    mstatus, t0                 # MPIE = 1 (MPP is M: machine-only core)
    csrs    mie, t0                     # MTIE
    lla     t0, after
    csrw    mepc, t0
    .align 4
    wfi
    mret
    li      a0, 11                      # (never) fell through the MRET
    j       fail
after:
    li      a0, 3
    beqz    x20, fail
    li      a0, 9
    li      t1, 1
    bne     x20, t1, fail
    li      a0, 7
    lla     t1, after
    bne     x22, t1, fail
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
    csrr    x22, mepc
    li      t1, 0x1000F100
    sw      zero, 0(t1)                 # clear the timer source
    li      t0, 0x80
    csrc    mie, t0
    mret
