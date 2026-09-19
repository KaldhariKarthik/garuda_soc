/* =============================================================================
 * t_chip_wdt.c - a real watchdog reset of the whole chip (t_wdt_req_survives,
 * TIMERS §7.6, CLKRST §8.3). Run 1: arm the watchdog, leave a marker in the
 * no-init DSRAM area, hang. The chip resets for the full stretch; SRAM is not
 * reset. Run 2 (testbench re-posts the mailbox): RSTREASON must read WDT and
 * the marker must have survived; the watchdog must have restarted disabled.
 * ========================================================================== */
#include "chip.h"

__attribute__((section(".noinit"))) volatile uint32_t marker;

uint32_t trap_handler(uint32_t mcause, uint32_t mepc) { (void)mcause; return mepc + 4; }

int main(void)
{
    uint32_t why = RSTREASON & 0x1Fu;
    if (why == 0x2u) {                                 /* second run */
        if (marker != 0x0DD0D06Eu) return 2;
        if (WDTCTL & 1u)           return 3;           /* restarts disabled */
        RSTREASON = 0x1Fu;                             /* W1C */
        if (RSTREASON & 0x1Fu)     return 4;
        marker = 0;
        return 0;
    }
    if (why != 0x1u) return 1;
    marker  = 0x0DD0D06Eu;
    WDTLOAD = 3000;
    WDTCTL  = 1u;
    for (;;) ;                                         /* never kick */
}
