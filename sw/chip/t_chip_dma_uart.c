/* =============================================================================
 * t_chip_dma_uart.c - peripheral transfers end to end through the pins (Track A
 * DMA plan D9; vPlan F39). (sw/chip/t_chip_uart.c, which the vPlan named, moves
 * bytes by the core only: no DMA.)
 *
 * tb_chip loops each UART's tx back to its own rx.
 *   P2M (F39): UART0 -> DMA channel 2. DMACTL[0] makes the UART request on RX data;
 *     the core sends N bytes through THR, each comes back on rx and the DMA moves
 *     it from RBR into a DSRAM buffer (word beats: the bridge is word-only, the byte
 *     is in bits 7:0). One beat per byte, no byte lost or doubled (D-21).
 *   M2P: DSRAM -> DMA channel 3 -> UART1 THR. DMACTL[1] makes the UART request on
 *     TX space; the core reads the bytes back from UART1's RBR as they loop round.
 * Both channels end COMPLETE with REMAINING 0; the D-21 contract is watched by the
 * shim's properties and dma_sva, bound in tb_chip.
 *
 * Returns 0 on success, otherwise the number of the first failed check.
 * ========================================================================== */
#include "chip.h"

#define U0 GARUDA_APB_BASE_UART0
#define U1 GARUDA_APB_BASE_UART1
#define UREG(base, off) (*(volatile uint32_t *)(uintptr_t)((base) + (off)))
#define THR     0x000u
#define RBR     0x000u
#define DLL     0x000u
#define DLM     0x004u
#define LCR     0x00Cu
#define LSR     0x014u
#define DMACTL  0xFE8u
#define LSR_DR   (1u << 0)
#define LSR_THRE (1u << 5)
#define DIV      25u                /* 4.8 Mbaud at 125 MHz, as t_chip_uart */
#define N        8u
#define ST_COMP  (1u << 17)
#define ST_ERR   (1u << 18)

volatile uint32_t n_trap;
static uint32_t rx_buf[N], tx_src[N];
static const uint8_t msg[N] = { 0x47, 0x41, 0x52, 0x55, 0x44, 0x41, 0x00, 0xFF };

uint32_t trap_handler(uint32_t mcause, uint32_t mepc)
{
    n_trap++;
    return (mcause & MCAUSE_INT) ? mepc : mepc + 4;
}

static void cfg(uint32_t base)
{
    UREG(base, LCR) = 0x83u;
    UREG(base, DLL) = DIV & 0xFFu;
    UREG(base, DLM) = DIV >> 8;
    UREG(base, LCR) = 0x03u;
}

static int wait_done(uint32_t ch)
{
    for (uint32_t spin = 400000u; spin; spin--)
        if (DMA_STAT(ch) & (ST_COMP | ST_ERR)) return 1;
    return 0;
}

int main(void)
{
    uint32_t st;
    cfg(U0); cfg(U1);
    while (UREG(U0, LSR) & LSR_DR) (void)UREG(U0, RBR);       /* drain anything stale */
    while (UREG(U1, LSR) & LSR_DR) (void)UREG(U1, RBR);

    /* ---- P2M: UART0 rx -> DSRAM by channel 2 ------------------------------------ */
    for (uint32_t i = 0; i < N; i++) rx_buf[i] = 0xDEAD0000u;
    DMA_SAR(2) = U0 + RBR;
    DMA_DAR(2) = (uint32_t)(uintptr_t)rx_buf;
    DMA_CNT(2) = N;
    DMA_CR(2)  = DMA_CR_EN | (0u << 1) /* P2M */ | DMA_CR_DINC | DMA_CR_WORD;
    UREG(U0, DMACTL) = 1u;                                    /* request on RX data */
    for (uint32_t i = 0; i < N; i++) {
        uint32_t spin = 100000u;
        while (!(UREG(U0, LSR) & LSR_THRE)) if (--spin == 0u) return 1;
        UREG(U0, THR) = msg[i];
    }
    if (!wait_done(2))                                        return 2;
    UREG(U0, DMACTL) = 0u;
    st = DMA_STAT(2);
    if ((st & ST_ERR) || (st & 0xFFFFu))                      return 3;
    for (uint32_t i = 0; i < N; i++) if ((rx_buf[i] & 0xFFu) != msg[i]) return 4;
    if (UREG(U0, LSR) & LSR_DR)                               return 5;   /* nothing left behind */
    DMA_ICLR(2) = 3u;

    /* ---- M2P: DSRAM -> UART1 tx by channel 3; the core reads the loopback --------- */
    for (uint32_t i = 0; i < N; i++) tx_src[i] = msg[N - 1 - i];
    DMA_SAR(3) = (uint32_t)(uintptr_t)tx_src;
    DMA_DAR(3) = U1 + THR;
    DMA_CNT(3) = N;
    DMA_CR(3)  = DMA_CR_EN | (1u << 1) /* M2P */ | DMA_CR_SINC | DMA_CR_WORD;
    UREG(U1, DMACTL) = 2u;                                    /* request on TX space */
    for (uint32_t i = 0; i < N; i++) {
        uint32_t spin = 100000u, b;
        while (!(UREG(U1, LSR) & LSR_DR)) if (--spin == 0u) return 6;
        b = UREG(U1, RBR) & 0xFFu;
        if (b != msg[N - 1 - i])                              return 7;
    }
    if (!wait_done(3))                                        return 8;
    UREG(U1, DMACTL) = 0u;
    st = DMA_STAT(3);
    if ((st & ST_ERR) || (st & 0xFFFFu))                      return 9;
    DMA_ICLR(3) = 3u;
    return n_trap ? 10 : 0;
}
