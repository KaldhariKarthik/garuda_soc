# =============================================================================
# t_lead1_mret_buserr.S -- ERRATUM T-13: a load bus error directly ahead of
# an MRET must trap.
#
# A trap-handler epilogue restores registers with loads and ends in mret, so a
# load that faults immediately before an mret is the ordinary shape of the
# code. The fault is older than the MRET and must win: mcause 5, mepc at the
# load, and the MRET does not run. Before the fix trap_ctrl blocked every
# trap while an MRET sat in EX, the fault was dropped and the MRET jumped to
# whatever mepc held - here, mret_target, which fails the test.
#
# Run with:  +ERR_EN=1 +ERR_BASE=10020000 +ERR_SIZE=1000
# (the same window t_buserr uses; try +DWAIT=n as well - the defect was seen
# with and without D-port wait states)
# =============================================================================

#define ERR_ADDR 0x10020000

    .section .text.init, "ax"
    .global _start
_start:
    lla     t0, trap_vector
    csrw    mtvec, t0
    li      x3, 0                       # TESTNUM
    li      x20, 0                      # traps taken
    li      x21, 0                      # last mcause
    li      x23, 0                      # last mepc

    # ---- test 1: lw to the error window, then mret ----
    li      x3, 1
    lla     t0, mret_target             # where a (wrongly) executed mret goes
    csrw    mepc, t0
    lla     x22, after_fault            # where the handler resumes on a fault
    li      x10, ERR_ADDR
    li      x11, 0xdeadbeef             # must NOT be overwritten
fault_insn:
    lw      x11, 0(x10)                 # -> load access fault
    mret                                # younger than the fault: must not run
mret_target:
    j       fail                        # T-13: fault dropped, MRET executed

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
    li      x3, 5
    li      x6, 0xdeadbeef
    bne     x11, x6, fail               # a faulting load must not write rd

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
