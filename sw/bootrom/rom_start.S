# =============================================================================
# GARUDA Boot ROM - reset entry and trap handler
# GARUDA-MEM-SPEC-001 §8.2; CORE-SPEC [N-7.34] (mtvec is uninitialised at reset,
# so the ROM installs its own handler before touching anything).
#
# A trap inside the ROM records mcause / mepc in the JTAG mailbox words 2..3
# and enters the recovery loop, so a board that faults during boot is still
# recoverable over JTAG (ADR-0016: never a dead halt).
# =============================================================================
    .section .text.init, "ax"
    .global _rom_start
_rom_start:
    lla     t0, rom_trap
    csrw    mtvec, t0
    li      sp, 0x2000FF00          # top of DSRAM, below the mailbox (D-20)
    call    boot_main
    j       boot_recovery           # boot_main never returns; belt and braces

    .align 2
rom_trap:
    li      t0, 0x2000FFF0          # mailbox
    csrr    t1, mcause
    sw      t1, 8(t0)
    csrr    t1, mepc
    sw      t1, 12(t0)
    li      sp, 0x2000FF00
    j       boot_recovery
