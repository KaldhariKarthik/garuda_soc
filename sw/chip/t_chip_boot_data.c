/* t_chip_boot_data.c - memories vPlan F14 data path (Track A, 2026-11-01): booted from SPI flash
 * with a 256-byte DATA image (sw/build/flash_data.hex, built by `make boot_images`). The Boot ROM
 * copies it to DSRAM_BASE (8.2 step 8) and checks DATA_CRC (step 9) before the jump. This program
 * has no globals, so crt0 neither copies .data nor clears .bss over that area; it checks the
 * 64 words the ROM placed. Returns 0 = pass, or 1 + the first wrong word. */
#include "chip.h"
uint32_t trap_handler(uint32_t mcause, uint32_t mepc) { (void)mcause; return mepc + 4; }
int main(void)
{
    volatile uint32_t *d = (volatile uint32_t *)(uintptr_t)GARUDA_DSRAM_BASE;
    for (uint32_t i = 0; i < 64; i++)
        if (d[i] != ((i * 0x9E3779B1u) ^ 0x5A5A5A5Au)) return (int)(1 + i);
    return 0;
}
