// =============================================================================
// GARUDA SoC - Blocks 3/4/5: Memory Subsystem
// filelist.f - synthesizable memory sources, bottom-up
//
// Top modules: isram_top (S0), bootrom_top (S1), dsram_top (S2)
//
// Three block tops in one filelist because they are one specification
// (GARUDA-MEM-SPEC-001 Rev 2.0) and share one slave wrapper and one array
// model. Listing them separately would mean three copies of the -incdir and
// three chances for a build to pick up two of the three.
//
// Everything here is silicon RTL. The verification models these replace stay
// where they are: tb/ahb/ahb_lite_sram.v is still the thing that proved the
// interconnect before the memories existed, and it is still what the Block 6
// block-level testbench uses.
//
// mem_array_sp.v is behavioural and is the ONE file the PDK swap replaces
// (Sec. 13.6). Nothing above it in this list knows how the array is built.
// =============================================================================

-incdir rtl/mem

// Shared leaves
rtl/mem/mem_array_sp.v
rtl/mem/ahb_mem_slave_if.v

// Block 4 bank
rtl/dsram/dsram_bank.v

// Block boundaries
rtl/isram/isram_top.v
rtl/dsram/dsram_top.v
rtl/brom/bootrom_top.v
