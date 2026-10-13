# =============================================================================
# JasperGold property app: the waivers that say "this property can never trigger
# here" or "this cover can never happen here" (the -assertion lines of
# flow/cov/<blk>_exclusions.tcl), proven. Second half of plan task 4.4.
#
# Run through flow/formal/unr_block.sh <block>, which sets
#   GARUDA_UNR_FL, GARUDA_UNR_TOP, GARUDA_UNR_CLK, GARUDA_UNR_RST   as in unr_block.tcl
#   GARUDA_UNR_WAIVERS   the exclusions file
#
# For an assertion the question is its precondition (JasperGold's own cover
# "<name>:precondition1"); for a cover, the cover itself. "unreachable" confirms
# the waiver, "covered" says the waiver is wrong. Every input is free.
# =============================================================================
set fl   $::env(GARUDA_UNR_FL)
set top  $::env(GARUDA_UNR_TOP)
set incs {}
foreach d [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $fl --incdirs] { lappend incs "+incdir+[string range $d 2 end]" }
analyze -sv09 {*}$incs {*}[exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $fl]
elaborate -top $top
foreach c $::env(GARUDA_UNR_CLK) {
    lassign [split $c :] name factor
    clock $name -factor $factor -phase 1
}
set rexp {}
foreach r $::env(GARUDA_UNR_RST) { lappend rexp "!$r" }
reset -expression {*}$rexp
set_prove_time_limit 5m

set f [open $::env(GARUDA_UNR_WAIVERS)]
while {[gets $f line] >= 0} {
    if {![regexp {^exclude -inst (\S+) -assertion (\S+)} $line -> inst name]} continue
    regsub -all {\\} $inst {} inst
    set prop "$inst.$name"
    if {[string match c_* $name]} { set q $prop } else { set q "$prop:precondition1" }
    if {[catch {prove -property [list $q]} msg]} {
        puts "VAC|$inst|$name|not found|$q|[lindex [split $msg \n] 0]"
        continue
    }
    puts "VAC|$inst|$name|[get_property_info $q -list status]|$q"
}
close $f
puts "==== END ===="
exit
