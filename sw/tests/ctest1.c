/* =========================================================================
 * ctest1.c - first C program on GARUDA.
 *
 * Deliberately exercises the things a hand-written assembly smoke cannot:
 *   - a real stack and function calls (JAL/JALR, ra save/restore)
 *   - byte / halfword / word loads and stores, signed and unsigned
 *   - .bss (zeroed by crt0) and .data (initialised, must survive the image)
 *   - the M-extension multiply
 *   - a loop with a data-dependent branch
 *
 * Returns 0 on success; a nonzero return identifies which check failed and
 * crt0 turns it into tohost = (n<<1)|1, so a failure names itself.
 * ========================================================================= */

/* .data - must arrive in the image with these values already set */
volatile unsigned int  g_word   = 0xDEADBEEFu;
volatile short         g_half   = -1234;
volatile unsigned char g_byte   = 0xA5u;

/* .bss - crt0 must have zeroed these */
volatile unsigned int  g_bss[4];

static int sum_to(int n)
{
    int s = 0;
    for (int i = 1; i <= n; i++)
        s += i;
    return s;
}

static int mul_check(int a, int b)
{
    return a * b;
}

int main(void)
{
    /* 1. .data survived the image */
    if (g_word != 0xDEADBEEFu) return 1;

    /* 2. signed halfword load sign-extends */
    if (g_half != -1234) return 2;

    /* 3. unsigned byte load zero-extends */
    if (g_byte != 0xA5u) return 3;

    /* 4. crt0 zeroed .bss */
    for (int i = 0; i < 4; i++)
        if (g_bss[i] != 0) return 4;

    /* 5. stores of each width read back */
    g_bss[0] = 0x12345678u;
    if (g_bss[0] != 0x12345678u) return 5;

    *(volatile unsigned char *)&g_bss[1] = 0xFFu;
    if (g_bss[1] != 0x000000FFu) return 6;

    *(volatile unsigned short *)&g_bss[2] = 0xBEEFu;
    if (g_bss[2] != 0x0000BEEFu) return 7;

    /* 6. calls, stack, loop, branch */
    if (sum_to(10) != 55) return 8;

    /* 7. M-extension */
    if (mul_check(1234, 5678) != 7006652) return 9;

    /* 8. negative multiply */
    if (mul_check(-3, 7) != -21) return 10;

    return 0;   /* -> tohost = 1 -> PASSED */
}
