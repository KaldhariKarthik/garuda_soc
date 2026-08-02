# =============================================================================
# divrem_emu.S -- software DIV/DIVU/REM/REMU for GARUDA.
#
# WHY THIS EXISTS
# ---------------
# decode_control.v deliberately raises illegal_instr for the div family
# (Sec. 7.2): the hardware divider was omitted and the ISA contract is that
# software emulates it from the illegal-instruction trap. This file is that
# software. Without it, div/divu/rem/remu are not merely untested - they do
# not work at all, and riscv-tests div/divu/rem/remu cannot run.
#
# ENTRY CONTRACT
# --------------
# Reached from trap_vector with mcause == illegal instruction. On entry
# garuda_trap_regs[30] and [31] already hold the trapping values of t5/t6
# (trap_vector clobbers those two before it can do anything). Every other
# register still holds its trapping value and is saved here.
#
# Once all 31 registers are in memory, every register is free to use, which is
# what makes indexed access to rs1/rs2/rd possible at all - you cannot read
# "register number N" on RISC-V without a table.
#
# If the faulting instruction is NOT a div-family encoding, this routine jumps
# to garuda_emu_fail, which restores the context and falls back to the normal
# unhandled-trap reporting path. It must never silently swallow a real illegal
# instruction - rv32mi/illegal.S depends on that.
#
# RISC-V division semantics implemented (RV32M, "Division" table):
#   divisor == 0 :  DIV -> -1        DIVU -> 0xFFFFFFFF
#                   REM -> dividend  REMU -> dividend
#   overflow (-2^31 / -1) : DIV -> -2^31,  REM -> 0
# Both are architectural, not error cases: division never traps.
# =============================================================================

# ---- register-number -> memory offset ----
# These MUST be assembler macros, not cpp #defines: this file is pulled in with
# the assembler's `.include`, which runs after preprocessing, so cpp never sees
# it and `#define` would be emitted literally.
# CAUSE_* come from encoding.h, which is a cpp header -- and cpp never sees
# this file (see the note on RSAVE below). They are therefore restated here as
# assembler symbols. These three values are architectural and cannot drift.
        .equ GARUDA_CAUSE_ILLEGAL,   2
        .equ GARUDA_CAUSE_MISALIGN_L, 4
        .equ GARUDA_CAUSE_MISALIGN_S, 6

        .macro RSAVE n, r
        sw      \r, (\n*4)(s0)
        .endm
        .macro RLOAD n, r
        lw      \r, (\n*4)(s0)
        .endm

# Shared entry for every emulated trap. Saves the full context once, then
# dispatches on mcause. Both emulators need indexed register access, so both
# need the context in memory first - doing the save once keeps the two paths
# from drifting apart.
garuda_trap_emu:
        lla     s0, garuda_trap_regs        # s0 is saved below, so this is safe
        # x30/x31 were stored by trap_vector before it clobbered them.
        RSAVE 1, x1;  RSAVE 2, x2;  RSAVE 3, x3;  RSAVE 4, x4
        RSAVE 5, x5;  RSAVE 6, x6;  RSAVE 7, x7
        # x8 (s0) holds the base pointer now; recover the original from mscratch,
        # which trap_vector left free after its own use.
        RSAVE 9, x9;  RSAVE 10, x10; RSAVE 11, x11; RSAVE 12, x12
        RSAVE 13, x13; RSAVE 14, x14; RSAVE 15, x15; RSAVE 16, x16
        RSAVE 17, x17; RSAVE 18, x18; RSAVE 19, x19; RSAVE 20, x20
        RSAVE 21, x21; RSAVE 22, x22; RSAVE 23, x23; RSAVE 24, x24
        RSAVE 25, x25; RSAVE 26, x26; RSAVE 27, x27; RSAVE 28, x28
        RSAVE 29, x29
        csrr    t0, mscratch                # original x8, stashed by trap_vector
        RSAVE 8, t0

        # ---- dispatch on the cause ----
        csrr    t0, mcause
        li      t1, GARUDA_CAUSE_MISALIGN_L
        beq     t0, t1, garuda_misalign_emu
        li      t1, GARUDA_CAUSE_MISALIGN_S
        beq     t0, t1, garuda_misalign_emu
        li      t1, GARUDA_CAUSE_ILLEGAL
        bne     t0, t1, garuda_emu_fail

garuda_divrem_emu:
        # ---- fetch and decode the faulting instruction ----
        csrr    t0, mepc
        lw      t0, 0(t0)                   # instruction word

        andi    t1, t0, 0x7f
        li      t2, 0x33                    # OP (register-register)
        bne     t1, t2, garuda_emu_fail

        srli    t1, t0, 25
        andi    t1, t1, 0x7f
        li      t2, 0x01                    # funct7 = MULDIV
        bne     t1, t2, garuda_emu_fail

        srli    t3, t0, 12
        andi    t3, t3, 7                   # funct3: 4=DIV 5=DIVU 6=REM 7=REMU
        li      t2, 4
        blt     t3, t2, garuda_emu_fail     # 0..3 are MUL* -- hardware handles those

        # ---- read rs1 / rs2 through the saved context ----
        srli    t1, t0, 15
        andi    t1, t1, 31
        slli    t1, t1, 2
        add     t1, t1, s0
        lw      a0, 0(t1)                   # a0 = rs1 value  (dividend)

        srli    t1, t0, 20
        andi    t1, t1, 31
        slli    t1, t1, 2
        add     t1, t1, s0
        lw      a1, 0(t1)                   # a1 = rs2 value  (divisor)

        srli    a7, t0, 7
        andi    a7, a7, 31                  # a7 = rd number

        # ---- divide-by-zero: architectural results, no trap ----
        bnez    a1, 1f
        li      t2, 6
        blt     t3, t2, 0f                  # DIV/DIVU -> all ones / -1
        mv      a2, a0                      # REM/REMU -> dividend
        j       9f
0:      li      a2, -1
        j       9f

1:      # ---- signed overflow: -2^31 / -1 ----
        li      t2, 5
        bge     t3, t2, 2f                  # only DIV(4) and REM(6) are signed...
        j       3f
2:      li      t2, 6
        bne     t3, t2, 3f                  # ...so re-check: 6 = REM
3:      andi    t2, t3, 1                   # bit0 set => unsigned (DIVU/REMU)
        bnez    t2, 4f
        li      t2, 0x80000000
        bne     a0, t2, 4f
        li      t2, -1
        bne     a1, t2, 4f
        li      t2, 4
        beq     t3, t2, 30f                 # DIV  -> -2^31
        li      a2, 0                       # REM  -> 0
        j       9f
30:     li      a2, 0x80000000
        j       9f

4:      # ---- take absolute values for the signed forms, remember the signs ----
        li      t4, 0                       # t4 = negate quotient
        li      t5, 0                       # t5 = negate remainder
        andi    t2, t3, 1
        bnez    t2, 5f                      # unsigned: use operands as-is
        bgez    a0, 40f
        neg     a0, a0
        li      t4, 1
        li      t5, 1                       # remainder takes the dividend's sign
40:     bgez    a1, 5f
        neg     a1, a1
        xori    t4, t4, 1                   # quotient sign = sign(rs1) ^ sign(rs2)

5:      # ---- restoring shift-subtract divide: a0 / a1 -> t0 quo, t1 rem ----
        li      t0, 0
        li      t1, 0
        li      t2, 32
6:      slli    t1, t1, 1
        srli    a3, a0, 31
        or      t1, t1, a3
        slli    a0, a0, 1
        slli    t0, t0, 1
        bltu    t1, a1, 7f
        sub     t1, t1, a1
        ori     t0, t0, 1
7:      addi    t2, t2, -1
        bnez    t2, 6b

        # ---- pick quotient or remainder, reapply sign ----
        li      t2, 6
        blt     t3, t2, 8f                  # funct3 4/5 -> quotient
        mv      a2, t1
        beqz    t5, 9f
        neg     a2, a2
        j       9f
8:      mv      a2, t0
        beqz    t4, 9f
        neg     a2, a2

9:      # ---- write the result back into the saved context (x0 stays zero) ----
        beqz    a7, 10f
        slli    a7, a7, 2
        add     a7, a7, s0
        sw      a2, 0(a7)

10:     # ---- resume after the emulated instruction ----
        csrr    t0, mepc
        addi    t0, t0, 4
        csrw    mepc, t0
        j       garuda_emu_restore

# =============================================================================
# Misaligned load/store emulation (mcause 4 / 6).
#
# GARUDA traps misaligned data accesses by design rather than splitting them in
# hardware, so software has to complete them. Everything is done a BYTE AT A
# TIME - a byte access can never itself be misaligned, so this can never
# re-trap and cannot recurse.
#
# Only the widths that can actually misalign are handled: LH/LHU/LW, SH/SW.
# =============================================================================
garuda_misalign_emu:
        csrr    t0, mepc
        lw      t0, 0(t0)                   # instruction word
        andi    t1, t0, 0x7f
        li      t2, 0x03                    # LOAD
        beq     t1, t2, 1f
        li      t2, 0x23                    # STORE
        beq     t1, t2, 2f
        j       garuda_emu_fail

        # ---------------- LOAD: imm = instr[31:20] ----------------
1:      srai    a1, t0, 20                  # sign-extended I-immediate
        srli    t1, t0, 15
        andi    t1, t1, 31
        slli    t1, t1, 2
        add     t1, t1, s0
        lw      a0, 0(t1)
        add     a0, a0, a1                  # effective address
        srli    t3, t0, 12
        andi    t3, t3, 7                   # funct3

        lbu     a2, 0(a0)
        lbu     a3, 1(a0)
        slli    a3, a3, 8
        or      a2, a2, a3

        andi    t1, t3, 3
        li      t2, 2
        beq     t1, t2, 11f                 # LW needs two more bytes
        li      t2, 5
        beq     t3, t2, 12f                 # LHU: already zero-extended
        slli    a2, a2, 16                  # LH: sign-extend from bit 15
        srai    a2, a2, 16
        j       12f
11:     lbu     a3, 2(a0)
        slli    a3, a3, 16
        or      a2, a2, a3
        lbu     a3, 3(a0)
        slli    a3, a3, 24
        or      a2, a2, a3
12:     srli    a7, t0, 7
        andi    a7, a7, 31                  # rd
        beqz    a7, 3f
        slli    a7, a7, 2
        add     a7, a7, s0
        sw      a2, 0(a7)
        j       3f

        # ---------------- STORE: imm = {instr[31:25], instr[11:7]} ----------
2:      srai    a1, t0, 25
        slli    a1, a1, 5
        srli    t1, t0, 7
        andi    t1, t1, 31
        or      a1, a1, t1                  # full S-immediate
        srli    t1, t0, 15
        andi    t1, t1, 31
        slli    t1, t1, 2
        add     t1, t1, s0
        lw      a0, 0(t1)
        add     a0, a0, a1                  # effective address
        srli    t1, t0, 20
        andi    t1, t1, 31
        slli    t1, t1, 2
        add     t1, t1, s0
        lw      a2, 0(t1)                   # rs2 value
        srli    t3, t0, 12
        andi    t3, t3, 7

        sb      a2, 0(a0)
        srli    a3, a2, 8
        sb      a3, 1(a0)
        li      t2, 2
        bne     t3, t2, 3f                  # SH done
        srli    a3, a2, 16
        sb      a3, 2(a0)
        srli    a3, a2, 24
        sb      a3, 3(a0)

3:      csrr    t0, mepc
        addi    t0, t0, 4
        csrw    mepc, t0
        j       garuda_emu_restore

garuda_emu_fail:
        # Not a div-family encoding: hand it back as a genuine unhandled trap.
        lla     s0, garuda_trap_regs
        RLOAD 8, x8
        j       garuda_unhandled

garuda_emu_restore:
        lla     s0, garuda_trap_regs
        RLOAD 1, x1;  RLOAD 2, x2;  RLOAD 3, x3;  RLOAD 4, x4
        RLOAD 5, x5;  RLOAD 6, x6;  RLOAD 7, x7
        RLOAD 9, x9;  RLOAD 10, x10; RLOAD 11, x11; RLOAD 12, x12
        RLOAD 13, x13; RLOAD 14, x14; RLOAD 15, x15; RLOAD 16, x16
        RLOAD 17, x17; RLOAD 18, x18; RLOAD 19, x19; RLOAD 20, x20
        RLOAD 21, x21; RLOAD 22, x22; RLOAD 23, x23; RLOAD 24, x24
        RLOAD 25, x25; RLOAD 26, x26; RLOAD 27, x27; RLOAD 28, x28
        RLOAD 29, x29; RLOAD 30, x30; RLOAD 31, x31
        RLOAD 8, x8                       # base pointer last
        mret

        .pushsection .data
        .align 4
        .globl garuda_trap_regs
garuda_trap_regs:
        .space 128                          # x0..x31, indexed by register number
        .popsection
