# =============================================================================
# t_cov_csr_ro.S -- writes to the read-only CSRs that t_cov_csr does not write
# (1-TOPS G5 5.8; contract Design_Docs/regs/core_csr.yaml, csr_file.v is_ro).
#   1  mip, mnxti, mintstatus (0x346) and mintstatus at its CLIC address (0xFB1)
#      are each written with CSRRW and with CSRRC from a non-zero register:
#      every one of the 8 is refused with an illegal-instruction trap (cause 2,
#      mtval = the instruction word, mepc = the instruction), and the CSR still
#      reads its old value afterwards
#   2  the same four CSRs read with CSRRC from x0 (a read, no write): no trap
#   3  misa (WARL, writes ignored) with CSRRC from x0 and from a non-zero
#      register: no trap, misa unchanged
# Covers cg_csr x_csr_op {mip, mnxti, mintstatus, mintstatus_std} x {rw, rc},
# misa x rc, and x_csr_illegal for the four (tb/cov/garuda_core_cov_ext.sv).
# Not in the Spike co-simulation: Spike accepts a write to mip with no effect
# (its machine-only mip has no writable bit) where GARUDA refuses it, and Spike
# has no mnxti or mintstatus.
# Fail codes: 3 a CSR changed, 11 wrong trap (cause, mtval or mepc), 13 trap count.
# =============================================================================
.macro refuse2 csr
    csrr    s2, \csr                    # value before
    csrrw   zero, \csr, s1              # write: refused
    csrrc   zero, \csr, s1              # clear with a non-zero mask: refused
    csrr    t1, \csr
    li      a0, 3
    bne     t1, s2, fail
.endm

    .section .text.init, "ax"
    .global _start
_start:
    lla     sp, stack_top
    lla     s0, trap_vector
    csrw    mtvec, s0
    li      s7, 0                       # traps taken
    li      s1, -1                      # a non-zero source for every write

    # ---- 1: eight refused writes ------------------------------------------------
    refuse2 mip
    refuse2 0x345                       # mnxti
    refuse2 0x346                       # mintstatus
    refuse2 0xFB1                       # mintstatus, CLIC standard address
    li      t0, 8
    li      a0, 13
    bne     s7, t0, fail

    # ---- 2: CSRRC from x0 is a read: no trap --------------------------------------
    csrrc   t1, mip, zero
    csrrc   t1, 0x345, zero
    csrrc   t1, 0x346, zero
    csrrc   t1, 0xFB1, zero

    # ---- 3: misa, WARL with writes ignored -------------------------------------
    csrr    s2, misa
    csrrc   t1, misa, zero
    csrrc   t1, misa, s1
    csrr    t1, misa
    li      a0, 3
    bne     t1, s2, fail
    li      t0, 8
    li      a0, 13
    bne     s7, t0, fail                # no trap in parts 2 and 3
    li      a0, 1
    j       done

    .align 6
trap_vector:
    csrr    t0, mcause
    li      t1, 2
    li      a0, 11
    bne     t0, t1, fail                # only illegal-instruction traps here
    csrr    t1, mepc
    lw      t2, 0(t1)
    csrr    t3, mtval
    bne     t2, t3, fail                # mtval = the instruction word
    andi    t3, t2, 0x7F
    li      t4, 0x73
    bne     t3, t4, fail                # mepc points at a SYSTEM instruction
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
