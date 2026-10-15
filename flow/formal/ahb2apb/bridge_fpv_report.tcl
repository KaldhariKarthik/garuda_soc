# reads the session of bridge_fpv.tcl and lists every property with its status
set F [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py rtl/ahb2apb/filelist.f]] "\n"]
analyze -sv09 +incdir+rtl/include {*}$F
elaborate -top ahb2apb_bridge
clock hclk_i
clock pclk_i -factor 2 -phase 1
reset -expression {!hreset_n_i} {!preset_n_i}
assume {pclk_phase_i == 1'b0}
prove -all -time_limit 300s
foreach p [get_property_list -include {type {assert cover}}] {
    puts [format "%-9s %-12s %s" [get_property_info $p -list status] [get_property_info $p -list type] $p]
}
exit
