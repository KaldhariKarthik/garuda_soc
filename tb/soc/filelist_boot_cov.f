// =============================================================================
// filelist_boot_cov.f -- tb_boot + bound functional covergroups.
//
// Separate from filelist_boot.f so the everyday regression stays fast: covergroup
// sampling costs simulation time and is only wanted on coverage runs.
//
// NOTE ON ORDER: -define MUST come before the -f include. Options in a filelist
// apply to files compiled AFTER them, so putting the define at the bottom left
// tb_boot.v compiled without GARUDA_COV and the coverage report silently never
// ran - no error, just no output.
// =============================================================================
-define GARUDA_COV

-f tb/soc/filelist_boot.f

-sv
tb/cov/garuda_cov.sv
