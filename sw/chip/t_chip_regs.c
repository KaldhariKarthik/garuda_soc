/* =============================================================================
 * t_chip_regs.c - every register of every APB window, over AHB from the core
 * (1-TOPS G6 6.2: "100% of addressable registers read and written; RW/RO/W1C checked")
 *
 * The table is sw/chip/chip_regs.h, generated from the Design_Docs/regs RDL files by
 * tools/gen/gen_chip_regs.py (the same sources as the block UVM register models);
 * its header lists every register left out of a phase and why.
 *   phase 1  reset values: every readable register read before anything is written
 *   phase 2  read-only: constant bits written with their complement, must not change
 *   phase 3  read/write: 0xAAAAAAAA, 0x55555555, all ones, 0 written and read back,
 *            then the reset value written back; MODE/SIZE = 3 of a DMA CR is reserved
 *            and must leave the field unchanged ([N-6.1])
 *   phase 4  write-1-to-clear: a 0 written clears nothing, a 1 written sets nothing;
 *            RSTREASON.EXT (no source left) must clear
 * No access may trap (every address is a register; 32-bit accesses only).
 * Returns 0 = pass, else phase * 1000 + table index; fail_addr/got/exp keep the detail.
 * ========================================================================== */
#include "chip.h"
#include "chip_regs.h"

#define R(a)    (*(volatile uint32_t *)(uintptr_t)(a))
#define MARK(n) CSRW(mscratch, (n))
#define RSTREASON_ADDR 0x40009000u

volatile uint32_t traps, fail_addr, fail_got, fail_exp, n_checks;

uint32_t trap_handler(uint32_t mcause, uint32_t mepc)
{
    (void)mcause;
    traps++;
    return mepc + 4;
}

static uint32_t fail(uint32_t phase, uint32_t i, uint32_t got, uint32_t exp)
{
    fail_addr = chip_regs[i].addr; fail_got = got; fail_exp = exp;
    return phase * 1000u + i;
}

/* expected read-back of the read/write bits after writing w over a register that read prev */
static uint32_t expect_rw(const chip_reg_t *r, uint32_t w, uint32_t prev)
{
    uint32_t e = w & r->rw;
    if (r->flags & CR_HOLD3) {                       /* DMA CR: MODE [2:1], SIZE [6:5] */
        static const uint8_t lsb[2] = { 1, 5 };
        for (int k = 0; k < 2; k++) {
            uint32_t m = 3u << lsb[k];
            if ((w & m) == m) e = (e & ~m) | (prev & m);
        }
    }
    return e;
}

int main(void)
{
    uint32_t i, k, v, w, prev;
    static const uint32_t pat[4] = { 0xAAAAAAAAu, 0x55555555u, 0xFFFFFFFFu, 0x00000000u };

    /* ---- 1: reset values ------------------------------------------------------ */
    MARK(1);
    for (i = 0; i < N_CHIP_REGS; i++) {
        const chip_reg_t *r = &chip_regs[i];
        if (r->flags & CR_NOREAD || !r->rstmask) continue;
        v = R(r->addr);
        n_checks++;
        if ((v ^ r->rst) & r->rstmask)                 return fail(1, i, v, r->rst);
    }
    if (traps)                                         return 1999;

    /* ---- 2: constant bits ignore writes --------------------------------------- */
    MARK(2);
    for (i = 0; i < N_CHIP_REGS; i++) {
        const chip_reg_t *r = &chip_regs[i];
        if (r->flags & (CR_NOWRITE | CR_NOREAD) || !r->ro) continue;
        w = ((r->rst & r->rw) | (~r->rst & r->ro)) & ~r->wzero & ~r->w1c;
        R(r->addr) = w;
        v = R(r->addr);
        n_checks++;
        if ((v ^ r->rst) & r->ro)                      return fail(2, i, v, r->rst);
        R(r->addr) = r->rst & r->rw;
    }
    if (traps)                                         return 2999;

    /* ---- 3: read/write bits --------------------------------------------------- */
    MARK(3);
    for (i = 0; i < N_CHIP_REGS; i++) {
        const chip_reg_t *r = &chip_regs[i];
        if (r->flags & (CR_NOWRITE | CR_NOREAD) || !r->rw) continue;
        prev = r->rst;
        for (k = 0; k < 4; k++) {
            w = pat[k] & ~r->wzero & ~r->w1c;
            R(r->addr) = w;
            v = R(r->addr);
            n_checks++;
            if ((v & r->rw) != expect_rw(r, w, prev))  return fail(3, i, v, expect_rw(r, w, prev));
            if ((v ^ r->rst) & r->ro)                  return fail(3, i, v, r->rst);
            prev = v;
        }
        R(r->addr) = r->rst & r->rw;
        v = R(r->addr);
        if ((v ^ r->rst) & r->rw)                      return fail(3, i, v, r->rst);
    }
    if (traps)                                         return 3999;

    /* ---- 4: write-1-to-clear -------------------------------------------------- */
    MARK(4);
    for (i = 0; i < N_CHIP_REGS; i++) {
        const chip_reg_t *r = &chip_regs[i];
        uint32_t b, a;
        if (r->flags & (CR_NOWRITE | CR_NOREAD) || !r->w1c) continue;
        b = R(r->addr);
        R(r->addr) = r->rst & r->rw;                   /* 0 in every W1C bit */
        a = R(r->addr);
        n_checks++;
        if (b & ~a & r->w1c)                           return fail(4, i, a, b);   /* a 0 cleared a bit */
        R(r->addr) = r->w1c | (r->rst & r->rw);
        v = R(r->addr);
        n_checks++;
        if (v & ~a & r->w1c)                           return fail(4, i, v, a);   /* a 1 set a bit */
        if (r->addr == RSTREASON_ADDR && (v & r->w1c)) return fail(4, i, v, 0);   /* EXT must clear */
    }
    if (traps)                                         return 4999;
    return 0;
}
