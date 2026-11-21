/* =============================================================================
 * t_chip_mem.c - memory march and walking ones over the ISRAM and DSRAM, from
 * the core through the AHB fabric (1-TOPS G6 6.12, bare-metal C suite)
 *
 * Regions the program does not use (sw/chip/link_chip.ld): the DSRAM from
 * 0x2000_1000 to 0x2000_CFFF (all four 16 KiB banks; .data/.bss sit below, the
 * stack below 0x2000_DF00, the noinit, tohost and Boot ROM areas above) and the
 * ISRAM from 0x0000_4000 to 0x0000_FFFF (the image is below 16 KiB).
 *   1  data bus: walking ones and walking zeros in one word of every bank
 *   2  address lines 2..15: a unique word at base + 2^k, none may alias
 *   3  byte and halfword lanes: each lane written alone, the word read back
 *   4  March C- over the whole region: up w0; up r0 w1; up r1 w0;
 *      down r0 w1; down r1 w0; up r0 (all-zeros / all-ones words)
 * Returns 0 = pass, otherwise region * 100 + test * 10 + detail (region 1 DSRAM,
 * 2 ISRAM); bad_addr / bad_got / bad_exp hold the first miscompare.
 * ========================================================================== */
#include "chip.h"

#define W(a)    (*(volatile uint32_t *)(uintptr_t)(a))
#define H(a)    (*(volatile uint16_t *)(uintptr_t)(a))
#define B(a)    (*(volatile uint8_t  *)(uintptr_t)(a))
#define MARK(n) CSRW(mscratch, (n))

volatile uint32_t bad_addr, bad_got, bad_exp, traps;

uint32_t trap_handler(uint32_t mcause, uint32_t mepc)
{
    (void)mcause;
    traps++;
    return mepc + 4;
}

static int miss(uint32_t a, uint32_t got, uint32_t exp)
{
    bad_addr = a; bad_got = got; bad_exp = exp;
    return 1;
}

/* 1: walking ones and zeros in one word */
static int data_bus(uint32_t a)
{
    for (uint32_t b = 0; b < 32; b++) {
        uint32_t p = 1u << b, v;
        W(a) = p;  v = W(a); if (v != p)  return miss(a, v, p);
        W(a) = ~p; v = W(a); if (v != ~p) return miss(a, v, ~p);
    }
    return 0;
}

/* 2: address lines: base + 2^k for k = 2..15 (base + 0 included) */
static int addr_lines(uint32_t base)
{
    uint32_t k, j, v;
    W(base) = 0xA5A50000u;
    for (k = 2; k <= 15; k++) W(base + (1u << k)) = 0xA5A50000u | k;
    for (k = 2; k <= 15; k++) {
        v = W(base + (1u << k));
        if (v != (0xA5A50000u | k)) return miss(base + (1u << k), v, 0xA5A50000u | k);
    }
    if ((v = W(base)) != 0xA5A50000u) return miss(base, v, 0xA5A50000u);
    /* each line alone: write one location, no other may change */
    for (k = 2; k <= 15; k++) {
        W(base + (1u << k)) = 0x5A5A0000u | k;
        for (j = 2; j <= 15; j++) if (j != k) {
            v = W(base + (1u << j));
            if (v != (0xA5A50000u | j)) return miss(base + (1u << j), v, 0xA5A50000u | j);
        }
        if ((v = W(base)) != 0xA5A50000u) return miss(base, v, 0xA5A50000u);
        W(base + (1u << k)) = 0xA5A50000u | k;
    }
    return 0;
}

/* 3: byte and halfword lanes */
static int lanes(uint32_t a)
{
    uint32_t v, e, i;
    for (i = 0; i < 4; i++) {
        W(a) = 0u;
        B(a + i) = (uint8_t)(0x11u * (i + 1));
        e = (0x11u * (i + 1)) << (8 * i);
        if ((v = W(a)) != e) return miss(a, v, e);
        W(a) = 0xFFFFFFFFu;
        B(a + i) = 0u;
        e = ~(0xFFu << (8 * i));
        if ((v = W(a)) != e) return miss(a, v, e);
        if ((v = B(a + i)) != 0u) return miss(a + i, v, 0);
    }
    for (i = 0; i < 2; i++) {
        W(a) = 0u;
        H(a + 2 * i) = 0xBEEFu;
        e = 0xBEEFu << (16 * i);
        if ((v = W(a)) != e) return miss(a, v, e);
        if ((v = H(a + 2 * i)) != 0xBEEFu) return miss(a + 2 * i, v, 0xBEEF);
    }
    return 0;
}

/* 4: March C- on [lo, hi); returns the failing element 1..5, or 0 */
static int march(uint32_t lo, uint32_t hi)
{
    uint32_t a, v;
    for (a = lo; a < hi; a += 4) W(a) = 0u;
    for (a = lo; a < hi; a += 4) { if ((v = W(a)) != 0u)  { miss(a, v, 0);   return 1; } W(a) = ~0u; }
    for (a = lo; a < hi; a += 4) { if ((v = W(a)) != ~0u) { miss(a, v, ~0u); return 2; } W(a) = 0u; }
    for (a = hi; a > lo; ) { a -= 4; if ((v = W(a)) != 0u)  { miss(a, v, 0);   return 3; } W(a) = ~0u; }
    for (a = hi; a > lo; ) { a -= 4; if ((v = W(a)) != ~0u) { miss(a, v, ~0u); return 4; } W(a) = 0u; }
    for (a = lo; a < hi; a += 4) if ((v = W(a)) != 0u)     { miss(a, v, 0);   return 5; }
    return 0;
}

static int region(uint32_t r, uint32_t lo, uint32_t hi, uint32_t addr_base, uint32_t bank)
{
    int e;
    MARK(r * 10 + 1);
    for (uint32_t a = lo; a < hi; a += bank) if (data_bus(a)) return (int)(r * 100 + 10);
    MARK(r * 10 + 2);
    if (addr_lines(addr_base))                                   return (int)(r * 100 + 20);
    MARK(r * 10 + 3);
    if (lanes(lo) || lanes(hi - 4))                              return (int)(r * 100 + 30);
    MARK(r * 10 + 4);
    if ((e = march(lo, hi)) != 0)                                return (int)(r * 100 + 40) + e;
    return 0;
}

int main(void)
{
    int rc;
    /* DSRAM: banks of 16 KiB; the address test spans 0x2000_4000 .. 0x2000_C000 */
    if ((rc = region(1, 0x20001000u, 0x2000D000u, 0x20004000u, 0x4000u)) != 0) return rc;
    /* ISRAM: one array; the address test spans 0x0000_4000 .. 0x0000_C000 */
    if ((rc = region(2, 0x00004000u, 0x00010000u, 0x00004000u, 0x4000u)) != 0) return rc;
    return traps ? 99 : 0;
}
