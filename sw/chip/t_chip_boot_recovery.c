/* t_chip_boot_recovery.c - memories vPlan F15-F18, F20, F21 (Track A, 2026-11-01): what the chip
 * looks like after a failed boot. tb_chip +MODE=bootfault puts a fault in the boot flash (a flipped
 * bit, a blank part, a bad header field, a stuck MISO, a flash that stops, a bus error on the SPI
 * master), waits for the Boot ROM to report BOOTFAIL, then loads THIS program over JTAG SBA and posts
 * the recovery mailbox, as a debugger would (F16). The program checks the state the ROM left:
 *   1  RSTREASON.BOOTFAIL is set (GARUDA-MEM-SPEC-001 8.2 steps 5, 6, 9; [N-8.12] for a trap)
 *   2  MEMCTL.ILOCK is clear (8.2 step 12: recovery leaves ISRAM unlocked)
 *   3  the core can write ISRAM (the lock really is off), and reads the word back
 *   4  BOOTFAIL is W1C: firmware can clear it (CLKRST [N-6.2])
 * Returns 0 = pass, otherwise the failed step. */
#include "chip.h"

#define BOOTFAIL        (1u << 4)          /* RSTREASON / MEMCTL come from chip.h */

uint32_t trap_handler(uint32_t mcause, uint32_t mepc) { (void)mcause; return mepc + 4; }

int main(void)
{
    if (!(RSTREASON & BOOTFAIL)) return 1;
    if (MEMCTL & 1u)             return 2;
    volatile uint32_t *probe = (volatile uint32_t *)(uintptr_t)(GARUDA_ISRAM_BASE + 0xF000u);
    *probe = 0xB007FA11u;
    if (*probe != 0xB007FA11u)   return 3;
    RSTREASON = BOOTFAIL;                         /* W1C */
    if (RSTREASON & BOOTFAIL)    return 4;
    return 0;
}
