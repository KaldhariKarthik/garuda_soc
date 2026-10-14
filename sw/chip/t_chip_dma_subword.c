/* =============================================================================
 * t_chip_dma_subword.c - sub-word DMA beats to an APB address (Track A DMA plan
 * D9; vPlan F51, decision D-21 rule 4)
 *
 * The AHB2APB bridge is word-only ([N-7.12], R-6): a byte or halfword access is
 * answered with ERROR, never widened (APB3 has no byte enables). So a DMA beat of
 * SIZE byte or halfword whose write goes to a peripheral must fail in the write
 * phase, and one whose read comes from a peripheral must fail in the read phase;
 * the channel ends in ERROR with the matching ERRPHASE, REMAINING unchanged, and
 * the peripheral register keeps its value (no partial write). A word beat to the
 * same register is the control: it lands.
 * Target: the timers' MTIMECMP_LO (read/write, no side effect while MIE is off).
 *
 * Returns 0 on success, otherwise the number of the first failed check.
 * ========================================================================== */
#include "chip.h"

#define CH        1u
#define ST_ACT    (1u << 16)
#define ST_COMP   (1u << 17)
#define ST_ERR    (1u << 18)

volatile uint32_t n_trap;

/* no trap is expected: the DMA's bus faults end in the channel's ERROR, not on the core */
uint32_t trap_handler(uint32_t mcause, uint32_t mepc)
{
    n_trap++;
    return (mcause & MCAUSE_INT) ? mepc : mepc + 4;
}

static uint32_t src[4] = { 0x11223344u, 0x55667788u, 0x99AABBCCu, 0xDDEEFF00u };
static uint32_t dst[4];

static uint32_t run(uint32_t sar, uint32_t dar, uint32_t cnt, uint32_t size)
{
    uint32_t st;
    DMA_SAR(CH) = sar;
    DMA_DAR(CH) = dar;
    DMA_CNT(CH) = cnt;
    DMA_CR(CH)  = DMA_CR_EN | DMA_CR_M2M | (size << 5);      /* no increments */
    for (int i = 0; i < 20000; i++) if (!((st = DMA_STAT(CH)) & ST_ACT)) break;
    st = DMA_STAT(CH);
    DMA_ICLR(CH) = 3u;
    return st;
}

int main(void)
{
    uint32_t st, keep = 0xCAFE0001u;
    uint32_t reg = (uint32_t)(uintptr_t)&MTIMECMP_LO;
    MTIMECMP_HI = 0xFFFFFFFFu;                                 /* no timer interrupt either way */
    MTIMECMP_LO = keep;

    /* byte and halfword writes to the peripheral: ERROR in the write phase, nothing written */
    for (uint32_t size = 0; size < 2; size++) {
        st = run((uint32_t)(uintptr_t)src, reg, 2, size);
        if (!(st & ST_ERR) || (st & ST_COMP))                 return 1 + 10 * size;
        if (((st >> 19) & 7u) != 2u)                          return 2 + 10 * size;   /* ERRPHASE = write */
        if ((st & 0xFFFFu) != 2u)                             return 3 + 10 * size;   /* no beat counted */
        if (MTIMECMP_LO != keep)                              return 4 + 10 * size;   /* no partial write */
    }
    /* byte and halfword reads from the peripheral: ERROR in the read phase, no write */
    for (uint32_t size = 0; size < 2; size++) {
        dst[0] = 0x5A5A5A5Au;
        st = run(reg, (uint32_t)(uintptr_t)dst, 1, size);
        if (!(st & ST_ERR) || ((st >> 19) & 7u) != 1u)        return 21 + 10 * size;  /* ERRPHASE = read */
        if ((st & 0xFFFFu) != 1u || dst[0] != 0x5A5A5A5Au)    return 22 + 10 * size;
    }
    /* control: a word beat to the same register lands */
    st = run((uint32_t)(uintptr_t)&src[2], reg, 1, 2);
    if (!(st & ST_COMP) || (st & ST_ERR))                     return 41;
    if (MTIMECMP_LO != src[2])                                return 42;
    return n_trap ? 43 : 0;
}
