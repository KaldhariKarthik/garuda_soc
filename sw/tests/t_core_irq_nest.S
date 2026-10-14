# =============================================================================
# t_core_irq_nest.S -- T-12 at program level: the CLIC interrupt-level stack
# across nesting, an exception inside a handler and the machine timer inside a
# handler, with real handlers that follow the firmware rule (save mcause/mepc
# on entry, restore before mret) and real interrupts from the tb_boot test
# device (tb/soc/tb_boot.sv: IRQ_SET/IRQ_CLR/MTIP, deterministic).
#
#   A  depth 3: id 3 @40 raises id 5 @120 raises id 6 @200; every handler
#      checks mintstatus.mil on entry and after its inner handler returned
#   B  id 8 @80 executes an illegal instruction with MIE on: the exception
#      handler sees mil 80, and after it returns the level is still 80
#   C  id 9 @80 raises the machine-timer interrupt with MIE on: the MTI
#      handler sees mil 80 (R1: MTI keeps the level), still 80 afterwards
#   D  id 10 @30 after everything returned: taken only if the level is back
#      at 0 (before the fix it stayed at 80 and this interrupt never came)
#   E  ecall at level 0: mcause is the plain cause (11), mpil 0
# Fail codes: 3 wrong level on entry, 5 wrong level after an inner return,
# 7 nesting not reached, 9 wrong mcause, 11 unexpected trap, 13 phase missing.
# =============================================================================
#define IRQ_SET   0x1000F200
#define IRQ_CLR   0x1000F204
#define MTIP      0x1000F208
#define MINTSTATUS 0x346
#define MINTTHRESH 0x347
    .option arch, +zifencei
    .section .text.init, "ax"
    .global _start
_start:
    lla     sp, stack_top
    lla     t0, trap_vector
    csrw    mtvec, t0
    csrw    MINTTHRESH, zero
    li      t0, 0x80
    csrw    mie, t0                     # MTIE for phase C
    lla     s11, flags                  # s11 = flag area for the whole test
    csrsi   mstatus, 8                  # MIE

    # ---- A: id 3 @40 starts the depth-3 chain -----------------------------
    li      a0, (40 << 8) | 3
    call    raise
    lw      t0, 0(s11)                  # flag: deepest level reached
    li      t1, 200
    li      a0, 7
    bne     t0, t1, fail
    csrr    t0, MINTSTATUS
    andi    t0, t0, 0xFF
    li      a0, 5
    bnez    t0, fail                    # back at level 0

    # ---- B: exception inside a level-80 handler ----------------------------
    li      a0, (80 << 8) | 8
    call    raise
    lw      t0, 4(s11)
    li      a0, 13
    beqz    t0, fail                    # phase B ran

    # ---- C: machine timer inside a level-80 handler ------------------------
    li      a0, (80 << 8) | 9
    call    raise
    lw      t0, 8(s11)
    li      a0, 13
    beqz    t0, fail

    # ---- D: a level-30 interrupt must be taken now -------------------------
    li      a0, (30 << 8) | 10
    call    raise
    lw      t0, 12(s11)
    li      a0, 13
    beqz    t0, fail

    # ---- E: an exception at level 0 has the plain mcause -------------------
    ecall
    lw      t0, 16(s11)
    li      a0, 13
    beqz    t0, fail

    li      a0, 1
    j       done

# raise(a0 = level<<8 | id): store to IRQ_SET; the interrupt is taken within a
# few instructions (MIE is on), and its handler clears the source
raise:
    li      t0, IRQ_SET
    sw      a0, 0(t0)
    nop
    nop
    nop
    nop
    ret

# ---------------------------------------------------------------------------
# one trap vector for everything (CLIC mode: all traps enter at mtvec)
# ---------------------------------------------------------------------------
    .align 6
trap_vector:
    addi    sp, sp, -64
    sw      ra, 0(sp)
    sw      t0, 4(sp)
    sw      t1, 8(sp)
    sw      t2, 12(sp)
    sw      a0, 16(sp)
    sw      a1, 20(sp)
    sw      s0, 24(sp)
    sw      s1, 28(sp)
    csrr    t0, mepc
    sw      t0, 32(sp)
    csrr    t0, mcause
    sw      t0, 36(sp)                  # firmware rule: mcause saved on entry
    mv      s0, t0                      # s0 = this trap's mcause
    csrr    s1, MINTSTATUS
    andi    s1, s1, 0xFF                # s1 = level on entry
    bltz    s0, is_interrupt
    # ---- exceptions --------------------------------------------------------
    andi    t1, s0, 0x1F
    li      t2, 2
    beq     t1, t2, exc_illegal
    li      t2, 11
    beq     t1, t2, exc_ecall
    li      a0, 11
    j       fail
exc_illegal:                            # phase B inner: level must still be 80
    li      t2, 80
    li      a0, 3
    bne     s1, t2, fail
    srli    t1, s0, 16
    andi    t1, t1, 0xFF                # mcause.mpil = the level it interrupted
    bne     t1, t2, fail
    lw      t0, 32(sp)
    addi    t0, t0, 4                   # skip the illegal instruction
    sw      t0, 32(sp)
    j       trap_return
exc_ecall:                              # phase E: plain mcause at level 0
    li      t2, 11
    li      a0, 9
    bne     s0, t2, fail
    li      t0, 1
    sw      t0, 16(s11)
    lw      t0, 32(sp)
    addi    t0, t0, 4
    sw      t0, 32(sp)
    j       trap_return

is_interrupt:
    andi    t1, s0, 0x1F                # id (7 = machine timer)
    li      t2, 7
    beq     t1, t2, irq_mti
    li      t0, IRQ_CLR                 # clear the source, as a driver would
    sw      zero, 0(t0)
    li      t2, 3
    beq     t1, t2, irq_3
    li      t2, 5
    beq     t1, t2, irq_5
    li      t2, 6
    beq     t1, t2, irq_6
    li      t2, 8
    beq     t1, t2, irq_8
    li      t2, 9
    beq     t1, t2, irq_9
    li      t2, 10
    beq     t1, t2, irq_10
    li      a0, 11
    j       fail

irq_3:  li      a1, 40                  # entered at 40, raises id 5 @120
        li      a0, (120 << 8) | 5
        j       nest
irq_5:  li      a1, 120                 # entered at 120, raises id 6 @200
        li      a0, (200 << 8) | 6
        j       nest
irq_6:  li      t2, 200                 # deepest
        li      a0, 3
        bne     s1, t2, fail
        sw      t2, 0(s11)
        j       trap_return
irq_8:  li      t2, 80                  # phase B
        li      a0, 3
        bne     s1, t2, fail
        csrsi   mstatus, 8
        .word   0x00000000              # illegal instruction, with MIE on
        csrci   mstatus, 8
        csrr    t0, MINTSTATUS
        andi    t0, t0, 0xFF
        li      a0, 5
        bne     t0, t2, fail
        li      t0, 1
        sw      t0, 4(s11)
        j       trap_return
irq_9:  li      t2, 80                  # phase C
        li      a0, 3
        bne     s1, t2, fail
        csrsi   mstatus, 8
        li      t0, MTIP
        li      t1, 1
        sw      t1, 0(t0)               # machine-timer interrupt, with MIE on
        nop
        nop
        nop
        nop
        csrci   mstatus, 8
        csrr    t0, MINTSTATUS
        andi    t0, t0, 0xFF
        li      a0, 5
        bne     t0, t2, fail
        lw      t0, 20(s11)             # the MTI handler ran
        li      a0, 13
        beqz    t0, fail
        li      t0, 1
        sw      t0, 8(s11)
        j       trap_return
irq_10: li      t2, 30                  # phase D: only possible at level 0
        li      a0, 3
        bne     s1, t2, fail
        li      t0, 1
        sw      t0, 12(s11)
        j       trap_return
irq_mti:                                # phase C inner (R1: MTI keeps mil)
        li      t2, 80
        li      a0, 3
        bne     s1, t2, fail
        li      t0, MTIP
        sw      zero, 0(t0)             # clear the timer
        li      t0, 1
        sw      t0, 20(s11)
        j       trap_return

# nest: check the entry level (a1), raise the next interrupt with MIE on, and
# check the level is the same after the inner handler returned
nest:   li      t0, 0
        li      t2, 0
        mv      t2, a1
        li      t0, 3
        bne     s1, t2, nest_fail_entry
        csrsi   mstatus, 8
        li      t0, IRQ_SET
        sw      a0, 0(t0)
        nop
        nop
        nop
        nop
        csrci   mstatus, 8
        csrr    t0, MINTSTATUS
        andi    t0, t0, 0xFF
        li      a0, 5
        bne     t0, t2, fail
        j       trap_return
nest_fail_entry:
        li      a0, 3
        j       fail

trap_return:                            # firmware rule: restore mcause and mepc
    lw      t0, 36(sp)
    csrw    mcause, t0
    lw      t0, 32(sp)
    csrw    mepc, t0
    lw      ra, 0(sp)
    lw      t0, 4(sp)
    lw      t1, 8(sp)
    lw      t2, 12(sp)
    lw      a0, 16(sp)
    lw      a1, 20(sp)
    lw      s0, 24(sp)
    lw      s1, 28(sp)
    addi    sp, sp, 64
    mret

fail:
done:
    lla     t0, tohost
    li      t1, 1
    beq     a0, t1, 2f
    slli    a0, a0, 1                   # (n << 1) | 1 -> FAILED (test n)
    ori     a0, a0, 1
2:  sw      a0, 0(t0)
1:  j       1b

    .section .data
    .align 4
flags:  .space 32                       # 0 deepest, 4 B, 8 C, 12 D, 16 E, 20 MTI ran
        .align 4
stack:  .space 1024
stack_top:
