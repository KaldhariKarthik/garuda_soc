# =============================================================================
# cov_g5_unr.tcl -- JasperGold: three core functional-coverage bins that cannot be
# reached, proven on the WHOLE core (1-TOPS G5 5.8; flow/4_core/core_g5.md).
#
#   jg -allow_unsupported_OS -fpv -batch -no_jges -proj sim/jg_cov_g5/jgproject flow/formal/core/cov_g5_unr.tcl
#
# Same environment as pipe_ctrl_core.tcl: the core with the inert DSU stub, the two
# AHB slaves held to the AHB-Lite response rules (ahb_slave_env.sv), interrupt
# inputs and bus read data free. Each assertion is the reason one bin is an
# ignore_bins; each cover shows the antecedent does happen (the assertion is not
# vacuous).
#   a_wake_needs_cond     garuda_core_cov_ext cg_sleep cp_woken_by "other": the core
#                         leaves the quiescent state only on a CLIC wake or a pending
#                         enabled timer interrupt (trap_ctrl.v wfi_hold_o). NOT proven:
#                         JasperGold gives a trace through the debug fetch stop in
#                         which the I-port still gets a gated-clock edge after the gate
#                         closed; cov_g5_unr.result.txt and flow/4_core/core_g5.md
#   a_no_exmem_fwd_stall  garuda_cov cg_hazard x_fwd_under_stall {exmem, stall}: EX/MEM
#                         is never a forwarding source while MEM waits on the D-port
#                         (a waiting EX/MEM holds a load or store; a store writes no
#                         register, a load's consumer is split off by the load-use bubble)
#   a_int_needs_ex_instr  garuda_cov_vplan cg_irq x_insn_class "bubble": an interrupt is
#                         taken only with a real instruction in EX (trap_ctrl.v
#                         take_int / take_mti & idex_valid_i, ERRATUM T-4)
# =============================================================================
set fl rtl/core/filelist_core.f
set incs {}
foreach d [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $fl --incdirs] { lappend incs "+incdir+[string range $d 2 end]" }
set srcs [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $fl]
analyze -sv09 {*}$incs {*}$srcs
analyze -sv09 flow/formal/core/ahb_slave_env.sv
elaborate -top garuda_core_top

clock clk_i
reset -expression {!core_rst_n_i} {!hartreset_n_i}

assert -name a_wake_needs_cond    {$fell(quiescent) |-> (clic_wake_cond | csr_mti_pending)}
assert -name a_no_exmem_fwd_stall {mem_stall |-> (fwd_a_sel != 2'b01)}
assert -name a_int_needs_ex_instr {(tr_enter & tr_is_int) |-> xe_valid}
cover  -name c_wake               {$fell(quiescent)}
cover  -name c_fwd_exmem          {fwd_a_sel == 2'b01}
cover  -name c_mem_stall          {mem_stall}
cover  -name c_int_taken          {tr_enter & tr_is_int}

set_prove_time_limit 20m
# only the properties of this file (the core's bound assertions have their own runs)
prove -property {a_wake_needs_cond a_no_exmem_fwd_stall a_int_needs_ex_instr c_wake c_fwd_exmem c_mem_stall c_int_taken}

puts "==== RESULT ===="
foreach p [get_property_list] {
    puts [format "%-10s %-14s %s" [get_property_info $p -list type] [get_property_info $p -list status] $p]
}
puts "==== END ===="
exit
