/* =============================================================================
 * bench_rt.h -- the small run-time the benchmarks need on GARUDA (plan 5.7).
 *
 * tb_boot has no console, so a benchmark "prints" into a RAM block at a fixed
 * address (BENCH_BLOCK, section .benchres in link_bench.ld). The bench dumps
 * that block at the end of the run with +SIGFILE/+SIGBEGIN/+SIGEND, and
 * tools/bench_report.py turns it back into text, checks the benchmark's own
 * self-check lines and works out the score per MHz.
 *
 * Block layout, 32-bit words:
 *   [0] magic 0x4842_4E47 ("GNBH" little-endian)   [1] cycles at start
 *   [2] cycles at stop    [3] instret at start     [4] instret at stop
 *   [5] number of log bytes  [6] 1 if the timer is the fake one (lockstep build)
 *   [7] reserved          [8..] log text, NUL-padded
 *
 * BENCH_FAKE_TIMER: every timer read returns the previous value plus
 * BENCH_FAKE_STEP instead of mcycle/minstret. The program is then fully
 * deterministic, so the RTL run can be compared with Spike instruction by
 * instruction (a real mcycle read differs between the two by design).
 * =============================================================================
 */
#ifndef BENCH_RT_H
#define BENCH_RT_H
#include <stdint.h>
#include <stddef.h>

#define BENCH_MAGIC      0x48424E47u
#define BENCH_FAKE_STEP  0x01000000u

uint32_t bench_read_mcycle(void);
uint32_t bench_read_minstret(void);
void     bench_mark(int start);          /* 1: record start counters, 0: stop */
int      bench_printf(const char *fmt, ...);

#endif
