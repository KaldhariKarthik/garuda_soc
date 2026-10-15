# t_core_mret_buserr.S -- T-13: a load bus error directly in front of an MRET.
# A precise core must take the load access fault (mcause 5, mepc = the lw).
# If the fault is dropped, the MRET runs and lands on `dropped` -> FAIL test 1.
# Run on tb_boot with +ERR_EN=1 +ERR_BASE=10020000 +ERR_SIZE=1000 (tb/core/run/directed.toml).
# Found by the free-tool audit 2026-10-05 (lead L1); bug Docs/bugs/core.md T-13.
#define ERR_ADDR 0x10020000
    .section .text.init, "ax"
    .global _start
_start:
    lla     t0, trap_vector
    csrw    mtvec, t0
    li      x21, 0                      # last mcause
    lla     t0, dropped
    csrw    mepc, t0                    # where the MRET goes if the fault vanishes
    li      x10, ERR_ADDR
    li      x11, 0xdeadbeef
the_load:
    lw      x11, 0(x10)                 # bus error (tb_boot +ERR_EN region)
    mret                                # in EX when the ERROR response returns
    li      a0, 5                       # (fall-through: FAIL code 5)
    j       done
dropped:
    li      a0, 3                       # MRET executed instead of the trap: FAIL test 1
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
    li      a0, 1                       # PASS
done:
    lla     t0, tohost
    sw      a0, 0(t0)
1:  j 1b
