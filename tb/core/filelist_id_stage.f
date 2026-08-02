// =============================================================================
// filelist_id_stage.f -- run tb_id_stage.sv against the REAL rtl/core sources.
//
// The testbench ships with its own inlined copy of the DUT so it can be built
// standalone under VCS. GARUDA_REAL_RTL skips that copy, so what is verified
// here is the RTL that actually ships rather than a snapshot of it. The
// standalone VCS build is unaffected - it simply does not define the macro.
//
// Top module is tb_top (not tb_id_stage).
// =============================================================================
-define GARUDA_REAL_RTL

-incdir rtl/common
-incdir rtl/core

rtl/core/decode_control.v
rtl/core/imm_gen.v
rtl/core/regfile.v
rtl/core/branch_predict.v
rtl/core/hazard_forward_unit.v
rtl/core/id_stage.v

-sv
tb/core/tb_id_stage.sv
