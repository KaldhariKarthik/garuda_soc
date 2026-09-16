// =============================================================================
// filelist_soc.f -- garuda_soc_top: the wired SoC
//
// Top module: garuda_soc_top
//
// Core (+ real DSU) + DMA + AHB interconnect + memories + AHB-to-APB bridge
// + CLIC. Ten of the twenty-four blocks, and every block that has RTL.
//
// Uses filelist_core_dsu.f, never filelist_core.f: the SoC build needs the real
// rtl/dsu/dsu_top.v, not tb/stub/dsu_top_stub.v. The two define the same module
// name, so including both is an elaboration error rather than a silent wrong
// build - which is the intended behaviour.
//
// NO VERIFICATION MODELS APPEAR IN THIS LIST. The previous revision pulled the
// memories and the bridge from tb/ahb/ because Blocks 3/4/5/8 had no RTL; they
// do now, and tb/ahb/ahb_lite_sram.v and tb/ahb/ahb2apb_bridge_model.v are no
// longer part of any SoC build. They remain in tb/ as what proved the
// interconnect before the real blocks existed, and tb_ahb_interconnect.sv still
// uses them.
//
// Blocks 22/23 (clock and reset) are NOT here either - they sit one level up in
// filelist_chip.f, because a testbench driving this module wants to drive reset
// directly rather than through a reset controller.
// =============================================================================
-incdir rtl/common
-incdir rtl/core
-incdir rtl/dsu
-incdir rtl/dma
-incdir rtl/ahb
-incdir rtl/mem
-incdir rtl/ahb2apb
-incdir rtl/clic

// Block 1 + Block 2 (core with the real DSU inside it)
-f rtl/core/filelist_core_dsu.f

// Block 9
-f rtl/dma/filelist.f

// Block 6
-f rtl/ahb/filelist.f

// Blocks 3 / 4 / 5
-f rtl/mem/filelist.f

// Block 8
-f rtl/ahb2apb/filelist.f

// Block 16
-f rtl/clic/filelist.f

// SoC boundary
rtl/soc/garuda_soc_top.v
