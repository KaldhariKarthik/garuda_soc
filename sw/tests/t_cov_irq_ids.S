# =============================================================================
# t_cov_irq_ids.S -- interrupt corners not reached by the other programs
# (1-TOPS G5 5.8; tb/cov/garuda_core_cov_ext.sv cg_irq, cg_sleep;
# tb/cov/garuda_cov_vplan.sv cg_irq, cg_wfi). Interrupts are raised through the
# tb_boot test device (IRQ_SET: id in bits 4:0, level in bits 15:8).
#   A  CLIC id 2 (DMA channel 2 done) and id 14 (SPI slave) taken, level 100
#   B  taken with mintthresh = 30 (a level-120 request, above the threshold)
#   C  nested at a low level: inside a level-20 handler with MIE on, a level-50
#      request preempts (both levels in 1..63)
#   D  MTI and a CLIC request pending together: with the CLIC request at level
#      100 above the threshold it is taken first; with mintthresh = 200 above
#      its level, MTI is taken while the CLIC request stays pending
#   E  WFI with mstatus.MIE = 0: a CLIC request armed while asleep wakes the
#      core and is NOT taken; the program goes on after the WFI
#   F  WFI with mstatus.MIE = 0 and mie.MTIE = 1, woken by a CLIC request and
#      MTIP raised in the same cycle (IRQ_ARMC bit 31): both pending at the wake
#   G  WFI woken one to eight cycles after the request is armed (short sleeps)
#   I  a WFI reached by a jump (the jump empties the prefetch buffer), woken by a
#      CLIC request 40 cycles later: the core sleeps with a part-filled buffer
#   J  the same with mgarudactl.CG_DIS = 1 (no clock gating: the clock runs in WFI).
#      Run with tb_boot +FSTOP_ON_WFI=1 (t_cov_irq_ids_fstop), the fetch port starts
#      again while the core waits and the core leaves the quiescent state with no
#      wake source (cg_sleep cp_woken_by "other"; JasperGold c_wake_other_cgdis)
#   H  an interrupt armed 1..8 retired instructions ahead (IRQ_ARM) lands on a
#      run of MULs, then on a run of load-use pairs: taken with a MUL, and with
#      a load-use bubble, in EX (cg_irq x_insn_class mul, bubble)
# Fail codes: 3 handler A/B not run, 5 nesting, 7 MTI/CLIC order, 9 WFI not
# woken or a masked request taken, 11 unexpected trap, 13 part H count.
# =============================================================================
#define IRQ_SET    0x1000F200
#define IRQ_CLR    0x1000F204
#define MTIP       0x1000F208
#define IRQ_STAGE  0x1000F210
#define IRQ_ARM    0x1000F20C
#define IRQ_ARMC   0x1000F214
#define MINTTHRESH 0x347
#define MGARUDACTL 0x7C0

.macro raise id, lvl
    li      t0, IRQ_SET
    li      t1, ((\lvl) << 8) | (\id)
    sw      t1, 0(t0)
.endm

    .section .text.init, "ax"
    .global _start
_start:
    lla     sp, stack_top
    lla     t0, trap_vector
    csrw    mtvec, t0
    csrw    MINTTHRESH, zero
    csrw    mie, zero
    lla     s11, flags
    csrsi   mstatus, 8                  # MIE on

    # ---- A: ids 2 and 14 ------------------------------------------------------------
    raise   2, 100
    li      a0, 3
    li      t2, 0
    call    wait_flag
    raise   14, 100
    li      t2, 4
    call    wait_flag

    # ---- B: taken with a non-zero threshold -------------------------------------------
    li      t0, 30
    csrw    MINTTHRESH, t0
    raise   16, 120
    li      t2, 8
    call    wait_flag
    csrw    MINTTHRESH, zero

    # ---- C: nested at low levels --------------------------------------------------
    raise   17, 20                      # its handler raises id 18 at level 50
    li      a0, 5
    li      t2, 16                      # flag 16: the level-50 handler ran (nested)
    call    wait_flag
    li      t2, 12                      # flag 12: the level-20 handler finished
    call    wait_flag

    # ---- D: MTI and CLIC pending together ------------------------------------------
    csrci   mstatus, 8                  # MIE off while both are set up
    li      t0, 0x80
    csrw    mie, t0                     # MTIE
    li      t0, MTIP
    li      t1, 1
    sw      t1, 0(t0)                   # MTIP pending
    raise   19, 100                     # CLIC pending at level 100
    nop
    nop
    sw      zero, 20(s11)
    csrsi   mstatus, 8                  # D1: the CLIC request is taken first
    li      a0, 7
    li      t2, 24                      # flag 24: the MTI handler ran
    call    wait_flag
    lw      t0, 20(s11)                 # order: 1 = CLIC first, 2 = MTI first
    li      t1, 1
    bne     t0, t1, fail
    csrci   mstatus, 8                  # D2: CLIC below the threshold, MTI taken
    sw      zero, 20(s11)
    sw      zero, 24(s11)
    li      t0, 200
    csrw    MINTTHRESH, t0
    raise   19, 100                     # pending, but below mintthresh
    li      t0, MTIP
    li      t1, 1
    sw      t1, 0(t0)
    nop
    nop
    csrsi   mstatus, 8
    li      t2, 24
    call    wait_flag                   # MTI taken with the CLIC request pending
    lw      t0, 20(s11)
    li      t1, 2
    bne     t0, t1, fail
    csrci   mstatus, 8
    li      t0, IRQ_CLR
    sw      zero, 0(t0)
    csrw    MINTTHRESH, zero
    csrw    mie, zero

    # ---- E: WFI with MIE = 0: woken, not taken -------------------------------------
    sw      zero, 28(s11)
    li      t0, IRQ_STAGE
    li      t1, (60 << 8) | 20
    sw      t1, 0(t0)
    li      t0, IRQ_ARMC
    li      t1, 30
    sw      t1, 0(t0)
    wfi
    nop
    li      t0, IRQ_CLR
    sw      zero, 0(t0)
    lw      t0, 28(s11)                 # the handler must not have run
    li      a0, 9
    bnez    t0, fail

    # ---- F: CLIC and MTI raised in the same cycle while asleep ------------------------
    li      t0, 0x80
    csrw    mie, t0                     # MTIE (mstatus.MIE stays 0: nothing is taken)
    li      t0, IRQ_STAGE
    li      t1, (60 << 8) | 20
    sw      t1, 0(t0)
    li      t0, IRQ_ARMC
    li      t1, 0x8000001E              # 30 cycles, and MTIP with it
    sw      t1, 0(t0)
    wfi
    nop
    li      t0, IRQ_CLR
    sw      zero, 0(t0)
    li      t0, MTIP
    sw      zero, 0(t0)
    csrw    mie, zero

    # ---- G: short sleeps: woken 1..8 cycles after arming ------------------------------
    li      s2, 1
1:  li      t0, IRQ_STAGE
    li      t1, (60 << 8) | 20
    sw      t1, 0(t0)
    li      t0, IRQ_ARMC
    sw      s2, 0(t0)
    wfi
    nop
    li      t0, IRQ_CLR
    sw      zero, 0(t0)
    addi    s2, s2, 1
    li      t0, 9
    blt     s2, t0, 1b

    # ---- I: WFI right after a jump --------------------------------------------------
    li      t0, IRQ_STAGE
    li      t1, (60 << 8) | 20
    sw      t1, 0(t0)
    li      t0, IRQ_ARMC
    li      t1, 40
    sw      t1, 0(t0)
    nop
    nop
    nop
    nop
    j       3f
3:  wfi
    nop
    li      t0, IRQ_CLR
    sw      zero, 0(t0)

    # ---- J: WFI after a jump with clock gating off -------------------------------------
    li      t0, 8
    csrw    MGARUDACTL, t0              # CG_DIS
    li      t0, IRQ_STAGE
    li      t1, (60 << 8) | 20
    sw      t1, 0(t0)
    li      t0, IRQ_ARMC
    li      t1, 40
    sw      t1, 0(t0)
    nop
    nop
    nop
    nop
    j       4f
4:  wfi
    nop
    li      t0, IRQ_CLR
    sw      zero, 0(t0)
    csrw    MGARUDACTL, zero

    # ---- H: interrupts landing on MULs and on load-use bubbles ---------------------
    csrsi   mstatus, 8                  # MIE on
    lla     s3, flags
    li      s2, 1
1:  li      t0, IRQ_STAGE
    li      t1, (100 << 8) | 21
    sw      t1, 0(t0)
    li      t0, IRQ_ARM
    sw      s2, 0(t0)
    li      t3, 3
    li      t4, 5
    mul     t5, t3, t4
    mul     t5, t5, t4
    mul     t5, t5, t3
    mul     t5, t5, t4
    mul     t5, t5, t3
    mul     t5, t5, t4
    mul     t5, t5, t3
    mul     t5, t5, t4
    mul     t5, t5, t3
    mul     t5, t5, t4
    li      t0, IRQ_STAGE
    li      t1, (100 << 8) | 21
    sw      t1, 0(t0)
    li      t0, IRQ_ARM
    sw      s2, 0(t0)
    lw      t5, 0(s3)
    addi    t5, t5, 1
    lw      t5, 4(s3)
    addi    t5, t5, 1
    lw      t5, 8(s3)
    addi    t5, t5, 1
    lw      t5, 12(s3)
    addi    t5, t5, 1
    lw      t5, 16(s3)
    addi    t5, t5, 1
    lw      t5, 0(s3)
    addi    t5, t5, 1
    addi    s2, s2, 1
    li      t0, 9
    blt     s2, t0, 1b
    nop
    nop
    csrci   mstatus, 8
    lw      t0, 32(s11)                 # id 21 taken 16 times
    li      t1, 16
    li      a0, 13
    bne     t0, t1, fail

    li      a0, 1
    j       done

# wait for flag word t2 (offset into flags) to become non-zero, bounded; a0 = fail code
wait_flag:
    add     t2, t2, s11
    li      t1, 400
1:  lw      t0, 0(t2)
    bnez    t0, 2f
    addi    t1, t1, -1
    bnez    t1, 1b
    j       fail
2:  ret

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
    li      t1, 2
    beq     t0, t1, h_a2
    li      t1, 14
    beq     t0, t1, h_a14
    li      t1, 16
    beq     t0, t1, h_b
    li      t1, 17
    beq     t0, t1, h_c20
    li      t1, 18
    beq     t0, t1, h_c50
    li      t1, 19
    beq     t0, t1, h_d
    li      t1, 20
    beq     t0, t1, h_e
    li      t1, 21
    beq     t0, t1, h_h
unexpected:
    li      a0, 11
    j       fail

h_a2:   li      t0, 1
        sw      t0, 0(s11)
        j       trap_return
h_a14:  li      t0, 1
        sw      t0, 4(s11)
        j       trap_return
h_b:    li      t0, 1
        sw      t0, 8(s11)
        j       trap_return
h_c20:  csrsi   mstatus, 8              # MIE on inside the level-20 handler
        li      t0, IRQ_SET
        li      t1, (50 << 8) | 18      # higher level: preempts
        sw      t1, 0(t0)
        li      t1, 400
1:      lw      t0, 16(s11)
        bnez    t0, 2f
        addi    t1, t1, -1
        bnez    t1, 1b
2:      csrci   mstatus, 8
        li      t0, 1
        sw      t0, 12(s11)
        j       trap_return
h_c50:  li      t0, 1
        sw      t0, 16(s11)
        j       trap_return
h_d:    lw      t0, 20(s11)             # first handler of part D records the order
        bnez    t0, trap_return
        li      t0, 1
        sw      t0, 20(s11)
        j       trap_return
h_mti:  li      t0, MTIP
        sw      zero, 0(t0)
        lw      t0, 20(s11)
        bnez    t0, 1f
        li      t0, 2
        sw      t0, 20(s11)
1:      li      t0, 1
        sw      t0, 24(s11)
        j       trap_return
h_h:    lw      t0, 32(s11)
        addi    t0, t0, 1
        sw      t0, 32(s11)
        j       trap_return
h_e:    li      t0, 1                   # parts E to G must never take id 20
        sw      t0, 28(s11)
        li      a0, 9
        j       fail

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
flags:  .space 64       # 0 id2, 4 id14, 8 threshold, 12 level-20 done, 16 level-50 nested,
                        # 20 order in D, 24 MTI ran, 28 a masked id-20 request was taken,
                        # 32 part H: id-21 interrupts taken
        .align 4
stack:  .space 512
stack_top:
