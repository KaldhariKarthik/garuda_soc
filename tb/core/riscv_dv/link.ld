/* link.ld - riscv-dv programs on the GARUDA verification memory: one 256 KB
 * window at 0x1000_0000 (the same image is seen by both bus ports of the core,
 * as in sw/common/link.ld). The address of `tohost` is read from the linked
 * program and given to the bench (+TOHOST) and to tools/lockstep.py (--tohost). */
OUTPUT_ARCH( "riscv" )
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x10000000, LENGTH = 256K
}

SECTIONS
{
  /DISCARD/ : { *(.note.gnu.build-id) }      /* or the linker puts it at the reset vector */
  . = 0x10000000;
  .text : { *(.text) } > RAM
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) } > RAM
  . = ALIGN(0x1000);
  .page_table : { *(.page_table) } > RAM
  .data : { *(.data) } > RAM
  .user_stack : { *(.user_stack) } > RAM
  .kernel_data : { *(.kernel_data) } > RAM
  .kernel_stack : { *(.kernel_stack) } > RAM
  .bss : { *(.bss) } > RAM
  _end = .;
}
