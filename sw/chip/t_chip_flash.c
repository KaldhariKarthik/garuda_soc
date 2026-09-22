/* =============================================================================
 * t_chip_flash.c - proof that the chip booted itself out of SPI flash.
 *
 * Every other chip test is placed in ISRAM by the testbench and entered through
 * the recovery mailbox. This one is never placed anywhere: the Boot ROM reads
 * it word by word off the SPI bus, checks its CRC, and jumps to it. So merely
 * arriving in main() already proves boot.c steps 3-11 and tools/mkbootimg.py
 * agree with sw/bootrom/spim.c about byte order - a CRC over a byte-swapped
 * image does not accidentally match.
 *
 * What is left to check is what reaching main() does NOT prove.
 * Returns 0 = pass, n = failed step n.
 * ========================================================================== */
#include "chip.h"

/* Initialised data and rodata travel through the flash as part of the ISRAM
 * blob, so a byte-order or length error that the CRC somehow survived would
 * still show up as a wrong value here. */
volatile uint32_t   g_data   = 0xC0FFEE01u;
volatile uint32_t   g_bss;
static const char   g_str[]  = "GARUDA";

#define SPIM(off)   (*(volatile uint32_t *)(uintptr_t)(GARUDA_APB_BASE_SPI_MASTER + (off)))
#define SPIM_STATUS 0x000u
#define SPIM_SPICMD 0x008u
#define SPIM_SPIADR 0x00Cu
#define SPIM_SPILEN 0x010u
#define SPIM_RXFIFO 0x020u
#define SPIM_ID     0xFECu

/* No trap is expected anywhere in this test; count any that happens and step
 * over it so the failure surfaces as a wrong step number, not a hang. */
volatile uint32_t exc_count;

uint32_t trap_handler(uint32_t mcause, uint32_t mepc)
{
    exc_count++;
    return (mcause & MCAUSE_INT) ? mepc : mepc + 4;
}

int main(void)
{
    /* 1: this is a cold flash boot, not the recovery path */
    if (CLKSTAT & (1u << 8))                        return 1;   /* boot_sel low */
    if ((RSTREASON & 0x1F) != 0x1)                  return 1;   /* EXT only */
    if (RSTCTL & (1u << 4))                         return 1;   /* no BOOTFAIL */

    /* 2: running from ISRAM, out of the copy the ROM made */
    if ((uintptr_t)&main >= GARUDA_ISRAM_BASE + (64u << 10)) return 2;

    /* 3: .data arrived intact and .bss was cleared by crt0 */
    if (g_data != 0xC0FFEE01u)                      return 3;
    if (g_bss  != 0u)                               return 3;
    if (g_str[0] != 'G' || g_str[5] != 'A' || g_str[6] != '\0') return 3;

    /* 4: ILOCK is set - boot.c closes ISRAM behind itself before jumping */
    if (!(MEMCTL & 1u))                             return 4;

    /* 5: the SPI master is still there and identifies itself */
    if (SPIM(SPIM_ID) != 0x6A5D0D01u)               return 5;

    /* 6: and still works after boot - re-read the image header from flash and
     *    check the magic, which means the ROM's driver is usable by the
     *    application too, not just once during boot. */
    {
        uint32_t w, spin = 20000u;
        SPIM(SPIM_SPICMD) = 0x03u << 24;
        SPIM(SPIM_SPIADR) = 0u;
        SPIM(SPIM_SPILEN) = (32u << 16) | (24u << 8) | 8u;
        SPIM(SPIM_STATUS) = (1u << 8) | (1u << 0);
        while ((((SPIM(SPIM_STATUS)) >> 16) & 0x1Fu) == 0u)
            if (--spin == 0u)                       return 6;
        w = SPIM(SPIM_RXFIFO);
        /* first byte off the wire is in [31:24]; "GARD" little-endian */
        w = (w >> 24) | ((w >> 8) & 0x0000FF00u)
                      | ((w << 8) & 0x00FF0000u) | (w << 24);
        if (w != 0x47415244u)                       return 6;
    }

    /* 7: and nothing trapped on the way through */
    if (exc_count != 0u)                            return 7;

    return 0;
}
