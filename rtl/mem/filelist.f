// =============================================================================
// GARUDA SoC - Blocks 3/4/5 : memory subsystem (Rev 4.0)
// ISRAM / Boot ROM / DSRAM behind one shared AHB front end, all macros in
// sram_wrapper.v (GARUDA-MEM-SPEC-001 [N-4.1]).
// =============================================================================
-incdir rtl/mem

rtl/mem/sram_wrapper.v
rtl/mem/ahb_mem_slave_if.v

rtl/isram/isram_top.v
rtl/dsram/dsram_top.v
rtl/brom/bootrom_top.v
