# =============================================================================
# t_cov_illegal.S -- illegal encodings by opcode class (Track A coverage
# closure, 2026-10-11). Each word below is not an instruction GARUDA
# implements (RV32I + MUL family + Zicsr + Zifencei + DSU custom-0; DN-ISA)
# and must raise illegal instruction: mcause 2, mtval = the word, no state
# change. Covers the decoder's reject paths per opcode (cg_decode opcode x
# funct3 for the encodings that exist only as illegal ones).
# DIV/REM are left out on purpose: they are illegal on GARUDA but legal for
# Spike, and the riscv-tests p-div/p-rem programs already exercise them.
# Fail codes: 3 wrong mcause, 5 wrong mtval, 7 an illegal word executed
# (no trap), 11 interrupt.
# =============================================================================
    .section .text.init, "ax"
    .global _start
_start:
    lla     sp, stack_top
    lla     t0, trap_vector
    csrw    mtvec, t0
    li      s7, 0                       # traps taken

illegal_start:
    .word 0x00003023, 0x00004023, 0x00005023, 0x00006023, 0x00007023  # STORE funct3 3..7
    .word 0x00003003, 0x00006003, 0x00007003                          # LOAD funct3 3, 6, 7
    .word 0x00002063, 0x00003063                                      # BRANCH funct3 2, 3
    .word 0x00001067, 0x00002067, 0x00003067, 0x00004067              # JALR funct3 1..7
    .word 0x00005067, 0x00006067, 0x00007067
    .word 0x0000200B, 0x0000300B, 0x0000400B, 0x0000500B              # CUSTOM-0 funct3 2..7
    .word 0x0000600B, 0x0000700B
    .word 0xF800000B                                                  # CUSTOM-0 unknown funct5
    .word 0x0600000B                                                  # CUSTOM-0 acc_sel 3
    .word 0x00004073                                                  # SYSTEM funct3 4
    .word 0x10200073                                                  # SRET (no S-mode)
    .word 0x80000033, 0x40001033, 0x40002033                          # OP bad funct7 (C-13)
    .word 0x02001013, 0x40001013, 0x08005013                          # OP-IMM shift bad funct7 (C-1)
    .word 0x00000000, 0xFFFFFFFF                                      # all zeros, all ones
    .word 0x0000007F, 0x00000057, 0x00000007, 0x0000002F, 0x00000053  # reserved / F / A / V opcodes
    .word 0x00000027, 0x0000001B, 0x0000003B, 0x0000005B, 0x0000006B  # more unimplemented majors
    .word 0x00000001, 0x00000002                                      # 16-bit (no C extension)
illegal_end:
    lla     t0, illegal_start           # words in the table
    lla     t1, illegal_end
    sub     t0, t1, t0
    srli    t0, t0, 2
    li      a0, 7
    bne     s7, t0, fail                # every word trapped
    li      a0, 1
    j       done

    .align 6
trap_vector:
    csrr    t0, mcause
    li      a0, 11
    bltz    t0, fail
    li      t1, 2
    li      a0, 3
    bne     t0, t1, fail
    csrr    t1, mepc
    lw      t2, 0(t1)
    csrr    t3, mtval
    li      a0, 5
    bne     t2, t3, fail                # mtval = the illegal word
    addi    t1, t1, 4
    csrw    mepc, t1
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
stack:  .space 256
stack_top:
