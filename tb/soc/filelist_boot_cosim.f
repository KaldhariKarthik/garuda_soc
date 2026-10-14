// filelist_boot_cosim.f -- tb_boot + RVFI + the Spike co-simulation (plan
// 5.2 / 5.3). The defines come before the -f include. The C++ glue is linked
// against the pinned Spike: see vl_flags in tb/core/run/cosim.toml.
-define GARUDA_RVFI
-define GARUDA_COSIM
-f tb/soc/filelist_boot.f
tools/cosim/garuda_cosim.cc
