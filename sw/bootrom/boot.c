/* =============================================================================
 * GARUDA Boot ROM - bootloader (GARUDA-MEM-SPEC-001 Rev 2.0 §8, ADR-0014/15/16)
 *
 *  1. Reset: PC = 0x1000_0000, rom_start.S installs a trap handler and a stack.
 *  2. Sample boot_sel (reset_ctrl CLKSTAT[8], DECISIONS D-19). 1 -> recovery.
 *  3. Configure the SPI master for the boot flash.
 *  4. Read the 32-byte header by polled PIO (ADR-0015: no DMA in the boot path).
 *  5. MAGIC must be 0x47415244 ("GARD"); an erased flash reads all ones.
 *  6. TEXT_LEN / DATA_LEN <= 64 KiB, word aligned; ENTRY inside ISRAM.
 *  7. Copy text  flash -> ISRAM,  8. copy data flash -> DSRAM (polled words).
 *  9. CRC-32 (reflected, poly 0xEDB88320, init/xorout 0xFFFFFFFF - the IEEE
 *     802.3 CRC of the yaml's boot.checksum) over both, read back from RAM.
 * 10. Set MEMCTL.ILOCK.  11. Jump to ENTRY.
 * 12. Recovery (boot_sel = 1, or any failure after setting BOOTFAIL): ISRAM
 *     stays unlocked; poll the JTAG mailbox at the top of DSRAM. A debugger
 *     loads an image over SBA, writes {MAGIC "JTAG", ENTRY} to the mailbox,
 *     and the ROM jumps (D-20). This is the ROM half of the development loop
 *     of DEBUG-SPEC §7.6 - "resume" restarts the core at the reset vector, so
 *     something in the ROM has to hand over, and this is it.
 *
 * FLASH ACCESS: the SPI master is sourced IP that has not landed. Without
 * GARUDA_HAVE_SPIM the flash reads as erased (all ones), MAGIC fails and the
 * ROM takes the BOOTFAIL -> recovery path - exactly what a blank board does.
 * spim_read_word() is the ONE function to fill in when the IP arrives.
 * ========================================================================== */
#include <stdint.h>
#include "garuda_map.h"

#define REG(a)          (*(volatile uint32_t *)(uintptr_t)(a))
#define RST_BASE        GARUDA_APB_BASE_RESET_CTRL
#define RSTCTL          REG(RST_BASE + 0x04)
#define CLKSTAT         REG(RST_BASE + 0x08)
#define MEMCTL          REG(RST_BASE + 0x20)
#define CLKSTAT_BOOTSEL (1u << 8)
#define RSTCTL_DIVSEL   (3u << 8)
#define RSTCTL_BOOTFAIL (1u << 4)

#define IMG_MAGIC       0x47415244u         /* "GARD" */
#define MBOX            ((volatile uint32_t *)(uintptr_t)(GARUDA_DSRAM_BASE + GARUDA_DSRAM_SIZE - 16))
#define MBOX_MAGIC      0x4A544147u         /* "JTAG" */

void boot_recovery(void) __attribute__((noreturn));
void boot_main(void) __attribute__((noreturn));

static void jump(uint32_t entry) __attribute__((noreturn));
static void jump(uint32_t entry)
{
    ((void (*)(void))(uintptr_t)entry)();
    for (;;) ;
}

/* ---- flash access (sourced SPI master IP) ------------------------------- */
#ifdef GARUDA_HAVE_SPIM
extern void     spim_init(void);
extern uint32_t spim_read_word(uint32_t byte_off);
#else
static void     spim_init(void) { }
static uint32_t spim_read_word(uint32_t byte_off) { (void)byte_off; return 0xFFFFFFFFu; }
#endif

/* ---- CRC-32, reflected, bitwise: small code beats speed in a 4 KiB ROM -- */
static uint32_t crc32_words(const volatile uint32_t *p, uint32_t nbytes)
{
    uint32_t crc = 0xFFFFFFFFu;
    for (uint32_t i = 0; i < nbytes / 4; i++) {
        uint32_t w = p[i];
        for (int b = 0; b < 4; b++) {
            crc ^= (w >> (8 * b)) & 0xFFu;
            for (int k = 0; k < 8; k++)
                crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
        }
    }
    return ~crc;
}

static void boot_fail(void) __attribute__((noreturn));
static void boot_fail(void)
{
    RSTCTL = (RSTCTL & RSTCTL_DIVSEL) | RSTCTL_BOOTFAIL;   /* keep DIVSEL */
    boot_recovery();
}

void boot_recovery(void)
{
    for (;;) {
        if (MBOX[0] == MBOX_MAGIC) {
            uint32_t entry = MBOX[1];
            MBOX[0] = 0;                                    /* one shot */
            jump(entry);
        }
    }
}

void boot_main(void)
{
    if (CLKSTAT & CLKSTAT_BOOTSEL)
        boot_recovery();

    spim_init();

    uint32_t hdr[8];
    for (int i = 0; i < 8; i++)
        hdr[i] = spim_read_word(4u * i);

    uint32_t magic = hdr[0], text_len = hdr[1], data_len = hdr[2],
             entry = hdr[3], text_crc = hdr[4], data_crc = hdr[5];

    if (magic != IMG_MAGIC)                                        boot_fail();
    if (text_len > GARUDA_ISRAM_SIZE || data_len > GARUDA_DSRAM_SIZE) boot_fail();
    if ((text_len | data_len) & 3u)                                boot_fail();
    if (entry >= GARUDA_ISRAM_BASE + text_len)                     boot_fail();   /* ISRAM starts at 0 */

    volatile uint32_t *isram = (volatile uint32_t *)(uintptr_t)GARUDA_ISRAM_BASE;
    volatile uint32_t *dsram = (volatile uint32_t *)(uintptr_t)GARUDA_DSRAM_BASE;
    for (uint32_t i = 0; i < text_len / 4; i++)
        isram[i] = spim_read_word(32u + 4u * i);
    for (uint32_t i = 0; i < data_len / 4; i++)
        dsram[i] = spim_read_word(32u + text_len + 4u * i);

    if (crc32_words(isram, text_len) != text_crc)                  boot_fail();
    if (crc32_words(dsram, data_len) != data_crc)                  boot_fail();

    MEMCTL = 1u;                                                   /* ILOCK */
    jump(entry);
}
