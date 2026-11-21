# =============================================================================
# hclk_spread.tcl -- arrival of hclk and aon_clk at every register clock pin
# (PD-15). env: ODB, LIB_FILES, PD_SDC_DIR, PLATFORM_DIR; SPEF optional (else
# placement parasitics). Prints one line:
#   SPREAD hclk_sinks N hclk_min .. hclk_max .. hclk_spread .. aon_min .. aon_max ..
# pnr_r8/r9: the core behind the ICG arrives ~300 ps after the ungated sinks.
# =============================================================================
foreach l $::env(LIB_FILES) { read_liberty $l }
read_db $::env(ODB)
if {[info exists ::env(SDC)] && $::env(SDC) ne ""} { read_sdc $::env(SDC) } else { read_sdc $::env(PD_SDC_DIR)/garuda_div2.sdc }
set_propagated_clock [all_clocks]
source $::env(PLATFORM_DIR)/setRC.tcl
if {[info exists ::env(SPEF)] && $::env(SPEF) ne "" && $::env(SPEF) ne "none"} { read_spef $::env(SPEF) } else { estimate_parasitics -placement }
set h {}; set a {}
foreach p [get_pins -hierarchical */CLK] {
  set cn {}; foreach c [get_property $p clocks] { lappend cn [get_name $c] }
  set t [get_property $p arrival_max_rise]
  if {[lsearch $cn hclk] >= 0} { lappend h $t } elseif {[lsearch $cn aon_clk] >= 0} { lappend a $t }
}
set hmin [tcl::mathfunc::min {*}$h]; set hmax [tcl::mathfunc::max {*}$h]
set amax [tcl::mathfunc::max {*}$a]; set amin [tcl::mathfunc::min {*}$a]
puts [format "SPREAD hclk_sinks %d hclk_min %.1f hclk_max %.1f hclk_spread %.1f aon_min %.1f aon_max %.1f" [llength $h] $hmin $hmax [expr {$hmax-$hmin}] $amin $amax]
exit
