# =============================================================================
# pd_common.tcl -- procedures the GARUDA ASAP7 analysis steps share.
# Sourced by the step scripts; reads the environment pd_env.sh exports.
# =============================================================================

# Every liberty the flow used: the standard cells and the hardened mock
# memories (ADDITIONAL_LIBS). ORFS already appends ADDITIONAL_LIBS to
# LIB_FILES, so each file is kept once, in order (a second read is
# STA-1140, "library already exists").
proc pd_libs {} {
    set out {}
    foreach l [concat $::env(LIB_FILES) $::env(ADDITIONAL_LIBS)] {
        if {[lsearch -exact $out $l] < 0} { lappend out $l }
    }
    return $out
}

proc pd_read_libs {} {
    if {[pd_corners] ne ""} {
        foreach c [pd_corners] { foreach l [pd_corner_libs $c] { read_liberty $l } }
        return
    }
    foreach l [pd_libs] { read_liberty $l }
}

# Multi-corner (PD-13): PD_CORNERS, e.g. "WC TC BC"; empty = one corner, as before.
proc pd_corners {} {
    if {[info exists ::env(PD_CORNERS)]} { return $::env(PD_CORNERS) }
    return ""
}
proc pd_corner_libs {c} {
    return $::env(PD_LIBS_$c)
}

# The DIVSEL scenarios this run checks, e.g. {div2 div4 div8 div16}.
proc pd_modes {} {
    return $::env(PD_MODES)
}

proc pd_sdc {mode} {
    return $::env(PD_SDC_DIR)/garuda_$mode.sdc
}

# One STA mode and one scene per DIVSEL scenario, all on the same libraries.
# The clocks are propagated: every caller runs after CTS.
proc pd_define_scenes {} {
    set libs [pd_libs]
    if {[pd_corners] eq ""} {
        foreach m [pd_modes] {
            read_sdc -mode $m [pd_sdc $m]
            set_mode $m
            set_propagated_clock [all_clocks]
        }
    }
    if {[pd_corners] eq ""} {
        foreach m [pd_modes] { define_scene $m -mode $m -liberty $libs }
    } else {
        # PD_SCENES (optional): only these <mode>_<corner> scenes, to bound the
        # memory of the repair (PD-13: 4 scenes of two corners took 8 GiB).
        set only {}
        if {[info exists ::env(PD_SCENES)]} { set only $::env(PD_SCENES) }
        foreach m [pd_modes] {
            foreach c [pd_corners] {
                if {$only ne "" && [lsearch -exact $only ${m}_$c] < 0} { continue }
                # One mode PER SCENE (PD-13): two scenes that shared a mode across
                # corners gave wrong slacks (div2_WC hold -320 ps where one scene
                # alone gives +0.31; div2_BC -567 against -69).
                read_sdc -mode ${m}_$c [pd_sdc $m]
                set_mode ${m}_$c
                set_propagated_clock [all_clocks]
                define_scene ${m}_$c -mode ${m}_$c -liberty [pd_corner_libs $c]
            }
        }
    }
}

proc pd_rc {} {
    source $::env(PLATFORM_DIR)/setRC.tcl
}

# Worst slack and total negative slack, setup and hold, one line per scene.
# A scene is named after its mode (pd_define_scenes).
proc pd_scene_summary {tag} {
    puts "=== $tag"
    puts [format "%-10s %12s %12s %12s %12s" scene setup_wns setup_tns hold_wns hold_tns]
    foreach s [sta::scenes] {
        set n [sta::scene_property $s name]
        puts [format "%-10s %12s %12s %12s %12s" $n \
            [sta::format_time [sta::worst_slack_scene $s max] 2] \
            [sta::format_time [sta::total_negative_slack_scene_cmd $s max] 2] \
            [sta::format_time [sta::worst_slack_scene $s min] 2] \
            [sta::format_time [sta::total_negative_slack_scene_cmd $s min] 2]]
    }
    report_worst_slack -max
    report_worst_slack -min
    report_tns -max
    report_tns -min
}

# The same numbers for a single-mode analysis, as "key value" lines that
# qor.py and the run summaries parse.
proc pd_summary_lines {} {
    puts "setup_wns [sta::format_time [sta::worst_slack_cmd max] 2]"
    puts "setup_tns [sta::format_time [sta::total_negative_slack_cmd max] 2]"
    puts "hold_wns [sta::format_time [sta::worst_slack_cmd min] 2]"
    puts "hold_tns [sta::format_time [sta::total_negative_slack_cmd min] 2]"
    puts "setup_viol_endpoints [sta::endpoint_violation_count max]"
    puts "hold_viol_endpoints [sta::endpoint_violation_count min]"
}
