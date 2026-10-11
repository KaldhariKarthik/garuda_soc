# =============================================================================
# t_lead2_wfi_buserr.S -- ERRATUM T-14: a load bus error directly ahead of a
# WFI must not leave the core asleep in the fault handler.
#
# While the faulting load waits on the D-port, the WFI behind it sits in EX.
# Before the fix it armed the sleep latch there; when the load then ended in
# ERROR the trap squashed the WFI but nothing cleared the latch, so the
# handler was fetched and held until an interrupt became pending. Interrupts
# are off in this test, so the old core never reaches tohost and the bench
# times out. The fixed core takes the fault, runs the handler and resumes.
#
# Run with:  +ERR_EN=1 +ERR_BASE=10020000 +ERR_SIZE=1000
# (try +DWAIT=n as well - the defect was seen with and without wait states)
# =============================================================================

#define ERR_ADDR 0x10020000

    .section .text.init, "ax"
    .global _start
_start:
    lla     t0, trap_vector
    csrw    mtvec, t0
    csrw    mie, zero                   # no interrupt source can wake a WFI
    csrci   mstatus, 8                  # MIE = 0
    li      x3, 0                       # TESTNUM
    li      x20, 0                      # traps taken
    li      x21, 0                      # last mcause
    li      x23, 0                      # last mepc

    # ---- test 1: lw to the error window, then wfi ----
    li      x3, 1
    lla     x22, after_fault            # where the handler resumes on a fault
    li      x10, ERR_ADDR
    li      x11, 0xdeadbeef
fault_insn:
    lw      x11, 0(x10)                 # -> load access fault
    wfi                                 # squashed by the trap: must not sleep
    j       fail                        # not reached either way

after_fault:
    # ---- test 2: exactly one trap, cause 5, at the load ----
    li      x3, 2
    li      x6, 1
    bne     x20, x6, fail
    li      x3, 3
    li      x6, 5
    bne     x21, x6, fail
    li      x3, 4
    lla     x6, fault_insn
    bne     x23, x6, fail

    li      a0, 1
    j       done
fail:
    slli    a0, x3, 1
    ori     a0, a0, 1
done:
    lla     t0, tohost
    sw      a0, 0(t0)
1:  j 1b

    # ---- trap handler: record cause and mepc, resume at x22 ----
    .align 6
trap_vector:
    csrr    x21, mcause
    csrr    x23, mepc
    addi    x20, x20, 1
    csrw    mepc, x22
    mret
