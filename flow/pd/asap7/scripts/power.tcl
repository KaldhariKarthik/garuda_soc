# =============================================================================
# power.tcl -- power of the routed design with switching activity from RTL
# simulation (PD-14). env: ODB, SPEF, SDC, PWR_LIBS (one corner's libraries),
# ACT_TCL (from saif_to_activity.py, or "none" for OpenSTA's default activity)
# Prints the power report twice: default activity, then simulated activity, and
# how many nets of the netlist the simulation annotated.
# =============================================================================
foreach l $::env(PWR_LIBS) { read_liberty $l }
read_db $::env(ODB)
read_sdc $::env(SDC)
set_propagated_clock [all_clocks]
read_spef $::env(SPEF)

puts "=== power, default activity (OpenSTA: 0.1 toggles per clock period on inputs, propagated)"
report_power

# Matching (PD-14). Synthesis renames almost every internal net, but a flop
# keeps its RTL register name: u_soc...fetch_pc_o[2]$_DFFE_PN0P_. So a simulated
# register bit is matched to the flop whose name starts with it, and the flop's
# output pin gets the activity (ASAP7 flops have QN only: duty is inverted). A
# name that is a net of the netlist (ports, a few kept nets) is matched to the
# net's driver. Anything toggling more than once per hclk period (density above
# 2.6e-4 per ps) is a clock or a refclk-domain net and is left to the clock
# definitions. OpenSTA propagates the annotated activity into the logic between.
set ::pd_found 0
set ::pd_flops 0
set ::pd_missing 0
set ::pd_fast 0
array set ::pd_flop {}
foreach i [[ord::get_db_block] getInsts] {
    # flops only: repair buffers are named after the flop they serve (..._DFFE_PN0P__3715)
    if {![string match "DFF*" [[$i getMaster] getName]]} { continue }
    set nm [string map [list \\ {}] [$i getName]]
    set k [string first {$_} $nm]
    if {$k > 0} { set ::pd_flop([string range $nm 0 [expr {$k - 1}]]) [$i getName] }
}
proc pd_activity {net density duty} {
    if {$density > 2.6e-4} { incr ::pd_fast; return }
    if {[info exists ::pd_flop($net)]} {
        set c [get_cells -quiet $::pd_flop($net)]
        set q [get_pins -quiet -of_objects $c -filter "direction == output"]
        if {[llength $q]} {
            set_power_activity -pins $q -density $density -duty [expr {1.0 - $duty}]
            incr ::pd_flops; incr ::pd_found; return
        }
    }
    set n [get_nets -quiet [list $net]]
    if {[llength $n] == 0} { incr ::pd_missing; return }
    set drv [get_pins -quiet -of_objects $n -filter "direction == output"]
    if {[llength $drv] == 0} { incr ::pd_missing; return }
    set_power_activity -pins $drv -density $density -duty $duty
    incr ::pd_found
}
if {$::env(ACT_TCL) ne "none"} {
    source $::env(ACT_TCL)
    set total [llength [get_nets *]]
    set nflops [llength [array names ::pd_flop]]
    puts "=== annotation: $::pd_found matched ($::pd_flops flops of $nflops in the netlist), $::pd_missing not in the netlist, $::pd_fast skipped as clock-rate; netlist nets $total"
    puts "=== power, simulated activity ($::env(ACT_TCL))"
    report_power
    report_power -instances [get_cells -hierarchical *u_macro*]
}
puts "=== POWER DONE"
