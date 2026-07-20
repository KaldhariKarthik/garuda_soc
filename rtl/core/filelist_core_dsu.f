// =============================================================================
// filelist_core_dsu.f -- core + REAL DSU (integration / SoC build)
//
// Identical to filelist_core.f except the last entry: the real rtl/dsu/dsu_top.v
// and its submodules replace tb/stub/dsu_top_stub.v. Never include both -- they
// define the same module name.
//
//   filelist_core.f      -> core standalone, inert DSU stub (fast core-only work)
//   filelist_core_dsu.f  -> core + real DSU  (integration, SoC, any DSU test)
// =============================================================================
-incdir rtl/common
-incdir rtl/core
-incdir rtl/dsu

// IF
rtl/core/garuda_pc_gen.v
rtl/core/garuda_iport_ahb_master.v
rtl/core/garuda_prefetch_buffer.v
rtl/core/garuda_if_stage_top.v
rtl/core/if_id.v

// ID
rtl/core/decode_control.v
rtl/core/imm_gen.v
rtl/core/regfile.v
rtl/core/branch_predict.v
rtl/core/hazard_forward_unit.v
rtl/core/id_stage.v
rtl/core/id_ex.v

// EX (+ forwarding)
rtl/core/alu.v
rtl/core/mul32.v
rtl/core/branch_unit.v
rtl/core/csr_rw.v
rtl/core/ex_stage.v
rtl/core/forward_unit.v
rtl/core/ex_mem.v

// MEM / WB
rtl/core/load_store_unit.v
rtl/core/d_port_ahb_master.v
rtl/core/load_formatter.v
rtl/core/mem_stage.v
rtl/core/mem_wb_reg.v
rtl/core/wb_stage.v

// CONTROL / CSR / TRAP / CLIC
rtl/core/csr_file.v
rtl/core/clic_ctrl.v
rtl/core/trap_ctrl.v
rtl/core/pipe_ctrl.v

// core top
rtl/core/garuda_core_top.v

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
