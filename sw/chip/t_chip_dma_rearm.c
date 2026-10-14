/* =============================================================================
 * t_chip_dma_rearm.c - DMA-11 reachability at chip level (Track A DMA plan D9,
 * run early because its result decides the DMA-11 ruling)
 *
 * Question: can firmware on the core, through the real interconnect and the
 * AHB2APB bridge, re-arm a DMA channel while a beat of its previous transfer is
 * still in flight? At block level (tb_dma_probe) such a beat lands in the new
 * transfer: REMAINING wraps to 0xFFFF, or the new buffer gets the old data.
 *
 * Method: start an M2M transfer, wait d delay steps (d = 0..47), then stop and
 * re-arm as fast as the core can store:
 *   B  zero-length re-arm, two back-to-back stores (CNT = 0 is written while the
 *      old transfer runs, which is legal: REMAINING was loaded at arm time):
 *      the channel must end COMPLETE with REMAINING 0.
 *   C  re-arm with a new buffer (stop, SAR, DAR, CNT, EN: five stores): the new
 *      buffer must get exactly its own two source words.
 * Each pattern runs with fast beats (DSRAM source) and slow beats (an APB source,
 * the timers' MTIME_LO, read through the bridge). dma_sva is bound in tb_chip:
 * a_beat_belongs_to_arm fires on the first stale beat, and c_rearm_in_flight
 * counts how often a re-arm landed inside a beat at all.
 *
 * Returns 0 when no attempt reached the defect. Otherwise the code (printed by
 * tb_chip as "program reported step N") is  verdict + 1000*h1 + 1000000*h0:
 * verdict = 100 + 1 (B reached) + 2 (C reached); h0, h1 = the first two hits,
 * each (C ? 500 : 0) + 100*slow + d. n_b / n_c / n_err hold the counts.
 * ========================================================================== */
#include "chip.h"

#define CH          2u
#define STAT_COMP   (1u << 17)
#define STAT_ERR    (1u << 18)
#define DSTEPS      48

volatile uint32_t n_b, n_c, n_err, n_attempts, n_trap, n_hits;
volatile uint32_t hit[8];
static uint32_t src_old[16], src_new[4], dst_old[16], dst_new[4];

/* no trap is expected in this program: count any, and fail the run */
uint32_t trap_handler(uint32_t mcause, uint32_t mepc)
{
    n_trap++;
    return (mcause & MCAUSE_INT) ? mepc : mepc + 4;
}

static void delay(int d)
{
    for (int i = 0; i < d; i++) __asm__ volatile ("nop");
}

static int wait_stat(uint32_t mask, int max)
{
    for (int i = 0; i < max; i++) if (DMA_STAT(CH) & mask) return 1;
    return 0;
}

static void clean(void)
{
    DMA_CR(CH)   = 0;
    DMA_ICLR(CH) = 3u;
}

int main(void)
{
    const uint32_t base = DMA_CR_M2M | DMA_CR_DINC | DMA_CR_WORD;
    for (int i = 0; i < 16; i++) { src_old[i] = 0xA0000000u + i; dst_old[i] = 0; }
    for (int i = 0; i < 4;  i++) { src_new[i] = 0xB0000000u + i; }

    for (int slow = 0; slow < 2; slow++) {
        const uint32_t src  = slow ? (uint32_t)(uintptr_t)&MTIME_LO : (uint32_t)(uintptr_t)src_old;
        const uint32_t cr   = base | (slow ? 0u : DMA_CR_SINC);

        /* ---- B: zero-length re-arm, two back-to-back stores ------------------ */
        for (int d = 0; d < DSTEPS; d++) {
            clean();
            DMA_SAR(CH) = src;
            DMA_DAR(CH) = (uint32_t)(uintptr_t)dst_old;
            DMA_CNT(CH) = 8;
            DMA_CR(CH)  = cr | DMA_CR_EN;
            DMA_CNT(CH) = 0;                       /* for the next arm only */
            delay(d);
            DMA_CR(CH)  = cr;                      /* stop */
            DMA_CR(CH)  = cr | DMA_CR_EN;          /* zero-length re-arm */
            delay(64);                             /* any old beat lands by now */
            uint32_t st = DMA_STAT(CH);
            n_attempts++;
            if (st & STAT_ERR) n_err++;
            else if (!(st & STAT_COMP) || (st & 0xFFFFu) != 0) {
                n_b++;
                if (n_hits < 8) hit[n_hits++] = 100u * slow + d;
            }
        }

        /* ---- C: re-arm with a new buffer, five stores --------------------------- */
        for (int d = 0; d < DSTEPS; d++) {
            clean();
            dst_new[0] = dst_new[1] = 0;
            DMA_SAR(CH) = src;
            DMA_DAR(CH) = (uint32_t)(uintptr_t)dst_old;
            DMA_CNT(CH) = 8;
            DMA_CR(CH)  = cr | DMA_CR_EN;
            delay(d);
            DMA_CR(CH)  = cr;                      /* stop */
            DMA_SAR(CH) = (uint32_t)(uintptr_t)src_new;
            DMA_DAR(CH) = (uint32_t)(uintptr_t)dst_new;
            DMA_CNT(CH) = 2;
            DMA_CR(CH)  = base | DMA_CR_SINC | DMA_CR_EN;
            int ok = wait_stat(STAT_COMP | STAT_ERR, 2000);
            delay(64);
            uint32_t st = DMA_STAT(CH);
            n_attempts++;
            if (!ok || (st & STAT_ERR)) n_err++;
            else if (dst_new[0] != src_new[0] || dst_new[1] != src_new[1] || (st & 0xFFFFu) != 0) {
                n_c++;
                if (n_hits < 8) hit[n_hits++] = 500u + 100u * slow + d;
            }
        }
    }
    clean();

    if (n_trap) return 8;                          /* an unexpected trap */
    if (n_err)  return 9;                          /* a refused or failed beat: not this test's question */
    if (!n_b && !n_c) return 0;
    return (int)(100u + (n_b ? 1u : 0u) + (n_c ? 2u : 0u)
                 + 1000u * (n_hits > 1 ? hit[1] : 0u) + 1000000u * hit[0]);
}
