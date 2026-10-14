# =============================================================================
# t_cov_rereset.S -- a warm reset in the middle of operation (Track A coverage
# closure, 2026-10-11). Run with tb_boot +RERESET_AT=<cycle>.
#   first boot : the boot flag in memory is 0 -> set it, then dirty the core
#                (CSRs, a DSU accumulator, mgarudactl, loads / stores), and keep
#                working in a loop until the reset arrives
#   second boot: the flag is 1 -> every architectural reset value must be back:
#                mscratch 0, mie 0, mtval 0, mintthresh 0, mgarudactl 0,
#                mstatus.MIE 0, the DSU accumulator 0, dsu_ovf 0
# Memory contents survive (SRAM), which is how the program knows which boot
# it is. Fail codes: 3 a CSR kept its value, 5 the DSU kept state, 7 the loop
# ended without a reset (the bench never reset the core).
# =============================================================================
#define DSU_R(f5, acc, rd, rs1, rs2) .insn r 0x0b, 0, ((f5) << 2) | (acc), rd, rs1, rs2
    .section .text.init, "ax"
    .global _start
_start:
    lla     sp, stack_top
    lla     s0, boot_flag
    lw      t0, 0(s0)
    bnez    t0, second_boot

first_boot:
    li      t0, 1
    sw      t0, 0(s0)
    li      t0, 0x5A5A5A5A
    csrw    mscratch, t0
    csrw    mtval, t0
    li      t0, 0x80
    csrw    mie, t0
    li      t0, 0x77
    csrw    0x347, t0                   # mintthresh
    li      t0, 0xF
    csrw    0x7C0, t0                   # mgarudactl: every knob on
    li      a1, 0x7FFFFFFF
    DSU_R(4, 2, zero, a1, zero)         # MACLOAD MAG
    DSU_R(6, 2, zero, zero, zero)       # MACSAT MAG (in range)
    li      s1, 200000                  # work until the reset arrives
1:  lw      t1, 4(s0)
    addi    t1, t1, 1
    sw      t1, 4(s0)
    addi    s1, s1, -1
    bnez    s1, 1b
    li      a0, 7                       # no reset came
    j       fail

second_boot:
    li      a0, 3
    csrr    t0, mscratch
    bnez    t0, fail
    csrr    t0, mtval
    bnez    t0, fail
    csrr    t0, mie
    bnez    t0, fail
    csrr    t0, 0x347
    bnez    t0, fail
    csrr    t0, 0x7C0
    bnez    t0, fail
    csrr    t0, mstatus
    andi    t0, t0, 8
    bnez    t0, fail
    li      a0, 5
    DSU_R(7, 2, t0, zero, zero)         # MACRD_LO MAG
    bnez    t0, fail
    DSU_R(8, 2, t0, zero, zero)         # MACRD_HI MAG
    bnez    t0, fail
    csrr    t0, 0xBC0                   # dsu_ovf
    bnez    t0, fail
    li      a0, 1
    j       done

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
boot_flag: .word 0, 0
    .align 4
stack:  .space 256
stack_top:
