/* =============================================================================
 * t_chip_stress.c - long random peripheral traffic with interrupts
 * (1-TOPS G6 6.8; part of 6.14: DMA, D-port and I-port contend on the fabric)
 *
 * A seeded random walk of ITER operations, each one of:
 *   DMA   an M2M job on a free channel (0..3, 5): random size, length and
 *         alignment; one job in eight writes to the ISRAM, which the DMA must
 *         refuse (R-9: ERROR, ERRPHASE = write, nothing written). The ISR checks
 *         every finished job: the copy, the bytes around it untouched.
 *   UART  a random byte on a random instance, back on its rx (tb_chip's wire
 *         loopback, or the UVM line agent's echo) and compared
 *   SWI   CLICSWI raised; the ISR withdraws it
 *   MTI   the machine timer armed a random distance ahead
 *   PWM   a random duty on a random channel, read back
 *   GPIO  pad 0 driven to a random level, read back from PADIN
 *   SPIS  a frame asked of the companion (gpio1 edge): A5 3C received
 *   I2C   one byte written to the board's slave at 0x48, ACKed
 *   ID    the ID register of a random APB window read
 * All the while DMA jobs are in flight, interrupts arrive in the middle of every
 * kind of access, and the core's own loads, stores and fetches share the fabric.
 * At the end every count must balance: jobs armed = completed + refused, SWIs
 * raised = taken, timers armed = taken; no exception, nothing left pending.
 *
 * Seed and length come from the bench (no-init DSRAM, written before the core
 * leaves reset): SEED at 0x2000_E010 (0 -> 1), ITER at 0x2000_E014 (0 -> 200).
 * tb_chip_uvm sets them from +SEED / +ITER.
 *
 * Returns 0 on success, otherwise the number of the first failed check
 * (operation code * 10 + n, or 90.. for the final balance).
 * ========================================================================== */
#include "chip.h"

#define PREG(base, off) (*(volatile uint32_t *)(uintptr_t)((base) + (off)))
#define IRQSTAT 0xFE0u
#define IDREG   0xFECu
#define SPIS  GARUDA_APB_BASE_SPI_SLAVE
#define I2C   GARUDA_APB_BASE_I2C
#define GPIO  GARUDA_APB_BASE_GPIO
#define PWM   GARUDA_APB_BASE_PWM
#define MARK(n) CSRW(mscratch, (n))                 /* breadcrumb, printed by tb_chip on a timeout */

#define SEED_W  (*(volatile uint32_t *)0x2000E010u)
#define ITER_W  (*(volatile uint32_t *)0x2000E014u)

#define UDIV    4u                                  /* fast lines: a frame in about 1.3 us */
#define NCH     6u
#define COMP0   GARUDA_CLIC_ID_DMA_COMPLETE_CH0_5_FIRST
#define ERR0    GARUDA_CLIC_ID_DMA_ERROR_CH0_5_FIRST
#define SWI_ID  GARUDA_CLIC_ID_SOFTWARE
#define MTI_CAUSE 0x80000007u
#define ISRAM_DST 0x00000400u
#define BUF     64u

static const uint32_t ubase[3] = { GARUDA_APB_BASE_UART0, GARUDA_APB_BASE_UART1, GARUDA_APB_BASE_UART2 };
static const uint32_t win[10] = { GARUDA_APB_BASE_SPI_SLAVE, GARUDA_APB_BASE_SPI_MASTER, GARUDA_APB_BASE_I2C,
                                  GARUDA_APB_BASE_UART0, GARUDA_APB_BASE_UART1, GARUDA_APB_BASE_UART2,
                                  GARUDA_APB_BASE_GPIO, GARUDA_APB_BASE_PWM, 0, 0 };
static const uint32_t win_id[8] = { 0x6A5D0E01u, 0x6A5D0D01u, 0x6A5D0F01u, 0x6A5D1001u,
                                    0x6A5D1101u, 0x6A5D1201u, 0x6A5D1301u, 0x6A5D1401u };

/* one DMA job per channel */
typedef struct { uint32_t busy, err_job, size, cnt, soff, doff; } job_t;
static volatile job_t job[NCH];
static uint8_t srcb[NCH][BUF], dstb[NCH][BUF + 8];

volatile uint32_t n_armed, n_comp, n_refused, n_swi_raised, n_swi, n_mti_armed, n_mti, bad, bad_why, exc;
volatile uint32_t mti_pending;
static uint32_t lfsr;

static uint32_t rnd(void)                           /* xorshift32 */
{
    lfsr ^= lfsr << 13; lfsr ^= lfsr >> 17; lfsr ^= lfsr << 5;
    return lfsr;
}

/* a value in 0..n-1 with no division: GARUDA executes only MUL* of the M extension
 * (CORE [7.2]; DIV/REM trap for the firmware to emulate), so no % here */
static uint32_t rng(uint32_t n) { return (uint32_t)(((uint64_t)rnd() * n) >> 32); }

static void spin(uint32_t n) { while (n--) __asm__ volatile ("nop"); }

static void fail_isr(uint32_t why) { if (!bad) bad_why = why; bad++; }

/* a finished job: the copy is exact and nothing around it moved */
static void check_job(uint32_t ch)
{
    uint32_t len = job[ch].cnt << job[ch].size, i;
    for (i = 0; i < BUF + 8; i++) {
        uint8_t want;
        if (i >= job[ch].doff && i < job[ch].doff + len) want = srcb[ch][job[ch].soff + (i - job[ch].doff)];
        else want = (uint8_t)(0xE0u + ch);          /* the fill */
        if (dstb[ch][i] != want) { fail_isr(100 + ch); return; }
    }
}

uint32_t trap_handler(uint32_t mcause, uint32_t mepc)
{
    uint32_t id = mcause & 0x1Fu;
    if (!(mcause & MCAUSE_INT)) { exc++; return mepc + 4; }
    if (mcause == MTI_CAUSE) {
        mtimecmp_set(~0ull);
        n_mti++; mti_pending = 0;
        return mepc;
    }
    if (id >= COMP0 && id < COMP0 + NCH) {
        uint32_t ch = id - COMP0;
        DMA_ICLR(ch) = 1u;
        if (!job[ch].busy || job[ch].err_job) fail_isr(110 + ch);
        else check_job(ch);
        job[ch].busy = 0; n_comp++;
    } else if (id >= ERR0 && id < ERR0 + NCH) {
        uint32_t ch = id - ERR0, ph = (DMA_STAT(ch) >> 19) & 7u;
        DMA_ICLR(ch) = 2u;
        if (!job[ch].busy || !job[ch].err_job || ph != 2u) fail_isr(120 + ch);
        job[ch].busy = 0; n_refused++;
    } else if (id == SWI_ID) {
        CLICSWI = 0u;
        n_swi++;
    } else {
        fail_isr(130 + id);
    }
    return mepc;
}

static int op_dma(void)
{
    static const uint32_t chs[5] = { 0, 1, 2, 3, 5 };
    uint32_t ch = chs[rng(5u)], size, cnt, len, soff, doff, i;
    if (job[ch].busy) return 0;                     /* still running: another time */
    size = rng(3u);                              /* byte, halfword, word */
    cnt  = 1u + rng(BUF >> size >> 1);         /* up to half the buffer */
    len  = cnt << size;
    soff = (rng(BUF - len + 1u)) & ~((1u << size) - 1u);
    doff = 4u + ((rng(BUF - len + 1u)) & ~((1u << size) - 1u));
    for (i = 0; i < BUF; i++) srcb[ch][i] = (uint8_t)rnd();
    for (i = 0; i < BUF + 8; i++) dstb[ch][i] = (uint8_t)(0xE0u + ch);
    job[ch].size = size; job[ch].cnt = cnt; job[ch].soff = soff; job[ch].doff = doff;
    job[ch].err_job = (rnd() & 7u) == 0u;
    job[ch].busy = 1;
    n_armed++;
    DMA_SAR(ch) = (uint32_t)(uintptr_t)&srcb[ch][soff];
    DMA_DAR(ch) = job[ch].err_job ? ISRAM_DST : (uint32_t)(uintptr_t)&dstb[ch][doff];
    DMA_CNT(ch) = cnt;
    DMA_CR(ch)  = DMA_CR_EN | DMA_CR_M2M | DMA_CR_SINC | DMA_CR_DINC | (size << 5) | DMA_CR_IECOMP | DMA_CR_IEERR;
    return 0;
}

static int op_uart(void)
{
    uint32_t b = ubase[rng(3u)], d = rnd() & 0xFFu, n = 20000u;
    while (!(PREG(b, 0x014u) & 0x20u)) if (--n == 0u) return 21;   /* LSR.THRE */
    PREG(b, 0x000u) = d;
    n = 20000u;
    while (!(PREG(b, 0x014u) & 0x01u)) if (--n == 0u) return 22;   /* LSR.DR */
    if ((PREG(b, 0x000u) & 0xFFu) != d) return 23;
    return 0;
}

static int op_swi(void)
{
    if (CLICSWI) return 0;                          /* the last one not yet taken */
    n_swi_raised++;
    CLICSWI = 1u;
    return 0;
}

static int op_mti(void)
{
    if (mti_pending) return 0;
    mti_pending = 1; n_mti_armed++;
    mtimecmp_set(mtime_get() + 20u + rng(400u));
    return 0;
}

static int op_pwm(void)
{
    uint32_t ch = rng(4u), d = rng(64u);
    PREG(PWM, 0x010u + 4u * ch) = d;
    if (PREG(PWM, 0x010u + 4u * ch) != d) return 51;
    return 0;
}

static int op_gpio(void)
{
    uint32_t v = rnd() & 1u;
    PREG(GPIO, v ? 0x010u : 0x014u) = 0x1u;         /* PADOUTSET / PADOUTCLR pin 0 */
    spin(4);                                        /* the input synchroniser */
    if ((PREG(GPIO, 0x008u) & 1u) != v) return 61;  /* PADIN */
    return 0;
}

static int op_spis(void)
{
    uint32_t n = 50000u, st;
    PREG(SPIS, 0x008u) = 0x3u;                      /* EN | RXFLUSH */
    PREG(GPIO, 0x014u) = 0x2u;                      /* gpio1 low, then the rising edge */
    spin(10);
    PREG(GPIO, 0x010u) = 0x2u;
    do { st = PREG(SPIS, 0x00Cu); if (--n == 0u) return 71; }
    while (((st >> 4) & 0x1Fu) != 2u || (st & 2u)); /* two bytes, chip select released */
    if ((PREG(SPIS, 0x000u) & 0xFFu) != 0xA5u) return 72;
    if ((PREG(SPIS, 0x000u) & 0xFFu) != 0x3Cu) return 73;
    PREG(GPIO, 0x014u) = 0x2u;
    return 0;
}

static int op_i2c(void)
{
    static const uint32_t cmd[2] = { 0x09u, 0x0Au }; /* STA|WR, WR|STO */
    uint32_t dat[2], k, n;
    dat[0] = 0x90u; dat[1] = rnd() & 0xFFu;         /* address 0x48 write, one data byte */
    for (k = 0; k < 2; k++) {
        PREG(I2C, 0x008u) = dat[k];
        PREG(I2C, 0x010u) = cmd[k];
        n = 200000u;
        while (PREG(I2C, 0x014u) & 1u) if (--n == 0u) return 81;   /* STATUS.TIP */
        if (PREG(I2C, 0x014u) & (1u << 3)) return 82;               /* RXNACK */
    }
    n = 200000u;
    while (PREG(I2C, 0x014u) & 2u) if (--n == 0u) return 83;       /* BUSY: the STOP is out */
    return 0;
}

static int op_id(void)
{
    uint32_t w = rng(8u);
    if (PREG(win[w], IDREG) != win_id[w]) return 91;
    return 0;
}

int main(void)
{
    uint32_t iter, it, i, ie = 0, rc = 0;

    lfsr = SEED_W ? SEED_W : 1u;
    iter = ITER_W ? ITER_W : 200u;

    for (i = 0; i < 3; i++) {                       /* 8N1 at UDIV */
        PREG(ubase[i], 0x00Cu) = 0x83u; PREG(ubase[i], 0x000u) = UDIV; PREG(ubase[i], 0x004u) = 0u;
        PREG(ubase[i], 0x00Cu) = 0x03u;
    }
    PREG(PWM, 0x000u) = 0u; PREG(PWM, 0x004u) = 63u;   /* PRESCALE, PERIOD */
    PREG(PWM, 0x008u) = (0xFu << 4) | 1u;               /* EN, four channels */
    PREG(GPIO, 0x004u) = 0x3u; PREG(GPIO, 0x000u) = 0x3u; PREG(GPIO, 0x014u) = 0x3u;  /* both outputs, low */
    PREG(I2C, 0x000u) = 61u; PREG(I2C, 0x018u) = 20000u; PREG(I2C, 0x004u) = 1u;
    PREG(SPIS, 0x004u) = 0x5Au;                         /* what MISO carries */

    for (i = 0; i < NCH; i++) {
        CLICINTCFG(COMP0 + i) = 10 + i; CLICINTCFG(ERR0 + i) = 20 + i;
        ie |= (1u << (COMP0 + i)) | (1u << (ERR0 + i));
    }
    CLICINTCFG(SWI_ID) = 5; ie |= 1u << SWI_ID;
    CLICIE = ie;
    mtimecmp_set(~0ull);
    CSRS(mie, 0x80);
    CSRS(mstatus, 8);

    for (it = 0; it < iter && rc == 0 && bad == 0 && exc == 0; it++) {
        uint32_t op = rng(32u);
        MARK(it);
        if      (op < 8)  rc = op_dma();
        else if (op < 14) rc = op_uart();
        else if (op < 17) rc = op_swi();
        else if (op < 20) rc = op_mti();
        else if (op < 23) rc = op_pwm();
        else if (op < 26) rc = op_gpio();
        else if (op < 28) rc = op_spis();
        else if (op < 29) rc = op_i2c();
        else              rc = op_id();
    }
    if (rc) return rc;

    /* drain: every job, SWI and timer must come home */
    for (i = 0; i < 400000u; i++) {
        uint32_t busy = 0, ch;
        for (ch = 0; ch < NCH; ch++) busy |= job[ch].busy;
        if (!busy && !mti_pending && !CLICSWI) break;
    }
    CSRC(mstatus, 8);
    CSRC(mie, 0x80);
    if (bad)                                      return 90 + (bad_why >= 130 ? 3 : bad_why >= 120 ? 2 : bad_why >= 110 ? 1 : 0);
    if (n_armed != n_comp + n_refused)            return 94;
    if (n_swi != n_swi_raised)                    return 95;
    if (n_mti != n_mti_armed)                     return 96;
    if (exc)                                      return 97;
    if (CLICIP & ie)                              return 98;
    if (n_armed == 0 || n_swi == 0 || n_mti == 0) return 99;   /* the walk must have mixed them */
    return 0;
}
