`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - core : properties of trap_ctrl, from GARUDA-CORE-SPEC-001 section 14
// and the errata it already fixed (T-1, T-4, T-9, T-13). Causes are the RISC-V
// literals. Bound to trap_ctrl; runs in every core run; proved by run_blocks.sh trap_ctrl.
// Not for synthesis, not under Icarus (TOOL-B2).
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module trap_ctrl_sva #(parameter ID_W = 5) (
    input wire clk_i, rst_n_i,
    input wire [31:0] idex_pc_i, idex_instr_i, ex_addr_i, ex_fetch_target_i, mem_exc_pc_i, mem_exc_tval_i,
    input wire idex_fault_i, idex_illegal_dec_i, idex_is_system_i, idex_valid_i,
    input wire ex_dsu_illegal_i, ex_csr_illegal_i, ex_load_misalign_i, ex_store_misalign_i, ex_fetch_misalign_i,
    input wire mem_stall_i, mem_exc_valid_i, input wire [3:0] mem_exc_cause_i,
    input wire clic_take_cond_i, input wire [ID_W-1:0] clic_irq_id_i, input wire [31:0] clic_vector_target_i,
    input wire mti_pending_i, mstatus_mie_i, input wire [31:0] mtvec_i, mepc_i,
    input wire trap_enter_o, is_interrupt_o, mret_o, trap_redirect_valid_o,
    input wire [31:0] trap_pc_o, trap_cause_o, trap_redirect_target_o
);
    wire ecall  = idex_is_system_i && idex_instr_i == 32'h0000_0073;
    wire ebreak = idex_is_system_i && idex_instr_i == 32'h0010_0073;
    wire mret   = idex_is_system_i && idex_instr_i == 32'h3020_0073;
    wire illegal = idex_illegal_dec_i || ex_dsu_illegal_i || ex_csr_illegal_i;
    wire any_ex = idex_fault_i || illegal || ex_fetch_misalign_i || ebreak || ex_load_misalign_i || ex_store_misalign_i || ecall;
    // CORE 14.1: 1 (instruction access fault) > 2 (illegal) > 0 (target misaligned, T-1) > 3 (EBREAK)
    //            > 4 (load misaligned) > 6 (store misaligned) > 11 (ECALL)
    wire [31:0] spec_cause = idex_fault_i ? 32'd1 : illegal ? 32'd2 : ex_fetch_misalign_i ? 32'd0 : ebreak ? 32'd3 :
                             ex_load_misalign_i ? 32'd4 : ex_store_misalign_i ? 32'd6 : 32'd11;

    // ---- exceptions ---------------------------------------------------------------------------
    a_trap_mem_first: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        mem_exc_valid_i |-> (trap_enter_o && !is_interrupt_o && trap_cause_o == {28'd0, mem_exc_cause_i} && trap_pc_o == mem_exc_pc_i) )
        else $error("[SVA-FAIL] a_trap_mem_first: a MEM-point bus error was not taken first");
    a_trap_ex_priority: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (!mem_exc_valid_i && !mem_stall_i && any_ex && !mret) |-> (trap_enter_o && !is_interrupt_o && trap_cause_o == spec_cause && trap_pc_o == idex_pc_i) )
        else $error("[SVA-FAIL] a_trap_ex_priority: exception cause %0d, the priority order says %0d", trap_cause_o, spec_cause);
    // T-9: nothing is taken in EX while a load or store is still on the bus
    a_trap_not_in_h2: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (trap_enter_o && !mem_exc_valid_i) |-> !mem_stall_i )
        else $error("[SVA-FAIL] a_trap_not_in_h2: an EX trap or interrupt taken during a D-port wait");
    a_mret_not_in_h2: assert property (@(posedge clk_i) disable iff (!rst_n_i) mret_o |-> (!mem_stall_i && !mem_exc_valid_i) )
        else $error("[SVA-FAIL] a_mret_not_in_h2: MRET taken during a D-port wait or over a bus error (T-9, T-13)");

    // ---- interrupts -----------------------------------------------------------------------------
    // T-4: taken only between instructions, never on a bubble; never over an exception
    a_int_on_instr: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (trap_enter_o && is_interrupt_o) |-> (idex_valid_i && !mem_exc_valid_i && !any_ex) )
        else $error("[SVA-FAIL] a_int_on_instr: an interrupt taken on a bubble or over an exception");
    // causes: a CLIC interrupt reports 0x8000_0000 | ID, the timer 0x8000_0007; the timer needs MIE
    a_int_cause: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (trap_enter_o && is_interrupt_o) |-> (clic_take_cond_i ? trap_cause_o == (32'h8000_0000 | clic_irq_id_i)
                                                               : (trap_cause_o == 32'h8000_0007 && mti_pending_i && mstatus_mie_i)) )
        else $error("[SVA-FAIL] a_int_cause: interrupt cause %h wrong", trap_cause_o);
    // ID 7 is never presented: the CLIC keeps it unwritable (CLIC [N-6.3], proved by clic_sva's
    // enable-mask properties in flow/formal/clic). Here that is the input's contract; in every
    // simulation it is checked like any other property.
    assume_clic_not_7: assume property (@(posedge clk_i) disable iff (!rst_n_i)
        clic_take_cond_i |-> clic_irq_id_i != 7 );

    // ---- where the PC goes ----------------------------------------------------------------------
    a_redirect_exc: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (trap_enter_o && !is_interrupt_o) |-> (trap_redirect_valid_o && trap_redirect_target_o == {mtvec_i[31:2], 2'b00}) )
        else $error("[SVA-FAIL] a_redirect_exc: an exception does not go to mtvec");
    a_redirect_mret: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        mret_o |-> (trap_redirect_valid_o && trap_redirect_target_o == mepc_i) )
        else $error("[SVA-FAIL] a_redirect_mret: MRET does not go to mepc");
    a_trap_xor_mret: assert property (@(posedge clk_i) disable iff (!rst_n_i) !(trap_enter_o && mret_o) )
        else $error("[SVA-FAIL] a_trap_xor_mret: a trap and an MRET together");

    c_trap_int_clic: cover property (@(posedge clk_i) trap_enter_o && is_interrupt_o && clic_take_cond_i);
    c_trap_int_mti:  cover property (@(posedge clk_i) trap_enter_o && is_interrupt_o && !clic_take_cond_i);
    c_mem_over_mret: cover property (@(posedge clk_i) mem_exc_valid_i && mret);
endmodule
bind trap_ctrl trap_ctrl_sva #(.ID_W(ID_W)) u_trap_ctrl_sva (.*);
`endif
`endif
