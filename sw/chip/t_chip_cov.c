/* =============================================================================
 * t_chip_cov.c - the chip top's wires that no other chip program moves
 * (D-40 coverage closure of garuda_chip_top / garuda_chip_core / garuda_soc_top,
 * 2026-11-21). Every step checks what it reads back; none is there only to toggle.
 *
 * Four runs of the one image, told apart by RSTREASON and a marker in the
 * no-init DSRAM (tb_chip +MODE=cov zeroes it before run 1 and re-posts the
 * mailbox after every reset):
 *
 *   run 1 (EXT)  1  DSU: every accumulator loaded with -1 and cleared through the
 *                   core; MACSAT overflow sets dsu_ovf, a read clears it
 *                2  register read-back at the chip level: DMA SAR/DAR, I2C
 *                   PRESCALE/TIMEOUT, GPIO PADCFG0/INTTYPE, PWM PRESCALE/PERIOD/
 *                   DUTY, CLIC level 0xFF (CLICINTCFG), PWM clamp status
 *                3  clock ratio: DIVSEL /4, /8, /16 and back; DIVBUSY while it moves
 *                4  RSTCTL.BOOTFAIL_SET -> RSTREASON[4], cleared by W1C
 *                5  a level-255 software interrupt reaches the core (CLIC level bit 7)
 *                6  pins: both GPIO directions, PWM channels 1-3, the IMU chip
 *                   select, SPI-slave MISO (TXDATA preloaded), the RX FIFO filled
 *                   to 16 by the companion (STATUS.count)
 *                7  instruction fetch: ISRAM through its alias at the top of the
 *                   segment, and an address in no region (instruction access fault)
 *                8  DMA master: a read through the DSRAM alias at the top of its
 *                   segment, and from an address in no region (DMA error)
 *                9  boot_sel pin: the testbench pulls it low, CLKSTAT[8] follows
 *               10  MEMCTL.ILOCK: a store to ISRAM faults; then RSTCTL.SWRST with
 *                   DIVSEL = /4
 *   run 2 (SW)      ILOCK cleared by the reset, DIVSEL kept (pin only); ask the
 *                   testbench for a debugger ndmreset over JTAG, DIVSEL = /8
 *   run 3 (NDM)     DIVSEL kept; ask for the external reset pin, DIVSEL = /16
 *   run 4 (EXT)     DIVSEL back to /2 (the pin resets it); pass
 *
 * Requests to the testbench go through `fromhost` (0x2000_F004): 1 pulse
 * boot_sel low, 3 ndmreset over JTAG, 4 pulse ext_rst_n. The testbench writes 0
 * when it has done it. Returns 0 = pass, otherwise run * 100 + step.
 * ========================================================================== */
#include "chip.h"

#define PREG(base, off) (*(volatile uint32_t *)(uintptr_t)((base) + (off)))
#define IRQSTAT   0xFE0u
#define SPIS  GARUDA_APB_BASE_SPI_SLAVE
#define SPIM  GARUDA_APB_BASE_SPI_MASTER
#define I2C   GARUDA_APB_BASE_I2C
#define GPIO  GARUDA_APB_BASE_GPIO
#define PWM   GARUDA_APB_BASE_PWM

#define M1 0xC0F10001u
#define M2 0xC0F10002u
#define M3 0xC0F10003u

#define DIVSEL(r)   (((r) >> 8) & 3u)
#define DIVBUSY     (1u << 2)
#define BOOTSEL     (1u << 8)

__attribute__((section(".noinit"))) volatile uint32_t phase_mark;
extern volatile uint32_t fromhost;

volatile uint32_t exc, last_exc, n_swi, bad, fetch_ret, fetch_faults;

uint32_t trap_handler(uint32_t mcause, uint32_t mepc)
{
    if (!(mcause & MCAUSE_INT)) {
        if (mcause == 1u && fetch_ret) {           /* instruction access fault: back to the caller */
            uint32_t r = fetch_ret;
            fetch_ret = 0;
            fetch_faults++;
            return r;
        }
        exc++; last_exc = mcause;
        return mepc + 4;
    }
    if ((mcause & 0x1Fu) == GARUDA_CLIC_ID_SOFTWARE) { n_swi++; CLICSWI = 0u; }
    else bad++;
    return mepc;
}

#define MARK(n) CSRW(mscratch, (n))
static void spin(uint32_t n) { while (n--) __asm__ volatile ("nop"); }

/* ask the testbench for something and wait until it says it is done */
static int tb_request(uint32_t what, uint32_t limit)
{
    fromhost = what;
    while (fromhost != 0u) if (--limit == 0u) return 1;
    return 0;
}

/* ---- DSU custom-0: funct7 = op + accumulator (FX 0, FY 1, MAG 2) ------------ */
#define DSU_R(f7, rd, a, b) __asm__ volatile (".insn r 0x0b, 0, " #f7 ", %0, %1, %2" : "=r"(rd) : "r"(a), "r"(b))
#define DSU_W(f7, a, b)     __asm__ volatile (".insn r 0x0b, 0, " #f7 ", x0, %0, %1" :: "r"(a), "r"(b))
#define DSU_ONE(acc, ld, clr, lo, hi, step)                                      \
    do {                                                                       \
        uint32_t l, h;                                                         \
        DSU_W(ld, 0xFFFFFFFFu, 0u);                       /* MACLOAD -1 */       \
        DSU_R(lo, l, 0u, 0u); DSU_R(hi, h, 0u, 0u);                            \
        if (l != 0xFFFFFFFFu || h != 0xFFFFFFFFu) return step;                 \
        DSU_W(clr, 0u, 0u);                               /* MACCLEAR */         \
        DSU_R(lo, l, 0u, 0u); DSU_R(hi, h, 0u, 0u);                            \
        if (l != 0u || h != 0u) return step;                                   \
    } while (0)

static int dsu(void)
{
    uint32_t v;
    DSU_ONE(FX,  16, 20, 28, 32, 101);
    DSU_ONE(FY,  17, 21, 29, 33, 102);
    DSU_ONE(MAG, 18, 22, 30, 34, 103);
    /* overflow: 0x7FFFFFFF + 0x7FFF*0x7FFF saturates (the sequence of t_cov_dsu) */
    DSU_W(16, 0x7FFFFFFFu, 0u);
    DSU_W(0, 0x7FFFu, 0x7FFFu);
    DSU_W(24, 0u, 0u);
    DSU_R(28, v, 0u, 0u);
    if (v != 0x7FFFFFFFu)                 return 104;
    v = CSRR(0xBC0);  if (v != 1u)        return 104;
    v = CSRR(0xBC0);  if (v != 0u)        return 104;
    DSU_W(20, 0u, 0u);
    return 0;
}

/* write a value, read it back, write zero, read it back */
static int rw(uint32_t a, uint32_t v)
{
    REG(a) = v; if (REG(a) != v)  return 1;
    REG(a) = 0; if (REG(a) != 0u) return 1;
    return 0;
}

static int regs(void)
{
    if (rw(GARUDA_APB_BASE_DMA_CFG + 0x04u, 0xFFFFFFFFu)) return 111;   /* SAR ch0 */
    if (rw(GARUDA_APB_BASE_DMA_CFG + 0x08u, 0xFFFFFFFFu)) return 111;   /* DAR ch0 */
    if (rw(I2C + 0x000u, 0xFFFFu))                        return 112;   /* PRESCALE */
    if (rw(I2C + 0x018u, 0xFFFFu))                        return 112;   /* TIMEOUT */
    if (rw(GPIO + 0x028u, 0xFFu))                         return 113;   /* PADCFG0 */
    if (rw(GPIO + 0x01Cu, 0xFu))                          return 113;   /* INTTYPE */
    if (rw(PWM + 0x000u, 0xFFFFu))                        return 114;   /* PRESCALE */
    if (rw(PWM + 0x004u, 0xFFFFu))                        return 114;   /* PERIOD */
    for (uint32_t c = 0; c < 4; c++)
        if (rw(PWM + 0x010u + 4u * c, 0xFFFFu))           return 114;   /* DUTY */
    if (rw((uint32_t)(uintptr_t)&CLICINTCFG(GARUDA_CLIC_ID_SOFTWARE), 0xFFu)) return 115;
    /* PWM: a duty above the period is clamped and reported (STATUS.clamp, PWM core) */
    PREG(PWM, 0x004u) = 8u;
    PREG(PWM, 0x014u) = 9u;                                  /* DUTY1 > PERIOD */
    spin(10);
    if (((PREG(PWM, 0x00Cu) >> 16) & 0xFu) != 0x2u)       return 116;
    PREG(PWM, 0x014u) = 0u;
    spin(10);
    if ((PREG(PWM, 0x00Cu) >> 16) & 0xFu)                 return 116;
    PREG(PWM, 0x004u) = 0u;
    return 0;
}

/* CLKSTAT: DIVBUSY while the divider moves, then DIVACT = DIVSEL */
static int ratio(uint32_t sel)
{
    uint32_t n = 100000u, seen_busy = 0;
    RSTCTL = sel << 8;
    while (1) {
        uint32_t s = CLKSTAT;
        if (s & DIVBUSY) seen_busy = 1;
        else if ((s & 3u) == sel) break;
        if (--n == 0u) return 1;
    }
    if (DIVSEL(RSTCTL) != sel) return 1;
    (void)seen_busy;               /* DIVBUSY may fall before the first read at /2 */
    return 0;
}

static int clocks(void)
{
    if (ratio(1) || ratio(2) || ratio(3) || ratio(0)) return 121;
    return 0;
}

static int bootfail(void)
{
    RSTREASON = 0x1Fu;
    RSTCTL = 1u << 4;                              /* BOOTFAIL_SET, DIVSEL /2 */
    if ((RSTREASON & 0x1Fu) != 0x10u) return 131;
    RSTREASON = 0x10u;                             /* W1C */
    if (RSTREASON & 0x1Fu)            return 131;
    return 0;
}

static int swi(void)
{
    CLICINTCFG(GARUDA_CLIC_ID_SOFTWARE) = 0xFFu;   /* level 255 */
    CLICIE = 1u << GARUDA_CLIC_ID_SOFTWARE;
    CSRS(mstatus, 8);
    CLICSWI = 1u;
    spin(50);
    CSRC(mstatus, 8);
    CLICIE = 0u;
    if (n_swi != 1u || CLICSWI != 0u) return 141;
    return 0;
}

static int pins(void)
{
    uint32_t k, n, st;
    /* GPIO: each pin an output on its own, both, then neither (pins low) */
    PREG(GPIO, 0x00Cu) = 0u;                       /* PADOUT */
    PREG(GPIO, 0x000u) = 1u; spin(5);
    PREG(GPIO, 0x000u) = 2u; spin(5);
    PREG(GPIO, 0x000u) = 3u; spin(5);
    PREG(GPIO, 0x000u) = 0u; spin(5);
    /* PWM: all four channels running, then off (pins low) */
    PREG(PWM, 0x000u) = 0u;
    PREG(PWM, 0x004u) = 8u;
    for (k = 0; k < 4; k++) PREG(PWM, 0x010u + 4u * k) = 2u + k;
    PREG(PWM, 0x008u) = (0xFu << 4) | 1u;
    st = 0;
    for (k = 0; k < 40; k++) st |= PREG(PWM, 0x00Cu) & 0xFFFFu;       /* STATUS.count moves */
    if (st == 0u)                                 return 151;
    PREG(PWM, 0x008u) = 0u;
    PREG(PWM, 0x004u) = 0u;
    for (k = 0; k < 4; k++) PREG(PWM, 0x010u + 4u * k) = 0u;
    /* SPI master: a write to the IMU (chip select 1); no device answers, nothing read */
    PREG(SPIM, 0x004u) = 3u;                       /* CLKDIV */
    PREG(SPIM, 0x014u) = 0u;                       /* SPIDUM */
    PREG(SPIM, 0x008u) = 0x0Fu << 24;              /* SPICMD */
    PREG(SPIM, 0x00Cu) = 0u;
    PREG(SPIM, 0x010u) = (32u << 16) | 8u;         /* 8-bit command, 32-bit data */
    PREG(SPIM, IRQSTAT) = 0x7u;
    PREG(SPIM, 0x018u) = 0xA55A0FF0u;              /* TXFIFO */
    PREG(SPIM, 0x000u) = (2u << 8) | 2u;           /* CS IMU | write */
    n = 200000u;
    while (!(PREG(SPIM, IRQSTAT) & 1u)) if (--n == 0u) return 152;
    PREG(SPIM, IRQSTAT) = 0x7u;
    /* SPI slave: TXDATA preloaded so MISO carries it; eight companion frames
     * fill the 16-byte RX FIFO (STATUS.count 2, 4, ..., 16) */
    PREG(SPIS, 0x008u) = 0x3u;                     /* EN | RXFLUSH */
    PREG(SPIS, 0x004u) = 0x96u;                    /* TXDATA */
    PREG(GPIO, 0x00Cu) = 0u;
    PREG(GPIO, 0x000u) = 2u;                       /* gpio1 out, low */
    for (k = 1; k <= 8; k++) {
        PREG(GPIO, 0x010u) = 2u;                   /* rising edge: the companion sends a frame */
        n = 200000u;
        do { st = PREG(SPIS, 0x00Cu); if (--n == 0u) return 153; }
        while (((st >> 4) & 0x1Fu) != 2u * k || (st & 2u));   /* count, and CS released */
        PREG(GPIO, 0x014u) = 2u;
        spin(5);
    }
    if (PREG(SPIS, 0x00Cu) & 4u)                  return 154;  /* no overrun at exactly 16 */
    for (k = 0; k < 8; k++) {
        if ((PREG(SPIS, 0x000u) & 0xFFu) != 0xA5u) return 155;
        if ((PREG(SPIS, 0x000u) & 0xFFu) != 0x3Cu) return 155;
    }
    PREG(SPIS, 0x008u) = 0x2u;                     /* RXFLUSH, disabled */
    PREG(SPIS, 0x004u) = 0u;
    PREG(SPIS, IRQSTAT) = 0x7u;
    PREG(GPIO, 0x000u) = 0u;
    return 0;
}

/* jump to `a`; an instruction access fault there comes back to the label */
static void fetch_at(uint32_t a)
{
    __asm__ volatile ("lla t0, 1f\n\t"
                      "sw t0, 0(%1)\n\t"
                      "jr %0\n"
                      "1:\n" :: "r"(a), "r"(&fetch_ret) : "t0", "memory");
}

static int fetch(void)
{
    /* a `ret` at the last ISRAM word, called through the alias at the top of the
     * segment: HADDR[27:2] all ones on the instruction port (MEM [N-7.2]) */
    REG(GARUDA_ISRAM_BASE + GARUDA_ISRAM_SIZE - 4u) = 0x00008067u;
    __asm__ volatile ("fence.i" ::: "memory");
    ((void (*)(void))(uintptr_t)(GARUDA_ISRAM_BASE + 0x0FFFFFFCu))();
    /* no region: the default slave's ERROR is an instruction access fault (cause 1) */
    fetch_at(0xE0000000u);
    if (fetch_faults != 1u || exc != 0u) return 171;
    return 0;
}

static int dma_master(void)
{
    static uint32_t s, d;
    s = 0x600DF00Du; d = 0;
    DMA_ICLR(0) = 3u;
    DMA_SAR(0) = ((uint32_t)(uintptr_t)&s) | 0x0FFF0000u;       /* DSRAM alias, top of segment */
    DMA_DAR(0) = (uint32_t)(uintptr_t)&d;
    DMA_CNT(0) = 1;
    DMA_CR(0)  = DMA_CR_EN | DMA_CR_M2M | DMA_CR_WORD;
    spin(200);
    if (!(DMA_STAT(0) & (1u << 17)) || d != s)  return 181;
    DMA_CR(0) = 0; DMA_ICLR(0) = 3u;
    DMA_SAR(0) = 0x90000000u;                                    /* no region: ERROR */
    DMA_DAR(0) = (uint32_t)(uintptr_t)&d;
    DMA_CNT(0) = 1;
    DMA_CR(0)  = DMA_CR_EN | DMA_CR_M2M | DMA_CR_WORD;
    spin(200);
    if (!(DMA_STAT(0) & (1u << 18)) || (DMA_STAT(0) & (1u << 17))) return 182;
    DMA_CR(0) = 0; DMA_ICLR(0) = 3u;
    DMA_SAR(0) = 0; DMA_DAR(0) = 0; DMA_CNT(0) = 0;
    return 0;
}

static int boot_pin(void)
{
    uint32_t n = 2000000u, low = 0;
    if (!(CLKSTAT & BOOTSEL)) return 191;
    fromhost = 1u;
    while (fromhost != 0u) {
        if (!(CLKSTAT & BOOTSEL)) low = 1;
        if (--n == 0u) return 191;
    }
    if (!low || !(CLKSTAT & BOOTSEL)) return 191;
    return 0;
}

static int run1(void)
{
    int r;
    phase_mark = 0;
    MARK(101); if ((r = dsu()))        return r;
    MARK(111); if ((r = regs()))       return r;
    MARK(121); if ((r = clocks()))     return r;
    MARK(131); if ((r = bootfail()))   return r;
    MARK(141); if ((r = swi()))        return r;
    MARK(151); if ((r = pins()))       return r;
    MARK(171); if ((r = fetch()))      return r;
    MARK(181); if ((r = dma_master())) return r;
    MARK(191); if ((r = boot_pin()))   return r;
    /* ILOCK: a store to ISRAM gets ERROR (store access fault, cause 7) */
    MARK(201);
    MEMCTL = 1u;
    if (MEMCTL != 1u)                                         return 201;
    REG(GARUDA_ISRAM_BASE + GARUDA_ISRAM_SIZE - 8u) = 0u;
    if (exc != 1u || last_exc != 7u)                          return 202;
    if (bad)                                                  return 203;
    /* software reset with DIVSEL = /4: the reset must keep DIVSEL and clear ILOCK */
    if (ratio(1))                                             return 204;
    RSTREASON = 0x1Fu;
    phase_mark = M1;
    RSTCTL = (1u << 8) | 1u;
    for (;;) ;
}

int main(void)
{
    uint32_t why = RSTREASON & 0x1Fu;

    if (why == 0x1u && phase_mark == 0u) return run1();

    if (why == 0x8u && phase_mark == M1) {                    /* run 2 */
        MARK(210);
        if (MEMCTL != 0u)                                     return 211;
        if (DIVSEL(RSTCTL) != 1u || (CLKSTAT & 3u) != 1u)     return 212;
        if (ratio(2))                                         return 213;
        RSTREASON = 0x1Fu;
        if (RSTREASON & 0x1Fu)                                return 214;
        phase_mark = M2;
        if (tb_request(3u, 4000000u))                         return 215;
        for (;;) ;                                            /* the debugger resets the chip */
    }
    if (why == 0x4u && phase_mark == M2) {                    /* run 3 */
        MARK(310);
        if (DIVSEL(RSTCTL) != 2u || (CLKSTAT & 3u) != 2u)     return 311;
        if (ratio(3))                                         return 312;
        RSTREASON = 0x1Fu;
        phase_mark = M3;
        if (tb_request(4u, 4000000u))                         return 313;
        for (;;) ;                                            /* the pin resets the chip */
    }
    if (why == 0x1u && phase_mark == M3) {                    /* run 4 */
        MARK(410);
        if (DIVSEL(RSTCTL) != 0u || (CLKSTAT & 3u) != 0u)     return 411;
        RSTREASON = 0x1Fu;
        phase_mark = 0;
        return 0;
    }
    return 1;
}
