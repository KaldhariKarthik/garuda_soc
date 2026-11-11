/* =============================================================================
 * bench_rt.c -- run-time for the benchmarks on GARUDA (plan 5.7); see bench_rt.h.
 *
 * Also supplies what libgcc and libc would: GARUDA is RV32I + Zmmul (no DIV/REM,
 * no C), and the toolchain's only rv32 libgcc is built for rv32imac, so its
 * routines may hold compressed or divide instructions the core rejects.
 * Everything here is compiled with the same -march as the benchmark.
 * =============================================================================
 */
#include <stdarg.h>
#include "bench_rt.h"

#define LOG_BYTES (16384 - 32)

struct bench_block {
    uint32_t magic, c0, c1, i0, i1, loglen, fake, rsvd;
    char     log[LOG_BYTES];
};
__attribute__((section(".benchres"))) volatile struct bench_block bench_res;

/* ---- counters ------------------------------------------------------------ */
#ifdef BENCH_FAKE_TIMER
static uint32_t fake_c, fake_i;
uint32_t bench_read_mcycle(void)   { return fake_c += BENCH_FAKE_STEP; }
uint32_t bench_read_minstret(void) { return fake_i += BENCH_FAKE_STEP; }
#else
uint32_t bench_read_mcycle(void)
{
    uint32_t v;
    __asm__ volatile ("csrr %0, mcycle" : "=r"(v));
    return v;
}
uint32_t bench_read_minstret(void)
{
    uint32_t v;
    __asm__ volatile ("csrr %0, minstret" : "=r"(v));
    return v;
}
#endif

void bench_mark(int start)
{
    uint32_t c = bench_read_mcycle(), i = bench_read_minstret();
    bench_res.magic = BENCH_MAGIC;
#ifdef BENCH_FAKE_TIMER
    bench_res.fake = 1;
#endif
    if (start) { bench_res.c0 = c; bench_res.i0 = i; }
    else       { bench_res.c1 = c; bench_res.i1 = i; }
}

/* ---- log ----------------------------------------------------------------- */
static void putch(char ch)
{
    bench_res.magic = BENCH_MAGIC;
    if (bench_res.loglen < LOG_BYTES - 1)
        bench_res.log[bench_res.loglen++] = ch;
}

static void putnum(uint32_t v, int neg, unsigned base, int width, char pad, int upper)
{
    char buf[12];
    int  n = 0;
    const char *dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    do { buf[n++] = dig[v % base]; v /= base; } while (v);
    if (neg) {
        if (pad == '0') { putch('-'); width--; }
        else            buf[n++] = '-';
    }
    while (width-- > n) putch(pad);
    while (n) putch(buf[--n]);
}

/* %d %i %u %x %X %c %s %%, with an optional '0', width and 'l' (all 32-bit) */
int bench_printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    for (; *fmt; fmt++) {
        if (*fmt != '%') { putch(*fmt); continue; }
        char pad = ' ';
        int  width = 0, n;
        const char *s;
        fmt++;
        if (*fmt == '0') { pad = '0'; fmt++; }
        while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
        while (*fmt == 'l') fmt++;
        switch (*fmt) {
        case 'd': case 'i': {
            int32_t v = va_arg(ap, int32_t);
            putnum(v < 0 ? (uint32_t)-v : (uint32_t)v, v < 0, 10, width, pad, 0);
            break; }
        case 'u': putnum(va_arg(ap, uint32_t), 0, 10, width, pad, 0); break;
        case 'x': putnum(va_arg(ap, uint32_t), 0, 16, width, pad, 0); break;
        case 'X': putnum(va_arg(ap, uint32_t), 0, 16, width, pad, 1); break;
        case 'c': putch((char)va_arg(ap, int)); break;
        case 's':
            s = va_arg(ap, const char *);
            for (n = 0; s[n]; n++) ;
            while (width-- > n) putch(' ');
            while (*s) putch(*s++);
            break;
        case '%': putch('%'); break;
        default:  putch('%'); putch(*fmt); break;
        }
    }
    va_end(ap);
    return 0;
}

/* printf for Dhrystone, ee_printf for CoreMark */
int printf(const char *fmt, ...) __attribute__((alias("bench_printf")));
int ee_printf(const char *fmt, ...) __attribute__((alias("bench_printf")));

/* ---- libc pieces the benchmarks call -------------------------------------- */
void *memcpy(void *d, const void *s, size_t n)
{
    char *dp = d;
    const char *sp = s;
    while (n--) *dp++ = *sp++;
    return d;
}

void *memset(void *d, int c, size_t n)
{
    char *dp = d;
    while (n--) *dp++ = (char)c;
    return d;
}

char *strcpy(char *d, const char *s)
{
    char *r = d;
    while ((*d++ = *s++)) ;
    return r;
}

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

/* ---- integer divide (GCC calls these for '/' and '%' without the M divide) -- */
unsigned int __udivsi3(unsigned int n, unsigned int d)
{
    unsigned int q = 0, r = 0;
    int i;
    if (d == 0) return 0xFFFFFFFFu;               /* RISC-V DIVU by zero */
    for (i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1u);
        if (r >= d) { r -= d; q |= 1u << i; }
    }
    return q;
}

unsigned int __umodsi3(unsigned int n, unsigned int d)
{
    if (d == 0) return n;                          /* RISC-V REMU by zero */
    return n - __udivsi3(n, d) * d;
}

int __divsi3(int n, int d)
{
    if (d == 0) return -1;                         /* RISC-V DIV by zero */
    unsigned int un = n < 0 ? -(unsigned int)n : (unsigned int)n;
    unsigned int ud = d < 0 ? -(unsigned int)d : (unsigned int)d;
    unsigned int q = __udivsi3(un, ud);
    return ((n < 0) != (d < 0)) ? -(int)q : (int)q;
}

int __modsi3(int n, int d)
{
    if (d == 0) return n;                          /* RISC-V REM by zero */
    return n - __divsi3(n, d) * d;
}
