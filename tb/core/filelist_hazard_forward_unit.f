// =============================================================================
// filelist_hazard_forward_unit.f -- run tb_hazard_forward_unit.sv against the REAL rtl/core sources.
//
// The testbench ships with its own inlined copy of the DUT so it can be built
// standalone under VCS. GARUDA_REAL_RTL skips that copy, so what is verified
// here is the RTL that actually ships rather than a snapshot of it. The
// standalone VCS build is unaffected - it simply does not define the macro.
//
// Top module is tb_top (not tb_hazard_forward_unit).
// =============================================================================
-define GARUDA_REAL_RTL

-incdir rtl/common
-incdir rtl/core

rtl/core/hazard_forward_unit.v

-sv
tb/core/tb_hazard_forward_unit.sv
