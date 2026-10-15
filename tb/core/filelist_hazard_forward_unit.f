// =============================================================================
// filelist_hazard_forward_unit.f -- run tb_hazard_forward_unit.sv against the REAL rtl/core sources.
//
// The bench has no inlined DUT copy (removed in W6, 2026-10-11): what is
// verified is the RTL that actually ships. GARUDA_REAL_RTL is kept defined for
// older scripts and has no effect.
//
// Top module is tb_top (not tb_hazard_forward_unit).
// =============================================================================
-define GARUDA_REAL_RTL

-incdir rtl/common
-incdir rtl/core

rtl/core/hazard_forward_unit.v

-sv
tb/core/tb_hazard_forward_unit.sv
