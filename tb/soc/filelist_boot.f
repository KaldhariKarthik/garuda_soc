// =============================================================================
// filelist_boot.f -- tb_boot: core + REAL DSU + AHB memory model
//
// Uses the real DSU (not the stub): tb_boot runs real instruction streams and
// any DSU test built on top of it needs the real cluster behind Custom-0.
// =============================================================================
-incdir rtl/common
-incdir rtl/core
-incdir rtl/dsu

-f rtl/core/filelist_core_dsu.f

// verification support
rtl/ahb/ahb_mem_slave.v

// AHB-Lite protocol checker. In the PLAIN filelist on purpose: every test in
// the suite now checks bus protocol as well as its own result, at no extra
// stimulus cost. Verilog-2001 with no SVA so it builds identically under
// xrun 22.09 and irun 15.20.
tb/ahb/ahb_lite_checker.v

tb/soc/tb_boot.v
