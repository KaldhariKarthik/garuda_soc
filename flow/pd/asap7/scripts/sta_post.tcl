# =============================================================================
# sta_post.tcl -- STA of one DIVSEL scenario on a CTS or routed database.
#
# env (run_sta.sh): ODB, SPEF ("none" = estimate from placement), SDC, MODE,
#      LIB_FILES, ADDITIONAL_LIBS, PLATFORM_DIR.
#
# Prints a "=== summary" block of key/value lines (pd_summary_lines) that
# run_sta.sh and qor.py read, then the worst paths, then the two
# reset-release paths and the reset fan-out that PD_LOG_2026-10-14 tracks.
# =============================================================================
source $::env(PD_SCRIPTS)/pd_common.tcl

pd_read_libs
read_db $::env(ODB)
puts "=== SDC $::env(SDC)"
read_sdc $::env(SDC)
set_propagated_clock [all_clocks]
pd_rc
if {$::env(SPEF) eq "none"} {
    estimate_parasitics -placement
    puts "=== parasitics: placement estimate"
} else {
    read_spef $::env(SPEF)
    puts "=== parasitics: $::env(SPEF)"
}

puts "=== summary"
pd_summary_lines

puts "=== worst setup per group"
report_checks -path_delay max -group_path_count 1 -format end -sort_by_slack
puts "=== worst hold per group"
report_checks -path_delay min -group_path_count 1 -format end -sort_by_slack
puts "=== worst setup path"
report_checks -path_delay max -digits 1 -fields {fanout cap slew}
puts "=== worst hold path"
report_checks -path_delay min -digits 1

# The bridge's APB-reset release flop: hclk captures a pclk-domain reset.
puts "=== reset-release 1: u_bridge.prst_ok_q D"
set p1 [get_pins -hierarchical -quiet {u_soc.u_bridge.prst_ok_q*/D}]
foreach p $p1 { puts "pin [get_full_name $p]" }
if {[llength $p1]} { report_checks -to $p1 -path_delay min_max -digits 1 -fields {fanout} }

# The SPI slave's chip select: an asynchronous set, so a recovery check.
puts "=== reset-release 2: SPI-slave cs_n_q SETN (recovery)"
set p2 [get_pins -hierarchical -quiet {*cs_n_q*/SETN}]
foreach p $p2 { puts "pin [get_full_name $p]" }
if {[llength $p2]} { report_checks -to $p2 -path_delay min_max -digits 1 -fields {fanout} }

puts "=== prst_q fan-out after resizing"
foreach p [get_pins -hierarchical -quiet {u_reset_ctrl.prst_q*/QN}] {
    set n [llength [get_pins -of_objects [get_nets -of_objects $p] -filter {direction == input}]]
    puts "[get_full_name $p] fanout $n"
}
puts "=== DONE $::env(MODE)"
