# =============================================================================
# GARUDA SoC - crt0.S : C runtime startup for bare-metal tests
#
# Runs at the reset vector (0x1000_0000). Responsibilities, in order:
#   1. establish a stack
#   2. zero .bss  (C code assumes it)
#   3. call main()
#   4. convert main's return value into the tohost pass/fail handshake
#
# NOTE ON GP: no .sdata relaxation is set up (no __global_pointer$ init), so
# the tests must be built without -mrelax gp-relative addressing. The Makefile
# passes -mno-relax for exactly this reason. If that flag is ever dropped,
# small-data accesses silently address off a zero gp and the failure looks
# like a load/store bug in the core, which is a very expensive false lead.
#
# NOTE ON `lla` vs `la`: the Vitis GCC in use defaults to PIC, where `la`
# expands to `auipc; lw` through the GOT. On bare metal nothing populates the
# GOT, so `la t0, tohost` loaded ZERO and the pass/fail store went to address
# 0. The core executed that sequence perfectly - it is a build bug that reads
# exactly like a load bug. `lla` always expands to auipc+addi (PC-relative,
# no GOT) and the Makefile also passes -fno-pic. Do not "simplify" these
# back to `la`.
# =============================================================================

    .section .text.init, "ax"
    .global _start
    .type   _start, @function

_start:
    # ---- 1. stack ----
    lla     sp, _stack_top

    # ---- 2. zero .bss ----
    lla     t0, _bss_start
    lla     t1, _bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    # ---- 3. main() ----
    li      a0, 0                   # argc
    li      a1, 0                   # argv
    call    main

    # ---- 4. exit ----
    # main() returns 0 for pass. tohost protocol: 1 = pass, (n<<1)|1 = fail n.
    beqz    a0, pass
    slli    a0, a0, 1
    ori     a0, a0, 1
    j       write_tohost
pass:
    li      a0, 1

write_tohost:
    lla     t0, tohost
    sw      a0, 0(t0)

hang:
    # The testbench terminates on the tohost write; this loop only exists so
    # the core has something architecturally defined to do if it does not.
    j       hang

    .size _start, . - _start
