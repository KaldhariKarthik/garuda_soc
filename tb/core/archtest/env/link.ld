/* riscv-arch-test on tb_boot (plan 5.4): code from the reset vector, data right
   after it (the branch tests alone are ~220 KiB of code), tohost at the top of
   the 2 MiB memory of the GARUDA_TB_MEM2M tb_boot build. The tests' stores go to .data / the signature, never to
   the tb_boot test device registers (0x1000_F200), which only react to writes. */
OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)
SECTIONS
{
  . = 0x10000000;
  .text.init : { *(.text.init) }
  .text : { *(.text) }
  . = ALIGN(16);
  .data : { *(.data) }
  .data.string : { *(.data.string) }
  .bss : { *(.bss) }
  ASSERT(. <= 0x101FF000, "arch test does not fit below tohost")
  . = 0x101FF000;
  .tohost : { *(.tohost) }
  _end = .;
}
