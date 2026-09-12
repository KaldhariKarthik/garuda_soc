// =============================================================================
// filelist_soc.f -- garuda_soc_top: core (+ real DSU) + DMA + AHB interconnect
//
// Top module: garuda_soc_top
//
// Uses filelist_core_dsu.f, never filelist_core.f: the SoC build needs the real
// rtl/dsu/dsu_top.v, not tb/stub/dsu_top_stub.v. The two define the same module
// name, so including both is an elaboration error rather than a silent wrong
// build - which is the intended behaviour.
//
// The four AHB slaves and the AHB-to-APB bridge are NOT in this list. Blocks
// 3/4/5/8 have no RTL and no design specification yet; garuda_soc_top exposes
// their ports at its boundary and the testbench supplies models from tb/ahb/.
// =============================================================================
-incdir rtl/common
-incdir rtl/core
-incdir rtl/dsu
-incdir rtl/dma
-incdir rtl/ahb

// Block 1 + Block 2 (core with the real DSU inside it)
-f rtl/core/filelist_core_dsu.f

// Block 9
-f rtl/dma/filelist.f

// Block 6
-f rtl/ahb/filelist.f

// SoC boundary
rtl/soc/garuda_soc_top.v
