/* =============================================================================
 * t_chip_basic.c - first program on the integrated chip (garuda_chip_top)
 * Entered from the Boot ROM recovery mailbox (boot_sel = 1).
 *   reset reason / boot_sel / CSR surface       CLKRST §6, CORE §6.1
 *   ISRAM writable, then ILOCK refuses writes   MEM [N-7.8]
 *   bus faults are precise: unmapped region, masked (deferred) APB window,
 *   sub-word APB access, misaligned load        AHB/AHB2APB/MEM
 *   DMA refuses an ISRAM destination            DMA R-9 (D-16)
 * Returns 0 = pass, n = failed step n.
 * ========================================================================== */
#include "chip.h"

volatile uint32_t exc_count, last_cause, last_tval;

uint32_t trap_handler(uint32_t mcause, uint32_t mepc)
{
    if (mcause & MCAUSE_INT) return mepc;           /* none expected */
    exc_count++;
    last_cause = mcause;
    last_tval  = CSRR(mtval);
    return mepc + 4;                                /* skip the faulting access */
}

static int fault(uint32_t expect_cause)
{
    int ok = (exc_count == 1) && (last_cause == expect_cause);
    exc_count = 0;
    return ok;
}

int main(void)
{
    volatile uint32_t *p;
    volatile uint32_t v;

    /* 1-3: reset, strap and CSR surface */
    if ((RSTREASON & 0x1F) != 0x1)                  return 1;   /* EXT only */
    if (!(CLKSTAT & (1u << 8)))                     return 2;   /* boot_sel */
    if (CSRR(misa) != 0x40001100u)                  return 3;
    if ((CSRR(mtvec) & 3u) != 3u)                   return 3;   /* MODE = CLIC */

    /* 4: M extension */
    volatile uint32_t a = 1234567u, b = 7654321u;
    if (a * b != 0x324F6057u)                       return 4;   /* low word */

    /* 5: ISRAM writable before the lock, refused after */
    p = (volatile uint32_t *)0x0000F000u;
    *p = 0x11223344u;
    if (*p != 0x11223344u)                          return 5;
    MEMCTL = 1u;
    if (!(MEMCTL & 1u))                             return 6;
    *p = 0x55667788u;
    if (!fault(7) || *p != 0x11223344u)             return 7;   /* store access fault */

    /* 8: unmapped AHB region -> default slave ERROR -> load access fault */
    v = *(volatile uint32_t *)0x30000000u;
    if (!fault(5) || last_tval != 0x30000000u)      return 8;

    /* 9a: a still-deferred peripheral window (i2c, masked) faults, never hangs */
    v = *(volatile uint32_t *)GARUDA_APB_BASE_I2C;
    if (!fault(5))                                  return 9;

    /* 9b: and a window that HAS landed answers - spi_master identifies itself */
    if (*(volatile uint32_t *)(GARUDA_APB_BASE_SPI_MASTER + 0xFECu)
        != 0x6A5D0D01u)                             return 9;
    if (exc_count != 0)                             return 9;   /* and no trap */

    /* 10: APB is word-only */
    v = *(volatile uint8_t *)(GARUDA_APB_BASE_CLIC_CFG + 4);
    if (!fault(5))                                  return 10;

    /* 11: misaligned word load -> load address misaligned (cause 4) */
    {   /* forced through asm: GCC splits a known-misaligned C load into lhu's */
        uint32_t addr = GARUDA_DSRAM_BASE + 0x102, tmp;
        __asm__ volatile ("lw %0, 0(%1)" : "=r"(tmp) : "r"(addr) : "memory");
        (void)tmp;
    }
    if (!fault(4))                                  return 11;

    /* 12: the DMA refuses an ISRAM destination (R-9) */
    DMA_SAR(1) = GARUDA_DSRAM_BASE;
    DMA_DAR(1) = 0x00008000u;
    DMA_CNT(1) = 4;
    DMA_CR(1)  = DMA_CR_EN | DMA_CR_M2M | DMA_CR_SINC | DMA_CR_DINC | DMA_CR_WORD;
    for (int i = 0; i < 100 && (DMA_STAT(1) & (1u << 16)); i++) ;
    if (((DMA_STAT(1) >> 18) & 1u) != 1u)           return 12;
    if (((DMA_STAT(1) >> 19) & 7u) != 2u)           return 12;   /* ERRPHASE = write */

    /* 13: counters run */
    uint32_t c0 = CSRR(mcycle), i0 = CSRR(minstret);
    if (CSRR(mcycle) == c0 || CSRR(minstret) == i0) return 13;

    (void)v;
    return 0;
}
