# =============================================================================
# t_hazard.S -- pipeline hazards at core level (1-TOPS G4 rows 4.13 and 4.6).
#
# Every case runs a short sequence that forms one hazard, then checks the
# architectural result. The bench runs it with no wait states and with random
# I-port and D-port wait states (tb/core/run/sanity.toml), and Spike checks
# every retired instruction (tb/core/run/cosim.toml).
#
#   RAW         ALU, load, MUL and CSR results read at distance 1, 2 and 3;
#               both operands from different stages; a loaded value used as a
#               load address, as a store address, as store data, as a branch
#               operand, as a JALR target, and by MUL (MUL while the load-use
#               interlock holds ID).
#   WAR         a register read by one instruction and written by the next:
#               the reader must see the old value (ALU, store, MUL readers).
#   WAW         two writes to one register, the younger must win: ALU after
#               load (the load finishes later under D-port waits), load after
#               ALU, MUL and ALU in both orders, load after load.
#   control     the two instructions behind a taken branch, JAL and JALR must
#               not write; a not-taken branch must not flush; a taken branch
#               whose target is another branch; JALR on a just-computed target.
#   structural  memory operations queued behind a waited one (store then load
#               of the same word, load chains, eight stores then eight loads);
#               the register file written and read in one cycle (distance 3).
#               The DSU busy hold is covered by t_dsu_b2b.
#
# GARUDA issues and writes back in order, so WAR and WAW cannot arise from
# reordering; they are checked because forwarding and the load-use interlock
# choose between in-flight values, and a wrong choice shows up exactly there.
#
# tohost: 1 = all pass, (n<<1)|1 = case n failed (case number in x3).
# =============================================================================

#define CHECK(reg, val)  li x31, val; bne reg, x31, fail

    .section .text.init, "ax"
    .global _start
_start:
    lla     x20, data
    li      x1, 0x00001234
    li      x2, 0x00000111

    # ================================================================ RAW, ALU
    li      x3, 1                   # EX -> EX (distance 1)
    add     x5, x1, x2
    add     x6, x5, x5
    CHECK(x6, 0x268A)

    li      x3, 2                   # MEM -> EX (distance 2)
    add     x5, x1, x2
    nop
    add     x6, x5, x2
    CHECK(x6, 0x1456)

    li      x3, 3                   # WB -> ID: register file written and read in one cycle
    add     x5, x1, x2
    nop
    nop
    add     x6, x5, x1
    CHECK(x6, 0x2579)

    li      x3, 4                   # rs1 from MEM, rs2 from EX
    addi    x5, x1, 1
    addi    x7, x2, 2
    sub     x8, x5, x7
    CHECK(x8, 0x1122)

    li      x3, 5                   # same register on both operands, distance 1
    addi    x5, x0, 21
    mul     x6, x5, x5
    CHECK(x6, 441)

    li      x3, 6                   # ALU result as a store address
    addi    x21, x20, 16
    sw      x1, 0(x21)
    lw      x6, 16(x20)
    CHECK(x6, 0x1234)

    # =============================================================== RAW, load
    li      x3, 7                   # load -> ALU (load-use interlock)
    lw      x5, 0(x20)
    add     x6, x5, x2
    CHECK(x6, 0x11223344 + 0x111)

    li      x3, 8                   # load -> store data
    lw      x5, 0(x20)
    sw      x5, 20(x20)
    lw      x6, 20(x20)
    CHECK(x6, 0x11223344)

    li      x3, 9                   # load -> load address
    lw      x5, 4(x20)              # x5 = &data + 8 (pointer word, below)
    lw      x6, 0(x5)
    CHECK(x6, 0x55667788)

    li      x3, 10                  # load -> branch, both operands loaded
    lw      x5, 0(x20)
    lw      x6, 24(x20)             # +24 holds the same value as +0
    bne     x5, x6, fail

    li      x3, 11                  # load -> MUL: the multiplier operand waits on the interlock
    lw      x5, 12(x20)             # 7
    mul     x6, x5, x5
    CHECK(x6, 49)
    lw      x5, 12(x20)
    mulh    x6, x5, x1
    CHECK(x6, 0)

    li      x3, 12                  # load -> JALR target
    lla     x7, 1f
    sw      x7, 28(x20)
    lw      x8, 28(x20)
    jalr    x0, 0(x8)
    j       fail
1:

    li      x3, 13                  # load-use into a CSR write, then the CSR read used at once
    lw      x5, 12(x20)
    csrw    mscratch, x5
    csrr    x6, mscratch
    addi    x6, x6, 1
    CHECK(x6, 8)

    # ================================================================ RAW, MUL
    li      x3, 14                  # MUL -> ALU, MUL -> MUL
    li      x5, -3
    mul     x6, x5, x2              # -0x333
    add     x7, x6, x0
    mul     x8, x7, x5              # 0x999
    CHECK(x7, -0x333)
    CHECK(x8, 0x999)

    li      x3, 15                  # MULHU / MULHSU -> branch and -> store data
    li      x5, -1
    mulhu   x6, x5, x5              # 0xFFFFFFFE
    li      x31, 0xFFFFFFFE
    bne     x6, x31, fail
    mulhsu  x7, x5, x5              # (-1) * 0xFFFFFFFF, high word = -1
    sw      x7, 32(x20)
    lw      x8, 32(x20)
    CHECK(x8, -1)

    li      x3, 16                  # MUL result at distance 2 and 3
    li      x5, 1000
    mul     x6, x5, x5
    nop
    add     x7, x6, x0
    mul     x8, x5, x5
    nop
    nop
    add     x9, x8, x0
    CHECK(x7, 1000000)
    CHECK(x9, 1000000)

    # ===================================================================== WAR
    li      x3, 17                  # ALU reader, then its source is written
    li      x6, 5
    add     x5, x6, x2
    addi    x6, x0, 99
    CHECK(x5, 0x116)
    CHECK(x6, 99)

    li      x3, 18                  # store reads x6, the next load writes x6
    li      x6, 0x0BADF00D
    sw      x6, 36(x20)
    lw      x6, 12(x20)
    CHECK(x6, 7)
    lw      x7, 36(x20)
    CHECK(x7, 0x0BADF00D)

    li      x3, 19                  # MUL reader, then its source is written
    li      x6, 12
    mul     x5, x6, x6
    addi    x6, x0, 1
    CHECK(x5, 144)

    # ===================================================================== WAW
    li      x3, 20                  # ALU, ALU
    addi    x5, x0, 1
    addi    x5, x0, 2
    CHECK(x5, 2)

    li      x3, 21                  # load, then ALU to the same register: ALU must win
    lw      x5, 0(x20)
    addi    x5, x0, 7
    CHECK(x5, 7)

    li      x3, 22                  # ALU, then load: load must win
    addi    x5, x0, 7
    lw      x5, 12(x20)
    addi    x6, x5, 1
    CHECK(x6, 8)

    li      x3, 23                  # MUL then ALU, ALU then MUL
    mul     x5, x1, x1
    addi    x5, x0, 3
    CHECK(x5, 3)
    addi    x5, x0, 3
    mul     x5, x2, x2
    CHECK(x5, 0x12321)

    li      x3, 24                  # load, load
    lw      x5, 0(x20)
    lw      x5, 12(x20)
    CHECK(x5, 7)

    li      x3, 25                  # write, read, write, read
    addi    x5, x0, 1
    add     x6, x5, x5
    addi    x5, x0, 3
    add     x7, x5, x5
    CHECK(x6, 2)
    CHECK(x7, 6)

    # ================================================================= control
    li      x3, 26                  # taken branch: two shadow instructions must not write
    li      x5, 0
    beq     x0, x0, 1f
    addi    x5, x0, 0x0BA
    addi    x5, x0, 0x0BB
1:  CHECK(x5, 0)

    li      x3, 27                  # not-taken branch: the next instruction executes
    li      x5, 0
    bne     x0, x0, fail
    addi    x5, x0, 5
    CHECK(x5, 5)

    li      x3, 28                  # JAL: shadow does not write, link is pc+4
    li      x5, 0
    jal     x6, 1f
2:  addi    x5, x0, 0x0BA
    addi    x5, x0, 0x0BB
1:  lla     x7, 2b
    bne     x6, x7, fail
    CHECK(x5, 0)

    li      x3, 29                  # JALR on a target computed by the instruction before
    lla     x6, 1f
    addi    x6, x6, -4
    addi    x6, x6, 4
    jalr    x7, 0(x6)
    j       fail
1:

    li      x3, 30                  # taken branch whose target is a taken branch
    li      x5, 0
    beq     x0, x0, 1f
    addi    x5, x0, 0x0BA
1:  beq     x0, x0, 2f
    addi    x5, x0, 0x0BB
2:  CHECK(x5, 0)

    li      x3, 31                  # branch on an ALU result at distance 1, taken backwards
    li      x5, 3
1:  addi    x5, x5, -1
    bnez    x5, 1b
    CHECK(x5, 0)

    # ============================================================== structural
    li      x3, 32                  # store then load of the same word, back to back
    addi    x21, x20, 40
    sw      x1, 0(x21)
    lw      x6, 0(x21)
    CHECK(x6, 0x1234)
    sh      x2, 0(x21)
    lhu     x6, 0(x21)
    CHECK(x6, 0x111)
    sb      x2, 1(x21)
    lw      x6, 0(x21)
    CHECK(x6, 0x1111)

    li      x3, 33                  # three loads in a row, each feeding the next
    lw      x5, 4(x20)              # pointer
    lw      x6, 0(x5)
    lw      x7, 4(x5)               # the word after it
    add     x8, x6, x7
    CHECK(x8, 0x55667788 + 7)

    li      x3, 34                  # eight stores, then eight loads, summed
    addi    x21, x20, 64
    li      x5, 1
    sw      x5, 0(x21)
    sw      x5, 4(x21)
    sw      x5, 8(x21)
    sw      x5, 12(x21)
    sw      x5, 16(x21)
    sw      x5, 20(x21)
    sw      x5, 24(x21)
    sw      x5, 28(x21)
    lw      x6, 0(x21)
    lw      x7, 4(x21)
    add     x6, x6, x7
    lw      x7, 8(x21)
    add     x6, x6, x7
    lw      x7, 12(x21)
    add     x6, x6, x7
    lw      x7, 16(x21)
    add     x6, x6, x7
    lw      x7, 20(x21)
    add     x6, x6, x7
    lw      x7, 24(x21)
    add     x6, x6, x7
    lw      x7, 28(x21)
    add     x6, x6, x7
    CHECK(x6, 8)

    li      x3, 35                  # load -> store address (the load-use interlock on a store base)
    lw      x5, 4(x20)              # x5 = &data + 8
    sw      x2, 8(x5)               # writes data + 16
    lw      x6, 16(x20)
    CHECK(x6, 0x111)

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
    .word 0x11223344                # +0
    .word data + 8                  # +4   pointer to +8
    .word 0x55667788                # +8
    .word 7                         # +12
    .word 0, 0                      # +16, +20
    .word 0x11223344                # +24
    .word 0, 0, 0, 0                # +28 .. +40
    .space 64
