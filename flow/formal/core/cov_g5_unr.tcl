# =============================================================================
# cov_g5_unr.tcl -- JasperGold on the WHOLE core for three bins of the core functional
# covergroups (1-TOPS G5 5.8; flow/4_core/core_g5.md, section 4).
#
#   jg -allow_unsupported_OS -fpv -batch -no_jges -proj sim/jg_cov_g5/jgproject flow/formal/core/cov_g5_unr.tcl
#
# Same environment as pipe_ctrl_core.tcl: the core with the inert DSU stub, the two
# AHB slaves held to the AHB-Lite response rules (ahb_slave_env.sv), interrupt
# inputs, bus read data and the instruction stream free. Each assertion is the
# reason for one ignore_bins or the boundary of one bin; each cover shows the
# antecedent happens (the assertion is not vacuous) or the bin is reachable.
#   a_no_exmem_fwd_stall  garuda_cov cg_hazard x_fwd_under_stall {exmem, stall}: EX/MEM
#                         is never a forwarding source while MEM waits on the D-port
#                         (a waiting EX/MEM holds a load or store; a store writes no
#                         register, a load's consumer is split off by the load-use bubble)
#   a_int_needs_ex_instr  garuda_cov_vplan cg_irq x_insn_class "bubble": an interrupt is
#                         taken only with a real instruction in EX (trap_ctrl.v
#                         take_int / take_mti & idex_valid_i, ERRATUM T-4)
#   a_wake_needs_cond_cg  garuda_core_cov_ext cg_sleep cp_woken_by "other": with the clock
#                         gate in use (mgarudactl.CG_DIS = 0) the core leaves the quiescent
#                         state only on a CLIC wake or a pending enabled timer interrupt.
#   c_wake_other_cgdis    ... and with CG_DIS = 1 (the clock keeps running in WFI) it can
#                         leave it with neither, when the fetch port starts again: the bin
#                         is reachable, and t_cov_irq_ids part J reaches it.
#   (a_wake_needs_cond without the CG_DIS term fails, through that CG_DIS = 1 path; it
#   was the first form of this check, 2026-11-15.)
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

assert -name a_wake_needs_cond_cg {$fell(quiescent) |-> (clic_wake_cond | csr_mti_pending | csr_ctl[3])}
assert -name a_no_exmem_fwd_stall {mem_stall |-> (fwd_a_sel != 2'b01)}
assert -name a_int_needs_ex_instr {(tr_enter & tr_is_int) |-> xe_valid}
cover  -name c_wake               {$fell(quiescent)}
cover  -name c_fwd_exmem          {fwd_a_sel == 2'b01}
cover  -name c_mem_stall          {mem_stall}
cover  -name c_int_taken          {tr_enter & tr_is_int}
cover  -name c_wake_other_cgdis   {$fell(quiescent) & ~clic_wake_cond & ~csr_mti_pending}

set_prove_time_limit 20m
# only the properties of this file (the core's bound assertions have their own runs)
prove -property {a_wake_needs_cond_cg a_no_exmem_fwd_stall a_int_needs_ex_instr c_wake c_fwd_exmem c_mem_stall c_int_taken c_wake_other_cgdis}

puts "==== RESULT ===="
foreach p [get_property_list] {
    puts [format "%-10s %-14s %s" [get_property_info $p -list type] [get_property_info $p -list status] $p]
}
puts "==== END ===="
exit
