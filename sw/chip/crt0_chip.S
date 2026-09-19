# =============================================================================
# crt0 for chip-level test programs (ISRAM-resident, entered from the Boot ROM)
#   stack, .data copy ISRAM -> DSRAM, .bss clear, mtvec, main(), tohost.
# Traps: registers saved on the stack, C trap_handler(mcause, mepc) returns the
# mepc to resume at (interrupts: unchanged; exceptions: the test decides).
# lla, never la (PIC toolchain - see sw/common/crt0.S).
# =============================================================================
    .section .text.init, "ax"
    .global _start
_start:
    lla     sp, _stack_top
    lla     t0, trap_entry
    csrw    mtvec, t0
    lla     t0, _data_lma
    lla     t1, _data_start
    lla     t2, _data_end
1:  bgeu    t1, t2, 2f
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    j       1b
2:  lla     t0, _bss_start
    lla     t1, _bss_end
3:  bgeu    t0, t1, 4f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       3b
4:  call    main
    beqz    a0, 5f
    slli    a0, a0, 1
    ori     a0, a0, 1
    j       6f
5:  li      a0, 1
6:  lla     t0, tohost
    sw      a0, 0(t0)
7:  j       7b

    .align 2
trap_entry:
    addi    sp, sp, -64
    sw      ra, 0(sp);  sw t0, 4(sp);  sw t1, 8(sp);  sw t2, 12(sp)
    sw      a0, 16(sp); sw a1, 20(sp); sw a2, 24(sp); sw a3, 28(sp)
    sw      a4, 32(sp); sw a5, 36(sp); sw a6, 40(sp); sw a7, 44(sp)
    sw      t3, 48(sp); sw t4, 52(sp); sw t5, 56(sp); sw t6, 60(sp)
    csrr    a0, mcause
    csrr    a1, mepc
    call    trap_handler
    csrw    mepc, a0
    lw      ra, 0(sp);  lw t0, 4(sp);  lw t1, 8(sp);  lw t2, 12(sp)
    lw      a0, 16(sp); lw a1, 20(sp); lw a2, 24(sp); lw a3, 28(sp)
    lw      a4, 32(sp); lw a5, 36(sp); lw a6, 40(sp); lw a7, 44(sp)
    lw      t3, 48(sp); lw t4, 52(sp); lw t5, 56(sp); lw t6, 60(sp)
    addi    sp, sp, 64
    mret
