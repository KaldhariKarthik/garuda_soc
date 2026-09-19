# =============================================================================
# t_mtip.S -- ERRATUM T-8 regression: WFI woken by the machine timer alone.
#
# MIE = 0, mie.MTIE = 1. WFI sleeps (the core clock gates), mtip wakes it
# (+MTIP_AT=<cyc>), execution resumes after the WFI without a trap. Software
# then clears the timer source (store to 0x1000_F100, the tb_boot stand-in for
# advancing mtimecmp) and keeps running.
#
# Before the fix, trap_ctrl's wfi_active latch was cleared only by a CLIC wake,
# so clearing mtip here re-asserted the WFI hold and the core slept until a
# CLIC interrupt that never comes: this test timed out.
#
# Run with: +MTIP_AT=300
# tohost: 1 = pass, (n<<1)|1 = step n failed.
# =============================================================================
    .section .text.init, "ax"
    .global _start
_start:
    lla     t0, trap_vector
    csrw    mtvec, t0
    li      x3, 1
    li      t0, 0x80
    csrs    mie, t0                     # MTIE
    csrci   mstatus, 8                  # MIE = 0: wake without a trap

    wfi                                 # sleeps until mtip

    li      x3, 2
    li      t1, 0x1000F100
    sw      zero, 0(t1)                 # clear the timer source

    li      x3, 3                       # with T-8 the core freezes in here
    li      t2, 64
1:  addi    t2, t2, -1
    bnez    t2, 1b

    li      a0, 1
    j       done
fail:
    slli    a0, x3, 1
    ori     a0, a0, 1
done:
    lla     t0, tohost
    sw      a0, 0(t0)
9:  j 9b

    .align 6
trap_vector:                            # no trap is expected (MIE = 0)
    j       fail
