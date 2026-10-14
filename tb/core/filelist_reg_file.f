// =============================================================================
// filelist_reg_file.f -- run tb_reg_file.sv against the REAL rtl/core sources.
//
// The bench has no inlined DUT copy (removed in W6, 2026-10-11): what is
// verified is the RTL that actually ships. GARUDA_REAL_RTL is kept defined for
// older scripts and has no effect.
//
// Top module is tb_top (not tb_reg_file).
// =============================================================================
-define GARUDA_REAL_RTL

-incdir rtl/common
-incdir rtl/core

rtl/core/regfile.v

-sv
tb/core/tb_reg_file.sv
