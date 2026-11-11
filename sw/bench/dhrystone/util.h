/* util.h -- GARUDA stand-in for riscv-tests benchmarks/common/util.h (plan 5.7).
 * dhrystone_main.c needs only setStats() and read_csr(); the counters come from
 * sw/bench/rt (real mcycle/minstret, or the fake timer of the lockstep build). */
#ifndef GARUDA_BENCH_UTIL_H
#define GARUDA_BENCH_UTIL_H
#include "bench_rt.h"
#define read_csr(reg)      bench_read_##reg()
#define setStats(enable)   bench_mark(enable)
#define debug_printf       bench_printf
#endif
