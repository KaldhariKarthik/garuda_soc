# t_core_wfi_buserr.S -- T-14: a load bus error directly in front of a WFI.
# The WFI is younger than the faulting load, so a precise core squashes it and runs
# the handler at once. No interrupt is ever enabled or raised: if the handler only
# runs after a wake, this test TIMES OUT (the core sleeps in the handler).
# Run on tb_boot with the +ERR_EN window (tb/core/run/directed.toml).
# Found by the free-tool audit 2026-10-05 (lead L2); bug Docs/bugs/core.md T-14.
#define ERR_ADDR 0x10020000
    .section .text.init, "ax"
    .global _start
_start:
    lla     t0, trap_vector
    csrw    mtvec, t0
    csrw    mie, zero
    csrci   mstatus, 8                  # MIE = 0, nothing can wake a WFI
    li      x10, ERR_ADDR
the_load:
    lw      x11, 0(x10)                 # bus error
    wfi                                 # younger than the faulting load
    li      a0, 5                       # (should never get here) FAIL code 5
    j       done
    .align 6
trap_vector:
    csrr    x21, mcause
    li      t1, 5
    li      a0, 7                       # wrong mcause: FAIL code 7
    bne     x21, t1, done
    csrr    t2, mepc
    lla     t3, the_load
    li      a0, 9                       # wrong mepc: FAIL code 9
    bne     t2, t3, done
    li      a0, 1                       # PASS: handler ran without a wake
done:
    lla     t0, tohost
    sw      a0, 0(t0)
1:  j 1b
