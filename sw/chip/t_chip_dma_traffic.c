/* =============================================================================
 * t_chip_dma_traffic.c - six DMA channels under CPU load (Track A DMA plan D9;
 * vPlan F38, plan 8.6)
 *
 * All six channels are armed back to back with M2M transfers of different sizes
 * (word, halfword, byte) between DSRAM buffers; channel 4's destination is the
 * ISRAM, which the DMA must refuse (R-9): its write is never issued, the channel
 * ends in ERROR with ERRPHASE = write and raises CLIC ID 4 + 8 = 12 (INT-2), while
 * the other five finish (R-8: one channel's error does not stop the others) and
 * raise their completion IDs 1..6. Meanwhile the core runs a checksum over its own
 * buffer, with interrupts taken in the middle; the result must equal the one
 * computed before the DMA started. The ISR records each ID and clears it at the
 * source (ICLR). dma_sva, the AHB checkers and the core SVA are bound in tb_chip.
 *
 * Returns 0 on success, otherwise the number of the first failed check.
 * ========================================================================== */
#include "chip.h"

#define NCH        6u
#define ERR_CH     4u
#define CLIC_COMP0 GARUDA_CLIC_ID_DMA_COMPLETE_CH0_5_FIRST   /* IDs 1..6  */
#define CLIC_ERR0  GARUDA_CLIC_ID_DMA_ERROR_CH0_5_FIRST      /* IDs 8..13 */
#define ISRAM_DST  0x00000400u                               /* R-9: refused */

volatile uint32_t n_comp[NCH], n_err[NCH], errph[NCH], n_done, bad;
static uint32_t w_src[2][48], w_dst[2][48];
static uint16_t h_src[40], h_dst[40];
static uint8_t  b_src[2][37], b_dst[2][37];
static uint32_t work[256];

uint32_t trap_handler(uint32_t mcause, uint32_t mepc)
{
    uint32_t id = mcause & 0x1Fu;
    if (!(mcause & MCAUSE_INT)) { bad++; return mepc + 4; }
    if (id >= CLIC_COMP0 && id < CLIC_COMP0 + NCH) {
        n_comp[id - CLIC_COMP0]++;
        DMA_ICLR(id - CLIC_COMP0) = 1u;
        n_done++;
    } else if (id >= CLIC_ERR0 && id < CLIC_ERR0 + NCH) {
        uint32_t ch = id - CLIC_ERR0;
        errph[ch] = (DMA_STAT(ch) >> 19) & 7u;     /* read before the clear */
        n_err[ch]++;
        DMA_ICLR(ch) = 2u;
        n_done++;
    } else {
        bad++;
    }
    return mepc;
}

static uint32_t checksum(void)
{
    uint32_t s = 0x12345678u;
    for (int r = 0; r < 4; r++)
        for (int i = 0; i < 256; i++) s = ((s << 5) | (s >> 27)) + (work[i] ^ (uint32_t)r);
    return s;
}

static void arm(uint32_t ch, const void *src, void *dst, uint32_t cnt, uint32_t size)
{
    DMA_SAR(ch) = (uint32_t)(uintptr_t)src;
    DMA_DAR(ch) = (uint32_t)(uintptr_t)dst;
    DMA_CNT(ch) = cnt;
    DMA_CR(ch)  = DMA_CR_EN | DMA_CR_M2M | DMA_CR_SINC | DMA_CR_DINC | (size << 5) |
                  DMA_CR_IECOMP | DMA_CR_IEERR;
}

int main(void)
{
    uint32_t want, got, ie = 0;
    for (int i = 0; i < 48; i++) { w_src[0][i] = 0xA5000000u + i; w_src[1][i] = 0x5A000000u ^ (i * 0x01010101u); w_dst[0][i] = w_dst[1][i] = 0; }
    for (int i = 0; i < 40; i++) { h_src[i] = (uint16_t)(0xB000u + 3 * i); h_dst[i] = 0; }
    for (int i = 0; i < 37; i++) { b_src[0][i] = (uint8_t)(0x30 + i); b_src[1][i] = (uint8_t)(0xF0 - i); b_dst[0][i] = b_dst[1][i] = 0; }
    for (int i = 0; i < 256; i++) work[i] = i * 2654435761u;
    want = checksum();

    for (uint32_t ch = 0; ch < NCH; ch++) {
        CLICINTCFG(CLIC_COMP0 + ch) = 10 + ch;
        CLICINTCFG(CLIC_ERR0 + ch)  = 20 + ch;
        ie |= (1u << (CLIC_COMP0 + ch)) | (1u << (CLIC_ERR0 + ch));
    }
    CLICIE = ie;
    CSRS(mstatus, 8);

    /* six channels armed back to back; channel 0 word stream first so it is long */
    arm(0, w_src[0], w_dst[0], 48, 2);
    arm(1, h_src,    h_dst,    40, 1);
    arm(2, b_src[0] + 1, b_dst[0] + 2, 35, 0);              /* unaligned bytes */
    arm(3, w_src[1], w_dst[1], 48, 2);
    arm(ERR_CH, w_src[1], (void *)(uintptr_t)ISRAM_DST, 8, 2);
    arm(5, b_src[1], b_dst[1], 37, 0);

    got = checksum();                                         /* CPU traffic + interrupts */

    for (int i = 0; i < 200000 && n_done < NCH; i++) __asm__ volatile ("nop");
    CSRC(mstatus, 8);
    if (n_done != NCH)                                         return 1;
    if (got != want)                                           return 2;
    for (int i = 0; i < 48; i++) if (w_dst[0][i] != w_src[0][i] || w_dst[1][i] != w_src[1][i]) return 3;
    for (int i = 0; i < 40; i++) if (h_dst[i] != h_src[i])     return 4;
    for (int i = 0; i < 35; i++) if (b_dst[0][i + 2] != b_src[0][i + 1]) return 5;
    if (b_dst[0][0] || b_dst[0][1])                            return 5;   /* bytes before the start untouched */
    for (int i = 0; i < 37; i++) if (b_dst[1][i] != b_src[1][i]) return 6;
    for (uint32_t ch = 0; ch < NCH; ch++) {
        uint32_t st = DMA_STAT(ch);
        if (ch == ERR_CH) {
            if (n_err[ch] != 1 || n_comp[ch] != 0 || errph[ch] != 2u)  return 7;
            if ((st & 0xFFFFu) != 8u || (st & (1u << 16)))            return 8;   /* nothing moved, idle */
        } else {
            if (n_comp[ch] != 1 || n_err[ch] != 0)                    return 9;
            if ((st & 0xFFFFu) != 0u || (st & (1u << 16)))            return 10;
        }
    }
    if (CLICIP & ie)                                           return 11;   /* nothing left pending */
    return bad ? 12 : 0;
}
