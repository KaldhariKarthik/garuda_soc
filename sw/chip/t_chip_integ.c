/* =============================================================================
 * t_chip_integ.c - integration: every wire between two blocks, from the core.
 *
 * The block benches prove each block; this proves they are joined up the way
 * garuda_system.yaml says. Nothing here tests what a block DOES with a request,
 * only that the right line arrives at the right place:
 *
 *   1  every DMA channel's completion interrupt reaches its CLIC ID
 *   2  every DMA channel's error interrupt reaches its CLIC ID, and no CLIC
 *      source reports the machine timer's cause (0x8000_0007)
 *   3  the machine timer does, and takes no CLIC ID with it
 *   4  each of the eight peripheral interrupt lines reaches its CLIC ID (14..21)
 *   5  each peripheral DMA request line reaches its own channel and no other
 *   6  an unmapped offset in every window, an absent window and a sub-word APB
 *      access each give one precise bus fault
 *
 * The companion on the SPI-slave pins sends a two-byte frame when firmware
 * raises gpio1 (tb_chip). Returns 0 = pass, otherwise the failed step * 10 + n.
 * ========================================================================== */
#include "chip.h"

#define PREG(base, off) (*(volatile uint32_t *)(uintptr_t)((base) + (off)))
#define IRQSTAT   0xFE0u
#define IRQEN     0xFE4u
#define DMACTL    0xFE8u

#define ST_COMP   (1u << 17)
#define DMA_CR_P2M (0u << 1)
#define DMA_CR_M2P (1u << 1)
#define COMP_ID(n) (GARUDA_CLIC_ID_DMA_COMPLETE_CH0_5_FIRST + (n))
#define ERR_ID(n)  (GARUDA_CLIC_ID_DMA_ERROR_CH0_5_FIRST + (n))
#define MTI_CAUSE  0x80000007u

#define SPIS  GARUDA_APB_BASE_SPI_SLAVE
#define SPIM  GARUDA_APB_BASE_SPI_MASTER
#define I2C   GARUDA_APB_BASE_I2C
#define U0    GARUDA_APB_BASE_UART0
#define U1    GARUDA_APB_BASE_UART1
#define U2    GARUDA_APB_BASE_UART2
#define GPIO  GARUDA_APB_BASE_GPIO
#define PWM   GARUDA_APB_BASE_PWM

/* the peripheral behind CLIC IDs 14..21, in ID order */
static const uint32_t pbase[8] = { SPIS, SPIM, I2C, U0, U1, U2, GPIO, PWM };

volatile uint32_t hits[32], n_mti, exc, bad, last_cause, expect_mti;
static uint32_t src[8], dst[8];

uint32_t trap_handler(uint32_t mcause, uint32_t mepc)
{
    uint32_t id = mcause & 0x1Fu;

    if (!(mcause & MCAUSE_INT)) { exc++; return mepc + 4; }
    last_cause = mcause;
    if (expect_mti && mcause == MTI_CAUSE) {
        n_mti++;
        mtimecmp_set(~0ull);
        return mepc;
    }
    hits[id]++;
    if (id >= COMP_ID(0) && id <= COMP_ID(5))      DMA_ICLR(id - COMP_ID(0)) = 1u;
    else if (id >= ERR_ID(0) && id <= ERR_ID(5))   DMA_ICLR(id - ERR_ID(0)) = 2u;
    else if (id >= GARUDA_CLIC_ID_SPI_SLAVE && id <= GARUDA_CLIC_ID_PWM_FAULT)
        PREG(pbase[id - GARUDA_CLIC_ID_SPI_SLAVE], IRQEN) = 0u;    /* drop the level at the source */
    else bad++;
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

static void spin(uint32_t n) { while (n--) __asm__ volatile ("nop"); }
#define MARK(n) CSRW(mscratch, (n))                 /* breadcrumb, printed by tb_chip on a timeout */

/* exactly one interrupt, on `id`, and nothing anywhere else since `before` */
static uint32_t total_hits(void)
{
    uint32_t i, t = 0;
    for (i = 0; i < 32; i++) t += hits[i];
    return t;
}

static void clic_only(uint32_t id)
{
    CLICINTCFG(id) = 10;
    CLICIE = 1u << id;
}

/* ask the companion on the SPI-slave pins for a frame: a rising edge on gpio1 */
static void esp_frame(void)
{
    PREG(GPIO, 0x014u) = 0x2u;                      /* PADOUTCLR pin1 */
    spin(20);
    PREG(GPIO, 0x010u) = 0x2u;                      /* PADOUTSET pin1 */
}

int main(void)
{
    uint32_t n, k, before, e0;

    CSRS(mstatus, 8);

    /* ---- 1: DMA completion, every channel ------------------------------------ */
    for (n = 0; n < 6; n++) {
        MARK(10 + n);
        src[n] = 0xC0DE0000u + n; dst[n] = 0;
        clic_only(COMP_ID(n));
        before = total_hits();
        DMA_SAR(n) = (uint32_t)(uintptr_t)&src[n];
        DMA_DAR(n) = (uint32_t)(uintptr_t)&dst[n];
        DMA_CNT(n) = 1;
        DMA_CR(n)  = DMA_CR_EN | DMA_CR_M2M | DMA_CR_WORD | DMA_CR_IECOMP;
        wait_for(&hits[COMP_ID(n)]);
        if (dst[n] != src[n] || hits[COMP_ID(n)] != 1 || total_hits() != before + 1)
            return 10 + n;
        DMA_CR(n) = 0;
    }

    /* ---- 2: DMA error, every channel ------------------------------------------- */
    /* A source in the boot ROM region is refused by the engine ([DMA N-7.x]).     */
    for (n = 0; n < 6; n++) {
        MARK(20 + n);
        clic_only(ERR_ID(n));
        before = total_hits();
        DMA_SAR(n) = GARUDA_BOOTROM_BASE;
        DMA_DAR(n) = (uint32_t)(uintptr_t)&dst[n];
        DMA_CNT(n) = 1;
        DMA_CR(n)  = DMA_CR_EN | DMA_CR_M2M | DMA_CR_WORD | DMA_CR_IEERR;
        wait_for(&hits[ERR_ID(n)]);
        if (hits[ERR_ID(n)] != 1 || total_hits() != before + 1)   return 20 + n;
        /* the cause a handler sees must name this source and nothing else */
        if (last_cause != (MCAUSE_INT | ERR_ID(n)))                return 20 + n;
        if (last_cause == MTI_CAUSE)                               return 29;
        DMA_CR(n) = 0;
        DMA_ICLR(n) = 3u;
    }

    /* ---- 3: the machine timer, and only the machine timer ---------------------- */
    MARK(30);
    CLICIE = 0;
    before = total_hits();
    expect_mti = 1;
    CSRS(mie, 0x80);
    mtimecmp_set(mtime_get() + 500);
    wait_for(&n_mti);
    CSRC(mie, 0x80);
    expect_mti = 0;
    if (n_mti != 1 || last_cause != MTI_CAUSE || total_hits() != before)  return 30;

    /* ---- 4: the eight peripheral interrupt lines ------------------------------------- */
    /* UART0/1/2: THRE is a level and true out of reset */
    for (k = 0; k < 3; k++) {
        uint32_t id = GARUDA_CLIC_ID_UART0 + k;
        MARK(40 + k);
        clic_only(id);
        before = total_hits();
        PREG(pbase[id - GARUDA_CLIC_ID_SPI_SLAVE], IRQEN) = 0x2u;
        wait_for(&hits[id]);
        if (hits[id] != 1 || total_hits() != before + 1)           return 40 + k;
    }
    /* PWM: the period boundary */
    MARK(43);
    clic_only(GARUDA_CLIC_ID_PWM_FAULT);
    before = total_hits();
    PREG(PWM, 0x000u) = 0u;                         /* PRESCALE */
    PREG(PWM, 0x004u) = 20u;                        /* PERIOD */
    PREG(PWM, IRQEN)  = 0x1u;
    PREG(PWM, 0x008u) = 0x1u;                       /* EN, no channel driven */
    wait_for(&hits[GARUDA_CLIC_ID_PWM_FAULT]);
    PREG(PWM, 0x008u) = 0u;
    if (hits[GARUDA_CLIC_ID_PWM_FAULT] != 1 || total_hits() != before + 1) return 43;
    /* GPIO: an edge on pin 0, driven by the chip itself and read back through the pad */
    MARK(44);
    clic_only(GARUDA_CLIC_ID_GPIO_AGGREGATE);
    before = total_hits();
    PREG(GPIO, 0x004u) = 0x3u;                      /* GPIOEN both */
    PREG(GPIO, 0x000u) = 0x3u;                      /* PADDIR: both outputs */
    PREG(GPIO, 0x01Cu) = 0x2u;                      /* INTTYPE pin0: either edge */
    PREG(GPIO, 0x018u) = 0x1u;                      /* INTEN pin0 */
    PREG(GPIO, IRQSTAT) = 0x1u;
    PREG(GPIO, IRQEN)  = 0x1u;
    PREG(GPIO, 0x010u) = 0x1u;                      /* PADOUTSET pin0 */
    wait_for(&hits[GARUDA_CLIC_ID_GPIO_AGGREGATE]);
    PREG(GPIO, 0x018u) = 0u;
    if (hits[GARUDA_CLIC_ID_GPIO_AGGREGATE] != 1 || total_hits() != before + 1) return 44;
    /* I2C: a transfer completes (address byte to the slave on the board) */
    MARK(45);
    clic_only(GARUDA_CLIC_ID_I2C);
    before = total_hits();
    PREG(I2C, 0x000u) = 24u;                        /* PRESCALE: fast, for sim */
    PREG(I2C, 0x018u) = 20000u;                     /* TIMEOUT */
    PREG(I2C, 0x004u) = 1u;                         /* EN */
    PREG(I2C, IRQSTAT) = 0xFu;
    PREG(I2C, IRQEN)  = 0x1u;
    PREG(I2C, 0x008u) = 0x90u;                      /* TXDATA: address 0x48, write */
    PREG(I2C, 0x010u) = 0x09u;                      /* CMD: STA | WR */
    wait_for(&hits[GARUDA_CLIC_ID_I2C]);
    if (hits[GARUDA_CLIC_ID_I2C] != 1 || total_hits() != before + 1) return 45;
    PREG(I2C, 0x010u) = 0x02u;                      /* CMD: STO, release the bus */
    n = 200000u;
    while (PREG(I2C, 0x014u) & 1u) if (--n == 0u)  return 45;
    PREG(I2C, IRQSTAT) = 0xFu;
    /* SPI master: end of a flash read, the boot ROM's own sequence */
    MARK(46);
    clic_only(GARUDA_CLIC_ID_SPI_MASTER);
    before = total_hits();
    PREG(SPIM, 0x004u) = 3u;                        /* CLKDIV */
    PREG(SPIM, 0x014u) = 0u;                        /* SPIDUM */
    PREG(SPIM, 0x008u) = 0x03u << 24;               /* SPICMD: read */
    PREG(SPIM, 0x00Cu) = 0u;                        /* SPIADR */
    PREG(SPIM, 0x010u) = (32u << 16) | (24u << 8) | 8u;
    PREG(SPIM, IRQSTAT) = 0x7u;
    PREG(SPIM, IRQEN)  = 0x1u;                      /* transfer complete */
    PREG(SPIM, 0x000u) = (1u << 8) | 1u;            /* CS flash | start read */
    wait_for(&hits[GARUDA_CLIC_ID_SPI_MASTER]);
    if (hits[GARUDA_CLIC_ID_SPI_MASTER] != 1 || total_hits() != before + 1) return 46;
    while ((PREG(SPIM, 0x000u) >> 16) & 0x1Fu) (void)PREG(SPIM, 0x020u);
    PREG(SPIM, IRQSTAT) = 0x7u;
    /* SPI slave: a byte arrives from the companion */
    MARK(47);
    clic_only(GARUDA_CLIC_ID_SPI_SLAVE);
    before = total_hits();
    PREG(SPIS, 0x008u) = 0x1u;                      /* CTRL.EN */
    PREG(SPIS, IRQSTAT) = 0x7u;
    PREG(SPIS, IRQEN)  = 0x1u;                      /* byte received */
    esp_frame();
    wait_for(&hits[GARUDA_CLIC_ID_SPI_SLAVE]);
    if (hits[GARUDA_CLIC_ID_SPI_SLAVE] != 1 || total_hits() != before + 1) return 47;
    spin(3000);                                     /* let the frame finish */
    if ((PREG(SPIS, 0x000u) & 0xFFu) != 0xA5u)                     return 48;
    PREG(SPIS, 0x008u) = 0x3u;                      /* RXFLUSH */
    PREG(SPIS, IRQSTAT) = 0x7u;
    CLICIE = 0;

    /* ---- 5: DMA request lines -------------------------------------------------- */
    /* One peripheral asks; all six channels are armed and listening. Only the     */
    /* channel the map gives that peripheral may move its beat.                    */
    {
        static const uint32_t rq_base[6] = { SPIM, I2C, U0, U1, U2, SPIS };
        static const uint32_t rq_ch[6]   = { GARUDA_DMA_CH_SPI_MASTER, GARUDA_DMA_CH_I2C,
                                             GARUDA_DMA_CH_UART0, GARUDA_DMA_CH_UART1,
                                             GARUDA_DMA_CH_UART2, GARUDA_DMA_CH_SPI_SLAVE };
        for (k = 0; k < 6; k++) {
            uint32_t rx = (rq_base[k] == SPIS);
            MARK(50 + k);     /* the slave only requests on RX data */
            for (n = 0; n < 6; n++) {
                src[n] = 0xD0000000u | (k << 8) | n; dst[n] = 0;
                DMA_ICLR(n) = 3u;
                DMA_SAR(n) = (uint32_t)(uintptr_t)&src[n];
                DMA_DAR(n) = (uint32_t)(uintptr_t)&dst[n];
                DMA_CNT(n) = 1;
                DMA_CR(n)  = DMA_CR_EN | (rx ? DMA_CR_P2M : DMA_CR_M2P) | DMA_CR_WORD;
            }
            PREG(rq_base[k], DMACTL) = rx ? 0x1u : 0x2u;
            if (rx) esp_frame();
            spin(rx ? 3000 : 300);
            PREG(rq_base[k], DMACTL) = 0u;
            for (n = 0; n < 6; n++) {
                uint32_t st = DMA_STAT(n);
                if (n == rq_ch[k]) { if (!(st & ST_COMP) || dst[n] != src[n]) return 50 + k; }
                else               { if ( (st & ST_COMP) || dst[n] != 0u)     return 60 + k; }
                DMA_CR(n) = 0;
                DMA_ICLR(n) = 3u;
            }
        }
        PREG(SPIS, 0x008u) = 0x3u;                  /* RXFLUSH */
    }

    /* ---- 6: precise bus faults -------------------------------------------------- */
    MARK(70);
    if (exc != 0u)                                                  return 70;
    {
        static const uint32_t bad_addr[14] = {
            SPIS + 0xF00u, SPIM + 0xF00u, I2C + 0xF00u, U0 + 0xF00u, U1 + 0xF00u,
            U2 + 0xF00u, GPIO + 0xF00u, PWM + 0xF00u,
            GARUDA_APB_BASE_DMA_CFG + 0xF00u, GARUDA_APB_BASE_RESET_CTRL + 0xF00u,
            GARUDA_APB_BASE_CLIC_CFG + 0xF00u, GARUDA_APB_BASE_TIMERS_CFG + 0xF00u,
            GARUDA_APB_BASE + 0xC000u, GARUDA_APB_BASE + 0xF000u };
        for (k = 0; k < 14; k++) {
            e0 = exc;
            (void)REG(bad_addr[k]);
            if (exc != e0 + 1u)                                     return 71 + (k > 7 ? (k > 11 ? 2 : 1) : 0);
        }
        e0 = exc;
        (void)*(volatile uint8_t *)(uintptr_t)U0;   /* APB is word-only */
        if (exc != e0 + 1u)                                         return 74;
    }

    return bad ? 80 : 0;
}
