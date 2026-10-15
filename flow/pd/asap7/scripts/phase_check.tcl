# =============================================================================
# phase_check.tcl -- are the STA launch and capture edges the physical ones?
#
# env (run_phase.sh): ODB, SDC, MODE, LIB_FILES, ADDITIONAL_LIBS, PLATFORM_DIR.
#
# aon_clk, hclk, pclk and t2..t4 all come from refclk through the divider
# flops, so they are synchronous and timed against each other ([N-5.6],
# [N-5.7]). A plain -divide_by on an inverted-output pin once put them half a
# period out of phase and made hold optimistic (BUGS PD-6); the SDCs now give
# every derived clock its edges explicitly. This report shows, for every
# crossing between those clocks, which edges STA pairs: the reader checks them
# against the divider waveforms (GARUDA-CLKRST-SPEC-001 §7).
#
# Ideal clocks: this is a constraint check, not a timing check, so it runs on
# any stage's database, including 1_synth.odb.
# =============================================================================
source $::env(PD_SCRIPTS)/pd_common.tcl

pd_read_libs
read_db $::env(ODB)
read_sdc $::env(SDC)
puts "=== SDC $::env(SDC)"
report_clock_properties

foreach {lbl a b} {
    "hclk->aon"  hclk    aon_clk
    "aon->hclk"  aon_clk hclk
    "hclk->pclk" hclk    pclk
    "pclk->hclk" pclk    hclk
    "aon->pclk"  aon_clk pclk
    "pclk->aon"  pclk    aon_clk
} {
    puts "=== $lbl SETUP"
    report_checks -from [get_clocks $a] -to [get_clocks $b] -path_delay max -digits 0
    puts "=== $lbl HOLD"
    report_checks -from [get_clocks $a] -to [get_clocks $b] -path_delay min -digits 0
}

# The DIVSEL request -> active handshake inside clk_div, and the core's clock
# gate enable. The flop and cell names are Yosys's (synth_r2); a missing pin
# is reported, not an error.
puts "=== sel_req_q -> sel_act_q SETUP"
set p [get_pins -hierarchical -quiet {u_clk_div.sel_act_q*/D}]
if {[llength $p]} { report_checks -to $p -path_delay max -digits 0 } else { puts "no u_clk_div.sel_act_q*/D pin" }

puts "=== ICG SETUP"
set icg [get_cells -hierarchical -quiet *u_icg*]
set ena {}
foreach c $icg { foreach q [get_pins -quiet -of_objects $c -filter "direction == input"] {
    if {[string match *ENA [get_full_name $q]] || [string match *GATE [get_full_name $q]]} { lappend ena $q }
} }
if {[llength $ena]} { report_checks -to $ena -path_delay max -digits 0 } else { puts "no ICG enable pin found under *u_icg*" }
puts "=== DONE $::env(MODE)"
