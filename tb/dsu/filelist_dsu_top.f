// =============================================================================
// filelist_dsu_top.f -- DSU unit TB against the real rtl/dsu sources.
//
// Vectors come from tools/gen/DSU_gen.py (dsu_stim.mem / dsu_expected.mem);
// regenerate them after ANY rtl/dsu change, because the expected values are
// produced by DSUModel and both must describe the same hardware.
// =============================================================================
-incdir rtl/dsu

rtl/dsu/csa_3to2.v
rtl/dsu/kogge_stone_49.v
rtl/dsu/mult_16x16.v
rtl/dsu/operand_router.v
rtl/dsu/mac_unit.v
rtl/dsu/mac_cluster.v
rtl/dsu/barrel_shifter.v
rtl/dsu/saturation_unit.v
rtl/dsu/readback_mux.v
rtl/dsu/result_selector.v
rtl/dsu/overflow_flag.v
rtl/dsu/dsu_stall.v
rtl/dsu/dsu_decoder.v
rtl/dsu/dsu_top.v

-sv
tb/dsu/tb_dsu_top.sv
