`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block I: Processor Core
// forward_unit.v - EX-side operand forwarding select (Sec. 11.1)
// Document: AERO-GARUDA-DS-001 Rev 1.1
//
// Generates fwd_a_sel / fwd_b_sel for ex_stage's operand muxes. This is the
// EX-side half deferred by hazard_forward_unit.v (which does only ID load-use
// detection). Encoding uses the shared FWD_* macros so it can never drift from
// ex_stage's mux (core_ex_defs.vh -> garuda_defs.vh).
//
// Priority (Sec. 11.1): most-recent producer wins.
//   EX/MEM (FWD_EXMEM) > MEM/WB (FWD_MEMWB) > register file (FWD_NONE)
// Each candidate qualified by reg_write & (rd != x0).
//
// NOTE: implemented as inlined ternary continuous assigns (not a function),
// so the selects are sensitive to ALL producer signals - a function called in
// an assign only re-evaluates on its declared args, which silently staled the
// selects.  Compare is against the EX-stage source indices (id_ex.rs*_idx).
// =============================================================================
`include "core_ex_defs.vh"

module forward_unit (
    input  wire [4:0] id_ex_rs1_idx_i,
    input  wire [4:0] id_ex_rs2_idx_i,
    input  wire [4:0] exmem_rd_i,
    input  wire       exmem_reg_write_i,
    input  wire [4:0] memwb_rd_i,
    input  wire       memwb_reg_write_i,
    output wire [1:0] fwd_a_sel_o,
    output wire [1:0] fwd_b_sel_o
);
    wire exmem_vld = exmem_reg_write_i & (exmem_rd_i != 5'd0);
    wire memwb_vld = memwb_reg_write_i & (memwb_rd_i != 5'd0);

    assign fwd_a_sel_o =
        (exmem_vld && (exmem_rd_i == id_ex_rs1_idx_i)) ? `FWD_EXMEM :
        (memwb_vld && (memwb_rd_i == id_ex_rs1_idx_i)) ? `FWD_MEMWB :
                                                         `FWD_NONE;

    assign fwd_b_sel_o =
        (exmem_vld && (exmem_rd_i == id_ex_rs2_idx_i)) ? `FWD_EXMEM :
        (memwb_vld && (memwb_rd_i == id_ex_rs2_idx_i)) ? `FWD_MEMWB :
                                                         `FWD_NONE;
endmodule
`default_nettype wire
