# =============================================================================
# t_cov_irq.S -- interrupt-gate cases and WFI with CG_DIS (Track A coverage
# closure, 2026-10-11), deterministic through the tb_boot test device.
#   A  MTI taken at level 0 (mie.MTIE, MIE on, the device raises MTIP)
#   B  inside a level-80 handler with MIE on, a level-80 request (equal) and
#      then a level-50 request (lower) must NOT preempt; once the handler
#      returns (level back to 0) the pending level-50 request is taken
#   C  WFI with mgarudactl.CG_DIS = 1: the core holds without gating the
#      clock and an interrupt armed a few instructions ahead wakes it
#   D  the same WFI with the clock gate enabled (CG_DIS = 0)
# Fail codes: 3 MTI not taken, 5 a not-higher level preempted, 7 the pending
# request was not taken after the return, 9 WFI not woken, 11 unexpected trap.
# =============================================================================
#define IRQ_SET    0x1000F200
#define IRQ_CLR    0x1000F204
#define MTIP       0x1000F208
#define IRQ_STAGE  0x1000F210
#define IRQ_ARMC   0x1000F214
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

    # ---- A: MTI at level 0 ----------------------------------------------------
    li      t0, 0x80
    csrw    mie, t0
    csrsi   mstatus, 8
    li      t0, MTIP
    li      t1, 1
    sw      t1, 0(t0)
    li      a0, 3
    call    wait_flag0                  # flag 0 = MTI handler ran

    # ---- B: equal and lower levels inside a level-80 handler ------------------
    li      t0, IRQ_SET
    li      t1, (80 << 8) | 3
    sw      t1, 0(t0)
    li      a0, 7
    call    wait_flag4                  # flag 4 = the level-50 request was taken
    lw      t0, 8(s11)                  # set by the level-50 handler if it ran early
    li      a0, 5
    bnez    t0, fail

    # ---- C: WFI with CG_DIS ----------------------------------------------------
    li      t0, 8
    csrw    MGARUDACTL, t0
    li      t0, IRQ_STAGE
    li      t1, (60 << 8) | 5
    sw      t1, 0(t0)
    li      t0, IRQ_ARMC
    li      t1, 40                      # raise it 40 cycles from now (the core is asleep then)
    sw      t1, 0(t0)
    wfi
    nop
    li      a0, 9
    call    wait_flag12                 # flag 12 = the wake handler ran
    csrw    MGARUDACTL, zero

    # ---- D: WFI with the clock gate enabled -------------------------------------
    sw      zero, 12(s11)
    li      t0, IRQ_STAGE
    li      t1, (60 << 8) | 5
    sw      t1, 0(t0)
    li      t0, IRQ_ARMC
    li      t1, 40
    sw      t1, 0(t0)
    wfi
    nop
    li      a0, 9
    call    wait_flag12

    li      a0, 1
    j       done

# wait for a flag word to become non-zero, bounded; a0 = fail code
wait_flag0:  li t2, 0
             j  wait_flag
wait_flag4:  li t2, 4
             j  wait_flag
wait_flag12: li t2, 12
wait_flag:   add  t2, t2, s11
             li   t1, 400
1:           lw   t0, 0(t2)
             bnez t0, 2f
             addi t1, t1, -1
             bnez t1, 1b
             j    fail
2:           ret

    .align 6
trap_vector:
    addi    sp, sp, -32
    sw      t0, 0(sp)
    sw      t1, 4(sp)
    sw      t2, 8(sp)
    csrr    t0, mepc
    sw      t0, 12(sp)
    csrr    t0, mcause
    sw      t0, 16(sp)
    bgez    t0, unexpected
    andi    t0, t0, 0x7FF
    li      t1, 7
    beq     t0, t1, h_mti
    li      t1, IRQ_CLR
    sw      zero, 0(t1)
    li      t1, 3
    beq     t0, t1, h80
    li      t1, 4
    beq     t0, t1, h50
    li      t1, 5
    beq     t0, t1, h_wake
unexpected:
    li      a0, 11
    j       fail

h_mti:  li      t0, MTIP
        sw      zero, 0(t0)
        li      t0, 1
        sw      t0, 0(s11)
        csrw    mie, zero
        j       trap_return
h80:    csrsi   mstatus, 8              # MIE on inside the handler
        li      t0, IRQ_SET
        li      t1, (80 << 8) | 4       # equal level: must not preempt
        sw      t1, 0(t0)
        nop
        nop
        nop
        nop
        nop
        nop
        li      t1, (50 << 8) | 4       # lower level: must not preempt
        sw      t1, 0(t0)
        nop
        nop
        nop
        nop
        nop
        nop
        csrci   mstatus, 8
        lw      t0, 4(s11)
        sw      t0, 8(s11)              # non-zero here = it preempted (fail 5)
        j       trap_return
h50:    li      t0, 1
        sw      t0, 4(s11)
        j       trap_return
h_wake: li      t0, 1
        sw      t0, 12(s11)
        j       trap_return

trap_return:
    lw      t0, 16(sp)
    csrw    mcause, t0
    lw      t0, 12(sp)
    csrw    mepc, t0
    lw      t0, 0(sp)
    lw      t1, 4(sp)
    lw      t2, 8(sp)
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
flags:  .space 32                       # 0 MTI, 4 level-50 taken, 8 early, 12 wake
        .align 4
stack:  .space 512
stack_top:
