/* =========================================================================
 * GARUDA Boot ROM linker script (Block 4, 4 KiB at 0x1000_0000)
 * The ROM has no .data and no .bss: it runs before anything is initialised
 * and must not depend on RAM contents. Its stack is the top of DSRAM, just
 * below the JTAG mailbox (DECISIONS D-20).
 * ========================================================================= */
OUTPUT_ARCH(riscv)
ENTRY(_rom_start)
MEMORY { ROM (rx) : ORIGIN = 0x10000000, LENGTH = 4K }
SECTIONS
{
  .text : { KEEP(*(.text.init)) *(.text .text.*) } > ROM
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > ROM
  /DISCARD/ : { *(.data*) *(.sdata*) *(.bss*) *(.sbss*) *(COMMON)
                *(.comment) *(.note*) *(.eh_frame*) }
}
