// =============================================================================
// GARUDA SoC - Blocks 3/4/5 : memory subsystem (Rev 4.0)
// ISRAM / Boot ROM / DSRAM behind one shared AHB front end, all macros in
// sram_wrapper.v (GARUDA-MEM-SPEC-001 [N-4.1]).
// =============================================================================
-incdir rtl/mem

rtl/mem/mem_pkg.sv
rtl/mem/sram_wrapper.sv
rtl/mem/ahb_mem_slave_if.sv

rtl/isram/isram_top.sv
rtl/dsram/dsram_top.sv
rtl/brom/bootrom_top.sv
rtl/mem/mem_sva.sv
