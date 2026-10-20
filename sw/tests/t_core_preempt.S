# =============================================================================
# t_core_preempt.S -- mgarudactl.PREEMPT_DIS (CORE-4, W5) with deterministic
# interrupts from the tb_boot test device.
#   1  PREEMPT_DIS = 1: inside the level-40 handler (MIE on) a level-200 request
#      is raised; it must NOT preempt: the level-40 handler finishes first, then
#      the level-200 interrupt is taken at level 0              (fail 3)
#   2  PREEMPT_DIS = 0: the same sequence preempts: the level-200 handler runs
#      inside the level-40 handler                              (fail 7)
# Fail 11: unexpected trap, 13: an interrupt never came.
# =============================================================================
#define IRQ_SET    0x1000F200
#define IRQ_CLR    0x1000F204
#define MGARUDACTL 0x7C0
#define MINTTHRESH 0x347
    .section .text.init, "ax"
    .global _start
_start:
    lla     sp, stack_top
    lla     t0, trap_vector
    csrw    mtvec, t0
    csrw    MINTTHRESH, zero
    lla     s11, flags
    csrsi   mstatus, 8

    # ---- 1: preemption disabled --------------------------------------------
    li      t0, 4                       # PREEMPT_DIS
    csrw    MGARUDACTL, t0
    sw      zero, 0(s11)                # step counter
    li      a0, (40 << 8) | 3
    call    raise
    call    wait_flag                   # t0 = order seen by the level-200 handler
    li      a0, 3
    li      t1, 2                       # level 40 finished (1), then level 200 (2)
    bne     t0, t1, fail

    # ---- 2: preemption enabled ---------------------------------------------
    csrw    MGARUDACTL, zero
    sw      zero, 0(s11)
    sw      zero, 4(s11)
    li      a0, (40 << 8) | 4
    call    raise
    call    wait_flag
    li      a0, 7
    li      t1, 1                       # level 200 ran first, inside level 40
    bne     t0, t1, fail

    li      a0, 1
    j       done

raise:
    li      t0, IRQ_SET
    sw      a0, 0(t0)
    nop
    nop
    nop
    nop
    nop
    nop
    ret

# wait_flag: poll the level-200 handler's flag for a bounded time (the test
# must not depend on how many nops the interrupt takes to arrive); t0 = flag
wait_flag:
    li      t1, 200
1:  lw      t0, 4(s11)
    bnez    t0, 2f
    addi    t1, t1, -1
    bnez    t1, 1b
    li      a0, 13                      # the level-200 interrupt never came
    j       fail
2:  ret

    .align 6
trap_vector:
    addi    sp, sp, -32
    sw      t0, 0(sp)
    sw      t1, 4(sp)
    sw      a0, 8(sp)
    csrr    t0, mepc
    sw      t0, 12(sp)
    csrr    t0, mcause
    sw      t0, 16(sp)
    bgez    t0, unexpected
    li      t1, IRQ_CLR
    sw      zero, 0(t1)                 # clear the source
    andi    t0, t0, 0x1F
    li      t1, 3
    beq     t0, t1, h40                 # step 1, level 40
    li      t1, 4
    beq     t0, t1, h40                 # step 2, level 40
    li      t1, 5
    beq     t0, t1, h200
unexpected:
    li      a0, 11
    j       fail

h40:    csrsi   mstatus, 8
        li      t0, IRQ_SET
        li      t1, (200 << 8) | 5
        sw      t1, 0(t0)
        nop
        nop
        nop
        nop
        nop
        nop
        csrci   mstatus, 8
        lw      t0, 0(s11)              # step counter: +1 for "level 40 done"
        addi    t0, t0, 1
        sw      t0, 0(s11)
        j       trap_return
h200:   lw      t0, 0(s11)
        addi    t0, t0, 1
        sw      t0, 0(s11)
        sw      t0, 4(s11)              # 1 = ran before level 40 finished, 2 = after
        j       trap_return

trap_return:
    lw      t0, 16(sp)
    csrw    mcause, t0
    lw      t0, 12(sp)
    csrw    mepc, t0
    lw      t0, 0(sp)
    lw      t1, 4(sp)
    lw      a0, 8(sp)
    addi    sp, sp, 32
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
flags:  .space 16
        .align 4
stack:  .space 512
stack_top:
