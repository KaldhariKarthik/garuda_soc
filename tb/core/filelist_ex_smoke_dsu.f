// EX-stage smoke against the REAL DSU (integration check).
// Same testbench as filelist_ex_smoke.f, but rtl/dsu/* replaces the inert stub.
// Proves the frozen Sec.9.2 boundary holds against real hardware: with dsu_en
// low the DSU must stay quiet (dsu_busy=0, dsu_rd_valid=0, no X into the EX
// result mux) and every non-DSU EX result must be bit-identical to the stub run.
-sv
-incdir rtl/common
-incdir rtl/core
-incdir rtl/dsu
rtl/core/alu.v
rtl/core/mul32.v
rtl/core/branch_unit.v
rtl/core/csr_rw.v
rtl/core/ex_stage.v

// DSU (real) -- leaf-first
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

tb/core/tb_ex_smoke.v
