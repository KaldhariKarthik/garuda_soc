# =============================================================================
# cts_skew.tcl -- clock-tree analysis after CTS: insertion delay per clock,
# skew, and the worst hold path with its clock paths expanded.
#
# env (run_skew.sh): ODB, SDC, LIB_FILES, ADDITIONAL_LIBS, PLATFORM_DIR.
#
# Written for BUGS PD-7: TritonCTS's latency balancer had put ~2.1 ns on the
# aon_clk branch feeding the hclk mux. The aon_clk, hclk and pclk trees must
# stay latency-aligned (config.mk CTS_ARGS -no_insertion_delay); this report
# is how that is checked.
# =============================================================================
source $::env(PD_SCRIPTS)/pd_common.tcl

pd_read_libs
read_db $::env(ODB)
read_sdc $::env(SDC)
pd_rc
estimate_parasitics -placement
set_propagated_clock [all_clocks]

puts "=== clock latency (insertion delay) to sinks, per clock"
foreach c {aon_clk hclk pclk clk_t2 tck} {
    if {[llength [get_clocks -quiet $c]] == 0} continue
    puts "-- $c"
    report_clock_latency -clock $c -digits 0
}
puts "=== clock skew"
report_clock_skew -setup -digits 0
report_clock_skew -hold -digits 0
puts "=== worst hold, clock path expanded"
report_checks -path_delay min -format full_clock_expanded -digits 0
puts "=== hold violators by group"
report_checks -path_delay min -group_path_count 1 -format end -slack_max 0
puts "=== worst setup by group"
report_checks -path_delay max -group_path_count 1 -format end
report_worst_slack -min
report_worst_slack -max
report_tns
puts "=== DONE"
