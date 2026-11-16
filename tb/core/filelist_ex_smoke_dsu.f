// EX-stage smoke against the REAL DSU (integration check).
// Same testbench as filelist_ex_smoke.f, but rtl/dsu/* replaces the inert stub.
// Proves the frozen Sec.9.2 boundary holds against real hardware: with dsu_en
// low the DSU must stay quiet (dsu_busy=0, dsu_rd_valid=0, no X into the EX
// result mux) and every non-DSU EX result must be bit-identical to the stub run.
-sv
-incdir rtl/common
-incdir rtl/core
-incdir rtl/dsu
rtl/common/garuda_pkg.sv
rtl/core/core_ex_pkg.sv
rtl/dsu/dsu_pkg.sv
rtl/core/alu_unit.sv
rtl/core/mul32.sv
rtl/core/branch_unit.sv
rtl/core/csr_rw.sv
rtl/core/ex_stage.sv

// DSU (real) -- leaf-first
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

tb/core/tb_ex_smoke.sv
