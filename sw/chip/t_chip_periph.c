/* =============================================================================
 * t_chip_periph.c - all seven peripherals, from the core, through the fabric.
 *
 * Every block has a different job, so this test does not try to exercise each
 * one deeply - the block TBs do that. It proves the thing only a chip-level
 * test can: that all seven are actually wired to the bus, at the right window,
 * answering as themselves, with no window stealing another's accesses.
 *
 * Returns 0 = pass, n = failed step n.
 * ========================================================================== */
#include "chip.h"

#define PREG(base, off) (*(volatile uint32_t *)(uintptr_t)((base) + (off)))
#define ID_OFF   0xFECu

volatile uint32_t exc_count;

uint32_t trap_handler(uint32_t mcause, uint32_t mepc)
{
    exc_count++;
    return (mcause & MCAUSE_INT) ? mepc : mepc + 4;
}

int main(void)
{
    uint32_t i, v;

    /* 1: every window identifies itself, and none answers for another.
     *    ID is {0x6A5D, block, rev}, so a wrong window shows up immediately. */
    {
        static const uint32_t base[7] = {
            GARUDA_APB_BASE_SPI_MASTER, GARUDA_APB_BASE_I2C,
            GARUDA_APB_BASE_UART0, GARUDA_APB_BASE_UART1,
            GARUDA_APB_BASE_UART2, GARUDA_APB_BASE_GPIO,
            GARUDA_APB_BASE_PWM };
        static const uint32_t blk[7] = { 13, 15, 16, 17, 18, 19, 20 };
        for (i = 0; i < 7; i++)
            if (PREG(base[i], ID_OFF) != (0x6A5D0000u | (blk[i] << 8) | 1u))
                return 1;
    }
    if (exc_count != 0u)                            return 1;

    /* 2: GPIO drives a pin and reads it back through the pad */
    PREG(GARUDA_APB_BASE_GPIO, 0x004u) = 0x3u;      /* GPIOEN both */
    PREG(GARUDA_APB_BASE_GPIO, 0x000u) = 0x1u;      /* PADDIR: pin0 output */
    PREG(GARUDA_APB_BASE_GPIO, 0x010u) = 0x1u;      /* PADOUTSET */
    for (i = 0; i < 20; i++) __asm__ volatile ("nop");
    if (!(PREG(GARUDA_APB_BASE_GPIO, 0x008u) & 1u)) return 2;   /* PADIN */
    PREG(GARUDA_APB_BASE_GPIO, 0x014u) = 0x1u;      /* PADOUTCLR */
    for (i = 0; i < 20; i++) __asm__ volatile ("nop");
    if (PREG(GARUDA_APB_BASE_GPIO, 0x008u) & 1u)    return 2;
    /* pin 1 is an input with a pull-down, so it reads 0 */
    if (PREG(GARUDA_APB_BASE_GPIO, 0x008u) & 2u)    return 2;

    /* 3: PWM runs - the live counter in STATUS advances */
    PREG(GARUDA_APB_BASE_PWM, 0x000u) = 0u;         /* PRESCALE */
    PREG(GARUDA_APB_BASE_PWM, 0x004u) = 2000u;      /* PERIOD */
    PREG(GARUDA_APB_BASE_PWM, 0x010u) = 500u;       /* DUTY0 */
    PREG(GARUDA_APB_BASE_PWM, 0x008u) = 0x11u;      /* EN + channel 0 */
    v = PREG(GARUDA_APB_BASE_PWM, 0x00Cu) & 0xFFFFu;
    for (i = 0; i < 50; i++) __asm__ volatile ("nop");
    if ((PREG(GARUDA_APB_BASE_PWM, 0x00Cu) & 0xFFFFu) == v) return 3;
    PREG(GARUDA_APB_BASE_PWM, 0x008u) = 0u;         /* motors off again */

    /* 4: I2C reaches the slave model on the board - a full register write */
    PREG(GARUDA_APB_BASE_I2C, 0x000u) = 24u;        /* PRESCALE: fast, for sim */
    PREG(GARUDA_APB_BASE_I2C, 0x018u) = 20000u;     /* TIMEOUT */
    PREG(GARUDA_APB_BASE_I2C, 0x004u) = 1u;         /* EN */
    {
        static const uint32_t cmd[3] = { 0x09u, 0x08u, 0x0Au };  /* STA|WR, WR, WR|STO */
        static const uint32_t dat[3] = { 0x90u, 0x55u, 0xC3u };  /* addr, ptr, data */
        uint32_t k, spin;
        for (k = 0; k < 3; k++) {
            PREG(GARUDA_APB_BASE_I2C, 0x008u) = dat[k];          /* TXDATA */
            PREG(GARUDA_APB_BASE_I2C, 0x010u) = cmd[k];          /* CMD */
            spin = 200000u;
            while (PREG(GARUDA_APB_BASE_I2C, 0x014u) & 1u)       /* STATUS.TIP */
                if (--spin == 0u) return 4;
            if (PREG(GARUDA_APB_BASE_I2C, 0x014u) & (1u << 3))   /* RXNACK */
                return 4;
        }
    }

    /* 6: nothing trapped anywhere above */
    if (exc_count != 0u)                            return 6;

    return 0;
}
