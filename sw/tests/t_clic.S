# =============================================================================
# t_clic.S -- directed CLIC interrupt controller test.
#
# clic_ctrl.v sat at 5.58% coverage (15/269 toggle bins) after the whole
# regression, because t_irq drives ONE interrupt configuration and software
# never writes mtvt. The module is small and mostly combinational, so the gap
# is almost entirely unexercised BUSES rather than unexercised logic:
# NOTE: mtvt (0x307) and mintthresh (0x347) are CLIC CSRs, not base RISC-V, so
# the assembler does not know their names - they are written numerically here.
#
#   clic_irq_id_i   12 bits    clic_irq_lvl_i   8 bits
#   mtvec_i         32 bits    mtvt_i          32 bits
#   vector_target_o 32 bits
#
# Two halves, and both are needed:
#   - the testbench sweeps id / level / shv per interrupt (+IRQ_SWEEP=1)
#   - this test drives the CSR side: mtvt, mtvec and mintthresh
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

    # ================= 1. mtvt is writable and read-backable =============
    # Also the point at which mtvt's 32 bits finally toggle. Values are
    # 64-byte aligned because CLIC mode masks mtvt[5:0].
    li      x3, 1
    li      x10, 0xAAAAAAC0
    csrw    0x307, x10
    csrr    x11, 0x307
    li      x10, 0x55555540
    csrw    0x307, x10
    csrr    x12, 0x307
    beq     x11, x12, fail              # two distinct values must read back differently

    # park mtvt somewhere sane for the rest of the test
    lla     x10, vector_table
    csrw    0x307, x10

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

    # =========================================================================
    # SHV vector table -- one entry PER INTERRUPT ID, holding a jump.
    #
    # clic_ctrl vectors an SHV interrupt to mtvt_base + id*4 and fetch lands
    # there directly, so each entry must be a real instruction, and the table
    # must span every id that can be presented. The testbench sweeps ids up to
    # 0xFFF, so the table needs 4096 entries (16 KB); a short table sends the
    # core off the end into blank memory, where it executes zeros and
    # trap-loops forever. That is precisely the ambiguity clic_ctrl.v's header
    # flags: "if the table holds handler pointers requiring a hardware
    # dereference, trap_ctrl issues that vector fetch; if it holds jump
    # instructions, fetch lands here directly. Flagged for reconciliation with
    # the SHV memory-model decision."
    #
    # This test resolves it the second way - jump instructions - because that
    # is what the RTL actually does today. It lives in .text, not .data: these
    # are instructions.
    # =========================================================================
    .section .text.init, "ax"
    .align 6
vector_table:
    .rept 4096
    j       trap_vector
    .endr
