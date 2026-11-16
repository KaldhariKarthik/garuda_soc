// t_core_hartreset bench: core + real DSU + memory + AHB checkers + the real Debug Module
-incdir rtl/common
-incdir rtl/core
-incdir rtl/dsu
-f rtl/core/filelist_core_dsu.f
rtl/ahb/ahb_mem_slave.sv
tb/ahb/ahb_lite_checker.v
rtl/debug/debug_module.sv
rtl/reset_ctrl/core_rst_sync.sv
-sv
tb/core/tb_core_halt.sv
