# =============================================================================
# JasperGold cross-check of RDC-1 (the formal proof of record is SymbiYosys:
# tb/core/formal/rdc1.toml, make -f flow/mk/track_a_run.mk fv_core_rdc1).
# The harness tb/core/formal/rdc1_top.sv (core + the real Debug Module + the
# reset_ctrl core_rst_sync of D-36), with the clock gate replaced by a pass-through
# as in the SBY run; no multiplier blackboxed (TOOL-A21).
# From the repository root, with the Cadence environment:
#   jg -allow_unsupported_OS -fpv -batch -no_jges -proj sim/jg_rdc1/jgproject flow/formal/core/rdc1_jg.tcl
# Prints one CEX: line per counterexample; the result is in rdc1_jg.result.txt.
# =============================================================================
set fl tb/core/formal/filelist_rdc1_fv.f
set incs {}
foreach d [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $fl --incdirs] { lappend incs "+incdir+[string range $d 2 end]" }
set srcs {}
foreach s [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $fl] {
    if {[string match *rtl/core/core_clk_gate.v $s]} { set s tb/core/formal/core_clk_gate_passthru.sv }
    lappend srcs $s
}
analyze -sv09 +define+FORMAL {*}$incs {*}$srcs
elaborate -top rdc1_top -bbox_mul 128
clock clk
reset -expression {!rst_n}
set_prove_time_limit 3600
prove -all
report -summary
foreach p [get_property_list -include {status {cex}}] { puts "CEX: $p [get_property_info $p -list trace_length]" }
exit
