/* =============================================================================
 * t_chip_irq.c - the interrupt path, end to end, for the first time
 *   DMA ch2 M2M completion -> CLIC ID 3 -> core trap, ISR clears via ICLR
 *   machine timer: mtime >= mtimecmp -> mip.MTIP -> trap 0x8000_0007
 *   watchdog early warning -> CLIC ID 22 (level, held - D-17), ISR kicks
 * Every wait is a race-free WFI loop, so the core clock gates between events.
 * ========================================================================== */
#include "chip.h"

volatile uint32_t n_dma, n_mti, n_warn, bad, last_id;
static uint32_t src[32], dst[32];

uint32_t trap_handler(uint32_t mcause, uint32_t mepc)
{
    if (!(mcause & MCAUSE_INT)) { bad++; return mepc + 4; }
    if (mcause == 0x80000007u) {                    /* machine timer */
        n_mti++;
        mtimecmp_set(~0ull);                         /* push the deadline away */
        return mepc;
    }
    last_id = mcause & 0x1Fu;
    if (last_id == GARUDA_CLIC_ID_DMA_COMPLETE_CH0_5_FIRST + 2) {
        n_dma++;
        DMA_ICLR(2) = 1u;                            /* clear at the source */
    } else if (last_id == GARUDA_CLIC_ID_WDT_EARLY_WARNING) {
        n_warn++;
        WDTKICK = WDT_KICK_MAGIC;                    /* kick clears the warning */
    } else {
        bad++;
    }
    return mepc;
}

/* sleep until *flag is set; MIE is off across the check so no wake is lost */
static void wait_for(volatile uint32_t *flag)
{
    CSRC(mstatus, 8);
    while (!*flag) {
        WFI();
        CSRS(mstatus, 8);
        __asm__ volatile ("nop");
        CSRC(mstatus, 8);
    }
    CSRS(mstatus, 8);
}

int main(void)
{
    for (int i = 0; i < 32; i++) { src[i] = 0xC0DE0000u + i; dst[i] = 0; }

    /* ---- DMA completion through the CLIC --------------------------------- */
    CLICINTCFG(3) = 10;
    CLICIE = 1u << 3;
    CSRS(mstatus, 8);
    DMA_SAR(2) = (uint32_t)(uintptr_t)src;
    DMA_DAR(2) = (uint32_t)(uintptr_t)dst;
    DMA_CNT(2) = 32;
    DMA_CR(2)  = DMA_CR_EN | DMA_CR_M2M | DMA_CR_SINC | DMA_CR_DINC |
                 DMA_CR_WORD | DMA_CR_IECOMP;
    wait_for(&n_dma);
    for (int i = 0; i < 32; i++) if (dst[i] != src[i]) return 1;
    if (n_dma != 1 || (CLICIP & (1u << 3)))           return 2;

    /* ---- machine timer ----------------------------------------------------- */
    CSRS(mie, 0x80);
    mtimecmp_set(mtime_get() + 2000);
    wait_for(&n_mti);
    if (n_mti != 1)                                    return 3;

    /* ---- watchdog early warning (CLIC 22) --------------------------------------- */
    CLICINTCFG(22) = 20;
    CLICIE = (1u << 3) | (1u << 22);
    WDTLOAD = 4000;
    WDTWARN = 3000;
    WDTCTL  = 3u;                                      /* EN | WARNEN */
    wait_for(&n_warn);
    if ((WDTCTL & 1u) != 1u)                           return 4;
    WDTCTL = 0u;                                       /* EN is sticky: stays 1 */
    if ((WDTCTL & 1u) != 1u)                           return 5;

    return bad ? 6 : 0;
}
