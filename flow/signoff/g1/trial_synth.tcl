# 1-TOPS item 1.15: gate-count budget from a trial synthesis of garuda_chip_top.
# Library: Nangate 45 nm open cell library (has area; the Cadence generic 45 nm
# typical.lib has none). Nangate has no tristate buffer, which the five
# bidirectional / tri-state pads of the chip top need, so typical.lib is read too
# with every cell dont_use except its TBUFX3 (5 cells, area 0 in that library).
# SRAMs and ROM are black boxes (GARUDA_SRAM_BLACKBOX):
# they become macros, so the count is logic only. No SDC: generic effort mapping.
# Run from the repository root:
#   /home/install/GENUS211/bin/genus -batch -no_gui -files flow/signoff/g1/trial_synth.tcl -log sim/g1_synth/genus
set LIB /home/install/FOUNDRY/digital/45nm/NangateOpenCellLibrary_v1.00_20080225/liberty/FreePDK45_lib_v1.0_typical.lib
set TBUF_LIB /home/install/FOUNDRY/digital/45nm/dig/lib/typical.lib
set OUT sim/g1_synth
file mkdir $OUT
set srcs [split [string trim [exec python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f]]]
set incs [split [string trim [exec python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f --incdirs]]]
set inc_paths {rtl/include}
foreach i $incs { lappend inc_paths [string range $i 2 end] }
set_db information_level 1
set_db hdl_error_on_latch false
set_db init_hdl_search_path $inc_paths
read_libs [list $LIB $TBUF_LIB]
foreach c [get_db lib_cells */typical/*] { set_db $c .dont_use true }
puts "TRIAL_SYNTH dont_use on [llength [get_db lib_cells */typical/*]] typical cells"
set_db [get_db lib_cells */typical/TBUFX3] .dont_use false
read_hdl -define SYNTHESIS -define GARUDA_SRAM_BLACKBOX -sv $srcs
elaborate garuda_chip_top
check_design -unresolved > $OUT/unresolved.rpt
syn_generic
syn_map
report_area > $OUT/area.rpt
report_gates > $OUT/gates.rpt
report_area -depth 2 > $OUT/area_by_block.rpt
set nand2 [get_db [get_db lib_cells */NAND2_X1] .area]
report_gates -power > /dev/null
set total 0.0
foreach i [get_db insts -if {.is_black_box == false}] { set a [get_db $i .area]; if {$a ne ""} { set total [expr {$total + $a}] } }
puts "TRIAL_SYNTH cells=[llength [get_db insts]] flops=[llength [get_db insts -if {.is_flop == true}]] latches=[llength [get_db insts -if {.is_latch == true}]] area_um2=[format %.1f $total] nand2_um2=$nand2 kGE=[format %.1f [expr {$total / $nand2 / 1000.0}]]"
quit
