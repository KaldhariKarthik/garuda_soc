/* t_chip_jtag.c - tiny image loaded over JTAG SBA by tb_chip (+MODE=jtag).
 * Proves the development loop of DEBUG-SPEC §7.6: halt, load ISRAM through
 * System Bus Access, post the mailbox, resume, run. */
#include "chip.h"
uint32_t trap_handler(uint32_t mcause, uint32_t mepc) { (void)mcause; return mepc + 4; }
int main(void)
{
    volatile uint32_t x = 6, y = 7;
    return (x * y == 42u) ? 0 : 1;
}
