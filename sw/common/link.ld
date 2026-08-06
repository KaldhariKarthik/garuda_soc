/* =========================================================================
 * GARUDA SoC - bare-metal linker script
 *
 * Memory map matches the verification model in rtl/ahb/ahb_mem_slave.v and
 * the core's RESET_VECTOR (rtl/core/garuda_pc_gen.v:42): one flat 256 KB
 * window at 0x1000_0000 holding text, data, bss and stack.
 *
 * This is deliberately ONE region, not separate I/D regions, because the
 * verification memory is dual-ported over a single image and there is no
 * address decoder yet. When the real TCM map lands, this file changes and
 * nothing else has to.
 *
 * tohost sits at a fixed address the testbench watches for the pass/fail
 * handshake (riscv-tests convention: 1 = pass, (n<<1)|1 = fail test n).
 * ========================================================================= */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x10000000, LENGTH = 256K
}

/* Must match tb_boot's +TOHOST default and DSU_lockstep's --tohost */
_tohost_addr = 0x1000F000;

SECTIONS
{
  . = 0x10000000;

  .text : {
    KEEP(*(.text.init))       /* crt0 / reset vector - must be first */
    *(.text .text.*)
  } > RAM

  .rodata : { *(.rodata .rodata.*) } > RAM

  /* Code placed deliberately far from the reset vector. Toggle coverage on the
     PC, the fetch address and the I-port address bus needs the UPPER address
     bits to move, and a program that lives entirely in the first few KB never
     moves them - which is why garuda_pc_gen and garuda_if_stage_top scored in
     the 70s with zero uncovered blocks. Anything in .text.far runs at
     0x1002_0000.
     NOTE the section is called .farcode, NOT .text.far: the .text output
     section above globs *(.text .text.*), which would swallow any .text.*
     input before this rule ever saw it - the symbol then links at the normal
     low address and the whole point is silently lost. */
  .farcode 0x10020000 : { *(.farcode) } > RAM

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

  /* tohost sits at a FIXED absolute address that both tb_boot (+TOHOST) and
     spike's HTIF resolve to, so the RTL run and the golden run agree on where
     the pass/fail handshake lands.
     Two things here are deliberate and were both learned the hard way:
       - the address is given on the section itself, NOT via `. = addr;` with
         `> RAM`. With a region attached, the region's allocation pointer wins
         and the section lands wherever .data ended - `lla t0, tohost` then
         resolves to a data address and the handshake writes into .data.
       - NOLOAD keeps 60 KB of zeros out of the $readmemh image. The testbench
         memory model already initialises to zero, and the symbol still exists
         for spike. */
  .tohost _tohost_addr (NOLOAD) : {
    tohost = .;
    . += 4;
    fromhost = .;
    . += 4;
  }

  . = ALIGN(16);
  _stack_top = ORIGIN(RAM) + LENGTH(RAM);

  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
