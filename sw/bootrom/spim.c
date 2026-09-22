/* =============================================================================
 * spim.c -- the Boot ROM's SPI flash driver (block 13, APB window 1)
 *
 * Spec: GARUDA-SPIM-SPEC-001 [N-7.1]. Two functions, nothing else: the ROM has
 * 4 KiB and boot.c owns the rest of it. Polled, no interrupts, no DMA - the
 * DMA is not configured this early and a 32-bit read is ~2 us, which for a
 * 64 KiB image is the boot time we budgeted.
 *
 * Deliberately NOT hangable: every wait is bounded, and a timeout returns
 * 0xFFFFFFFF (what an erased or absent flash reads as), so a dead SPI bus
 * fails MAGIC and lands in boot_fail() instead of spinning until the watchdog.
 * =========================================================================== */
#include <stdint.h>
#include "garuda_map.h"

#define SPIM(off)   (*(volatile uint32_t *)(uintptr_t)(GARUDA_APB_BASE_SPI_MASTER + (off)))

#define SPIM_STATUS 0x000u
#define SPIM_CLKDIV 0x004u
#define SPIM_SPICMD 0x008u
#define SPIM_SPIADR 0x00Cu
#define SPIM_SPILEN 0x010u
#define SPIM_SPIDUM 0x014u
#define SPIM_RXFIFO 0x020u

#define CS_FLASH    (1u << 8)           /* STATUS[8]: chip select 0 = flash */
#define START_RD    (1u << 0)           /* STATUS[0] on write: start a read  */
#define RX_WORDS(s) (((s) >> 16) & 0x1Fu)

/* Comfortably longer than one 32-bit transfer at 15.6 MHz (~2 us = ~500 core
 * cycles at 250 MHz), short enough that a dead bus fails boot in milliseconds. */
#define SPIM_SPIN   20000u

void spim_init(void)
{
    SPIM(SPIM_CLKDIV) = 3u;             /* SCLK = pclk/8 = 15.6 MHz ([N-6.2]) */
    SPIM(SPIM_SPIDUM) = 0u;             /* command 0x03 has no dummy cycles   */

    while (RX_WORDS(SPIM(SPIM_STATUS))) /* drop anything left in the RX FIFO  */
        (void)SPIM(SPIM_RXFIFO);
}

uint32_t spim_read_word(uint32_t byte_off)
{
    uint32_t w, spin = SPIM_SPIN;

    SPIM(SPIM_SPICMD) = 0x03u << 24;                    /* MSB-first from b31 */
    SPIM(SPIM_SPIADR) = byte_off << 8;                  /* 24-bit, left-aligned */
    SPIM(SPIM_SPILEN) = (32u << 16) | (24u << 8) | 8u;  /* data / addr / cmd   */
    SPIM(SPIM_STATUS) = CS_FLASH | START_RD;

    /* Wait for a word to ARRIVE, not for the engine to look idle: STATUS[0] is
     * still set in the cycles before the engine starts ([N-6.1a]). */
    while (RX_WORDS(SPIM(SPIM_STATUS)) == 0u) {
        if (--spin == 0u)
            return 0xFFFFFFFFu;
    }

    w = SPIM(SPIM_RXFIFO);

    /* The first byte off the wire sits in [31:24]; the image is little-endian,
     * so flash byte n must become bits [8n+7:8n] ([N-7.3]). tools/mkbootimg.py
     * writes the image in exactly this order - make test_chip_flash proves it. */
    return (w >> 24) | ((w >> 8) & 0x0000FF00u)
                     | ((w << 8) & 0x00FF0000u) | (w << 24);
}
