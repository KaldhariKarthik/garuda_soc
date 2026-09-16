// =============================================================================
// filelist_mem.f -- tb_mem_subsystem: Blocks 3/4/5 block-level testbench
//
// Top module: tb_mem_subsystem
//
// RTL under test is rtl/mem/filelist.f exactly as it would be synthesised.
//
// There are no verification models here at all. The memories ARE the slaves, so
// there is nothing to stand in for, and the testbench drives the slave bundle
// directly rather than through a master BFM - see the testbench header for why
// that is the right choice for a slave-contract test.
// =============================================================================

-incdir rtl/mem

-f rtl/mem/filelist.f

tb/mem/tb_mem_subsystem.sv
