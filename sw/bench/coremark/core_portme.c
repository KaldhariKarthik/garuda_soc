/* =============================================================================
 * core_portme.c -- CoreMark port for GARUDA (plan 5.7), from coremark/barebones.
 * Original: Copyright 2018 EEMBC, Apache License 2.0 (LICENSE.md here).
 *
 * Timing: mcycle through sw/bench/rt, EE_TICKS_PER_SEC = 1 000 000, i.e. the
 * score is reported as if the core ran at 1 MHz, which makes "Iterations/Sec"
 * equal to CoreMark/MHz. The run must last 10 notional seconds (10 M cycles)
 * for CoreMark to call it valid; ITERATIONS is set for that in the Makefile.
 * This is a simulated score, not an EEMBC-certified one.
 * =============================================================================
 */
#include "coremark.h"
#include "core_portme.h"
#include "bench_rt.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

#define EE_TICKS_PER_SEC 1000000u

static CORETIMETYPE start_time_val, stop_time_val;

void start_time(void)
{
    bench_mark(1);
    start_time_val = bench_read_mcycle();
}

void stop_time(void)
{
    stop_time_val = bench_read_mcycle();
    bench_mark(0);
}

CORE_TICKS get_time(void)
{
    return (CORE_TICKS)(stop_time_val - start_time_val);
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret)(ticks / EE_TICKS_PER_SEC);
}

ee_u32 default_num_contexts = 1;

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
        ee_printf("ERROR! Please define ee_ptr_int to a type that holds a pointer!\n");
    if (sizeof(ee_u32) != 4)
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    p->portable_id = 0;
}

/* ee_printf is an alias of bench_printf, in sw/bench/rt/bench_rt.c */
