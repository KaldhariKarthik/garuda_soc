/* stand-in for <string.h>: the three routines Dhrystone uses (sw/bench/rt) */
#ifndef GARUDA_BENCH_STRING_H
#define GARUDA_BENCH_STRING_H
#include <stddef.h>
void *memcpy(void *d, const void *s, size_t n);
char *strcpy(char *d, const char *s);
int   strcmp(const char *a, const char *b);
#endif
