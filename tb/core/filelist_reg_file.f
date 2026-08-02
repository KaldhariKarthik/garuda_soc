// =============================================================================
// filelist_reg_file.f -- run tb_reg_file.sv against the REAL rtl/core sources.
//
// The testbench ships with its own inlined copy of the DUT so it can be built
// standalone under VCS. GARUDA_REAL_RTL skips that copy, so what is verified
// here is the RTL that actually ships rather than a snapshot of it. The
// standalone VCS build is unaffected - it simply does not define the macro.
//
// Top module is tb_top (not tb_reg_file).
// =============================================================================
-define GARUDA_REAL_RTL

-incdir rtl/common
-incdir rtl/core

rtl/core/regfile.v

-sv
tb/core/tb_reg_file.sv
