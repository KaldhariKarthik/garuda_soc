/* t_chip_jtag_bulk.c - debug vPlan F34 (Track A, 2026-10-16): a bulk load over JTAG. tb_chip
 * (+MODE=jtagbulk) streams this program and then 1024 data words to ISRAM 0x8000 with
 * sbautoincrement, the loop a full 16384-word image uses; the firmware checks every word.
 * Returns 0, or 1 + the index of the first wrong word. */
#include "chip.h"
uint32_t trap_handler(uint32_t mcause, uint32_t mepc) { (void)mcause; return mepc + 4; }
int main(void)
{
    volatile uint32_t *d = (volatile uint32_t *)0x8000u;
    for (uint32_t i = 0; i < 1024u; i++)
        if (d[i] != ((i * 0x9E3779B1u) ^ 0xA5A5A5A5u)) return (int)(i + 1u);
    return 0;
}
