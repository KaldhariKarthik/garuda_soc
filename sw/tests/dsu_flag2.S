# =============================================================================
# dsu_flag2.S - FLAG-2 reproduction: DSU compute -> accumulator read ordering.
#
# THE QUESTION THIS TEST ANSWERS
# ------------------------------
# mac_unit is a 2-cycle pipeline (CSA1 -> sum/carry reg -> CSA2 -> Kogge-Stone),
# so a compute issued in cycle T does not land in `acc` until T+2.
# dsu_stall.v interlocks a read against the PREVIOUS instruction only when that
# previous instruction was itself 2-cycle:
#
#     cur_is_2cycle = MACRD_LO | MACRD_HI | MACSAT
#
# The compute ops - MAC_SEL, MACSUB, MACABS, MACDOT - are NOT in that set. So
# a compute immediately followed by a read of the same accumulator is not
# interlocked, and the read is architecturally free to observe the accumulator
# before the compute has landed in it.
#
# This test makes that concrete rather than theoretical. Both halves do the
# identical arithmetic; they differ ONLY in instruction spacing:
#
#   acc0: MACCLEAR, MAC_SEL(3,5), MACRD_LO        <- read immediately after
#   acc1: MACCLEAR, MAC_SEL(3,5), nop x3, MACRD_LO <- read after 3 independent
#
# Both must produce 15 (3*5 + 0*0). If the immediate read returns anything else
# while the spaced read returns 15, FLAG-2 is real in the assembled pipeline and
# the difference is pure instruction ordering.
#
# Results are stored to memory (not compared here) so the value is reported
# rather than merely pass/fail - the actual stale value is the diagnostic.
#
# Custom-0 encoding (rtl/dsu/dsu_decoder.v):
#   opcode = 0x0b, funct3 = 000 (R-type)
#   funct7 = {funct5[4:0], acc_sel[1:0]}   <- .insn r func7 field
# =============================================================================

#define DSU_R(f5, acc, rd, rs1, rs2) .insn r 0x0b, 0, ((f5) << 2) | (acc), rd, rs1, rs2

#define F5_MAC_SEL  0
#define F5_MACCLEAR 5
#define F5_MACRD_LO 7

    .section .text.init, "ax"
    .global _start
_start:
    lla     x20, results

    li      x1, 3
    li      x2, 5

    # ---------------- acc0: read IMMEDIATELY after the compute ----------
    DSU_R(F5_MACCLEAR, 0, x0, x0, x0)
    DSU_R(F5_MAC_SEL,  0, x0, x1, x2)
    DSU_R(F5_MACRD_LO, 0, x5, x0, x0)      # <-- no gap: the FLAG-2 case
    sw      x5, 0(x20)

    # ---------------- acc1: read after 3 independent instructions -------
    DSU_R(F5_MACCLEAR, 1, x0, x0, x0)
    DSU_R(F5_MAC_SEL,  1, x0, x1, x2)
    nop
    nop
    nop
    DSU_R(F5_MACRD_LO, 1, x6, x0, x0)      # <-- spaced: the "correct" case
    sw      x6, 4(x20)

    # ---------------- re-read acc0 late, to prove the value DID land ----
    # If this returns 15 while the immediate read did not, the accumulator
    # was never wrong - only the read was early.
    DSU_R(F5_MACRD_LO, 0, x7, x0, x0)
    sw      x7, 8(x20)

    # Report through tohost. PASS only if the immediate read already saw 15.
    li      x8, 15
    bne     x5, x8, flag2_confirmed
    li      a0, 1                           # immediate read correct -> no FLAG-2
    j       done
flag2_confirmed:
    li      a0, 3                           # tohost fail code 1 -> FLAG-2 real
done:
    lla     t0, tohost
    sw      a0, 0(t0)
1:  j 1b

    .section .data
    .align 4
    .global results
results:
    .word 0, 0, 0
