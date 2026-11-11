# core_g5_merge.tcl -- merge every passing core run of flow/regress/garuda.vsif and
# report core coverage by module type (1-TOPS G5 5.8, 5.9; flow/4_core/core_g5.md).
#
#   imc -exec flow/cov/core_g5_merge.tcl      (after every run of flow/cov/core_g5_runs.txt, flow/regress/run_test.sh <test>)
#
# Type-based: a module's numbers are the union over every bench that instantiates
# it (the core inside tb_boot and tb_core_halt, the units and smokes on their own),
# so a unit bench's corner cases count for the core.
# flow/cov/core_g5_runs.txt: every core test of garuda.vsif (units, smokes, DSU, ISA,
# sanity, core programs, riscv-dv), t_dsu_macsat_rd left out (DSU-15 xfail).
# Raw numbers first, then with the written waivers of tb/core/cov/core_waivers.toml applied per module type
# (flow/cov/core_exclusions_type.tcl, python3.12 tools/cov/gen_imc_exclusions.py core --type).
merge -runfile flow/cov/core_g5_runs.txt -out sim/cov_g5/merged -overwrite -initial_model union_all -message 1
load -run sim/cov_g5/merged
report -summary -type -metrics block:expression:toggle:fsm -out sim/cov_g5/type_raw.txt
report -detail -metrics covergroup -out sim/cov_g5/func_cov.txt
report -summary -metrics covergroup -out sim/cov_g5/func_sum.txt
set f [open flow/cov/core_exclusions_type.tcl r]
set n 0; set bad 0
foreach line [split [read $f] "\n"] {
    if {[string match {exclude *} $line]} {
        if {[catch {eval $line} err]} { incr bad; puts "NOT APPLIED: $line -- $err" } else { incr n }
    }
}
close $f
puts "exclusions applied: $n, not applied: $bad"
# The line waivers of core_waivers.toml that the generator leaves "TO COMPLETE IN IMC",
# with IMC's block numbers (report -detail -metrics block, 2026-11-11). If the RTL of
# these modules changes, check the numbers against that report again.
exclude -type decode_control -block 32 -comment "CW-006: default arm of case(funct3) at decode_control.v:216; the case lists all eight values, reached only by an X funct3"
exclude -type decode_control -block 47 -comment "CW-006: default arm of case(funct3) at decode_control.v:243; the case lists all eight values, reached only by an X funct3"
exclude -type d_port_ahb_master -block 13 -comment "CW-003: default arm of the D-port FSM at d_port_ahb_master.v:140; state is S_ADDR or S_DATA (PROVEN a_dport_state_legal)"
report -summary -type -metrics block:expression:toggle:fsm -out sim/cov_g5/type_waived.txt
report -detail -type -metrics block:expression:toggle -uncovered -out sim/cov_g5/type_holes.txt
exit
