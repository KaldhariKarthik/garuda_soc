# =============================================================================
# validate.tcl -- physical-design checks of the routed database (PD task 5):
# clock-tree quality per clock, slew/capacitance/fanout limits, clock cells.
# env: ODB, SPEF, SDC, VAL_LIBS (one corner), CORNER
# Signal integrity (crosstalk delay and noise) is NOT analysed: OpenROAD/OpenSTA
# have no coupling-capacitance timing. That needs a commercial SI engine.
# =============================================================================
foreach l $::env(VAL_LIBS) { read_liberty $l }
read_db $::env(ODB)
read_sdc $::env(SDC)
set_propagated_clock [all_clocks]
read_spef $::env(SPEF)
puts "=== corner $::env(CORNER)"
puts "=== clock latency (insertion delay) min/max to the sinks of each clock"
foreach c [get_clocks *] {
    set n [get_name $c]
    puts "-- $n"
    report_clock_latency -clock $n -digits 1
}
puts "=== clock skew"
report_clock_skew -setup -digits 1
report_clock_skew -hold -digits 1
puts "=== limit checks (max slew, max capacitance, max fanout): violators"
report_check_types -max_slew -max_capacitance -max_fanout -violators -digits 1
puts "=== limit summary"
puts "max_slew_violations [sta::max_slew_violation_count]"
puts "max_cap_violations [sta::max_capacitance_violation_count]"
puts "max_fanout_violations [sta::max_fanout_violation_count]"
puts "=== clock tree cells"
set cb 0; set ci 0
foreach i [get_cells *] {
    set m [get_property $i ref_name]
    if {[string match "clkbuf*" [get_name $i]] || [string match "*clkbuf*" [get_name $i]]} { incr cb }
    if {[string match "ICG*" $m]} { incr ci }
}
puts "clock_buffer_instances $cb"
puts "icg_instances $ci"
puts "=== VALIDATE DONE"
