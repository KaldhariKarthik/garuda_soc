// filelist_pkg.f -- the RTL packages, in dependency order (zero-waiver F4, 2026-11-16).
// Included once, first, by every ROOT filelist whose sources import a package. Nested
// filelists never list a package: Xcelium refuses a package compiled twice in one run
// (DLCSMD). scripts/expand_filelist.py adds what a block list needs on its own.
rtl/common/garuda_pkg.sv
rtl/core/core_ex_pkg.sv
rtl/ahb/ahb_pkg.sv
rtl/dsu/dsu_pkg.sv
rtl/mem/mem_pkg.sv
rtl/include/soc_map_pkg.sv
