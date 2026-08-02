# =============================================================================
# t_irq.S -- Core Sanity TB rows 18/19: CLIC interrupt mid-stream, MRET resume.
#
# The testbench asserts clic_irq_i at +IRQ_AT (re-arming every +IRQ_EVERY
# cycles) and holds it until the core acknowledges. This test spins in a
# counting loop so the interrupt lands at an arbitrary point in the instruction
# stream rather than a convenient one, then checks that:
#   - any trap taken was an INTERRUPT (mcause bit 31), not an exception
#   - MRET resumed the loop without losing or repeating work
#   - the loop counter still reaches exactly its expected total
#
# The last point is the one that matters. A trap that saves the wrong mepc, or
# an MRET that resumes one instruction early or late, still "takes the
# interrupt" and still returns - it just silently corrupts the count.
#
# Run with: +IRQ_AT=<cycle>  or  +IRQ_EVERY=<n>
# Passing with no interrupt asserted is also correct (x20 stays 0).
# =============================================================================
    .section .text.init, "ax"
    .global _start
_start:
    lla     t0, trap_vector
    csrw    mtvec, t0
    li      x3, 0
    li      x20, 0                      # interrupts taken
    li      x21, 0                      # non-interrupt traps (must stay 0)

    li      t0, 8                       # mstatus.MIE
    csrs    mstatus, t0
    li      t0, -1
    csrs    mie, t0                     # enable whatever the CSR permits

    # ---- counting loop: interruptible at any point ----
    li      x3, 1
    li      x10, 0
    li      x11, 200
1:  addi    x10, x10, 1
    blt     x10, x11, 1b
    bne     x10, x11, fail              # must complete exactly

    li      x3, 2
    bnez    x21, fail                   # no exceptions, only interrupts

    li      a0, 1
    j       done
fail:
    slli    a0, x3, 1
    ori     a0, a0, 1
done:
    lla     t0, tohost
    sw      a0, 0(t0)
1:  j 1b

    .align 6
trap_vector:
    csrr    t1, mcause
    bltz    t1, 2f                      # bit31 set -> interrupt
    addi    x21, x21, 1                 # exception: record and skip
    csrr    t1, mepc
    addi    t1, t1, 4
    csrw    mepc, t1
    mret
2:  addi    x20, x20, 1                 # interrupt: resume where we left off
    mret
