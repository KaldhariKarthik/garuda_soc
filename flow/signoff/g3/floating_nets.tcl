# 1-TOPS item 3.16: undriven, unloaded and multiply driven nets and ports at every
# level of garuda_chip_top, from Genus check_design on the elaborated RTL (before
# any optimisation, so nothing is hidden by constant propagation).
# Run from the repository root, in tcsh:
#   source /home/install/cshrc
#   /home/install/GENUS211/bin/genus -batch -no_gui -files flow/signoff/g3/floating_nets.tcl -log sim/g3_float/genus
set OUT sim/g3_float
file mkdir $OUT
set srcs [split [string trim [exec python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f]]]
set incs [split [string trim [exec python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f --incdirs]]]
set inc_paths {rtl/include}
foreach i $incs { lappend inc_paths [string range $i 2 end] }
set_db information_level 1
set_db hdl_error_on_latch false
set_db init_hdl_search_path $inc_paths
read_libs /home/install/FOUNDRY/digital/45nm/NangateOpenCellLibrary_v1.00_20080225/liberty/FreePDK45_lib_v1.0_typical.lib
read_hdl -define SYNTHESIS -define GARUDA_SRAM_BLACKBOX -sv $srcs
elaborate garuda_chip_top
check_design -undriven     > $OUT/undriven.rpt
check_design -unloaded     > $OUT/unloaded.rpt
check_design -multiple_driver > $OUT/multidriven.rpt
check_design -unresolved   > $OUT/unresolved.rpt
check_design -all          > $OUT/all.rpt
quit
