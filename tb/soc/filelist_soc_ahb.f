// =============================================================================
// filelist_soc_ahb.f -- tb_soc_ahb: the wired SoC
//
// The DUT is rtl/soc/filelist_soc.f exactly as it would be synthesised.
//
// WHAT CHANGED: this list used to pull tb/ahb/ahb_lite_sram.v and
// tb/ahb/ahb2apb_bridge_model.v, because Blocks 3/4/5 and 8 had no RTL and the
// testbench had to supply them. They do now, so the SoC contains the real
// memories, the real bridge and the real CLIC, and NO VERIFICATION MODEL IS
// COMPILED INTO THIS TESTBENCH AT ALL.
//
// Those models still exist and are still used - by tb_ahb_interconnect.sv,
// which tests Block 6 in isolation and needs slaves to test it against. They
// are simply no longer part of any SoC build.
// =============================================================================
-incdir rtl/common
-incdir rtl/core
-incdir rtl/dsu
-incdir rtl/dma
-incdir rtl/ahb
-incdir rtl/mem
-incdir rtl/ahb2apb
-incdir rtl/clic

-f rtl/soc/filelist_soc.f

// passive protocol monitor - the only non-RTL file in this build
tb/ahb/ahb_lite_checker.v

tb/soc/tb_soc_ahb.sv
