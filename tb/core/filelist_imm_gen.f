// =============================================================================
// filelist_imm_gen.f -- run tb_imm_gen.sv against the REAL rtl/core sources.
//
// The testbench ships with its own inlined copy of the DUT so it can be built
// standalone under VCS. GARUDA_REAL_RTL skips that copy, so what is verified
// here is the RTL that actually ships rather than a snapshot of it. The
// standalone VCS build is unaffected - it simply does not define the macro.
//
// Top module is tb_top (not tb_imm_gen).
// =============================================================================
-define GARUDA_REAL_RTL

-incdir rtl/common
-incdir rtl/core

rtl/core/imm_gen.v

-sv
tb/core/tb_imm_gen.sv
