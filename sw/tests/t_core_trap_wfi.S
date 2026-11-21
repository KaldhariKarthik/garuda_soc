# t_core_trap_wfi.S -- a synchronous trap directly in front of a WFI (2026-11-21).
# ECALL, EBREAK and an illegal instruction, each followed by a WFI. The WFI is younger than
# the trapping instruction and must be squashed; no interrupt is ever enabled, so a core that
# lets the WFI sleep TIMES OUT. The handler checks mcause and mepc and resumes past the WFI.
# The companion of t_core_wfi_buserr (a load fault in front of a WFI). It does not reach the
# cover c_h5_vs_trap (the trap redirects before the WFI holds); t_core_wfi_mret does.
    .section .text.init, "ax"
    .global _start
_start:
    lla     t0, trap_vector
    csrw    mtvec, t0
    csrw    mie, zero
    csrci   mstatus, 8                  # MIE = 0: nothing can wake a WFI
    li      s0, 0                       # traps taken
at_ecall: ecall
    wfi                                 # squashed; a WFI that sleeps never wakes (timeout)
at_ebreak: ebreak
    wfi
at_illegal: .word   0x00000000                  # illegal instruction
    wfi
at_end: li      a0, 11                      # FAIL 11: wrong number of traps
    li      t1, 3
    bne     s0, t1, done
    li      a0, 1                       # PASS
    j       done

    .align 6
trap_vector:
    csrr    t2, mepc
    csrr    t3, mcause
    li      a0, 7                       # FAIL 7: unexpected trap
    lla     t4, at_ecall
    li      t5, 11                      # ECALL from M-mode
    beq     t2, t4, check
    lla     t4, at_ebreak
    li      t5, 3                       # breakpoint
    beq     t2, t4, check
    lla     t4, at_illegal
    li      t5, 2                       # illegal instruction
    beq     t2, t4, check
    j       done
check:
    li      a0, 9                       # FAIL 9: wrong mcause
    bne     t3, t5, done
    addi    s0, s0, 1
    addi    t2, t2, 8                   # past the WFI
    csrw    mepc, t2
    mret
done:
    lla     t0, tohost
    sw      a0, 0(t0)
1:  j 1b
