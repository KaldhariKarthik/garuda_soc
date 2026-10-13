# GARUDA / ASAP7 EXPLORATORY macro placement: all six memory macros in one row
# along the bottom of the core, pins (right edge, M4) facing a channel of at
# least $gap um, standard cells above.
#
# ON-GRID ORIGINS (BUGS PD-8). Each mock block's pins sit on the block's own
# routing tracks, and ASAP7's track grid is anchored at the die origin with the
# same pitches in parent and block (platforms/asap7/openRoad/make_tracks.tcl:
# M4/M5 0.048 um, M1-M4 verticals 0.036 um). A macro therefore keeps its pins on
# the parent's tracks only if its origin is on those pitches:
#   x: multiple of 0.432 um (lcm 0.036, 0.048, 0.054 site)
#   y: multiple of 2.16 um  (lcm 0.036, 0.048, 0.27 row)
# The first placement (y = 7.02, x on the 0.054 site) put every pin 0.012 um off
# track (DRT-0419) and made addr[0] unreachable (DRT-0073).
# Macros are found by MASTER name (instance names contain escaped [n]).
set gap   [expr {[info exists ::env(GARUDA_MACRO_GAP)] ? $::env(GARUDA_MACRO_GAP) : 4.0}]
set xg 0.432
set yg 2.16
proc snapup {v g} { return [expr {round(ceil($v / $g - 1e-9) * $g * 1000.0) / 1000.0}] }
set block [ord::get_db_block]
set dbu [$block getDefUnits]
set core [$block getCoreArea]
set core_xmax [expr {[$core xMax] / double($dbu)}]
set order {}
foreach master {garuda_sram_16384x32 garuda_sram_4096x32 garuda_rom_1024x32} {
  set found {}
  foreach inst [$block getInsts] {
    if {[[$inst getMaster] getName] eq $master} { lappend found [list [$inst getName] $inst] }
  }
  if {[llength $found] == 0} { utl::error FLW 9001 "macro_place.tcl: no instance of $master" }
  foreach pair [lsort -index 0 $found] { lappend order [lindex $pair 1] }
}
if {[llength $order] != 6} { utl::error FLW 9002 "macro_place.tcl: expected 6 macros, found [llength $order]" }
set x [snapup 5.4 $xg]
set y [snapup 7.0 $yg]
foreach inst $order {
  set name [$inst getName]
  set w [expr {[[$inst getMaster] getWidth] / double($dbu)}]
  $inst setOrient R0
  $inst setLocation [expr {round($x * $dbu)}] [expr {round($y * $dbu)}]
  $inst setPlacementStatus FIRM
  puts "macro_place: [[$inst getMaster] getName] $name at ($x, $y) width $w"
  set xr [expr {$x + $w}]
  set x [snapup [expr {$xr + $gap}] $xg]
}
if {$xr + $gap > $core_xmax} {
  utl::error FLW 9003 "macro_place.tcl: last macro ends at $xr um; no $gap um pin channel before core edge $core_xmax um (enlarge DIE_AREA/CORE_AREA)"
}
