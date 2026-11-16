// =============================================================================
// filelist_dsu_top.f -- DSU unit TB against the real rtl/dsu sources.
//
// Vectors come from tools/gen/DSU_gen.py (dsu_stim.mem / dsu_expected.mem);
// regenerate them after ANY rtl/dsu change, because the expected values are
// produced by DSUModel and both must describe the same hardware.
// =============================================================================
-incdir rtl/dsu

rtl/dsu/dsu_pkg.sv
rtl/dsu/csa_3to2.sv
rtl/dsu/kogge_stone_49.sv
rtl/dsu/mult_16x16.sv
rtl/dsu/operand_router.sv
rtl/dsu/mac_unit.sv
rtl/dsu/mac_cluster.sv
rtl/dsu/barrel_shifter.sv
rtl/dsu/saturation_unit.sv
rtl/dsu/readback_mux.sv
rtl/dsu/result_selector.sv
rtl/dsu/overflow_flag.sv
rtl/dsu/dsu_stall.sv
rtl/dsu/dsu_decoder.sv
rtl/dsu/dsu_top.sv
rtl/dsu/dsu_sva.sv
rtl/dsu/dsu_arith_sva.sv
rtl/dsu/dsu_props_a.sv

-sv
tb/dsu/dsu_cov.sv
tb/dsu/dsu_cov_vplan.sv
tb/dsu/tb_dsu_top.sv
