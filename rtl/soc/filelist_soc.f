// =============================================================================
// GARUDA SoC - garuda_soc_top (Rev 4.0): every block except clock/reset
// =============================================================================
-incdir rtl/include
-incdir rtl/common
-incdir rtl/core
-incdir rtl/dsu
-incdir rtl/ahb
-incdir rtl/mem

-f rtl/core/filelist_core_dsu.f
-f rtl/dma/filelist.f
-f rtl/ahb/filelist.f
-f rtl/mem/filelist.f
-f rtl/ahb2apb/filelist.f
-f rtl/clic/filelist.f
-f rtl/timers/filelist.f
-f rtl/debug/filelist.f

rtl/soc/garuda_soc_top.v
