/* =============================================================================
 * t_chip_uart.c - the three UARTs from the core, through the real fabric.
 *
 * tb_chip loops each instance's tx back to its own rx, so a byte written to
 * THR must come back out of RBR on the SAME instance and on neither other one.
 * That is R-9 (three independent blocks) and the pin path, in one test.
 *
 * Returns 0 = pass, n = failed step n.
 * ========================================================================== */
#include "chip.h"

#define U0 GARUDA_APB_BASE_UART0
#define U1 GARUDA_APB_BASE_UART1
#define U2 GARUDA_APB_BASE_UART2

#define UREG(base, off) (*(volatile uint32_t *)(uintptr_t)((base) + (off)))
#define THR     0x000u
#define RBR     0x000u
#define DLL     0x000u
#define DLM     0x004u
#define LCR     0x00Cu
#define LSR     0x014u
#define IRQSTAT 0xFE0u
#define ID      0xFECu

#define LSR_DR   (1u << 0)
#define LSR_THRE (1u << 5)

/* 125 MHz / (25 + 1) = 4.8 Mbaud: a byte is ~2 us, which keeps the simulation
 * short. The baud arithmetic itself is proven at 115200 in tb_uart. */
#define DIV 25u

volatile uint32_t exc_count;

uint32_t trap_handler(uint32_t mcause, uint32_t mepc)
{
    exc_count++;
    return (mcause & MCAUSE_INT) ? mepc : mepc + 4;
}

static void cfg(uint32_t base)
{
    UREG(base, LCR) = 0x83u;                 /* DLAB=1, 8N1 */
    UREG(base, DLL) = DIV & 0xFFu;
    UREG(base, DLM) = DIV >> 8;
    UREG(base, LCR) = 0x03u;                 /* DLAB=0 */
}

/* send one byte and wait for the loopback to deliver it; 0 = timed out */
static int xfer(uint32_t base, uint32_t b, uint32_t *got)
{
    uint32_t spin = 100000u;
    while (!(UREG(base, LSR) & LSR_THRE))
        if (--spin == 0u) return 0;
    UREG(base, THR) = b;
    spin = 100000u;
    while (!(UREG(base, LSR) & LSR_DR))
        if (--spin == 0u) return 0;
    *got = UREG(base, RBR) & 0xFFu;
    return 1;
}

int main(void)
{
    uint32_t g;

    /* 1: three instances, three identities */
    if (UREG(U0, ID) != 0x6A5D1001u)                 return 1;   /* block 16 */
    if (UREG(U1, ID) != 0x6A5D1101u)                 return 1;   /* block 17 */
    if (UREG(U2, ID) != 0x6A5D1201u)                 return 1;   /* block 18 */

    cfg(U0); cfg(U1); cfg(U2);

    /* 2: uart0 round trip, and neither neighbour saw it */
    if (!xfer(U0, 0xA5u, &g) || g != 0xA5u)         return 2;
    if (UREG(U1, LSR) & LSR_DR)                      return 2;
    if (UREG(U2, LSR) & LSR_DR)                      return 2;

    /* 3: uart1 round trip, neighbours quiet */
    if (!xfer(U1, 0x5Au, &g) || g != 0x5Au)         return 3;
    if (UREG(U0, LSR) & LSR_DR)                      return 3;
    if (UREG(U2, LSR) & LSR_DR)                      return 3;

    /* 4: uart2 round trip, neighbours quiet */
    if (!xfer(U2, 0x3Cu, &g) || g != 0x3Cu)         return 4;
    if (UREG(U0, LSR) & LSR_DR)                      return 4;
    if (UREG(U1, LSR) & LSR_DR)                      return 4;

    /* 5: a short burst keeps its order through the FIFO */
    {
        int i;
        for (i = 0; i < 8; i++) {
            if (!xfer(U2, 0x30u + i, &g) || g != (uint32_t)(0x30u + i)) return 5;
        }
    }

    /* 6: the interrupt tail is per instance, not shared */
    UREG(U0, IRQSTAT) = 0x7u;
    UREG(U1, IRQSTAT) = 0x7u;
    if (!xfer(U0, 0x11u, &g))                       return 6;
    if (!(UREG(U0, IRQSTAT) & 1u))                   return 6;   /* uart0 saw it */
    UREG(U1, IRQSTAT) = 0x7u;                        /* clear any THRE level */
    if (UREG(U1, IRQSTAT) & 1u)                      return 6;   /* uart1 did not */

    /* 7: nothing trapped */
    if (exc_count != 0u)                            return 7;

    return 0;
}
