# =============================================================================
# t_buserr.S -- Core Sanity TB row 17: D-port returns ERROR.
#
# The memory model returns the two-cycle AHB ERROR response for any access in
# the window given by +ERR_EN=1 +ERR_BASE=<hex> +ERR_SIZE=<hex>. The core must
# turn that into a precise trap:
#     load  -> mcause 5 (load access fault)
#     store -> mcause 7 (store access fault)
# with mepc pointing at the faulting instruction, and no register write.
#
# Run with:  +ERR_EN=1 +ERR_BASE=10020000 +ERR_SIZE=1000
#
# Why this matters beyond "does the trap fire": the D-port takes TWO bus phases
# per access (ERRATUM D-1) and signals ERROR across a two-cycle response, so
# the error has to be latched in the data phase and turned into an exception
# without the pipeline having already retired the instruction. That interaction
# has never been exercised.
# =============================================================================

#define ERR_ADDR 0x10020000

    .section .text.init, "ax"
    .global _start
_start:
    lla     t0, trap_vector
    csrw    mtvec, t0
    li      x3, 0                       # TESTNUM
    li      x20, 0                      # traps taken
    li      x21, 0                      # last mcause

    # ---- test 1: load access fault (cause 5) ----
    li      x3, 1
    li      x10, ERR_ADDR
    li      x11, 0xdeadbeef             # must NOT be overwritten
    lw      x11, 0(x10)                 # -> trap, handler skips it
    li      x6, 5
    bne     x21, x6, fail               # mcause must be 5
    li      x6, 0xdeadbeef
    bne     x11, x6, fail               # a faulting load must not write rd

    # ---- test 2: store access fault (cause 7) ----
    li      x3, 2
    li      x12, 0x12345678
    sw      x12, 0(x10)                 # -> trap, handler skips it
    li      x6, 7
    bne     x21, x6, fail

    # ---- test 3: normal access after the fault still works ----
    li      x3, 3
    lla     x13, scratch
    li      x14, 0x5a5a5a5a
    sw      x14, 0(x13)
    lw      x15, 0(x13)
    bne     x15, x14, fail

    # ---- test 4: exactly two traps were taken ----
    li      x3, 4
    li      x6, 2
    bne     x20, x6, fail

    li      a0, 1
    j       done
fail:
    slli    a0, x3, 1
    ori     a0, a0, 1
done:
    lla     t0, tohost
    sw      a0, 0(t0)
1:  j 1b

    # ---- trap handler: record the cause, skip the faulting instruction ----
    .align 6                            # mtvec base (4-byte is enough now, but
                                        # 64-byte costs nothing and is safe)
trap_vector:
    csrr    x21, mcause
    addi    x20, x20, 1
    csrr    t1, mepc
    addi    t1, t1, 4
    csrw    mepc, t1
    mret

    .section .data
    .align 4
scratch:
    .word 0
