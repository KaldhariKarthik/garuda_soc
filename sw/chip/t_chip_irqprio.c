/* =============================================================================
 * t_chip_irqprio.c - the CLIC's enable, level and priority, at chip level
 * (1-TOPS G6 6.5; nesting, G6 6.13)
 *
 * Six sources firmware can raise and hold as levels, each from its own block:
 * UART0/1/2 THRE (IDs 17..19), GPIO (20, a latched pad edge), PWM (21, a latched
 * period boundary) and the software interrupt (23).
 *   1  per source: pending visible in CLICIP with its enable off and no trap;
 *      enabled at level 0, never taken (CLIC [N-6.6]); at a level, taken once
 *   2  priority: all six raised with MIE off under a table of levels (ties,
 *      level 0 among them); with MIE on they are served highest level first,
 *      ties to the lowest ID ([N-7.5]); a level-0 source is never served
 *   3  nesting ([N-7.9], [N-7.10]): inside a level-40 handler with MIE on, a
 *      level-200 source preempts at once, a level-40 one waits until the
 *      handler returns; mintstatus.mil reads 40 inside it
 * Returns 0 = pass, otherwise the step * 10 + n (step 1: 10 + source index * 3).
 * ========================================================================== */
#include "chip.h"

#define PREG(base, off) (*(volatile uint32_t *)(uintptr_t)((base) + (off)))
#define IRQSTAT 0xFE0u
#define IRQEN   0xFE4u
#define GPIO    GARUDA_APB_BASE_GPIO
#define PWM     GARUDA_APB_BASE_PWM
#define MARK(n) CSRW(mscratch, (n))

#define NSRC 6u
static const uint32_t sid[NSRC] = { 17, 18, 19, 20, 21, 23 };
static const uint32_t ubase[3]  = { GARUDA_APB_BASE_UART0, GARUDA_APB_BASE_UART1, GARUDA_APB_BASE_UART2 };

volatile uint32_t order[16], n_order, hits[32], bad, nest_step, mil_seen;

static void spin(uint32_t n) { while (n--) __asm__ volatile ("nop"); }

static void raise(uint32_t id)
{
    if (id <= 19)       PREG(ubase[id - 17], IRQEN) = 0x2u;     /* THRE: true while the FIFO is empty */
    else if (id == 20)  PREG(GPIO, IRQEN) = 0x1u;               /* IRQSTAT latched in setup */
    else if (id == 21)  PREG(PWM, IRQEN) = 0x1u;                /* likewise */
    else                CLICSWI = 1u;
}

static void drop(uint32_t id)
{
    if (id <= 19)       PREG(ubase[id - 17], IRQEN) = 0u;
    else if (id == 20)  PREG(GPIO, IRQEN) = 0u;
    else if (id == 21)  PREG(PWM, IRQEN) = 0u;
    else                CLICSWI = 0u;
}

uint32_t trap_handler(uint32_t mcause, uint32_t mepc)
{
    uint32_t id = mcause & 0x1Fu;
    if (!(mcause & MCAUSE_INT)) { bad++; return mepc + 4; }
    drop(id);
    hits[id]++;
    if (n_order < 16) order[n_order++] = id;
    if (nest_step == 1 && id == 17) {                /* step 3: the level-40 handler */
        mil_seen = CSRR(0x346) & 0xFFu;      /* mintstatus.mil */
        CSRS(mstatus, 8);                            /* nesting allowed */
        raise(18);                                   /* level 40: must wait */
        spin(200);
        if (hits[18]) bad++;
        raise(19);                                   /* level 200: must preempt */
        spin(200);
        if (hits[19] != 1) bad++;
        CSRC(mstatus, 8);
        CSRW(mcause, mcause);                        /* mret restores mil from mcause.mpil (MPIE is in mstatus) */
        nest_step = 2;
    }
    return mepc;
}

/* wait until k traps have been served since n_order was last cleared, with a bound.
 * Absolute, not relative: the interrupt is often taken before this is even called. */
static int wait_n(uint32_t k)
{
    uint32_t n = 20000u;
    while (n_order < k) if (--n == 0u) return 1;
    return 0;
}

int main(void)
{
    uint32_t i, j, all = 0;

    /* latch the GPIO and PWM sources once, with their interrupt enables off */
    PREG(GPIO, 0x004u) = 0x3u; PREG(GPIO, 0x000u) = 0x3u;      /* GPIOEN, PADDIR: outputs */
    PREG(GPIO, 0x014u) = 0x1u;                                  /* pin0 low */
    PREG(GPIO, 0x01Cu) = 0x2u; PREG(GPIO, 0x018u) = 0x1u;       /* INTTYPE either edge, INTEN pin0 */
    PREG(GPIO, IRQEN) = 0u; PREG(GPIO, IRQSTAT) = 0x1u;
    PREG(GPIO, 0x010u) = 0x1u;                                  /* the edge */
    spin(20);
    if (!(PREG(GPIO, IRQSTAT) & 1u))                    return 1;
    PREG(PWM, IRQEN) = 0u; PREG(PWM, 0x000u) = 0u; PREG(PWM, 0x004u) = 20u;
    PREG(PWM, 0x008u) = 0x1u;                                   /* EN: a period boundary */
    for (i = 0; i < 2000u && !(PREG(PWM, IRQSTAT) & 1u); i++) ;
    PREG(PWM, 0x008u) = 0u;
    if (!(PREG(PWM, IRQSTAT) & 1u))                     return 2;

    for (i = 0; i < NSRC; i++) all |= 1u << sid[i];
    CLICIE = 0;
    CSRS(mstatus, 8);

    /* ---- 1: enable and level, per source ---------------------------------------- */
    for (i = 0; i < NSRC; i++) {
        uint32_t id = sid[i], b = 1u << id;
        MARK(10 + i);
        CLICINTCFG(id) = 0;
        raise(id);
        spin(100);
        if (!(CLICIP & b) || n_order)                   return 10 + 3 * i;   /* pending, not taken */
        CLICIE = b;                                     /* enabled at level 0 */
        spin(100);
        if (n_order)                                    return 11 + 3 * i;
        CLICINTCFG(id) = 7;
        if (wait_n(1) || order[0] != id || hits[id] != 1) return 12 + 3 * i;
        if (CLICIP & b)                                 return 12 + 3 * i;   /* dropped at the source */
        CLICIE = 0; n_order = 0; hits[id] = 0;
    }

    /* ---- 2: priority ------------------------------------------------------------ */
    {
        static const uint8_t lv[12][NSRC] = {     /* levels of IDs 17, 18, 19, 20, 21, 23 */
            {  10,  20,  30,  40,  50,  60 }, {  60,  50,  40,  30,  20,  10 },
            { 100, 100, 100, 100, 100, 100 }, {   5, 200,   5, 200,   5, 200 },
            { 255,   1, 128,   0,  64,   0 }, {   0,   0,   0,   0,   0,   9 },
            {  33,  33,  34,  34,  32,  32 }, {   1,   2,   3,   3,   2,   1 },
            { 200,  10, 200,  10, 200,  10 }, {  77,   0,  77,   0,  77,   0 },
            {  12,  99,  45,  99,  12,  45 }, { 254, 255, 253, 255, 254, 253 } };
        for (j = 0; j < 12; j++) {
            uint32_t exp[NSRC], ne = 0, used = 0, k;
            MARK(20 + j);
            CSRC(mstatus, 8);
            for (i = 0; i < NSRC; i++) { CLICINTCFG(sid[i]) = lv[j][i]; raise(sid[i]); }
            CLICIE = all;
            spin(50);
            /* expected order: highest level first, ties to the lower ID, level 0 never */
            for (k = 0; k < NSRC; k++) {
                int best = -1;
                for (i = 0; i < NSRC; i++)
                    if (!(used & (1u << i)) && lv[j][i] != 0 &&
                        (best < 0 || lv[j][i] > lv[j][best]))   /* sid[] ascending: first wins a tie */
                        best = (int)i;
                if (best < 0) break;
                used |= 1u << best; exp[ne++] = sid[best];
            }
            n_order = 0;
            CSRS(mstatus, 8);
            if (wait_n(ne))                             return 20 + j;
            spin(200);
            CSRC(mstatus, 8);
            if (n_order != ne)                          return 20 + j;   /* nothing extra: level 0 stayed */
            for (k = 0; k < ne; k++) if (order[k] != exp[k]) return 20 + j;
            for (i = 0; i < NSRC; i++) if (lv[j][i] == 0) {
                if (!(CLICIP & (1u << sid[i])))         return 20 + j;   /* still pending, never served */
                drop(sid[i]);
            }
            CLICIE = 0;
        }
        for (i = 0; i < 32; i++) hits[i] = 0;
    }

    /* ---- 3: nesting --------------------------------------------------------------- */
    MARK(30);
    CLICINTCFG(17) = 40; CLICINTCFG(18) = 40; CLICINTCFG(19) = 200;
    CLICIE = (1u << 17) | (1u << 18) | (1u << 19);
    n_order = 0; nest_step = 1;
    CSRS(mstatus, 8);
    raise(17);
    if (wait_n(3))                                      return 30;
    CSRC(mstatus, 8);
    if (nest_step != 2 || bad)                          return 31;
    if (order[0] != 17 || order[1] != 19 || order[2] != 18) return 32;   /* 19 inside 17, 18 after */
    if (mil_seen != 40)                                 return 33;
    if (CSRR(0x346) & 0xFFu)                    return 34;       /* mil back to 0 */
    CLICIE = 0;
    return bad ? 35 : 0;
}
