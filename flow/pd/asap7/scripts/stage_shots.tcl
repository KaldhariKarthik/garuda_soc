# =============================================================================
# stage_shots.tcl -- one layout picture of a run at one stage (run in the GUI
# off-screen by run_stage_shots.sh). env: ODB, OUT (.png), VIEW:
#   floorplan  macros, rows, power grid, pins (2_floorplan.odb)
#   placement  standard cells, no routing (3_place.odb)
#   grt        estimated routing demand, RUDY heat map (5_1_grt.odb)
#   route      every routed net except power (6_final.odb)
# Modelled on ORFS's flow/scripts/save_images.tcl. For the clock tree use ORFS's own
# final_clocks and cts_<scene>_<clock>_layout pictures (reports/<run>/): this GUI
# does not hide the standard cells by subgroup, so a CTS-only view here shows every cell.
# =============================================================================
set height [ord::dbu_to_microns [[[ord::get_db_block] getBBox] getDY]]
set resolution [expr {$height / 1000.0}]
gui::clear_highlights -1
gui::clear_selections
gui::fit
gui::set_display_controls "*" visible false
gui::set_display_controls "Layers/*" visible true
gui::set_display_controls "Instances/*" visible true
gui::set_display_controls "Shape Types/*" visible true
gui::set_display_controls "Misc/Scale bar" visible true
gui::set_display_controls "Misc/Detailed view" visible true
gui::set_display_controls "Misc/Instances/Pins" visible true
gui::set_display_controls "Misc/Instances/Blockages" visible true
switch $::env(VIEW) {
    floorplan {
        gui::set_display_controls "Nets/*" visible true
        gui::set_display_controls "Instances/StdCells/*" visible false
        gui::set_display_controls "Instances/Physical/*" visible true
        gui::set_display_controls "Misc/Instances/Names" visible true
    }
    placement {
        gui::set_display_controls "Nets/*" visible false
        gui::set_display_controls "Shape Types/Routing/*" visible false
        gui::set_display_controls "Instances/Physical/*" visible false
    }
    grt {
        gui::set_display_controls "Nets/*" visible false
        gui::set_display_controls "Instances/Physical/*" visible false
        gui::set_display_controls "Heat Maps/Estimated Congestion (RUDY)" visible true
    }
    route {
        gui::set_display_controls "Nets/*" visible true
        gui::set_display_controls "Nets/Power" visible false
        gui::set_display_controls "Nets/Ground" visible false
        gui::set_display_controls "Instances/Physical/Fill cell" visible false
    }
    default { error "stage_shots.tcl: unknown VIEW $::env(VIEW)" }
}
save_image -resolution $resolution $::env(OUT)
puts "stage_shots: wrote $::env(OUT)"
