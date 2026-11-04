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
    # ERRATUM MEM-1 (fixed 2026-11-01): [N-8.12] says any exception during boot sets
    # RSTREASON.BOOTFAIL; this handler went to recovery without it, so a debugger could not
    # tell a boot that trapped from boot_sel = 1. RSTCTL = (RSTCTL & DIVSEL) | BOOTFAIL, as
    # boot_fail() does; after the mailbox record, so a fault here still leaves the record.
    li      t0, 0x40009000          # GARUDA_APB_BASE_RESET_CTRL
    lw      t1, 4(t0)
    andi    t1, t1, 0x300           # keep DIVSEL
    ori     t1, t1, 0x10            # BOOTFAIL
    sw      t1, 4(t0)
    li      sp, 0x2000FF00
    j       boot_recovery
