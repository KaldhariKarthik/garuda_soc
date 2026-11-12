# =============================================================================
# block_corner_libs.tcl -- one timing model of a hardened memory block for one
# corner (PD-13). ORFS writes a single <block>_typ.lib at the run's corner; the
# multi-corner analysis needs SS, TT and FF models of the same block.
#
# env: BLOCK_DIR (the block's results directory), BLOCK, CORNER, CORNER_LIBS
#      (the standard-cell libraries of that corner), OUT (the .lib to write)
# Same steps as ORFS's generate_abstract.tcl: the block's final database and
# SDC, its extracted parasitics, propagated clocks, source latency 0.
# =============================================================================
foreach l $::env(CORNER_LIBS) { read_liberty $l }
read_db $::env(BLOCK_DIR)/6_final.odb
read_sdc $::env(BLOCK_DIR)/6_final.sdc
if {[file exists $::env(BLOCK_DIR)/6_final.spef]} { read_spef $::env(BLOCK_DIR)/6_final.spef }
set_propagated_clock [all_clocks]
set_clock_latency -source 0 [all_clocks]
write_timing_model -library_name $::env(BLOCK)_$::env(CORNER) $::env(OUT)
puts "=== wrote $::env(OUT)"
