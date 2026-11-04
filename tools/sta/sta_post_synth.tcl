# sta_post_synth.tcl -- post-synthesis STA of garuda_chip_core on ASAP7 (Track A, 2026-11-01), run by
# tools/sta/synth_sta.sh inside the OpenROAD-flow-scripts container. FF corner (the corner ABC mapped
# to), ideal clocks, no wires: setup is meaningful, hold is for information (CTS fixes it).
# MODE = div2 | div4 | div8 | div16 (flow/constraints/asap7/garuda_<MODE>.sdc). With LOGIC_ONLY=1 the
# reset tree (reset_ctrl outputs: thousands of loads, unbuffered before placement) is excluded.
set libdir /OpenROAD-flow-scripts/flow/platforms/asap7/lib/NLDM
foreach f {asap7sc7p5t_AO_RVT_FF_nldm_211120.lib.gz asap7sc7p5t_INVBUF_RVT_FF_nldm_220122.lib.gz asap7sc7p5t_OA_RVT_FF_nldm_211120.lib.gz asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120.lib.gz asap7sc7p5t_SEQ_RVT_FF_nldm_220123.lib} {
    read_liberty $libdir/$f
}
read_lef /OpenROAD-flow-scripts/flow/platforms/asap7/lef/asap7_tech_1x_201209.lef
read_lef /OpenROAD-flow-scripts/flow/platforms/asap7/lef/asap7sc7p5t_28_R_1x_220121a.lef
read_verilog /work/1_2_nomacro.v
link_design garuda_chip_core
read_sdc /garuda/flow/constraints/asap7/garuda_$::env(MODE).sdc
if {[info exists ::env(LOGIC_ONLY)] && $::env(LOGIC_ONLY)} {
    set_false_path -from [get_cells u_reset_ctrl.*]
    set_false_path -from [get_ports ext_rst_n]
}
puts "=== MODE $::env(MODE)"
report_worst_slack -max -digits 1
report_tns -max -digits 1
report_worst_slack -min -digits 1
report_tns -min -digits 1
report_checks -path_delay max -group_path_count 1 -format end
report_checks -path_delay max -digits 1
report_checks -path_delay min -digits 1
report_checks -unconstrained -path_delay max -group_path_count 1 -format end
exit
