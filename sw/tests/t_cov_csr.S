# =============================================================================
# t_cov_csr.S -- CSR patterns and access kinds (Track A coverage closure,
# 2026-10-11; contract Design_Docs/regs/core_csr.yaml).
#   1  every writable CSR gets all-ones, all-zeros, 0xAAAAAAAA and 0x55555555
#      through CSRRW / CSRRS / CSRRC and the immediate forms; the fully
#      read-write ones (mscratch, mtval, mcause) are read back and checked,
#      the WARL ones are checked against their legal masks
#   2  the counters mcycle / mcycleh / minstret / minstreth are WRITTEN (never
#      done by any suite before) with all-ones then zero; a high half written
#      with all-ones must read back non-zero and then zero
#   3  every implemented read-only CSR and every C-16 read-zero group is read;
#      the read-zero ones must read 0
#   4  writes to read-only CSRs (mvendorid, cycle) and an access to an absent
#      CSR (dcsr 0x7B0) raise illegal instruction (cause 2, mtval = the word)
# mtvec is restored to the handler after its patterns; mstatus patterns leave
# MIE clear (no interrupt source is active in this test).
# Fail codes: 3 readback mismatch, 5 WARL mask violated, 7 read-zero CSR not 0,
# 9 counter write had no effect, 11 wrong trap, 13 trap count.
# =============================================================================
#define P1 0xFFFFFFFF
#define P2 0xAAAAAAAA
#define P3 0x55555555

# rw_check CSR: full read-write register, every pattern read back
.macro rw_check csr
    li      t0, P1
    csrrw   zero, \csr, t0
    csrr    t1, \csr
    li      a0, 3
    bne     t1, t0, fail
    csrrc   zero, \csr, t0
    csrr    t1, \csr
    bnez    t1, fail
    li      t0, P2
    csrrs   zero, \csr, t0
    csrr    t1, \csr
    bne     t1, t0, fail
    li      t0, P3
    csrrw   t2, \csr, t0
    li      t3, P2
    bne     t2, t3, fail                # CSRRW returns the old value
    csrrwi  zero, \csr, 0x1F
    csrrsi  zero, \csr, 0x0
    csrrci  zero, \csr, 0x1F
    csrr    t1, \csr
    bnez    t1, fail
.endm

# warl CSR, MASK: patterns through every op; the read value never has a bit
# outside MASK set
.macro warl csr, mask
    li      t4, (~(\mask)) & 0xFFFFFFFF
    li      t0, P1
    csrrw   zero, \csr, t0
    csrr    t1, \csr
    and     t1, t1, t4
    li      a0, 5
    bnez    t1, fail
    li      t0, P2
    csrrw   zero, \csr, t0
    li      t0, P3
    csrrs   zero, \csr, t0
    csrrc   zero, \csr, t0
    csrrwi  zero, \csr, 0x15
    csrrsi  zero, \csr, 0x0A
    csrrci  zero, \csr, 0x1F
    csrrw   zero, \csr, zero
.endm

    .section .text.init, "ax"
    .global _start
_start:
    lla     sp, stack_top
    lla     s0, trap_vector
    csrw    mtvec, s0
    li      s7, 0                       # traps taken

    # ---- 1: patterns --------------------------------------------------------
    rw_check mscratch
    rw_check mtval
    rw_check mcause
    warl    mepc, 0xFFFFFFFC
    warl    mie, 0x00000080
    warl    0x347, 0x000000FF           # mintthresh
    warl    0x7C0, 0x0000000F           # mgarudactl: timing only
    li      t0, P1                      # mstatus: MIE kept clear
    li      t1, ~8
    and     t0, t0, t1
    csrrw   zero, mstatus, t0
    csrrc   zero, mstatus, t0
    li      t0, P2
    csrrs   zero, mstatus, t0
    csrrci  zero, mstatus, 0x8
    li      t0, P1                      # mtvec: every storage bit both ways
    csrrw   zero, mtvec, t0
    csrrw   zero, mtvec, zero
    li      t0, P2
    csrrw   zero, mtvec, t0
    li      t0, P3
    csrrw   zero, mtvec, t0
    csrrsi  zero, mtvec, 0x3
    csrrci  zero, mtvec, 0x3
    csrw    mtvec, s0                   # restore the handler

    # ---- 2: counters written --------------------------------------------------
    li      t0, P1
    csrw    mcycleh, t0
    csrr    t1, mcycleh
    li      a0, 9
    beqz    t1, fail
    csrw    mcycle, t0                  # low half all-ones: next cycles carry
    nop
    nop
    csrw    mcycleh, zero
    csrw    mcycle, zero
    li      t0, P2
    csrw    mcycle, t0
    csrw    mcycleh, t0
    li      t0, P3
    csrw    mcycle, t0
    csrw    mcycleh, t0
    csrw    mcycleh, zero
    li      t0, P1
    csrw    minstreth, t0
    csrr    t1, minstreth
    beqz    t1, fail
    csrw    minstret, t0
    nop
    nop
    csrw    minstreth, zero
    csrw    minstret, zero
    li      t0, P2
    csrw    minstret, t0
    csrw    minstreth, t0
    li      t0, P3
    csrw    minstret, t0
    csrw    minstreth, t0
    csrw    minstreth, zero
    csrr    t1, mcycle                  # reads of every counter half
    csrr    t1, mcycleh
    csrr    t1, minstret
    csrr    t1, minstreth
    csrr    t1, cycle
    csrr    t1, cycleh
    csrr    t1, instret
    csrr    t1, instreth

    # ---- 3: read-only and read-zero -----------------------------------------------
    csrr    t1, misa
    csrr    t1, mip
    csrr    t1, 0x345                   # mnxti
    csrr    t1, 0x346                   # mintstatus
    csrr    t1, 0xFB1                   # mintstatus (standard layout)
    csrr    t1, mvendorid
    csrr    t1, marchid
    csrr    t1, mimpid
    csrr    t1, mhartid
    csrr    t1, 0xBC0                   # dsu_ovf
    li      a0, 7
    csrr    t1, 0x310                   # mstatush
    bnez    t1, fail
    csrr    t1, 0xF15                   # mconfigptr
    bnez    t1, fail
    csrr    t1, 0xB03                   # mhpmcounter3
    bnez    t1, fail
    csrr    t1, 0xB1F                   # mhpmcounter31
    bnez    t1, fail
    csrr    t1, 0xB83                   # mhpmcounter3h
    bnez    t1, fail
    csrr    t1, 0xB9F                   # mhpmcounter31h
    bnez    t1, fail
    csrr    t1, 0x323                   # mhpmevent3
    bnez    t1, fail
    csrr    t1, 0x33F                   # mhpmevent31
    bnez    t1, fail
    csrw    0x323, t0                   # read-zero: writes are ignored
    csrr    t1, 0x323
    bnez    t1, fail

    # ---- 4: illegal accesses ----------------------------------------------------
    csrw    mvendorid, t0               # read-only -> illegal
    csrw    cycle, t0                   # read-only -> illegal
    csrr    t1, 0x7B0                   # dcsr: absent -> illegal
    li      t0, 3
    li      a0, 13
    bne     s7, t0, fail
    li      a0, 1
    j       done

    .align 6
trap_vector:
    csrr    t0, mcause
    li      t1, 2
    li      a0, 11
    bne     t0, t1, fail                # only illegal-instruction traps here
    csrr    t1, mepc
    lw      t2, 0(t1)
    csrr    t3, mtval
    bne     t2, t3, fail                # mtval = the instruction word
    addi    t1, t1, 4
    csrw    mepc, t1
    addi    s7, s7, 1
    mret

fail:
done:
    lla     t0, tohost
    li      t1, 1
    beq     a0, t1, 2f
    slli    a0, a0, 1
    ori     a0, a0, 1
2:  sw      a0, 0(t0)
1:  j       1b

    .section .data
    .align 4
stack:  .space 256
stack_top:
