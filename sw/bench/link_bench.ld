/* =============================================================================
 * link_bench.ld -- benchmarks on tb_boot (plan 5.7). sw/common/link.ld plus the
 * result block: .benchres at 0x1003_0000, 16 KB, NOLOAD (the memory model
 * starts at zero). The stack runs down from 0x1004_0000 and must stay above it;
 * tools/bench_report.py checks the block's magic word, so a stack that ran into
 * it shows up as a bad block, not as a wrong score.
 * ========================================================================= */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x10000000, LENGTH = 256K
}

_tohost_addr = 0x1000F000;

SECTIONS
{
  . = 0x10000000;
  .text   : { KEEP(*(.text.init)) *(.text .text.*) } > RAM
  .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) } > RAM
  . = ALIGN(4);
  .data : {
    _data_start = .;
    *(.data .data.*)
    *(.sdata .sdata.*)
    _data_end = .;
  } > RAM
  . = ALIGN(4);
  .bss (NOLOAD) : {
    _bss_start = .;
    *(.bss .bss.*)
    *(.sbss .sbss.*)
    *(COMMON)
    _bss_end = .;
  } > RAM
  ASSERT(_bss_end <= _tohost_addr, "benchmark image runs into tohost")

  .tohost _tohost_addr (NOLOAD) : {
    tohost = .;
    . += 4;
    fromhost = .;
    . += 4;
  }

  .benchres 0x10030000 (NOLOAD) : { bench_res_start = .; KEEP(*(.benchres)) bench_res_end = .; }

  _stack_top = ORIGIN(RAM) + LENGTH(RAM);

  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
