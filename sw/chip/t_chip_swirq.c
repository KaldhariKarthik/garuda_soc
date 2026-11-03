/* =============================================================================
 * t_chip_swirq.c - the software interrupt, end to end (1-TOPS item 3.6)
 *   firmware writes CLICSWI = 1 -> CLIC ID 23 (level) -> core trap with
 *   mcause = 0x8000_0017; the handler writes CLICSWI = 0 and returns.
 * Then: a software interrupt (level 50) raised inside the handler of a level-100
 * interrupt is held off (MIE is 0 in a handler, and 50 is not above mil = 100)
 * and taken as soon as that handler's mret restores MIE and mil.
 * ========================================================================== */
#include "chip.h"

volatile uint32_t n_swi, n_hi, bad, order[4], n_order;

uint32_t trap_handler(uint32_t mcause, uint32_t mepc)
{
    uint32_t id;
    if (!(mcause & MCAUSE_INT)) { bad++; return mepc + 4; }
    id = mcause & 0x1Fu;
    if (n_order < 4) order[n_order++] = id;
    if (id == GARUDA_CLIC_ID_SOFTWARE) {
        n_swi++;
        CLICSWI = 0u;                                /* level source: withdraw it */
    } else if (id == GARUDA_CLIC_ID_DMA_COMPLETE_CH0_5_FIRST + 2) {
        n_hi++;
        /* raise the software interrupt inside this level-100 handler: it must
         * wait for this mret */
        CLICSWI = 1u;
        for (volatile int i = 0; i < 20; i++) ;      /* time in which it must not be taken */
        if (n_swi != 1) bad++;                       /* only the one of step 3 so far */
        DMA_ICLR(2) = 1u;
    } else {
        bad++;
    }
    return mepc;
}

static void wait_for(volatile uint32_t *flag, uint32_t want)
{
    CSRC(mstatus, 8);
    while (*flag < want) {
        WFI();
        CSRS(mstatus, 8);
        __asm__ volatile ("nop");
        CSRC(mstatus, 8);
    }
    CSRS(mstatus, 8);
}

static uint32_t src[8], dst[8];

int main(void)
{
    /* 1: the register: resets to 0, keeps only bit 0 */
    if (CLICSWI != 0u)                                 return 1;
    CLICSWI = 0xFFFFFFFEu;
    if (CLICSWI != 0u)                                 return 2;

    /* 2: set it with the interrupt disabled: pending, not taken */
    CLICINTCFG(GARUDA_CLIC_ID_SOFTWARE) = 50;
    CLICSWI = 1u;
    if (!(CLICIP & (1u << GARUDA_CLIC_ID_SOFTWARE)))   return 3;
    CLICSWI = 0u;
    if (CLICIP & (1u << GARUDA_CLIC_ID_SOFTWARE))      return 4;

    /* 3: enabled: firmware raises it and the core takes it */
    CLICIE = 1u << GARUDA_CLIC_ID_SOFTWARE;
    CSRS(mstatus, 8);
    CLICSWI = 1u;
    wait_for(&n_swi, 1);
    if (n_swi != 1 || CLICSWI != 0u)                   return 5;
    if (order[0] != GARUDA_CLIC_ID_SOFTWARE)           return 6;

    /* 4: nesting: raised inside a higher-level handler, taken after its mret */
    n_order = 0;
    for (int i = 0; i < 8; i++) { src[i] = i; dst[i] = 0; }
    CLICINTCFG(3) = 100;
    CLICIE = (1u << 3) | (1u << GARUDA_CLIC_ID_SOFTWARE);
    DMA_SAR(2) = (uint32_t)(uintptr_t)src;
    DMA_DAR(2) = (uint32_t)(uintptr_t)dst;
    DMA_CNT(2) = 8;
    DMA_CR(2)  = DMA_CR_EN | DMA_CR_M2M | DMA_CR_SINC | DMA_CR_DINC |
                 DMA_CR_WORD | DMA_CR_IECOMP;
    wait_for(&n_swi, 2);
    if (n_hi != 1)                                     return 7;
    if (order[0] != 3 || order[1] != GARUDA_CLIC_ID_SOFTWARE) return 8;

    return bad ? 9 : 0;
}
