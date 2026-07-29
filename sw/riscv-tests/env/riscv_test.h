// =============================================================================
// GARUDA env for riscv-tests
//
// riscv-tests ships two environments: `p` (physical, machine mode) and `v`
// (virtual memory). Neither is usable here:
//   - both link at 0x8000_0000; GARUDA's reset vector is 0x1000_0000
//   - `p` reports pass/fail through an ECALL into a trap handler, which drags
//     mtvec, mcause and MRET into the very first ISA test. Those paths are
//     worth verifying, but not as a precondition for testing ADD.
//
// This env reports pass/fail with a direct store to tohost - the same
// handshake crt0.S and tb_boot already use - so an ADD failure is reported by
// ADD, not by the trap unit. The trap paths get exercised separately by the
// rv32mi tests once the base ISA is green.
//
// TESTNUM (gp) carries the failing test index, so a FAIL tells you which
// numbered case in the .S file broke.
// =============================================================================
#ifndef _GARUDA_RISCV_TEST_H
#define _GARUDA_RISCV_TEST_H

#define TESTNUM gp

// The tests select an XLEN/extension prologue through these; GARUDA is RV32IM
// and needs no per-extension enable (no FP, no vector).
#define RVTEST_RV32U
#define RVTEST_RV64U
#define RVTEST_RV32M
#define RVTEST_RV32S
#define RVTEST_FP_ENABLE
#define RVTEST_VEC_ENABLE

#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align 6;                                                       \
        .globl _start;                                                  \
_start:

// Unreachable: every test ends in TEST_PASSFAIL. If control ever arrives here
// the test fell off its own end, and `unimp` traps rather than running into
// whatever follows in memory.
#define RVTEST_CODE_END                                                 \
        unimp

// lla, never la: the toolchain defaults to PIC and `la` becomes a GOT load
// that reads zero on bare metal. See sw/common/crt0.S.
#define RVTEST_PASS                                                     \
        li   a0, 1;                                                     \
        lla  t0, tohost;                                                \
        sw   a0, 0(t0);                                                 \
1:      j 1b;

#define RVTEST_FAIL                                                     \
        slli a0, TESTNUM, 1;                                            \
        ori  a0, a0, 1;                                                 \
        lla  t0, tohost;                                                \
        sw   a0, 0(t0);                                                 \
1:      j 1b;

#define RVTEST_DATA_BEGIN .align 4; .global begin_signature; begin_signature:
#define RVTEST_DATA_END   .align 4; .global end_signature;   end_signature:

#endif // _GARUDA_RISCV_TEST_H
