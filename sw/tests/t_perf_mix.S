# =============================================================================
# t_perf_mix.S -- throughput benchmark program (plan P0.11). About 1 M retired
# instructions of a mixed load: ALU, MUL, loads/stores, taken and not-taken
# branches, call/return and CSR traffic (mscratch only: no counters, which the
# Spike lockstep cannot match, C-17). Used to measure simulator speed, not to
# find bugs; it still checks itself (fail 3: the in-memory iteration count is
# wrong, fail 5: the checksum word was not written back) and runs in lockstep.
# =============================================================================
#define ITER 25000
    .section .text.init, "ax"
    .global _start
_start:
    lla     sp, stack_top
    lla     s0, buf                     # s0 = data buffer
    li      s1, ITER                    # s1 = iterations left
    li      s2, 0x12345678              # s2 = running checksum
    sw      zero, 0(s0)                 # buf[0] = iterations done (memory counter)

loop:
    lw      t0, 0(s0)                   # memory counter: load, add, store
    addi    t0, t0, 1
    sw      t0, 0(s0)
    add     s2, s2, t0                  # ALU mix
    xor     s2, s2, s1
    slli    t1, s2, 3
    srli    t2, s2, 7
    or      t1, t1, t2
    sub     s2, s2, t1
    mul     t3, s2, s1                  # multiplier
    mulh    t4, s2, t0
    add     s2, s2, t3
    xor     s2, s2, t4
    andi    t5, s1, 3                   # word index 1..4 by the low bits
    addi    t5, t5, 1
    slli    t5, t5, 2
    add     t5, s0, t5
    sw      s2, 0(t5)                   # store / load back
    lw      t6, 0(t5)
    bne     t6, s2, bad_rd
    andi    t1, s1, 1
    beqz    t1, 1f                      # taken on even iterations
    addi    s2, s2, 13
1:  call    leaf                        # call / return
    csrw    mscratch, s2                # CSR traffic
    csrr    t2, mscratch
    bne     t2, s2, bad_rd
    addi    s1, s1, -1
    bnez    s1, loop

    lw      t0, 0(s0)                   # every iteration counted in memory
    li      t1, ITER
    li      a0, 3
    bne     t0, t1, fail
    sw      s2, 20(s0)                  # final checksum word, read back
    lw      t0, 20(s0)
    li      a0, 5
    bne     t0, s2, fail
    li      a0, 1
    j       done

bad_rd:
    li      a0, 5
    j       fail

leaf:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    srai    t3, s2, 5
    add     s2, s2, t3
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret

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
buf:    .space 32
        .align 4
stack:  .space 256
stack_top:
