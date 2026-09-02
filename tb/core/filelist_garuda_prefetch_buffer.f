// filelist_garuda_prefetch_buffer.f -- SystemVerilog element TB. Top module is tb_top.
//
// No GARUDA_REAL_RTL define here: unlike the older unit TBs, these carry no
// inlined DUT snapshot, so the real rtl/core source below is the only DUT
// that can ever be compiled. See docs/CORE_ELEMENT_VERIFICATION.md.

-incdir rtl/common
-incdir rtl/core
rtl/core/garuda_prefetch_buffer.v

-sv
tb/core/garuda_tb_pkg.sv
tb/core/tb_garuda_prefetch_buffer.sv
