# =============================================================================
# t_flush.S -- Core Sanity TB row 22: flush with an outstanding fetch.
#
# THE HIGHEST-VALUE ROW IN THE SHEET. ERRATUM I-1 rewrote the I-port master to
# track address and data phases separately, which introduced drop_cnt[1:0] -
# the obligation to DISCARD in-flight fetch data across a redirect. Up to two
# transfers can be live at once, so the count matters.
#
# That logic is currently proven only indirectly (the wait-state regression
# passes). This test aims straight at it: a dense sequence of mispredicted
# branches and taken jumps, so redirects fire while fetches are still
# outstanding. Run with I-port wait states to widen the window:
#
#     +IWAIT=3 +IRAND=1 +SEED=<n>
#
# If a dropped fetch is NOT discarded, a stale instruction word lands in the
# prefetch buffer after the flush and the core executes something from the
# wrong path - which shows up here as a wrong sum or a wrong branch outcome,
# not as a hang.
# =============================================================================
    .section .text.init, "ax"
    .global _start
_start:
    li      x3, 0
    li      x10, 0                      # accumulator

    # ---- test 1: alternating taken / not-taken, each mispredicted ----
    li      x3, 1
    li      x11, 0
    li      x12, 40
1:  addi    x11, x11, 1
    andi    x13, x11, 1
    beqz    x13, 2f                     # taken on even
    addi    x10, x10, 3                 # odd path
    j       3f
2:  addi    x10, x10, 5                 # even path
3:  blt     x11, x12, 1b
    # 20 odd iterations * 3 + 20 even * 5 = 60 + 100 = 160
    li      x6, 160
    bne     x10, x6, fail

    # ---- test 2: back-to-back jumps, redirect every other instruction ----
    li      x3, 2
    li      x10, 0
    jal     x0, 4f
    addi    x10, x10, 100               # must be skipped
4:  addi    x10, x10, 1
    jal     x0, 5f
    addi    x10, x10, 100               # must be skipped
5:  addi    x10, x10, 1
    jal     x0, 6f
    addi    x10, x10, 100               # must be skipped
6:  addi    x10, x10, 1
    li      x6, 3
    bne     x10, x6, fail

    # ---- test 3: jump backwards into a loop, tight redirect spacing ----
    li      x3, 3
    li      x10, 0
    li      x11, 0
    li      x12, 30
7:  addi    x11, x11, 1
    addi    x10, x10, 2
    bne     x11, x12, 7b
    li      x6, 60
    bne     x10, x6, fail

    # ---- test 4: JALR through a register, target computed at run time ----
    li      x3, 4
    li      x10, 0
    lla     x14, 8f
    jalr    x1, 0(x14)
    addi    x10, x10, 100               # must be skipped
8:  addi    x10, x10, 7
    li      x6, 7
    bne     x10, x6, fail

    li      a0, 1
    j       done
fail:
    slli    a0, x3, 1
    ori     a0, a0, 1
done:
    lla     t0, tohost
    sw      a0, 0(t0)
9:  j 9b
