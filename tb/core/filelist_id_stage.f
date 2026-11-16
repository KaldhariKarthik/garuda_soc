// =============================================================================
// filelist_id_stage.f -- run tb_id_stage.sv against the REAL rtl/core sources.
//
// The bench has no inlined DUT copy (removed in W6, 2026-10-11): what is
// verified is the RTL that actually ships. GARUDA_REAL_RTL is kept defined for
// older scripts and has no effect.
//
// Top module is tb_top (not tb_id_stage).
// =============================================================================
-define GARUDA_REAL_RTL

-incdir rtl/common
-incdir rtl/core

rtl/common/garuda_pkg.sv
rtl/core/decode_control.sv
rtl/core/imm_gen.sv
rtl/core/regfile.sv
rtl/core/branch_predict.sv
rtl/core/hazard_fwd_unit.sv
rtl/core/id_stage.sv

-sv
tb/core/tb_id_stage.sv
