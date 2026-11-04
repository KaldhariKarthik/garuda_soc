/* t_chip_jtag_ilock.c - memories vPlan F10-F13 at chip level (Track A, 2026-10-16), with the
 * debugger (tb_chip +MODE=jtagilck):
 *   2  an unlocked ISRAM store works            5  a store to locked ISRAM faults (mcause 7)
 *   3  MEMCTL.ILOCK sets on a write of 1         6  ... and changes nothing
 *   4  a write of 0 does not clear it (sticky)   7  the debugger's SBA write lands in locked ISRAM
 * Returns 0 = pass, otherwise the failed step. */
#include "chip.h"
static volatile uint32_t cause;
uint32_t trap_handler(uint32_t mcause, uint32_t mepc) { cause = mcause; return mepc + 4; }
int main(void)
{
    volatile uint32_t *w = (volatile uint32_t *)0x8000u;
    w[0] = 0x11111111u; w[1] = 0u;
    if (w[0] != 0x11111111u) return 2;
    MEMCTL = 1u;
    if ((MEMCTL & 1u) == 0u) return 3;
    MEMCTL = 0u;
    if ((MEMCTL & 1u) == 0u) return 4;
    cause = 0u;
    w[0] = 0x22222222u;
    if (cause != 7u) return 5;
    if (w[0] != 0x11111111u) return 6;
    REG(0x20008010u) = 1u;                         /* tell the debugger: locked, waiting */
    for (uint32_t t = 0; t < 400000u && w[1] != 0x5BA05BA0u; t++) ;
    if (w[1] != 0x5BA05BA0u) return 7;
    return 0;
}
