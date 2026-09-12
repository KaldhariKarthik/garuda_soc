// =============================================================================
// filelist_soc_ahb.f -- tb_soc_ahb: core + real DSU + DMA + AHB interconnect
//
// The DUT is rtl/soc/filelist_soc.f exactly as it would be synthesised. Blocks
// 3/4/5/8 do not exist, so their models come from tb/ahb/ - each one says so in
// its own header.
// =============================================================================
-incdir rtl/common
-incdir rtl/core
-incdir rtl/dsu
-incdir rtl/dma
-incdir rtl/ahb

-f rtl/soc/filelist_soc.f

// verification models for the blocks that have no RTL yet
tb/ahb/ahb_lite_sram.v
tb/ahb/ahb2apb_bridge_model.v

// passive protocol monitor
tb/ahb/ahb_lite_checker.v

tb/soc/tb_soc_ahb.sv
