# =============================================================================
# boot6.S - the first six instructions ever executed by GARUDA silicon RTL.
#
# No crt0, no stack, no C. This is the smallest program that proves the fetch
# path, the decoder, the ALU, the forwarding network and the D-port store path
# all work at once, and it self-reports through tohost.
#
# Expected commit log (PC, rd, value) - hand-checked, this is the golden
# reference for the very first run:
#   10000000 x1 = 00000005
#   10000004 x2 = 00000007
#   10000008 x3 = 0000000c    <- needs BOTH EX-stage forwards
#   1000000c x4 = 1000f000
#   10000010 x5 = 00000001
#   10000014 (store, no rd)   <- tohost = 1 -> PASS
#
# Instruction 3 is the load-bearing one: x1 and x2 are written by the two
# immediately preceding instructions, so it can only produce 0xc if MEM->EX
# and WB->EX forwarding both work. A core with broken forwarding produces
# 0x0 here and still "runs".
# =============================================================================

    .section .text.init, "ax"
    .global _start
_start:
    addi    x1, x0, 5           # x1 = 5
    addi    x2, x0, 7           # x2 = 7
    add     x3, x1, x2          # x3 = 12   (back-to-back RAW, both forwards)
    lui     x4, 0x1000f         # x4 = 0x1000f000 (tohost)
    addi    x5, x0, 1           # x5 = 1    (pass code)
    sw      x5, 0(x4)           # tohost = 1 -> testbench prints PASSED

hang:
    j       hang
