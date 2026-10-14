// filelist_core_halt_cov.f -- tb_core_halt + the bound core covergroups
// (tb/cov/garuda_cov.sv, garuda_cov_ext.sv) for coverage runs: the halt bench
// is the one place the debug halt request (cg_halt, RDC-1) is driven.
-f tb/core/filelist_core_halt.f
-sv
tb/cov/garuda_cov.sv
tb/cov/garuda_cov_ext.sv
tb/cov/garuda_cov_vplan.sv
tb/dsu/dsu_cov_vplan.sv
