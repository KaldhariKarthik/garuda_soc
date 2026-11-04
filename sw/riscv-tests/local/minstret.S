# =============================================================================
# minstret.S - the instructions-retired counter read and written in the middle of
# the pipeline (bug C-17, ruling D-32 of 2026-11-04).
#
# Before the fix a read of minstret in EX missed the one or two older instructions
# still in MEM and WB, so its value lagged Spike's by up to 2. Every value read here
# lands in a GPR and is compared with Spike instruction by instruction (lockstep):
#   - reads right behind ALU instructions, a load and a store (MEM busy);
#   - two reads back to back;
#   - minstreth and the Zicntr copies instret / instreth;
#   - csrw minstret, then reads: the next instruction must see exactly the value
#     written (the writing instruction is not counted, as Spike counts);
#   - a write of all ones to minstret, so the next retirements carry into minstreth;
#   - csrrs / csrrc forms, which read before they write.
# Built with the trap-handler environment as p-minstret.
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32M
RVTEST_CODE_BEGIN

    la    s0, tdat

    # ---- reads behind ALU instructions, a load, a store ----------------------
    addi  t0, x0, 1
    addi  t0, t0, 1
    csrr  a0, minstret
    lw    t1, 0(s0)
    csrr  a1, minstret
    sw    t1, 4(s0)
    csrr  a2, minstret
    csrr  a3, minstret
    csrr  a4, minstreth
    csrr  a5, instret
    csrr  a6, instreth

    # ---- write, then read at once -------------------------------------------
    li    t2, 1000
    csrw  minstret, t2
    csrr  a0, minstret
    addi  t0, t0, 1
    csrr  a1, minstret
    lw    t1, 0(s0)
    csrr  a2, minstret

    # ---- carry into minstreth -------------------------------------------------
    li    t2, -2
    csrw  minstret, t2
    csrw  minstreth, x0
    addi  t0, t0, 1
    addi  t0, t0, 1
    addi  t0, t0, 1
    csrr  a3, minstret
    csrr  a4, minstreth

    # ---- read-and-modify forms ------------------------------------------------
    li    t2, 0x00F0
    csrrs a5, minstret, t2
    csrr  a6, minstret
    csrrc a7, minstret, t2
    csrr  a0, minstret
    csrrw a1, minstreth, x0
    csrr  a2, minstreth

    RVTEST_PASS

RVTEST_CODE_END

    .data
RVTEST_DATA_BEGIN
    TEST_DATA
tdat:
    .word 0x12345678
    .word 0
RVTEST_DATA_END
