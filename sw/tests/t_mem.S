# =============================================================================
# t_mem.S -- directed memory matrix (verification plan item 6).
#
# riscv-tests already proves each load/store instruction in isolation, and the
# rv32mi misalignment tests prove the traps fire. What neither does is sweep the
# WIDTH x OFFSET space systematically, or check that a narrow store leaves the
# rest of the word alone. Those are the two places a byte-enable or lane-select
# bug hides, and they are exercised here deliberately rather than incidentally.
#
# Sections:
#   1  word   store/load                        (offset 0 only - the sole legal one)
#   2  half   store/load at both halfword lanes, signed and unsigned
#   3  byte   store/load at all four lanes, signed and unsigned
#   4  byte-enable isolation: a narrow store must not disturb neighbouring bytes
#   5  half-enable isolation
#   6  back-to-back store -> load to the SAME address (the ERRATA F-1 / P-1
#      pattern: the store stalls MEM for its two-phase AHB access while the
#      dependent load is still in the pipeline behind it)
#   7  TCM boundary: the last word of the 256 KB region
#   8  misaligned accesses trap with the right cause, do NOT write rd, and do
#      NOT modify memory
#
# tohost: 1 = pass, (n<<1)|1 = section n failed.
# =============================================================================

    .section .text.init, "ax"
    .global _start
_start:
    lla     t0, trap_vector
    csrw    mtvec, t0
    li      x3, 0                       # TESTNUM
    li      x20, 0                      # trap count
    li      x21, 0                      # last mcause
    li      x22, 0                      # last mtval
    lla     x19, scratch

    # ================= 1. word =================
    li      x3, 1
    li      x10, 0xDEADBEEF
    sw      x10, 0(x19)
    lw      x11, 0(x19)
    bne     x10, x11, fail

    # ================= 2. halfword, both lanes =================
    li      x3, 2
    li      x10, 0x00000000
    sw      x10, 0(x19)
    li      x10, 0xF00D
    sh      x10, 0(x19)                 # low lane
    lhu     x11, 0(x19)
    li      x6, 0xF00D
    bne     x11, x6, fail
    lh      x11, 0(x19)                 # signed: 0xF00D is negative
    li      x6, 0xFFFFF00D
    bne     x11, x6, fail

    li      x10, 0x1234
    sh      x10, 2(x19)                 # high lane
    lhu     x11, 2(x19)
    li      x6, 0x1234
    bne     x11, x6, fail
    lh      x11, 2(x19)                 # signed, positive -> unchanged
    bne     x11, x6, fail

    # ================= 3. byte, all four lanes =================
    li      x3, 3
    li      x10, 0
    sw      x10, 0(x19)
    li      x10, 0x81                   # negative when sign-extended
    sb      x10, 0(x19)
    lbu     x11, 0(x19)
    li      x6, 0x81
    bne     x11, x6, fail
    lb      x11, 0(x19)
    li      x6, 0xFFFFFF81
    bne     x11, x6, fail

    li      x10, 0x7F                   # positive
    sb      x10, 1(x19)
    lbu     x11, 1(x19)
    li      x6, 0x7F
    bne     x11, x6, fail
    lb      x11, 1(x19)
    bne     x11, x6, fail

    li      x10, 0xC3
    sb      x10, 2(x19)
    lbu     x11, 2(x19)
    li      x6, 0xC3
    bne     x11, x6, fail

    li      x10, 0x5A
    sb      x10, 3(x19)
    lbu     x11, 3(x19)
    li      x6, 0x5A
    bne     x11, x6, fail

    # ================= 4. byte-enable isolation =================
    # Each SB must change exactly one lane. A byte-enable bug typically writes
    # the whole word, which the reload below catches immediately.
    li      x3, 4
    li      x10, 0xAABBCCDD
    sw      x10, 0(x19)
    li      x10, 0x11
    sb      x10, 0(x19)
    lw      x11, 0(x19)
    li      x6, 0xAABBCC11
    bne     x11, x6, fail

    li      x10, 0xAABBCCDD
    sw      x10, 0(x19)
    li      x10, 0x22
    sb      x10, 1(x19)
    lw      x11, 0(x19)
    li      x6, 0xAABB22DD
    bne     x11, x6, fail

    li      x10, 0xAABBCCDD
    sw      x10, 0(x19)
    li      x10, 0x33
    sb      x10, 2(x19)
    lw      x11, 0(x19)
    li      x6, 0xAA33CCDD
    bne     x11, x6, fail

    li      x10, 0xAABBCCDD
    sw      x10, 0(x19)
    li      x10, 0x44
    sb      x10, 3(x19)
    lw      x11, 0(x19)
    li      x6, 0x44BBCCDD
    bne     x11, x6, fail

    # ================= 5. half-enable isolation =================
    li      x3, 5
    li      x10, 0xAABBCCDD
    sw      x10, 0(x19)
    li      x10, 0x1234
    sh      x10, 0(x19)
    lw      x11, 0(x19)
    li      x6, 0xAABB1234
    bne     x11, x6, fail

    li      x10, 0xAABBCCDD
    sw      x10, 0(x19)
    li      x10, 0x5678
    sh      x10, 2(x19)
    lw      x11, 0(x19)
    li      x6, 0x5678CCDD
    bne     x11, x6, fail

    # ================= 6. back-to-back store -> load, same address =========
    # The store holds MEM for its two AHB phases while the load is right behind
    # it. This is the exact shape that exposed ERRATUM F-1 (forwarded operand
    # lost across the stall) and ERRATUM P-1 (the load deleted from ID/EX).
    li      x3, 6
    li      x10, 0x0BADF00D
    sw      x10, 0(x19)
    lw      x11, 0(x19)                 # distance 1
    bne     x10, x11, fail

    li      x10, 0x600DF00D
    sw      x10, 0(x19)
    nop
    lw      x11, 0(x19)                 # distance 2
    bne     x10, x11, fail

    li      x10, 0x12345678
    sw      x10, 4(x19)
    lw      x12, 4(x19)
    lw      x13, 4(x19)                 # two loads chasing one store
    bne     x10, x12, fail
    bne     x10, x13, fail

    # narrow store immediately followed by a wide load of the same word
    li      x10, 0
    sw      x10, 0(x19)
    li      x10, 0xEE
    sb      x10, 1(x19)
    lw      x11, 0(x19)
    li      x6, 0x0000EE00
    bne     x11, x6, fail

    # ================= 7. TCM boundary =================
    # Last word of the 256 KB region (0x1000_0000 + 0x4_0000 - 4). Nothing else
    # uses it in this test - there is no stack here.
    li      x3, 7
    li      x14, 0x1003FFFC
    li      x10, 0xC0FFEE00
    sw      x10, 0(x14)
    lw      x11, 0(x14)
    bne     x10, x11, fail

    # ================= 8. misaligned traps =================
    # Each must: trap with the right cause, leave rd untouched, leave memory
    # untouched. The handler skips the faulting instruction.
    li      x3, 8
    li      x10, 0xA5A5A5A5
    sw      x10, 0(x19)                 # known good word

    # --- misaligned LOADS -> cause 4 ---
    li      x20, 0
    li      x11, 0xFEEDFACE             # canary: must survive
    lw      x11, 1(x19)
    li      x6, 4
    bne     x21, x6, fail               # mcause == load misaligned
    li      x6, 0xFEEDFACE
    bne     x11, x6, fail               # faulting load must not write rd

    lw      x11, 2(x19)                 # LW at +2 is also misaligned
    li      x6, 4
    bne     x21, x6, fail
    li      x6, 0xFEEDFACE
    bne     x11, x6, fail               # canary still intact

    lh      x11, 1(x19)                 # LH at an odd offset
    li      x6, 4
    bne     x21, x6, fail
    li      x6, 0xFEEDFACE
    bne     x11, x6, fail

    # --- misaligned STORES -> cause 6 ---
    li      x10, 0xFFFFFFFF
    sw      x10, 1(x19)
    li      x6, 6
    bne     x21, x6, fail               # mcause == store misaligned
    sh      x10, 1(x19)
    bne     x21, x6, fail

    # memory must be untouched by the faulting stores
    lw      x11, 0(x19)
    li      x6, 0xA5A5A5A5
    bne     x11, x6, fail

    # exactly five traps were taken above
    li      x6, 5
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

    # ---- trap handler: record cause/mtval, skip the faulting instruction ----
    # Uses x30 as its scratch, NOT t1/x6. The test body holds its expected
    # value in x6 across a faulting instruction, so a handler that clobbered
    # x6 would corrupt the very comparison the test makes on return - which is
    # exactly what happened first time round, and it looked like a wrong
    # mcause rather than a clobbered register.
    .align 6
trap_vector:
    csrr    x21, mcause
    csrr    x22, mtval
    addi    x20, x20, 1
    csrr    x30, mepc
    addi    x30, x30, 4
    csrw    mepc, x30
    mret

    .section .data
    .align 4
scratch:
    .word 0, 0, 0, 0
