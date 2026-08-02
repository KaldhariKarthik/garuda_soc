// =============================================================================
// GARUDA "p" (physical, machine-mode) env for riscv-tests.
//
// This env ADDS a trap handler. It does not replace ../riscv_test.h, and the
// two are not interchangeable:
//
//   ../riscv_test.h  - reports pass/fail with a direct store to tohost. Keeps
//                      the trap unit out of the base ISA tests, so a failing
//                      ADD is reported by ADD. Used for rv32ui/rv32um.
//   this file        - installs mtvec and reports through ECALL, so tests that
//                      are ABOUT traps can run: rv32mi, ma_data, and the
//                      div/rem family that decode_control.v deliberately
//                      raises illegal_instr for (Sec. 7.2).
//
// THREE GARUDA-SPECIFIC DEVIATIONS FROM UPSTREAM env/p/riscv_test.h
// -----------------------------------------------------------------
// 1. trap_vector must be 64-BYTE aligned, not 4-byte. trap_ctrl.v computes
//       mtvec_base = {mtvec_i[31:6], 6'b0}
//    so the low six bits of whatever is written to mtvec are discarded. The
//    upstream env uses `.align 2` here; on GARUDA that silently relocates the
//    handler backwards to the previous 64-byte boundary and the first trap
//    lands in the middle of unrelated code. This is the single most likely
//    thing to break when porting a new test suite in.
//
// 2. NO `fence`. decode_control.v has no OP_MISC_MEM (0001111) case, so FENCE
//    falls through to `default: illegal_instr_o = 1'b1` and traps. Upstream's
//    RVTEST_PASS/RVTEST_FAIL both begin with `fence`, which would make every
//    passing test take an illegal-instruction trap on its way out. Tracked as
//    an RV32I compliance gap - FENCE is permitted to be a no-op but is not
//    permitted to trap.
//
// 3. NO supervisor mode. GARUDA is M-only: no stvec, medeleg, satp or PMP
//    init, and no delegation. Interrupts arrive through the CLIC, not through
//    the standard mtvec vectored mode, so INTERRUPT_HANDLER is not wired here.
//
// Tests that need their own handler define `mtvec_handler` (a weak symbol);
// trap_vector jumps to it, exactly as upstream does. That is the mechanism the
// rv32mi suite relies on.
// =============================================================================
#ifndef _GARUDA_RISCV_TEST_P_H
#define _GARUDA_RISCV_TEST_P_H

// The tests reference CAUSE_* symbolically (CAUSE_MISALIGNED_LOAD etc.), which
// live here. Upstream's p env includes it too; omitting it fails late, at the
// test body rather than in this header.
#include "encoding.h"

#define TESTNUM gp

// GARUDA is RV32IM, M-mode only, so none of these needs a real prologue -- but
// each MUST still define the `init` macro, because RVTEST_CODE_BEGIN invokes
// `init` and the assembler has no other definition of it. Defining these as
// empty (the obvious simplification) fails with "unrecognized opcode `init'".
// Only one of them is expanded per test, so there is no redefinition clash.
#define RVTEST_RV32U  .macro init; .endm
#define RVTEST_RV64U  .macro init; .endm
#define RVTEST_RV32M  .macro init; .endm
#define RVTEST_RV64M  .macro init; .endm
#define RVTEST_RV32S  .macro init; .endm
#define RVTEST_RV64S  .macro init; .endm
#define RVTEST_FP_ENABLE
#define RVTEST_VEC_ENABLE

// Zero the architectural registers so a test never reads a value it did not
// write. x1/x2 are set up afterwards; gp is TESTNUM and is initialised below.
#define GARUDA_INIT_XREG                                                 \
        li x1,  0; li x2,  0; li x4,  0; li x5,  0;                      \
        li x6,  0; li x7,  0; li x8,  0; li x9,  0;                      \
        li x10, 0; li x11, 0; li x12, 0; li x13, 0;                      \
        li x14, 0; li x15, 0; li x16, 0; li x17, 0;                      \
        li x18, 0; li x19, 0; li x20, 0; li x21, 0;                      \
        li x22, 0; li x23, 0; li x24, 0; li x25, 0;                      \
        li x26, 0; li x27, 0; li x28, 0; li x29, 0;                      \
        li x30, 0; li x31, 0;

#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .weak mtvec_handler;                                            \
        .globl _start;                                                  \
_start:                                                                 \
        j reset_vector;                                                 \
                                                                        \
        /* 64-byte aligned: trap_ctrl.v masks mtvec[5:0] (deviation 1) */\
        .align 6;                                                       \
trap_vector:                                                            \
        /* Free up t5/t6 before anything else, preserving their trapping   \
           values, so the div/rem emulator below sees a complete context. \
           x8 goes to mscratch for the same reason. */                    \
        csrw mscratch, t6;                                              \
        lla  t6, garuda_trap_regs;                                      \
        sw   t5, 120(t6);                 /* x30 */                     \
        csrr t5, mscratch;                                              \
        sw   t5, 124(t6);                 /* x31 */                     \
        csrw mscratch, x8;                                              \
                                                                        \
        csrr t5, mcause;                                                \
        li   t6, CAUSE_MACHINE_ECALL;                                   \
        beq  t5, t6, write_tohost;                                      \
        /* a test-supplied handler wins over every default policy */     \
        lla  t6, mtvec_handler;                                         \
        beqz t6, 1f;                                                    \
        jr   t6;                                                        \
        /* Emulated causes: illegal (div/rem) and misaligned load/store.  \
           garuda_trap_emu bounces to garuda_unhandled if it cannot handle \
           the encoding, so a real illegal instruction is never swallowed. */\
1:      li   t6, CAUSE_ILLEGAL_INSTRUCTION;                             \
        beq  t5, t6, garuda_trap_emu;                                   \
        li   t6, CAUSE_MISALIGNED_LOAD;                                 \
        beq  t5, t6, garuda_trap_emu;                                   \
        li   t6, CAUSE_MISALIGNED_STORE;                                \
        beq  t5, t6, garuda_trap_emu;                                   \
        j    garuda_unhandled;                                          \
garuda_unhandled:                                                       \
        /* report an unhandled trap distinctly, so it cannot be mistaken \
           for an ordinary numbered test failure */                     \
        ori  TESTNUM, TESTNUM, 1337;                                    \
write_tohost:                                                           \
        lla  t5, tohost;                                                \
        sw   TESTNUM, 0(t5);                                            \
2:      j 2b;                                                           \
                                                                        \
        .include "divrem_emu.S";          /* no fallthrough: 2b loops */ \
                                                                        \
reset_vector:                                                           \
        GARUDA_INIT_XREG                                                \
        li   TESTNUM, 0;                                                \
        lla  t0, trap_vector;                                           \
        csrw mtvec, t0;                                                 \
        csrwi mstatus, 0;                                               \
        lla  sp, _stack_top;                                            \
        init;                                                           \
        lla  t0, 1f;                                                    \
        csrw mepc, t0;                                                  \
        csrr a0, mhartid;                                               \
        mret;                                                           \
1:

#define RVTEST_CODE_END                                                 \
        unimp

// No `fence` (deviation 2). TESTNUM=1 is the pass code the handler stores.
#define RVTEST_PASS                                                     \
        li   TESTNUM, 1;                                                \
        li   a7, 93;                                                    \
        li   a0, 0;                                                     \
        ecall

#define RVTEST_FAIL                                                     \
1:      beqz TESTNUM, 1b;                                               \
        slli TESTNUM, TESTNUM, 1;                                       \
        ori  TESTNUM, TESTNUM, 1;                                       \
        li   a7, 93;                                                    \
        addi a0, TESTNUM, 0;                                            \
        ecall

// tohost is provided by sw/common/link.ld at a fixed address, so unlike
// upstream this does NOT push its own .tohost section.
#define RVTEST_DATA_BEGIN .align 4; .global begin_signature; begin_signature:
#define RVTEST_DATA_END   .align 4; .global end_signature;   end_signature:

#endif // _GARUDA_RISCV_TEST_P_H
