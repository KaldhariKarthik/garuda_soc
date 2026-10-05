# =============================================================================
# csr_warl.S - what each writable machine CSR holds after a write of all ones,
# of zero, and (mepc) of a misaligned address. Core plan F08 to F11.
#
# Built with the trap-handler environment as p-csr_warl and run in lockstep:
# the test has no expected values of its own. Every value read back, and the
# value Spike says each CSR holds after each write, is compared by
# tools/lockstep.py. What GARUDA defines differently from Spike on purpose is
# not exercised here, because the two would disagree correctly: mtvec (MODE
# reads 3, CLIC only), marchid and mimpid, the mie bits for the software and
# external interrupts (GARUDA has neither; they read 0), and writes to misa
# (hardwired in GARUDA, the M bit can be cleared in Spike).
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32M
RVTEST_CODE_BEGIN

    li   t0, -1

    # ---- mscratch, mcause, mtval: every bit is storage ------------------------
    csrw mscratch, t0
    csrr t1, mscratch
    csrw mscratch, x0
    csrr t1, mscratch
    csrw mcause, t0
    csrr t1, mcause
    csrw mcause, x0
    csrr t1, mcause
    csrw mtval, t0
    csrr t1, mtval
    csrw mtval, x0
    csrr t1, mtval

    # ---- mie: the timer enable, the one bit GARUDA and Spike both have ---------
    li   t3, 0x80
    csrw mie, t3
    csrr t1, mie
    csrw mie, x0
    csrr t1, mie
    csrr t1, misa

    # ---- mepc: an instruction address, so the low bits are not storage --------
    csrw mepc, t0
    csrr t1, mepc
    li   t3, 0x10000002
    csrw mepc, t3
    csrr t1, mepc
    li   t3, 0x10000001
    csrw mepc, t3
    csrr t1, mepc
    csrw mepc, x0
    csrr t1, mepc

    # ---- set and clear forms on mscratch -----------------------------------------
    li   t3, 0x0F0F0F0F
    csrs mscratch, t3
    csrr t1, mscratch
    li   t3, 0x00FF00FF
    csrc mscratch, t3
    csrr t1, mscratch
    csrrw t1, mscratch, t0
    csrrs t1, mscratch, x0
    csrrc t1, mscratch, x0
    csrrwi t1, mscratch, 21
    csrrsi t1, mscratch, 10
    csrrci t1, mscratch, 1
    csrr t1, mscratch

    # ---- mstatus: MIE and MPIE are the only storage; no interrupt is pending ----
    csrr t2, mstatus
    csrw mstatus, t0
    csrr t1, mstatus
    csrw mstatus, x0
    csrr t1, mstatus
    csrw mstatus, t2

    # ---- mret to an mepc written with bit 1 set: lands on the aligned address ---
    la   t3, landing
    addi t3, t3, 2
    csrw mepc, t3
    mret
    nop
landing:
    nop
    csrr t1, mepc

    RVTEST_PASS

RVTEST_CODE_END

    .data
RVTEST_DATA_BEGIN
RVTEST_DATA_END
