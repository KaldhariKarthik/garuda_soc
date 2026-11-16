// =============================================================================
// filelist_core_dsu.f -- core + REAL DSU (integration / SoC build)
//
// Identical to filelist_core.f except the last entry: the real rtl/dsu/dsu_top.sv
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
rtl/common/garuda_pkg.sv
rtl/core/core_ex_pkg.sv
rtl/dsu/dsu_pkg.sv
rtl/core/garuda_pc_gen.sv
rtl/core/iport_master.sv
rtl/core/prefetch_buf.sv
rtl/core/if_stage_top.sv
rtl/core/if_id.sv

// ID
rtl/core/decode_control.sv
rtl/core/imm_gen.sv
rtl/core/regfile.sv
rtl/core/branch_predict.sv
rtl/core/hazard_fwd_unit.sv
rtl/core/id_stage.sv
rtl/core/id_ex.sv

// EX (+ forwarding)
rtl/core/alu_unit.sv
rtl/core/mul32.sv
rtl/core/branch_unit.sv
rtl/core/csr_rw.sv
rtl/core/ex_stage.sv
rtl/core/forward_unit.sv
rtl/core/ex_mem.sv

// MEM / WB
rtl/core/load_store_unit.sv
rtl/core/dport_master.sv
rtl/core/load_formatter.sv
rtl/core/mem_stage.sv
rtl/core/mem_wb_reg.sv
rtl/core/wb_stage.sv

// CONTROL / CSR / TRAP / CLIC
rtl/core/csr_file.sv
rtl/core/clic_ctrl.sv
rtl/core/trap_ctrl.sv
rtl/core/pipe_ctrl.sv
// [N-11.3] properties, bound at garuda_core_top. Simulation only; -sv because
// the rest of this filelist is Verilog-2001.
-sv
rtl/core/pipe_ctrl_sva.sv
rtl/core/pipe_regs_sva.sv
rtl/core/core_units_sva.sv
rtl/core/core_units2_sva.sv
rtl/core/trap_ctrl_sva.sv
rtl/core/core_units3_sva.sv
rtl/core/decode_control_sva.sv
rtl/core/trap_ctrl_props_a.sv
rtl/core/csr_file_props_a.sv
rtl/core/core_ctl_sva.sv
rtl/core/core_vplan_sva.sv
rtl/core/core_clk_gate.sv

// core top
rtl/core/garuda_rvfi.sv
rtl/core/garuda_core_top.sv

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
rtl/dsu/dsu_sva.sv
rtl/dsu/dsu_arith_sva.sv
