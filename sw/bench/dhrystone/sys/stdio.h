/* stand-in for <stdio.h>: Dhrystone needs only printf (sw/bench/rt) */
#ifndef GARUDA_BENCH_STDIO_H
#define GARUDA_BENCH_STDIO_H
int printf(const char *fmt, ...);
#endif
