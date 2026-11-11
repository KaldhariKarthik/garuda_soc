# =============================================================================
# crt0_bench.S -- start-up for sw/bench (plan 5.7): sw/common/crt0.S plus
# zeroing x1..x31 first.
#
# The register file has no reset (CORE spec, ID stage: "no reset"), so a
# register the program never wrote reads X in simulation. Compiled C saves and
# restores callee-saved registers it may never have written (bench_printf's
# prologue saves s1..s6); the RTL then stores and reloads X where Spike, whose
# registers start at 0, has 0, and the lockstep comparison cannot read the
# value. riscv-tests' benchmarks/common/crt.S zeroes them for the same reason.
# =============================================================================
    .section .text.init, "ax"
    .global _start
    .type   _start, @function
_start:
    .irp r, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li      x\r, 0
    .endr
    lla     sp, _stack_top
    lla     t0, _bss_start
    lla     t1, _bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
    li      a0, 0                   # argc
    li      a1, 0                   # argv
    call    main
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
    j       hang
    .size _start, . - _start
