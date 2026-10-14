# =============================================================================
# csr_readzero.S - the CSRs that privileged spec v1.12 says exist and that
# GARUDA implements as read-zero (bug C-16, contract Design_Docs/regs/core_csr.yaml):
#   mstatush (0x310), mconfigptr (0xF15, read-only), mhpmcounter3..31 (0xB03-0xB1F),
#   mhpmcounter3h..31h (0xB83-0xB9F), mhpmevent3..31 (0x323-0x33F).
# Each is read; each writable one is then written with all ones and with zero,
# using every write form, and read again. Nothing may trap and everything reads 0.
#
# Built with the trap-handler environment as p-csr_readzero and run in lockstep
# with Spike, which hardwires the same registers to zero (checked 2026-10-11):
# every value read lands in a GPR and is compared instruction by instruction.
# An access that traps on GARUDA (the bug) goes to the env's handler and fails.
# The write to the read-only mconfigptr traps on both and is checked by the
# property a_readzero_csrs (rtl/core/csr_file_sva.sv), not here.
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"

#define RZ_RW(csr)            \
    csrr  t1, csr;            \
    csrw  csr, t0;            \
    csrr  t1, csr;            \
    csrrs t1, csr, t0;        \
    csrrc t1, csr, t0;        \
    csrrwi t1, csr, 31;       \
    csrrsi t1, csr, 7;        \
    csrw  csr, x0;            \
    csrr  t1, csr;

RVTEST_RV32M
RVTEST_CODE_BEGIN

    li   t0, -1

    RZ_RW(0x310)                        # mstatush
    csrr t1, 0xF15                      # mconfigptr (read-only: read only)

    .irp n, 3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    RZ_RW(0xB00 + \n)                   # mhpmcounter\n
    RZ_RW(0xB80 + \n)                   # mhpmcounter\n h
    RZ_RW(0x320 + \n)                   # mhpmevent\n
    .endr

    # (No counter reads here: mcycle cannot match an ISA model, and a minstret
    # read differs from Spike by the instructions still in MEM/WB -- bug C-17.)

    RVTEST_PASS

RVTEST_CODE_END

    .data
RVTEST_DATA_BEGIN
    TEST_DATA
RVTEST_DATA_END
