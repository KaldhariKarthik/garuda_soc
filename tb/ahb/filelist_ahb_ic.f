// =============================================================================
// filelist_ahb_ic.f -- tb_ahb_interconnect: Block 6 block-level testbench
//
// RTL under test is rtl/ahb/filelist.f exactly as synthesised. Everything else
// here is a verification model and lives under tb/.
// =============================================================================
-incdir rtl/ahb

-f rtl/ahb/filelist.f

// verification models (NOT SoC RTL - see each file's header)
tb/ahb/ahb_lite_sram.v
tb/ahb/ahb_lite_master_bfm.sv

// passive protocol monitor, bound to all three master ports and the slave bus
tb/ahb/ahb_lite_checker.v

tb/ahb/tb_ahb_interconnect.sv
