# =============================================================================
# t_cov_vplan.S -- stimulus for the core vPlan coverage items no other program
# reaches (Track A wrap-up 2026-10-12; tb/cov/garuda_cov_vplan.sv):
#   A  F01 cg_isa: every operand-corner pair (0, 1, -1, INT_MIN, INT_MAX, other)
#      through add / slt / sltu / xor and blt / bgeu, results self-checked for add
#   B  F30 cg_pipe_pair: memory, branch, MUL, CSR and DSU instructions next to MUL
#   C  F25 cg_hazard_lu: a load used as both ALU operands, and by a JALR
#   D  F08 cg_csr_op: every op on a machine counter, the DSU flag, an ID register,
#      a user counter and a read-zero counter (illegal ones trap and are skipped)
#   E  F14 / F16 cg_trap_x: an older exception over an illegal word; at the last word of tb_boot memory (0x1003_FFFC), so the
#      next sequential fetch faults: a misaligned load trapping in EX over the
#      faulted fetch in ID, and a JALR squashing the faulted fetch
# Fail codes: 3 wrong add result, 5 unexpected trap cause, 7 trap count, 9 load-use.
# =============================================================================
#define DSU_R(f5, acc, rd, rs1, rs2) .insn r 0x0b, 0, ((f5) << 2) | (acc), rd, rs1, rs2
#define MEM_END 0x10040000

    .section .text.init, "ax"
    .global _start
_start:
    lla     sp, stack_top
    lla     t0, trap_vector
    csrw    mtvec, t0
    li      s7, 0                       # traps taken (illegal CSR + E)
    li      s4, 2                       # expected cause while in D

    # ---- A: operand corners ----------------------------------------------------
    lla     s0, corners
    li      s1, 0
1:  slli    t0, s1, 2
    add     t0, t0, s0
    lw      a2, 0(t0)
    li      s2, 0
2:  slli    t0, s2, 2
    add     t0, t0, s0
    lw      a3, 0(t0)
    add     a4, a2, a3
    slt     a5, a2, a3
    sltu    a5, a2, a3
    xor     a5, a2, a3
    blt     a2, a3, 3f
3:  bgeu    a2, a3, 4f
4:  sub     a6, a4, a3                  # (a + b) - b = a
    li      a0, 3
    bne     a6, a2, fail
    addi    s2, s2, 1
    li      t0, 6
    blt     s2, t0, 2b
    addi    s1, s1, 1
    blt     s1, t0, 1b

    # ---- B: class pairs around MUL -----------------------------------------------
    li      t2, 7
    li      t3, 9
    lw      t4, 0(sp)
    mul     t5, t2, t3                  # mem -> mul
    beq     t2, t3, 5f                  # not taken: ctrl -> mul
    mul     t5, t2, t3
    beq     t2, t3, 5f                  # mul -> ctrl
5:  mul     t5, t2, t3
    DSU_R(0, 0, x0, t2, t3)             # mul -> dsu
    mul     t5, t2, t3                  # dsu -> mul
    csrr    t6, mscratch
    mul     t5, t2, t3                  # sys -> mul

    # ---- C: load-use consumers -----------------------------------------------------
    li      t0, 21
    sw      t0, 0(sp)
    lw      t1, 0(sp)
    add     t2, t1, t1                  # both ALU operands from the load
    li      a0, 9
    li      t3, 42
    bne     t2, t3, fail
    lla     t0, 6f
    sw      t0, 4(sp)
    lw      t1, 4(sp)
    jalr    zero, 0(t1)                 # the JALR target from the load
6:

    # ---- D: CSR ops on every group (illegal ones trap: cause 2, skipped) -----------------
    li      s4, 2
    .irp csr, 0xb00, 0xbc0, 0xf11, 0xc00, 0xb03
    csrr    t0, \csr
    csrrw   t1, \csr, t0
    csrrs   t1, \csr, zero
    csrrc   t1, \csr, zero
    csrrwi  t1, \csr, 0
    csrrsi  t1, \csr, 0
    csrrci  t1, \csr, 0
    .endr

    # ---- E0: a misaligned load in EX over an illegal word in ID -----------------------
    li      s4, 4
    lla     s3, 12f
    lw      a1, 1(zero)
    .word   0x00000000                  # illegal, never executed: squashed by the trap
12:
    # ---- E: trap cases at the end of memory ---------------------------------------------
    # Each case is two instructions at the last two words (0x1003_FFF8 / _FFFC); the
    # first is a load whose result the second needs, so the second waits in ID (load-use)
    # while the sequential fetch of 0x1004_0000 faults and reaches the front end.
    li      s8, MEM_END - 8
    li      t0, 1
    sw      t0, 8(sp)                   # E1: base address 1 for the misaligned load
    lla     t0, tmpl_e1
    lw      t1, 0(t0)
    sw      t1, 0(s8)
    lw      t1, 4(t0)
    sw      t1, 4(s8)
    fence.i
    li      s4, 4
    lla     s3, 7f
    jalr    zero, 0(s8)
7:  lla     t0, 8f                      # E2: the JALR's target, read by the load
    sw      t0, 12(sp)
    lla     t0, tmpl_e2
    lw      t1, 0(t0)
    sw      t1, 0(s8)
    lw      t1, 4(t0)
    sw      t1, 4(s8)
    fence.i
    li      s4, 99                      # no trap expected
    jalr    zero, 0(s8)
8:
    li      a0, 7
    beqz    s7, fail
    li      a0, 1
    j       done

tmpl_e1:
    lw      a2, 8(sp)                   # a2 = 1
    lw      a1, 0(a2)                   # misaligned load (cause 4) in EX, the faulted fetch in ID
tmpl_e2:
    lw      t1, 12(sp)
    jalr    zero, 0(t1)                 # the JALR redirect squashes the faulted fetch in ID

    .align 6
trap_vector:
    csrr    t0, mcause
    li      a0, 5
    bne     t0, s4, fail
    addi    s7, s7, 1
    li      t1, 4
    beq     t0, t1, 9f
    csrr    t1, mepc                    # illegal CSR access: skip it
    addi    t1, t1, 4
    csrw    mepc, t1
    mret
9:  csrw    mepc, s3                    # the misaligned load: resume after E1
    mret

fail:
    slli    a0, a0, 1
    ori     a0, a0, 1
    j       10f
done:
10: lla     t0, tohost
    sw      a0, 0(t0)
11: j       11b

    .section .data
    .align 4
corners:
    .word 0x00000000, 0x00000001, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0x12345678
    .align 4
stack:  .space 64
stack_top:
    .space 64
