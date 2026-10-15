// t_core_hartreset bench: core + real DSU + memory + AHB checkers + the real Debug Module
-incdir rtl/common
-incdir rtl/core
-incdir rtl/dsu
-f rtl/core/filelist_core_dsu.f
rtl/ahb/ahb_mem_slave.v
tb/ahb/ahb_lite_checker.v
rtl/debug/debug_module.v
-sv
tb/core/tb_core_halt.sv
