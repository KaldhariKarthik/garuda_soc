# =============================================================================
# t_core_ctl.S -- mgarudactl (CSR 0x7C0, Track A W5 / DN-CTL): feature-disable
# bits that firmware can use to work around a defect found in silicon.
#   bit0 BP_DIS       static branch predictor off (backward branches predicted not-taken)
#   bit1 PF_DIS       prefetch depth 1
#   bit2 PREEMPT_DIS  a CLIC interrupt is taken only at level 0 (no nesting)
#   bit3 CG_DIS       the WFI clock gate stays open
# Reset value 0: every feature on.
#
# Checks (self-checking on tb_boot, no Spike: 0x7C0 is a GARUDA register):
#   1  the register holds exactly bits [3:0] and never traps     (fail code 3)
#   2  one workload gives the same checksum under all 16 settings:
#      the bits may change timing only, never architectural results (fail 5)
#   3  BP_DIS and PF_DIS each make the workload slower in mcycle:
#      a bit that changes nothing is itself a finding             (fail 7, 9)
# A trap anywhere is a failure (fail 11). PREEMPT_DIS and CG_DIS change only
# interrupt and sleep behaviour: properties a_ctl_* (rtl/core/core_ctl_sva.sv)
# and the nesting test after the tb_boot test device (plan P0.8).
# =============================================================================
#define MGARUDACTL 0x7C0
    .option arch, +zifencei             # sw/Makefile builds rv32im_zicsr; GCC 15 needs Zifencei named for fence.i
    .section .text.init, "ax"
    .global _start
_start:
    lla     sp, stack_top               # the sw/tests assembly programs have no crt0: own stack
    lla     t0, trap_vector
    csrw    mtvec, t0

    # ---- 1: the register --------------------------------------------------
    li      t0, -1
    csrw    MGARUDACTL, t0
    csrr    t1, MGARUDACTL
    li      t2, 0xF
    li      a0, 3
    bne     t1, t2, done
    csrw    MGARUDACTL, zero
    csrr    t1, MGARUDACTL
    bnez    t1, done

    # ---- 2 and 3: the same workload under all 16 settings -----------------
    li      s1, 0                       # setting
    li      s3, 0                       # mcycle with setting 0
next_setting:
    csrw    MGARUDACTL, s1
    fence.i                             # take effect for everything fetched after
    csrr    s4, mcycle
    call    workload                    # -> a0 = checksum
    csrr    s5, mcycle
    sub     s5, s5, s4                  # cycles taken
    bnez    s1, compare
    mv      s2, a0                      # reference checksum (setting 0)
    mv      s3, s5                      # reference cycles
    j       advance
compare:
    li      a1, 5
    bne     a0, s2, fail_a1             # 2: architectural results differ
#ifndef CTL_ARCH_ONLY
    # 3 (zero-wait builds only): with bus wait states fetch latency dominates
    # and the predictor's one-cycle saving disappears (measured 2026-10-11),
    # so t_core_ctl_arch.S (+IWAIT/+DWAIT runs) checks results only
    li      t0, 1
    bne     s1, t0, 1f
    li      a1, 7
    bge     s3, s5, fail_a1             # 3: BP_DIS alone not slower
1:  li      t0, 2
    bne     s1, t0, advance
    li      a1, 9
    bge     s3, s5, fail_a1             # 3: PF_DIS alone not slower
#endif
advance:
    addi    s1, s1, 1
    li      t0, 16
    blt     s1, t0, next_setting
    csrw    MGARUDACTL, zero
    li      a0, 1                       # PASS
    j       done
fail_a1:
    mv      a0, a1
    j       done

# workload: a backward-branch loop with loads, stores, multiplies, a forward
# branch and a call; returns a checksum in a0
workload:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    lla     t3, buf
    li      t4, 0                       # i
    li      a0, 0x1234                  # checksum
    li      t5, 24
wl_loop:
    slli    t6, t4, 2
    add     t6, t6, t3
    mul     a2, t4, t4
    add     a2, a2, a0
    sw      a2, 0(t6)
    lw      a3, 0(t6)
    xor     a0, a0, a3
    andi    a4, t4, 3
    bnez    a4, wl_skip                 # forward branch, taken 3 of 4 times
    call    wl_leaf
wl_skip:
    addi    t4, t4, 1
    blt     t4, t5, wl_loop             # backward branch: the predictor's case
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
wl_leaf:
    slli    a5, a0, 3
    srli    a6, a0, 5
    xor     a0, a5, a6
    addi    a0, a0, 7
    ret

    .align 6
trap_vector:
    li      a0, 11                      # any trap is a failure
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
buf:    .space 128
        .align 4
stack:  .space 256
stack_top:
