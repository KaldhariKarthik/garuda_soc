/* =========================================================================
 * GARUDA chip-level test programs - Rev 4.0 memory map (GARUDA-SYS-001)
 *
 *   ISRAM 0x0000_0000 64 KiB   .text .rodata, and the load image of .data
 *   DSRAM 0x2000_0000          .data .bss (0x0000-0xBFFF), stack top 0x2000_DF00
 *         0x2000_E000          noinit area: survives a watchdog reset
 *         0x2000_F000          tohost / fromhost (testbench handshake)
 *         0x2000_FF00 down     Boot ROM stack
 *         0x2000_FFF0          JTAG mailbox (DECISIONS D-20)
 * Images are placed in ISRAM (backdoor or over JTAG SBA) and entered through
 * the Boot ROM's recovery mailbox with boot_sel = 1.
 * ========================================================================= */
OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY
{
  ISRAM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K
  DSRAM (rw)  : ORIGIN = 0x20000000, LENGTH = 48K
}
_stack_top = 0x2000DF00;
SECTIONS
{
  .text   : { KEEP(*(.text.init)) *(.text .text.*) } > ISRAM
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > ISRAM
  . = ALIGN(4);
  _data_lma = LOADADDR(.data);
  .data : { _data_start = .; *(.data .data.* .sdata .sdata.*) . = ALIGN(4); _data_end = .; } > DSRAM AT > ISRAM
  .bss (NOLOAD) : { _bss_start = .; *(.bss .bss.* .sbss .sbss.* COMMON) . = ALIGN(4); _bss_end = .; } > DSRAM
  .noinit 0x2000E000 (NOLOAD) : { *(.noinit) }
  .tohost 0x2000F000 (NOLOAD) : { tohost = .; . += 4; fromhost = .; . += 4; }
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
