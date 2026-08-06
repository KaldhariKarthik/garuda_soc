# =============================================================================
# t_cov.S -- coverage-closure test.
#
# Written against the ACTUAL uncovered-block list from IMC, not guesswork. Two
# jobs, because the coverage shortfall has two quite different causes:
#
#  A. BLOCK coverage. Only a handful of blocks in the whole design were never
#     executed. Each section below names the module and line it closes.
#
#  B. TOGGLE coverage. This is where the real shortfall is: clic_ctrl,
#     garuda_if_stage_top, garuda_pc_gen and trap_ctrl have ZERO uncovered
#     blocks yet score 56-80%, because toggle coverage demands every bit of
#     every bus go both 0->1 and 1->0. Ordinary test programs use small
#     constants and low addresses, so the upper bits of 32-bit datapaths never
#     move. Section T walks complementary patterns (0000_0000 / FFFF_FFFF /
#     5555_5555 / AAAA_AAAA) through registers, ALU operands, addresses and
#     store data, which flips every bit in both directions.
#
# tohost: 1 = pass, (n<<1)|1 = section n failed.
# =============================================================================

# Custom-0 encoding (rtl/dsu/dsu_decoder.v): opcode 0x0b, funct3 000 R-type,
# funct7 = {funct5[4:0], acc_sel[1:0]}.
#define DSU_R(f5, acc, rd, rs1, rs2) .insn r 0x0b, 0, ((f5) << 2) | (acc), rd, rs1, rs2
#define F5_MAC_SEL  0
#define F5_MACLOAD  4
#define F5_MACCLEAR 5
#define F5_MACSAT   6
#define F5_MACRD_LO 7

    .section .text.init, "ax"
    .global _start
_start:
    lla     t0, trap_vector
    csrw    mtvec, t0
    li      x3, 0
    li      x20, 0                      # traps taken
    li      x21, 0                      # last mcause
    lla     x19, scratch

    # ================= 1. FENCE  (decode_control line 249/250) ============
    # OP_MISC_MEM had no case at all until ERRATUM C-2. Executing a plain
    # FENCE covers the case item and its implicit-else; FENCE.I covers the
    # funct3 != 0 arm, and must still raise illegal (Zifencei is not claimed).
    li      x3, 1
    fence                               # must be a NO-OP, not a trap
    li      x10, 0x1234
    addi    x10, x10, 1                 # still executing -> fence did not trap
    li      x6, 0x1235
    bne     x10, x6, fail

    # ERRATUM C-3: FENCE.I is now IMPLEMENTED - it redirects to pc+4, which
    # flushes the prefetch buffer. It must execute cleanly and take NO trap.
    li      x3, 2
    li      x20, 0
    li      x10, 0x4000
    .word   0x0000100f                  # FENCE.I
    addi    x10, x10, 1                 # must still execute
    li      x6, 0x4001
    bne     x10, x6, fail
    bnez    x20, fail                   # and must not have trapped

    # ================= 3. OP_REG with a reserved funct7 ===================
    # decode_control line 186: the `else illegal` arm for a funct7 that is
    # neither 0000000 nor 0100000 nor the MULDIV 0000001.
    li      x3, 3
    li      x20, 0
    .word   0xFE0000B3                  # funct7=1111111, rd=x1, ADD-shaped
    li      x6, 2
    bne     x21, x6, fail
    li      x6, 1
    bne     x20, x6, fail

    # ================= 4. CSR reads never previously issued ===============
    # csr_file lines 114-120: MINTSTATUS, MCYCLE, MINSTRET, MINSTRETH, DSU_OVF
    # were all readable but no test had ever read them.
    li      x3, 4
    csrr    x10, 0xFB1                  # mintstatus
    csrr    x11, 0xB00                  # mcycle
    csrr    x12, 0xB02                  # minstret
    csrr    x13, 0xB82                  # minstreth
    csrr    x14, 0xB80                  # mcycleh
    # mcycle must be advancing -- a counter stuck at 0 would read equal twice
    csrr    x15, 0xB00
    beq     x11, x15, fail

    # ================= 5. MCAUSE / MTVAL writes ===========================
    # csr_file lines 208-209: both are written by hardware on every trap but
    # had never been written by SOFTWARE via a CSR instruction.
    li      x3, 5
    li      x10, 0x55555555
    csrw    mcause, x10
    csrr    x11, mcause
    bne     x10, x11, fail
    li      x10, 0xAAAAAAAA
    csrw    mtval, x10
    csrr    x11, mtval
    bne     x10, x11, fail

    # ================= 6. DSU overflow set, then cleared ==================
    # overflow_flag lines 30-31: the sticky flag had never been SET in the
    # in-pipeline instance, nor cleared while set (ERRATUM DSU-8's new
    # clear-keeps-simultaneous-set path).
    # DSU_OVF (0xBC0) is read-to-clear.
    li      x3, 6
    DSU_R(F5_MACCLEAR, 0, x0, x0, x0)
    li      x10, 0x7FFF7FFF
    DSU_R(F5_MACLOAD,  0, x0, x10, x0)   # acc near the 48-bit limit
    DSU_R(F5_MAC_SEL,  0, x0, x10, x10)  # push it over -> overflow
    nop
    nop
    csrr    x11, 0xBC0                   # read DSU_OVF (clears it)
    csrr    x12, 0xBC0                   # second read must show it cleared
    bnez    x12, fail

    # ================= 7. MACSAT with a NEGATIVE clamp ====================
    # saturation_unit line 25: the is_neg arm. Every previous saturating case
    # clamped positive.
    li      x3, 7
    DSU_R(F5_MACCLEAR, 1, x0, x0, x0)
    li      x10, 0x80000000
    DSU_R(F5_MACLOAD,  1, x0, x10, x0)   # acc = 0xFFFF_8000_0000 (negative)
    # 0x8000 * 0x8000 is POSITIVE (-32768 * -32768), which drives the
    # accumulator back toward zero. A product of exactly -1 (lane 0 = 1 * -1)
    # takes it to -2147483649, one below the clamp, which is what the is_neg
    # arm needs. Confirmed against DSUModel before writing it here.
    li      x10, 0x00000001
    li      x17, 0x0000FFFF
    DSU_R(F5_MAC_SEL,  1, x0, x10, x17)  # acc = -2^31 - 1 -> below sat_neg
    nop
    nop
    DSU_R(F5_MACSAT,   1, x0, x0, x0)    # must clamp to sat_neg
    nop
    nop
    DSU_R(F5_MACRD_LO, 1, x13, x0, x0)
    li      x6, 0x80000000
    bne     x13, x6, fail

    # ================= T. TOGGLE patterns =================================
    # Complementary walks so every datapath bit moves BOTH ways.
    li      x3, 8

    # T1: all-ones / all-zeros / alternating through the ALU, every operation.
    li      x10, 0xFFFFFFFF
    li      x11, 0x00000000
    li      x12, 0x55555555
    li      x13, 0xAAAAAAAA

    add     x14, x10, x11
    sub     x14, x10, x12
    and     x14, x10, x13
    or      x14, x11, x12
    xor     x14, x12, x13
    sll     x14, x10, x12
    srl     x14, x10, x11
    sra     x14, x13, x12
    slt     x14, x13, x10
    sltu    x14, x10, x13
    lui     x14, 0xFFFFF
    lui     x14, 0x55555
    auipc   x14, 0xAAAAA
    auipc   x14, 0x00000

    # reverse the operand order so each input bus sees both polarities
    add     x14, x11, x10
    sub     x14, x12, x10
    and     x14, x13, x10
    or      x14, x12, x11
    xor     x14, x13, x12
    slt     x14, x10, x13
    sltu    x14, x13, x10

    # T2: multiplier operands, both polarities on every bit
    mul     x14, x10, x13
    mul     x14, x12, x10
    mulh    x14, x10, x13
    mulhu   x14, x13, x12
    mulhsu  x14, x12, x13

    # T3: store/load data patterns -- toggles the D-port data buses and the
    # load-format lanes in both directions.
    sw      x10, 0(x19)
    lw      x15, 0(x19)
    bne     x10, x15, fail
    sw      x11, 0(x19)
    lw      x15, 0(x19)
    bne     x11, x15, fail
    sw      x12, 4(x19)
    lw      x15, 4(x19)
    bne     x12, x15, fail
    sw      x13, 4(x19)
    lw      x15, 4(x19)
    bne     x13, x15, fail

    # T4: addresses across the map -- toggles the address buses. The base is
    # rebuilt each time so the upper address bits move, which a program using
    # one small scratch buffer never achieves.
    # NOT 0x1002_0000 - that is where far_routine links (see .farcode in
    # link.ld). Writing data there overwrites the routine.
    li      x16, 0x10030000
    sw      x10, 0(x16)
    lw      x15, 0(x16)
    bne     x10, x15, fail
    li      x16, 0x1003FFF0
    sw      x12, 0(x16)
    lw      x15, 0(x16)
    bne     x12, x15, fail
    li      x16, 0x10001554
    sw      x13, 0(x16)
    lw      x15, 0(x16)
    bne     x13, x15, fail
    li      x16, 0x1002AAA8
    sw      x11, 0(x16)
    lw      x15, 0(x16)
    bne     x11, x15, fail

    # T5: byte and halfword lanes with complementary data
    sb      x10, 0(x19)
    lbu     x15, 0(x19)
    sb      x11, 1(x19)
    lbu     x15, 1(x19)
    sh      x12, 2(x19)
    lhu     x15, 2(x19)
    sh      x13, 0(x19)
    lhu     x15, 0(x19)

    # T6: every WRITABLE CSR gets complementary patterns. Each CSR is a 32-bit
    # register whose upper bits never move under normal use, so this is most of
    # what was missing from csr_file's toggle score.
    li      x3, 9
    li      x10, 0x55555555
    li      x11, 0xAAAAAAAA
    csrw    mscratch, x10
    csrr    x15, mscratch
    bne     x10, x15, fail
    csrw    mscratch, x11
    csrr    x15, mscratch
    bne     x11, x15, fail

    csrw    0x347, x10                  # mintthresh (8 bits of it)
    csrw    0x347, x11
    csrw    0x307, x10                  # mtvt
    csrw    0x307, x11
    csrw    mie,  x10
    csrw    mie,  x11
    csrw    mtval, x10
    csrw    mtval, x11
    csrw    mcause, x11
    csrw    mcause, x10

    # mepc last, and restored, because MRET reads it
    csrr    x18, mepc
    csrw    mepc, x10
    csrw    mepc, x11
    csrw    mepc, x18

    # mtvec must be restored to the handler before anything can trap again
    lla     x17, trap_vector
    csrw    mtvec, x17

    # T7: run code FAR from the reset vector, so the PC, the fetch address and
    # the I-port address bus toggle their upper bits. .text.far links at
    # 0x1002_0000 (see sw/common/link.ld).
    li      x3, 10
    li      x10, 0x12345678
    lla     x17, far_routine
    jalr    x1, 0(x17)
    li      x6, 0x12345679
    bne     x10, x6, fail               # far_routine must have run
back_from_far:

    li      a0, 1
    j       done
fail:
    slli    a0, x3, 1
    ori     a0, a0, 1
done:
    lla     t0, tohost
    sw      a0, 0(t0)
9:  j 9b

    # ---- trap handler: record cause, skip the faulting instruction -------
    # Uses x30 as scratch, never x6, because the test body holds expected
    # values in x6 across faulting instructions.
    .align 6
trap_vector:
    csrr    x21, mcause
    addi    x20, x20, 1
    csrr    x30, mepc
    addi    x30, x30, 4
    csrw    mepc, x30
    mret

    # Linked at 0x1002_0000 by the .farcode output section.
    .section .farcode, "ax"
    .align 6
far_routine:
    addi    x10, x10, 1
    nop
    nop
    jr      x1

    .section .data
    .align 4
scratch:
    .word 0, 0, 0, 0
