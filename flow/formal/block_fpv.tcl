# =============================================================================
# block_fpv.tcl - prove the bound properties of one block in JasperGold.
#
# Settings from the environment, so this file is never edited:
#   TOP    the module                         garuda_pwm_top
#   FL     its RTL file list                  rtl/pwm/filelist.f
#   CLKS   its clock(s), first is the base    "pclk_i"   or "hclk_i pclk_i:2"  (name:factor)
#   RSTS   its active-low reset port(s)       "preset_n_i"  or "hreset_n_i preset_n_i"
#   PROPS  where the status list goes         sim/formal_<TOP>/props.txt
#   DEFS   extra +define+ names               "FORMAL"
#   PARAMS extra elaborate options            "-parameter NCH 4"
#   TRACE  property names: save their counterexamples as VCD and stop
#   APB    the APB clock, when the block has a standard APB slave port (see below)
#
#   TOP=garuda_pwm_top FL=rtl/pwm/filelist.f CLKS=pclk_i RSTS=preset_n_i \
#     /home/install/JASPER/bin/jg -allow_unsupported_OS -fpv -batch -no_jges \
#     -proj sim/formal_pwm/jgproject flow/formal/block_fpv.tcl
#
# Everything not a clock or a reset is a free input: the properties' own assume_*
# say what the surroundings must do.
# =============================================================================
set TOP $::env(TOP); set FL $::env(FL); set CLKS $::env(CLKS); set RSTS $::env(RSTS)
set PROPS sim/formal_$TOP/props.txt
if {[info exists ::env(PROPS)]} { set PROPS $::env(PROPS) }
set DEFS {}
if {[info exists ::env(DEFS)]} { foreach d $::env(DEFS) { lappend DEFS +define+$d } }
set PARAMS {}
if {[info exists ::env(PARAMS)]} { set PARAMS $::env(PARAMS) }

set FILES [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $FL]] "\n"]
set INCS {}
foreach d [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $FL --incdirs]] " "] {
    if {$d ne ""} { lappend INCS +incdir+[string range $d 2 end] }
}
analyze -sv09 {*}$DEFS +incdir+rtl/include +incdir+rtl/common {*}$INCS {*}$FILES
elaborate -top $TOP {*}$PARAMS

# COMB=1: a combinational unit, no clock and no reset
if {[info exists ::env(COMB)]} {
    clock -none
    reset -none
    set CLKS {}
}
foreach c $CLKS {
    set p [split $c :]
    if {[llength $p] == 1} { clock [lindex $p 0] } else { clock [lindex $p 0] -factor [lindex $p 1] -phase 1 }
}
if {![info exists ::env(COMB)]} {
    set r {}
    foreach x $RSTS { lappend r "!$x" }
    reset -expression {*}$r
}

# APB=<clock>: the block has an APB slave port with the standard names (psel_i, penable_i, pwrite_i,
# paddr_i, pwdata_i); the free master is held to APB3: SETUP first, then one ACCESS cycle with the
# address, direction and data unchanged (these blocks never stall, PREADY is high).
if {[info exists ::env(APB)]} {
    set k $::env(APB); set r [lindex $RSTS end]
    # the bridge drives APB on pclk: the inputs change only at pclk edges
    clock -rate {psel_i penable_i pwrite_i paddr_i pwdata_i} $k
    assume -name assume_apb_setup_first "@(posedge $k) disable iff (!$r) \$rose(psel_i) |-> !penable_i"
    assume -name assume_apb_access_next "@(posedge $k) disable iff (!$r) (psel_i && !penable_i) |=> (psel_i && penable_i && \$stable(paddr_i) && \$stable(pwrite_i) && \$stable(pwdata_i))"
    assume -name assume_apb_one_access  "@(posedge $k) disable iff (!$r) (psel_i && penable_i) |=> !penable_i"
    assume -name assume_apb_enable_sel  "@(posedge $k) disable iff (!$r) penable_i |-> psel_i"
    # no transfer while any reset is asserted (the bridge and the peripheral leave reset together)
    set busrst $RSTS
    # APBRST: further active-low resets that hold the bus, e.g. reset_ctrl's own preset_n_o
    if {[info exists ::env(APBRST)]} { set busrst [concat $busrst $::env(APBRST)] }
    set anyrst [join [lmap x $busrst {set x "!$x"}] " || "]
    assume -name assume_apb_not_in_reset "@(posedge $k) ($anyrst) |-> !psel_i"
    # ACCESS only in the pclk cycle right after a SETUP (also at the first edge after reset)
    assume -name assume_apb_access_after_setup "@(posedge $k) penable_i |-> \$past(psel_i && !penable_i)"
}
# ASSUMES: extra assumptions of the surroundings, one SVA expression per line, clocked on the base clock
# ASSUMES_FILE: the same, read from a file (one expression per line)
if {[info exists ::env(ASSUMES_FILE)]} {
    set fh [open $::env(ASSUMES_FILE)]; set ::env(ASSUMES) [read $fh]; close $fh
}
if {[info exists ::env(ASSUMES)]} {
    set k [lindex [split [lindex $CLKS 0] :] 0]; set i 0
    foreach a [split $::env(ASSUMES) "\n"] {
        if {[string trim $a] eq ""} continue
        assume -name assume_env_[incr i] "@(posedge $k) $a"
    }
}
# TRACE="a_x a_y": prove only those, save each counterexample as sim/formal_<TOP>/<name>.vcd, stop
if {[info exists ::env(TRACE)]} {
    foreach p $::env(TRACE) {
        set full [lindex [get_property_list -include [list name "*$p"]] 0]
        prove -property $full
        visualize -violation -property $full -batch
        visualize -save -vcd sim/formal_$TOP/$p.vcd -force
    }
    exit
}
prove -all -time_limit 900s
report -summary
source flow/formal/common.tcl
file mkdir [file dirname $PROPS]
list_props $PROPS
exit
