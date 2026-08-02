# =============================================================================
# t_loadbranch.S -- minimal reproduction: LOAD immediately feeding a BRANCH.
#
# Extracted from riscv-tests rv32mi/ma_addr, which fails on GARUDA at exactly
# this pattern inside its trap handler:
#
#       lb   t0, 0(t0)          # t0 = 0xffffffcc
#       beqz t0, fail           # must NOT be taken
#
# GARUDA took the branch, which means the comparison used a STALE t0 rather
# than the loaded value. The load-use interlock exists to prevent precisely
# this, so either it is not firing for branch operands, or the value is being
# lost across the two-cycle D-port access (ERRATUM D-1 made every load two
# cycles, which is what opened this window).
#
# Distances are swept so the failing distance is identifiable rather than just
# "it broke": test 1 has the branch immediately after the load, test 2 has one
# independent instruction between, test 3 has two.
#
# tohost: 1 = all pass, (n<<1)|1 = test n failed.
# =============================================================================

    .section .text.init, "ax"
    .global _start
_start:
    lla     x20, data

    # ---- test 1: branch immediately after the load (distance 1) ----
    li      x3, 1
    lb      x5, 0(x20)              # x5 = 0xffffffcc
    beqz    x5, fail                # must NOT branch
    li      x6, 0xffffffcc
    bne     x5, x6, fail            # and the value must be correct

    # ---- test 2: one independent instruction between (distance 2) ----
    li      x3, 2
    lb      x7, 0(x20)
    nop
    beqz    x7, fail
    li      x6, 0xffffffcc
    bne     x7, x6, fail

    # ---- test 3: two independent instructions between (distance 3) ----
    li      x3, 3
    lb      x8, 0(x20)
    nop
    nop
    beqz    x8, fail
    li      x6, 0xffffffcc
    bne     x8, x6, fail

    # ---- test 4: load feeding an ALU op, not a branch (control case) ----
    # If this passes while test 1 fails, the defect is specific to the branch
    # operand path, not to load-use forwarding in general.
    li      x3, 4
    lb      x9, 0(x20)
    addi    x10, x9, 0
    li      x6, 0xffffffcc
    bne     x10, x6, fail

    li      a0, 1                   # all passed
    j       done
fail:
    slli    a0, x3, 1
    ori     a0, a0, 1
done:
    lla     t0, tohost
    sw      a0, 0(t0)
1:  j 1b

    .section .data
    .align 4
data:
    .byte 0xcc, 0x11, 0x22, 0x33
