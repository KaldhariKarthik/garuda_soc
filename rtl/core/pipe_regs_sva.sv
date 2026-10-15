`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - core : properties of the three pipeline registers IF/ID, ID/EX, EX/MEM
// pipe_regs_sva.sv
//
// Spec: GARUDA-CORE-SPEC section 11.4 (hold and flush): a flush makes a bubble
// with every side-effect enable low, and wins over a stall; a stall holds every
// field; otherwise the register takes its inputs. pipe_ctrl_sva proves WHEN the
// pipeline holds and flushes; these check that each register DOES it.
// Each antecedent includes rst_n_i: in the last cycle of reset the register is held
// by reset and takes nothing, which the "takes its inputs" rule must not count.
// Bound to if_id, id_ex and ex_mem; they run in every core, sanity and chip run.
// Not for synthesis, not under Icarus (TOOL-B2).
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module if_id_sva (
    input wire clk_i, rst_n_i, stall_i, flush_i,
    input wire [31:0] instr_i, pc_i, input wire valid_i, fault_i,
    input wire [31:0] instr_o, pc_o, input wire valid_o, fault_o
);
    a_ifid_flush: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (rst_n_i && flush_i) |=> (!valid_o && !fault_o && instr_o == 32'h0000_0013) )
        else $error("[SVA-FAIL] a_ifid_flush: IF/ID is not a NOP bubble after a flush");
    a_ifid_hold: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (rst_n_i && stall_i && !flush_i) |=> $stable({instr_o, pc_o, valid_o, fault_o}) )
        else $error("[SVA-FAIL] a_ifid_hold: IF/ID moved during a stall");
    a_ifid_take: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (rst_n_i && !stall_i && !flush_i) |=> {instr_o, pc_o, valid_o, fault_o} === $past({instr_i, pc_i, valid_i, fault_i}) )
        else $error("[SVA-FAIL] a_ifid_take: IF/ID did not take its inputs");
    c_ifid_flush_and_stall: cover property (@(posedge clk_i) flush_i && stall_i);
endmodule

module id_ex_sva (
    input wire clk_i, rst_n_i, stall_i, flush_i,
    input wire valid_i, reg_write_i, mem_read_i, mem_write_i, csr_en_i, dsu_en_i, mul_en_i,
    input wire branch_i, jal_i, jalr_i, is_system_i,
    input wire [31:0] pc_i, instr_i,
    input wire valid_o, reg_write_o, mem_read_o, mem_write_o, csr_en_o, dsu_en_o, mul_en_o,
    input wire branch_o, jal_o, jalr_o, is_system_o,
    input wire [31:0] pc_o, instr_o
);
    wire [10:0] ctl_i = {valid_i, reg_write_i, mem_read_i, mem_write_i, csr_en_i, dsu_en_i, mul_en_i, branch_i, jal_i, jalr_i, is_system_i};
    wire [10:0] ctl_o = {valid_o, reg_write_o, mem_read_o, mem_write_o, csr_en_o, dsu_en_o, mul_en_o, branch_o, jal_o, jalr_o, is_system_o};
    // a bubble does nothing: no register write, no memory access, no CSR, DSU, multiply,
    // branch, jump or system instruction
    a_idex_flush: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (rst_n_i && flush_i) |=> (ctl_o == 11'd0) )
        else $error("[SVA-FAIL] a_idex_flush: ID/EX is not a bubble after a flush (controls %b)", ctl_o);
    a_idex_hold: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (rst_n_i && stall_i && !flush_i) |=> $stable({ctl_o, pc_o, instr_o}) )
        else $error("[SVA-FAIL] a_idex_hold: ID/EX moved during a stall");
    a_idex_take: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (rst_n_i && !stall_i && !flush_i) |=> {ctl_o, pc_o, instr_o} === $past({ctl_i, pc_i, instr_i}) )
        else $error("[SVA-FAIL] a_idex_take: ID/EX did not take its inputs: now %b %h %h, inputs then %b %h %h, rst then %b", ctl_o, pc_o, instr_o, $past(ctl_i), $past(pc_i), $past(instr_i), $past(rst_n_i));
endmodule

module ex_mem_sva (
    input wire clk_i, rst_n_i, stall_i, flush_i,
    input wire valid_i, reg_write_i, mem_read_i, mem_write_i, mem_to_reg_i,
    input wire [31:0] ex_result_i, store_data_i, pc_i, input wire [4:0] rd_i,
    input wire valid_o, reg_write_o, mem_read_o, mem_write_o, mem_to_reg_o,
    input wire [31:0] ex_result_o, store_data_o, pc_o, input wire [4:0] rd_o
);
    a_exmem_flush: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (rst_n_i && flush_i) |=> !(valid_o || reg_write_o || mem_read_o || mem_write_o || mem_to_reg_o) )
        else $error("[SVA-FAIL] a_exmem_flush: EX/MEM is not a bubble after a flush");
    a_exmem_hold: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (rst_n_i && stall_i && !flush_i) |=> $stable({valid_o, reg_write_o, mem_read_o, mem_write_o, ex_result_o, store_data_o, pc_o, rd_o}) )
        else $error("[SVA-FAIL] a_exmem_hold: EX/MEM moved during a stall");
    a_exmem_take: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (rst_n_i && !stall_i && !flush_i) |=> {valid_o, reg_write_o, mem_read_o, mem_write_o, ex_result_o, store_data_o, pc_o, rd_o}
                                   === $past({valid_i, reg_write_i, mem_read_i, mem_write_i, ex_result_i, store_data_i, pc_i, rd_i}) )
        else $error("[SVA-FAIL] a_exmem_take: EX/MEM did not take its inputs");
endmodule

bind if_id if_id_sva u_if_id_sva (.*);
bind id_ex id_ex_sva u_id_ex_sva (.*);
bind ex_mem ex_mem_sva u_ex_mem_sva (.*);
`endif
`endif
