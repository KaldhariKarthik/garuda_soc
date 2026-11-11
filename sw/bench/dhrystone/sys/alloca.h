/* stand-in for <alloca.h> */
#ifndef GARUDA_BENCH_ALLOCA_H
#define GARUDA_BENCH_ALLOCA_H
#define alloca(n) __builtin_alloca(n)
#endif
