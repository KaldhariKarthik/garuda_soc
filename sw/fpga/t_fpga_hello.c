/* =============================================================================
 * t_fpga_hello.c - KV260 bring-up: first words out of GARUDA's uart0.
 *
 * Loaded over JTAG SBA like every chip test. Prints a banner and a few
 * self-computed values on uart0 at 115200 8N1 to the PL AXI UartLite, which
 * the host reads. Then writes tohost as usual.
 * Needs the host to put uart0 in console mode (ctrl bit 5 = 0).
 *
 * baud = pclk / (DIV + 1)   (block 16, pulp apb_uart: no 16x oversampling)
 * PCLK_HZ defaults to the FPGA build's 25 MHz. Override with -DPCLK_HZ=...
 * ========================================================================== */
#include "chip.h"

#ifndef PCLK_HZ
#define PCLK_HZ 25000000u
#endif
#define BAUD    115200u
#define DIV     ((PCLK_HZ + BAUD / 2u) / BAUD - 1u)

#define U0      GARUDA_APB_BASE_UART0
#define UREG(o) (*(volatile uint32_t *)(uintptr_t)(U0 + (o)))
#define THR 0x000u
#define DLL 0x000u
#define DLM 0x004u
#define LCR 0x00Cu
#define LSR 0x014u
#define LSR_TEMT (1u << 6)
#define LSR_THRE (1u << 5)

volatile uint32_t n_trap, last_cause;
uint32_t trap_handler(uint32_t mcause, uint32_t mepc) { n_trap++; last_cause = mcause; return mepc + 4; }

static void putc_(char c)
{
    while (!(UREG(LSR) & LSR_THRE)) ;
    UREG(THR) = (uint32_t)(uint8_t)c;
}
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void puthex(uint32_t v)
{
    int i;
    puts_("0x");
    for (i = 28; i >= 0; i -= 4) putc_("0123456789ABCDEF"[(v >> i) & 0xFu]);
}

int main(void)
{
    volatile uint32_t a = 0x12345u, b = 0x6789u;
    UREG(LCR) = 0x83u;
    UREG(DLL) = DIV & 0xFFu;
    UREG(DLM) = DIV >> 8;
    UREG(LCR) = 0x03u;

    puts_("\r\nGARUDA alive on KV260\r\n");
    puts_("misa    = "); puthex(CSRR(misa));    puts_("\r\n");
    puts_("mul     = "); puthex(a * b);         puts_("  (exp 0x75CCA2ED)\r\n");
    /* DIV/DIVU/REM/REMU are decoded but trap as illegal (CORE Sec 7.2) */
    { volatile uint32_t q = 0xFFFFFFFFu / b; (void)q; }
    puts_("divu    -> trap mcause="); puthex(last_cause); puts_("  (exp 0x00000002, CORE 7.2)\r\n");
    puts_("RSTREAS = "); puthex(RSTREASON);     puts_("\r\n");
    puts_("done.\r\n");
    while (!(UREG(LSR) & LSR_TEMT)) ;
    if ((a * b) != 0x75CCA2EDu)             return 1;
    if (n_trap != 1u || last_cause != 2u)  return 2;
    return 0;
}
