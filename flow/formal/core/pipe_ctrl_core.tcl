# =============================================================================
# JasperGold: the pipe_ctrl properties (CORE [N-11.3]) on the WHOLE core.
#
# What SymbiYosys could not answer on pipe_ctrl alone (Docs/BUGS.md FV-2, AUD-8):
#   - a_no_gate_with_flush is a property of the core, not of pipe_ctrl: each of
#     its disjuncts fails when pipe_ctrl's inputs are free;
#   - whether the four hold-against-flush cells (c_h1_vs_redirect,
#     c_h2_vs_redirect, c_h4_vs_redirect, c_h5_vs_trap) can be reached inside
#     the core, or are dead by construction.
#
# From the repository root:
#   GARUDA_FV_ENV=<free|ahb> GARUDA_FV_DSU=<0|1> \
#   jg -allow_unsupported_OS -fpv -batch -no_jges -proj sim/jg_core/jgproject flow/formal/core/pipe_ctrl_core.tcl
#   (defaults: ahb, 0; GARUDA_FV_LIMIT sets the time limit, default 20m)
#
# Environment. The core with the inert DSU stub or the real DSU, pipe_ctrl_sva bound at
# garuda_core_top on the ungated clock. Interrupt inputs and bus read data are
# free. The two AHB slaves are either free ("free": any HREADY and HRESP in any
# cycle, which no AHB-Lite slave may do) or held to the AHB-Lite response rules
# ("ahb": the assumptions in ahb_slave_env.sv).
# =============================================================================
set env_mode ahb
if {[info exists ::env(GARUDA_FV_ENV)]} { set env_mode $::env(GARUDA_FV_ENV) }
set limit 20m
if {[info exists ::env(GARUDA_FV_LIMIT)]} { set limit $::env(GARUDA_FV_LIMIT) }

# the same file lists the simulators read: the core with the inert DSU stub, or
# with the real DSU (GARUDA_FV_DSU=1), which the H4 cells need
set fl rtl/core/filelist_core.f
if {[info exists ::env(GARUDA_FV_DSU)] && $::env(GARUDA_FV_DSU)} { set fl rtl/core/filelist_core_dsu.f }
# (JasperGold puts its own libraries on LD_LIBRARY_PATH, which the system python cannot load)
set incs {}
foreach d [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $fl --incdirs] { lappend incs "+incdir+[string range $d 2 end]" }
set srcs [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $fl]
analyze -sv09 {*}$incs {*}$srcs
if {$env_mode eq "ahb"} { analyze -sv09 flow/formal/core/ahb_slave_env.sv }
elaborate -top garuda_core_top

clock clk_i
# both resets low together for the reset sequence, then released for good
reset -expression {!core_rst_n_i} {!hartreset_n_i}

set_prove_time_limit $limit
prove -all

puts "==== RESULT ($env_mode environment, file list $fl) ===="
foreach p [get_property_list] {
    puts [format "%-10s %-14s %s" [get_property_info $p -list type] [get_property_info $p -list status] $p]
}
puts "==== END ===="
exit
