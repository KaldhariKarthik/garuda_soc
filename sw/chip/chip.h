/* GARUDA chip-level test helpers. Addresses come from the generated map. */
#ifndef GARUDA_CHIP_H
#define GARUDA_CHIP_H
#include <stdint.h>
#include "garuda_map.h"

#define REG(a)        (*(volatile uint32_t *)(uintptr_t)(a))
#define CSRR(c)       ({ uint32_t _v; __asm__ volatile ("csrr %0, " #c : "=r"(_v)); _v; })
#define CSRW(c, v)    __asm__ volatile ("csrw " #c ", %0" :: "r"((uint32_t)(v)))
#define CSRS(c, v)    __asm__ volatile ("csrs " #c ", %0" :: "r"((uint32_t)(v)))
#define CSRC(c, v)    __asm__ volatile ("csrc " #c ", %0" :: "r"((uint32_t)(v)))
#define WFI()         __asm__ volatile ("wfi")

/* reset_ctrl (window 9) */
#define RSTREASON     REG(GARUDA_APB_BASE_RESET_CTRL + 0x00)
#define RSTCTL        REG(GARUDA_APB_BASE_RESET_CTRL + 0x04)
#define CLKSTAT       REG(GARUDA_APB_BASE_RESET_CTRL + 0x08)
#define MEMCTL        REG(GARUDA_APB_BASE_RESET_CTRL + 0x20)
/* CLIC (window 10) */
#define CLICIE        REG(GARUDA_APB_BASE_CLIC_CFG + 0x004)
#define CLICIP        REG(GARUDA_APB_BASE_CLIC_CFG + 0x008)
#define CLICINTCFG(n) REG(GARUDA_APB_BASE_CLIC_CFG + 0x100 + 4 * (n))
/* timers (window 11) */
#define MTIME_LO      REG(GARUDA_APB_BASE_TIMERS_CFG + 0x00)
#define MTIME_HI      REG(GARUDA_APB_BASE_TIMERS_CFG + 0x04)
#define MTIMECMP_LO   REG(GARUDA_APB_BASE_TIMERS_CFG + 0x08)
#define MTIMECMP_HI   REG(GARUDA_APB_BASE_TIMERS_CFG + 0x0C)
#define WDTCTL        REG(GARUDA_APB_BASE_TIMERS_CFG + 0x10)
#define WDTLOAD       REG(GARUDA_APB_BASE_TIMERS_CFG + 0x14)
#define WDTVAL        REG(GARUDA_APB_BASE_TIMERS_CFG + 0x18)
#define WDTKICK       REG(GARUDA_APB_BASE_TIMERS_CFG + 0x1C)
#define WDTWARN       REG(GARUDA_APB_BASE_TIMERS_CFG + 0x20)
/* DMA (window 5), channel n */
#define DMA_CR(n)     REG(GARUDA_APB_BASE_DMA_CFG + 0x20 * (n) + 0x00)
#define DMA_SAR(n)    REG(GARUDA_APB_BASE_DMA_CFG + 0x20 * (n) + 0x04)
#define DMA_DAR(n)    REG(GARUDA_APB_BASE_DMA_CFG + 0x20 * (n) + 0x08)
#define DMA_CNT(n)    REG(GARUDA_APB_BASE_DMA_CFG + 0x20 * (n) + 0x0C)
#define DMA_STAT(n)   REG(GARUDA_APB_BASE_DMA_CFG + 0x20 * (n) + 0x10)
#define DMA_ICLR(n)   REG(GARUDA_APB_BASE_DMA_CFG + 0x20 * (n) + 0x14)
#define DMA_CR_EN     (1u << 0)
#define DMA_CR_M2M    (2u << 1)
#define DMA_CR_SINC   (1u << 3)
#define DMA_CR_DINC   (1u << 4)
#define DMA_CR_WORD   (2u << 5)
#define DMA_CR_IECOMP (1u << 7)
#define DMA_CR_IEERR  (1u << 8)

#define MCAUSE_INT    0x80000000u
#define WDT_KICK_MAGIC 0x5A5AC3C3u

static inline void mtimecmp_set(uint64_t t)       /* TIMERS §7.4 sequence */
{
    MTIMECMP_LO = 0xFFFFFFFFu;
    MTIMECMP_HI = (uint32_t)(t >> 32);
    MTIMECMP_LO = (uint32_t)t;
}
static inline uint64_t mtime_get(void)            /* LO first: coherent read */
{
    uint32_t lo = MTIME_LO;
    uint32_t hi = MTIME_HI;
    return ((uint64_t)hi << 32) | lo;
}
#endif
