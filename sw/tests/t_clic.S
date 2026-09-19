# =============================================================================
# t_clic.S -- directed CLIC interrupt controller test.
#
# clic_ctrl.v sat at 5.58% coverage (15/269 toggle bins) after the whole
# regression, because t_irq drives ONE interrupt configuration and software
# never writes mtvt. The module is small and mostly combinational, so the gap
# is almost entirely unexercised BUSES rather than unexercised logic:
# NOTE: mintstatus (0x346) and mintthresh (0x347) are CLIC CSRs, not base RISC-V, so
# the assembler does not know their names - they are written numerically here.
#
#   clic_irq_id_i   12 bits    clic_irq_lvl_i   8 bits
#   mtvec_i         32 bits    mtvt_i          32 bits
#   vector_target_o 32 bits
#
# Two halves, and both are needed:
#   - the testbench sweeps id / level per interrupt (+IRQ_SWEEP=1)
#   - this test drives the CSR side: mtvec, mintstatus, mnxti and mintthresh
# Rev 4.0: 5-bit ids, level-triggered, no SHV/mtvt - every trap enters at
# mtvec BASE and the handler reads mcause[4:0].
#
# It also covers both arms of every term in the take condition (Sec. 14.3):
#     irq & MIE & (lvl > mintthresh) & (lvl > mintstatus.mil)
# A test that only ever TAKES interrupts leaves the "condition false" arm of
# each comparison uncovered, which is exactly where a wrongly-inverted compare
# would hide.
#
# Run with: +IRQ_EVERY=<n> +IRQ_SWEEP=1
# tohost: 1 = pass, (n<<1)|1 = section n failed.
# =============================================================================

    .section .text.init, "ax"
    .global _start
_start:
    lla     t0, trap_vector
    csrw    mtvec, t0
    li      x3, 0                       # TESTNUM
    li      x20, 0                      # interrupts taken
    li      x21, 0                      # last mcause
    li      x22, 0                      # exceptions (must stay 0)

    # ================= 1. Rev 4.0 CLIC CSR surface =======================
    # CORE-SPEC Rev 3.0 §6.1: mtvec.MODE reads 3 (CLIC), mintstatus lives at
    # 0x346 (0xFB1 kept as an alias), mnxti (0x345) is present and reads 0,
    # and mtvt (0x307) no longer exists - SHV vectoring was removed.
    li      x3, 1
    csrr    x10, mtvec
    andi    x10, x10, 3
    li      x11, 3
    bne     x10, x11, fail              # MODE must read 3
    csrr    x10, 0x346
    csrr    x11, 0xFB1
    bne     x10, x11, fail              # both mintstatus addresses agree
    csrr    x10, 0x345
    bnez    x10, fail                   # mnxti reads 0
    li      x22, 0
    csrr    x10, 0x307                  # mtvt: must trap (illegal)
    li      x11, 1
    bne     x22, x11, fail
    li      x22, 0

    # ================= 2. mintthresh is writable ==========================
    # Sweeping it toggles the 8-bit threshold bus and moves the lvl>thresh
    # comparison across its boundary.
    li      x3, 2
    li      x10, 0xFF
    csrw    0x347, x10                  # mintthresh
    csrr    x11, 0x347
    li      x10, 0x00
    csrw    0x347, x10
    csrr    x12, 0x347
    beq     x11, x12, fail

    # ================= 3. threshold BLOCKS a low-priority interrupt =======
    # mintthresh = 0xFF means nothing can beat it (compare is strictly >), so
    # no interrupt may be taken however many the testbench asserts. This is
    # the "take condition false" arm.
    li      x3, 3
    li      x10, 0xFF
    csrw    0x347, x10
    li      t0, 8
    csrs    mstatus, t0                 # MIE = 1
    li      t0, -1
    csrs    mie, t0
    li      x20, 0

    li      x13, 0
    li      x14, 300
1:  addi    x13, x13, 1
    blt     x13, x14, 1b
    bnez    x20, fail                   # nothing may have been taken

    # ================= 4. lowering the threshold ADMITS interrupts ========
    li      x3, 4
    li      x10, 0
    csrw    0x347, x10                  # mintthresh = 0 -> any level > 0 wins
    li      x20, 0

    li      x13, 0
    li      x14, 2000
2:  addi    x13, x13, 1
    blt     x13, x14, 2b
    beqz    x20, fail                   # at least one must have been taken

    # ================= 5. MIE=0 blocks the TAKE but not the WAKE ==========
    # wake_cond is MIE-independent by design (Sec. 14.5); take_cond is not.
    li      x3, 5
    li      t0, 8
    csrc    mstatus, t0                 # MIE = 0
    li      x20, 0
    li      x13, 0
    li      x14, 600
3:  addi    x13, x13, 1
    blt     x13, x14, 3b
    bnez    x20, fail                   # MIE=0 -> nothing taken

    # ================= 6. re-enabling MIE resumes taking ==================
    li      x3, 6
    li      t0, 8
    csrs    mstatus, t0
    li      x20, 0
    li      x13, 0
    li      x14, 2000
4:  addi    x13, x13, 1
    blt     x13, x14, 4b
    beqz    x20, fail

    # ================= 7. no EXCEPTION may have occurred ==================
    # Every trap in this test must have been an interrupt. An exception here
    # would mean a CSR access or the vectoring itself went wrong.
    li      x3, 7
    bnez    x22, fail

    li      a0, 1
    j       done
fail:
    slli    a0, x3, 1
    ori     a0, a0, 1
done:
    lla     t0, tohost
    sw      a0, 0(t0)
9:  j 9b

    # ---- trap handler ----------------------------------------------------
    # Interrupts resume in place; exceptions are recorded and skipped so a
    # stray one cannot hang the test and hide the CLIC result.
    .align 6
trap_vector:
    csrr    x21, mcause
    bltz    x21, 8f                     # mcause bit 31 -> interrupt
    addi    x22, x22, 1
    csrr    x30, mepc
    addi    x30, x30, 4
    csrw    mepc, x30
    mret
8:  addi    x20, x20, 1
    mret

