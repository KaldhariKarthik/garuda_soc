// =============================================================
// tapeout_id_stage.sv
// Tapeout-grade SV verification environment for GARUDA id_stage.v
// (TOP WRAPPER instantiating all 5 ID-stage sub-blocks:
//  decode_control, imm_gen, regfile, branch_predict, hazard_forward_unit -
//  Sec. 5, Sec. 7, Sec. 11, Sec. 12)
//
// id_stage.v is a MIX of combinational logic (four of its five sub-
// blocks) and real registered state (regfile.v's storage array, embedded
// two levels down). That mix drives this file's structure: the sequence-
// based generator / synchronous apply-sample-check loop is used
// throughout (as in every file in this set), but the STATEFUL half of the
// reference model follows the exact discipline established in
// tapeout_regfile.sv, for the same reason.
//
// *** ARCHITECTURAL FINDING (inherited from tapeout_regfile.sv, restated
// here because it applies just as much at the stage level) ***
// regfile.v's rst_n_i is never referenced in any always block - writes
// are the ONLY thing that ever changes the storage array. Consequently:
//   - This environment's reference model keeps ONE persistent sparse
//     register-file shadow map for the entire run, never reset between
//     sequences, exactly like tapeout_regfile.sv. Resetting it per
//     sequence (the pattern that is CORRECT for dsu_stall.v, whose
//     registers genuinely do clear) would silently desynchronize the
//     model from the real DUT here.
//   - id_stage_i's rst_n_i is pulsed exactly once, at the very start,
//     purely for interface bring-up - never again mid-run.
//
// Two further id_stage-level (not sub-block-level) architectural
// contracts are checked here because they only exist once the sub-blocks
// are wired together: JALR must never trigger an ID-stage redirect (Sec.
// 12.2 - it resolves in EX), and a bubble (if_id_valid_i=0) must present
// an architecturally inert control bundle. Every sub-block already has
// its own dedicated unit environment in this set (tapeout_decode_
// control.sv, tapeout_imm_gen.sv, tapeout_regfile.sv, tapeout_branch_
// predict.sv, tapeout_hazard_forward_unit.sv) with block-local assertions
// and reference models - this file's job is the WIRING between them, not
// re-litigating each block's own internal logic in isolation.
//
// Requires a simulator with full IEEE1800 support (covergroup, assert
// property). NOT Icarus Verilog.
// =============================================================

`timescale 1ns / 1ps

// -------------------------------------------------------------
// 0. DEFINES (inlined from garuda_defs.vh)
// -------------------------------------------------------------
// decode_control.v and imm_gen.v both begin with
// `` `include "garuda_defs.vh" ``. That include is REMOVED from both
// pasted DUT sub-modules below (a literal `include would require the
// file on disk, breaking standalone compilation) and its content
// inlined ONCE here, shared by both.
`ifndef GARUDA_DEFS_VH
`define GARUDA_DEFS_VH
`define ALU_ADD   4'h0
`define ALU_SUB   4'h1
`define ALU_AND   4'h2
`define ALU_OR    4'h3
`define ALU_XOR   4'h4
`define ALU_SLL   4'h5
`define ALU_SRL   4'h6
`define ALU_SRA   4'h7
`define ALU_SLT   4'h8
`define ALU_SLTU  4'h9
`define ALU_PASSB 4'hA
`define IMM_I    3'h0
`define IMM_S    3'h1
`define IMM_B    3'h2
`define IMM_U    3'h3
`define IMM_J    3'h4
`define IMM_CSR  3'h5
`define IMM_NONE 3'h6
`endif // GARUDA_DEFS_VH

// -------------------------------------------------------------
// 1. DUT: all 6 modules pasted verbatim (id_stage.v cannot elaborate
//    without its 5 sub-blocks); `include lines substituted per above.
// -------------------------------------------------------------

// ---- Sub-block 1/5: Decode / Control --------------------------------------
`ifndef GARUDA_REAL_RTL
// -----------------------------------------------------------------------------
// INLINED DUT COPY -- guarded (added 2026-08-02).
//
// This file carries its own copy of the DUT so it can be compiled standalone
// under VCS. That copy is a SNAPSHOT and had already drifted from rtl/core/*.v
// (it predates the SLLI/SRLI/SRAI funct7 check and the FENCE decode), so a
// green run against it proves nothing about the RTL that actually ships.
//
// Defining GARUDA_REAL_RTL skips this copy so the testbench binds to the real
// rtl/core sources -- that is what tb/core/filelist_*.f does. Compiling this
// file standalone with no define behaves exactly as before.
// -----------------------------------------------------------------------------
module decode_control (
    input  wire [31:0] instr_i,
    output wire [6:0]  opcode_o,
    output wire [4:0]  rd_o,
    output wire [2:0]  funct3_o,
    output wire [4:0]  rs1_o,
    output wire [4:0]  rs2_o,
    output reg          reg_write_o,
    output reg          mem_read_o,
    output reg          mem_write_o,
    output reg          mem_to_reg_o,
    output reg          alu_src_o,
    output reg          alu_a_pc_o,
    output reg  [3:0]  alu_op_o,
    output reg          branch_o,
    output reg          jal_o,
    output reg          jalr_o,
    output reg          mul_en_o,
    output reg          dsu_en_o,
    output reg          csr_en_o,
    output reg  [2:0]  csr_op_o,
    output reg          is_system_o,
    output reg          illegal_instr_o,
    output reg  [2:0]  imm_sel_o
);
    wire [6:0] opcode;
    wire [4:0] rd_f, rs1_f, rs2_f;
    wire [2:0] funct3;
    wire [6:0] funct7;

    assign opcode = instr_i[6:0];
    assign rd_f   = instr_i[11:7];
    assign funct3 = instr_i[14:12];
    assign rs1_f  = instr_i[19:15];
    assign rs2_f  = instr_i[24:20];
    assign funct7 = instr_i[31:25];

    assign opcode_o = opcode;
    assign rd_o     = rd_f;
    assign funct3_o = funct3;
    assign rs1_o    = rs1_f;
    assign rs2_o    = rs2_f;

    localparam [6:0] OP_LUI     = 7'b0110111;
    localparam [6:0] OP_AUIPC   = 7'b0010111;
    localparam [6:0] OP_JAL     = 7'b1101111;
    localparam [6:0] OP_JALR    = 7'b1100111;
    localparam [6:0] OP_BRANCH  = 7'b1100011;
    localparam [6:0] OP_LOAD    = 7'b0000011;
    localparam [6:0] OP_STORE   = 7'b0100011;
    localparam [6:0] OP_IMM     = 7'b0010011;
    localparam [6:0] OP_REG     = 7'b0110011;
    localparam [6:0] OP_SYSTEM  = 7'b1110011;
    localparam [6:0] OP_CUSTOM0 = 7'b0001011;

    wire is_muldiv, is_mul_family, is_div_family;
    assign is_muldiv = (opcode == OP_REG) && (funct7 == 7'b0000001);
    assign is_mul_family = is_muldiv && (funct3[2] == 1'b0);
    assign is_div_family = is_muldiv && (funct3[2] == 1'b1);

    always @(*) begin
        reg_write_o = 1'b0; mem_read_o = 1'b0; mem_write_o = 1'b0; mem_to_reg_o = 1'b0;
        alu_src_o = 1'b0; alu_a_pc_o = 1'b0; alu_op_o = `ALU_ADD;
        branch_o = 1'b0; jal_o = 1'b0; jalr_o = 1'b0; mul_en_o = 1'b0; dsu_en_o = 1'b0;
        csr_en_o = 1'b0; csr_op_o = 3'b000; is_system_o = 1'b0; illegal_instr_o = 1'b0;
        imm_sel_o = `IMM_NONE;

        case (opcode)
            OP_LUI: begin reg_write_o=1'b1; alu_src_o=1'b1; alu_op_o=`ALU_PASSB; imm_sel_o=`IMM_U; end
            OP_AUIPC: begin reg_write_o=1'b1; alu_src_o=1'b1; alu_a_pc_o=1'b1; alu_op_o=`ALU_ADD; imm_sel_o=`IMM_U; end
            OP_JAL: begin reg_write_o=1'b1; jal_o=1'b1; imm_sel_o=`IMM_J; end
            OP_JALR: begin reg_write_o=1'b1; jalr_o=1'b1; imm_sel_o=`IMM_I; end
            OP_BRANCH: begin branch_o=1'b1; alu_op_o=`ALU_SUB; imm_sel_o=`IMM_B; end
            OP_LOAD: begin reg_write_o=1'b1; mem_read_o=1'b1; mem_to_reg_o=1'b1; alu_src_o=1'b1; alu_op_o=`ALU_ADD; imm_sel_o=`IMM_I; end
            OP_STORE: begin mem_write_o=1'b1; alu_src_o=1'b1; alu_op_o=`ALU_ADD; imm_sel_o=`IMM_S; end
            OP_IMM: begin
                reg_write_o=1'b1; alu_src_o=1'b1; imm_sel_o=`IMM_I;
                case (funct3)
                    3'b000: alu_op_o=`ALU_ADD; 3'b010: alu_op_o=`ALU_SLT; 3'b011: alu_op_o=`ALU_SLTU;
                    3'b100: alu_op_o=`ALU_XOR; 3'b110: alu_op_o=`ALU_OR; 3'b111: alu_op_o=`ALU_AND;
                    3'b001: alu_op_o=`ALU_SLL;
                    3'b101: alu_op_o = funct7[5] ? `ALU_SRA : `ALU_SRL;
                    // funct3 is 3 bits and all 8 values are enumerated above,
                    // so this arm is unreachable -- kept as a synthesis
                    // safety net against an inferred latch.
                    /* VCS_COVERAGE_ANALYSIS_OFF */
                    default: illegal_instr_o = 1'b1;
                    /* VCS_COVERAGE_ANALYSIS_ON */
                endcase
            end
            OP_REG: begin
                if (is_mul_family) begin reg_write_o=1'b1; mul_en_o=1'b1; end
                else if (is_div_family) begin illegal_instr_o=1'b1; end
                else if (funct7 == 7'b0000000 || funct7 == 7'b0100000) begin
                    reg_write_o=1'b1;
                    case (funct3)
                        3'b000: alu_op_o = funct7[5] ? `ALU_SUB : `ALU_ADD;
                        3'b001: alu_op_o=`ALU_SLL; 3'b010: alu_op_o=`ALU_SLT; 3'b011: alu_op_o=`ALU_SLTU;
                        3'b100: alu_op_o=`ALU_XOR;
                        3'b101: alu_op_o = funct7[5] ? `ALU_SRA : `ALU_SRL;
                        3'b110: alu_op_o=`ALU_OR; 3'b111: alu_op_o=`ALU_AND;
                        // Same reasoning as the OP_IMM funct3 case above: all
                        // 8 values of the 3-bit field are enumerated, so this
                        // default is unreachable dead code, not a stimulus gap.
                        /* VCS_COVERAGE_ANALYSIS_OFF */
                        default: illegal_instr_o=1'b1;
                        /* VCS_COVERAGE_ANALYSIS_ON */
                    endcase
                end else begin illegal_instr_o=1'b1; end
            end
            OP_SYSTEM: begin
                is_system_o=1'b1;
                if (funct3 != 3'b000) begin csr_en_o=1'b1; csr_op_o=funct3; reg_write_o=1'b1; imm_sel_o=`IMM_CSR; end
            end
            OP_CUSTOM0: begin dsu_en_o=1'b1; end
            default: begin illegal_instr_o=1'b1; end
        endcase
    end
endmodule

// ---- Sub-block 2/5: Immediate Generator ------------------------------------
module imm_gen (
    input  wire [31:0] instr_i,
    input  wire [2:0]  imm_sel_i,
    output reg  [31:0] imm_o,
    output wire [31:0] imm_b_o,
    output wire [31:0] imm_j_o
);
    wire [31:0] imm_i_f, imm_s_f, imm_b_f, imm_u_f, imm_j_f, imm_csr_f;
    assign imm_i_f   = {{20{instr_i[31]}}, instr_i[31:20]};
    assign imm_s_f   = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
    // B/J-immediate bit 0 and CSR-immediate bits[31:5]/U-immediate bits[11:0]
    // are architecturally constant (see tapeout_imm_gen.sv's fuller
    // comments) -- isolated via bit-select assigns so only those exact
    // bits are excluded from toggle coverage, not the surrounding
    // meaningful bits of the same net.
    assign imm_b_f[31:1] = {{19{instr_i[31]}}, instr_i[31], instr_i[7], instr_i[30:25], instr_i[11:8]};
/* VCS_COVERAGE_ANALYSIS_OFF */
    assign imm_b_f[0]    = 1'b0;
/* VCS_COVERAGE_ANALYSIS_ON */
    assign imm_u_f[31:12] = instr_i[31:12];
/* VCS_COVERAGE_ANALYSIS_OFF */
    assign imm_u_f[11:0]  = 12'b0;
/* VCS_COVERAGE_ANALYSIS_ON */
    assign imm_j_f[31:1] = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12], instr_i[20], instr_i[30:21]};
/* VCS_COVERAGE_ANALYSIS_OFF */
    assign imm_j_f[0]    = 1'b0;
/* VCS_COVERAGE_ANALYSIS_ON */
    assign imm_csr_f[4:0]  = instr_i[19:15];
/* VCS_COVERAGE_ANALYSIS_OFF */
    assign imm_csr_f[31:5] = 27'b0;
/* VCS_COVERAGE_ANALYSIS_ON */
    assign imm_b_o[31:1] = imm_b_f[31:1];
/* VCS_COVERAGE_ANALYSIS_OFF */
    assign imm_b_o[0]    = imm_b_f[0];
/* VCS_COVERAGE_ANALYSIS_ON */
    assign imm_j_o[31:1] = imm_j_f[31:1];
/* VCS_COVERAGE_ANALYSIS_OFF */
    assign imm_j_o[0]    = imm_j_f[0];
/* VCS_COVERAGE_ANALYSIS_ON */
    always @(*) begin
        case (imm_sel_i)
            `IMM_I: imm_o = imm_i_f; `IMM_S: imm_o = imm_s_f; `IMM_B: imm_o = imm_b_f;
            `IMM_U: imm_o = imm_u_f; `IMM_J: imm_o = imm_j_f; `IMM_CSR: imm_o = imm_csr_f;
            default: imm_o = 32'b0;
        endcase
    end
endmodule

// ---- Sub-block 3/5: Register File ------------------------------------------
module regfile (
    input  wire         clk_i,
    input  wire         rst_n_i,
    input  wire [4:0]  rs1_idx_i,
    input  wire [4:0]  rs2_idx_i,
    input  wire         wb_reg_write_i,
    input  wire [4:0]  wb_rd_i,
    input  wire [31:0] wb_data_i,
    output wire [31:0] rs1_data_o,
    output wire [31:0] rs2_data_o
);
    reg [31:0] mem [1:31];
    wire [31:0] rs1_raw, rs2_raw;
    always @(posedge clk_i) begin
        if (wb_reg_write_i && (wb_rd_i != 5'd0)) mem[wb_rd_i] <= wb_data_i;
    end
    assign rs1_raw = (rs1_idx_i == 5'd0) ? 32'd0 : mem[rs1_idx_i];
    assign rs2_raw = (rs2_idx_i == 5'd0) ? 32'd0 : mem[rs2_idx_i];
    assign rs1_data_o = (wb_reg_write_i && (wb_rd_i != 5'd0) && (wb_rd_i == rs1_idx_i)) ? wb_data_i : rs1_raw;
    assign rs2_data_o = (wb_reg_write_i && (wb_rd_i != 5'd0) && (wb_rd_i == rs2_idx_i)) ? wb_data_i : rs2_raw;
endmodule

// ---- Sub-block 4/5: Branch Predict -----------------------------------------
module branch_predict (
    input  wire [31:0] pc_i,
    input  wire [31:0] imm_b_i,
    input  wire [31:0] imm_j_i,
    input  wire         branch_i,
    input  wire         jal_i,
    output wire         predict_taken_o,
    output wire         id_redirect_valid_o,
    output wire [31:0] id_redirect_target_o
);
    wire [31:0] branch_target, jal_target;
    assign branch_target = pc_i + imm_b_i;
    assign jal_target    = pc_i + imm_j_i;
    assign predict_taken_o = branch_i & imm_b_i[31];
    assign id_redirect_valid_o  = jal_i | predict_taken_o;
    assign id_redirect_target_o = jal_i ? jal_target : branch_target;
endmodule

// ---- Sub-block 5/5: Hazard / Forwarding Unit -------------------------------
module hazard_forward_unit (
    input  wire [4:0] id_rs1_idx_i,
    input  wire [4:0] id_rs2_idx_i,
    input  wire        ex_mem_read_i,
    input  wire [4:0] ex_rd_i,
    output wire         load_use_stall_o
);
    assign load_use_stall_o = ex_mem_read_i && (ex_rd_i != 5'd0) &&
                               ((ex_rd_i == id_rs1_idx_i) || (ex_rd_i == id_rs2_idx_i));
endmodule

// ---- Top wrapper: ID Stage --------------------------------------------------
module id_stage (
    input  wire         clk_i,
    input  wire         rst_n_i,

    input  wire [31:0] if_id_instr_i,
    input  wire [31:0] if_id_pc_i,
    input  wire         if_id_fault_i,
    input  wire         if_id_valid_i,

    input  wire         wb_reg_write_i,
    input  wire [4:0]  wb_rd_i,
    input  wire [31:0] wb_data_i,

    input  wire         ex_mem_read_i,
    input  wire [4:0]  ex_rd_i,

    output wire         reg_write_o,
    output wire         mem_read_o,
    output wire         mem_write_o,
    output wire         mem_to_reg_o,
    output wire         alu_src_o,
    output wire         alu_a_pc_o,
    output wire [3:0]  alu_op_o,
    output wire         branch_o,
    output wire         jal_o,
    output wire         jalr_o,
    output wire         mul_en_o,
    output wire         dsu_en_o,
    output wire         csr_en_o,
    output wire [2:0]  csr_op_o,
    output wire         is_system_o,
    output wire         illegal_instr_dec_o,

    output wire [31:0] rs1_data_o,
    output wire [31:0] rs2_data_o,
    output wire [31:0] imm_o,
    output wire [31:0] pc_o,
    output wire [4:0]  rs1_idx_o,
    output wire [4:0]  rs2_idx_o,
    output wire [4:0]  rd_o,
    output wire [2:0]  funct3_o,
    output wire [31:0] instr_o,
    output wire         fault_o,

    output wire         load_use_stall_o,

    output wire         id_redirect_valid_o,
    output wire [31:0] id_redirect_target_o,

    output wire         predict_taken_o,

    output wire         valid_o
);
    wire [4:0] rd_w, rs1_idx_w, rs2_idx_w;
    wire [2:0] funct3_w;
    wire [2:0] imm_sel_w;
    wire [31:0] id_instr = if_id_valid_i ? if_id_instr_i : 32'h0000_0013;

    decode_control u_decode_control (
        .instr_i(id_instr), .opcode_o(), .rd_o(rd_w), .funct3_o(funct3_w),
        .rs1_o(rs1_idx_w), .rs2_o(rs2_idx_w), .reg_write_o(reg_write_o), .mem_read_o(mem_read_o),
        .mem_write_o(mem_write_o), .mem_to_reg_o(mem_to_reg_o), .alu_src_o(alu_src_o),
        .alu_a_pc_o(alu_a_pc_o), .alu_op_o(alu_op_o), .branch_o(branch_o), .jal_o(jal_o),
        .jalr_o(jalr_o), .mul_en_o(mul_en_o), .dsu_en_o(dsu_en_o), .csr_en_o(csr_en_o),
        .csr_op_o(csr_op_o), .is_system_o(is_system_o), .illegal_instr_o(illegal_instr_dec_o),
        .imm_sel_o(imm_sel_w)
    );

    wire [31:0] imm_w, imm_b_w, imm_j_w;
    imm_gen u_imm_gen (
        .instr_i(id_instr), .imm_sel_i(imm_sel_w), .imm_o(imm_w), .imm_b_o(imm_b_w), .imm_j_o(imm_j_w)
    );

    wire [31:0] rs1_data_w, rs2_data_w;
    regfile u_regfile (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .rs1_idx_i(rs1_idx_w), .rs2_idx_i(rs2_idx_w),
        .wb_reg_write_i(wb_reg_write_i), .wb_rd_i(wb_rd_i), .wb_data_i(wb_data_i),
        .rs1_data_o(rs1_data_w), .rs2_data_o(rs2_data_w)
    );

    branch_predict u_branch_predict (
        .pc_i(if_id_pc_i), .imm_b_i(imm_b_w), .imm_j_i(imm_j_w), .branch_i(branch_o), .jal_i(jal_o),
        .predict_taken_o(predict_taken_o), .id_redirect_valid_o(id_redirect_valid_o),
        .id_redirect_target_o(id_redirect_target_o)
    );

    hazard_forward_unit u_hazard_forward_unit (
        .id_rs1_idx_i(rs1_idx_w), .id_rs2_idx_i(rs2_idx_w), .ex_mem_read_i(ex_mem_read_i),
        .ex_rd_i(ex_rd_i), .load_use_stall_o(load_use_stall_o)
    );

    assign rs1_data_o = rs1_data_w;
    assign rs2_data_o = rs2_data_w;
    assign imm_o        = imm_w;
    assign pc_o         = if_id_pc_i;
    assign rs1_idx_o    = rs1_idx_w;
    assign rs2_idx_o    = rs2_idx_w;
    assign rd_o         = rd_w;
    assign funct3_o     = funct3_w;
    assign instr_o      = id_instr;
    assign fault_o      = if_id_fault_i;
    assign valid_o      = if_id_valid_i;
endmodule
`endif // GARUDA_REAL_RTL -- inlined DUT copy ends; verification env follows



// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA assertions)
// -------------------------------------------------------------
interface id_stage_if (input bit clk);
    logic         rst_n;
    logic [31:0] if_id_instr;
    logic [31:0] if_id_pc;
    logic         if_id_fault;
    logic         if_id_valid;
    logic         wb_reg_write;
    logic [4:0]  wb_rd;
    logic [31:0] wb_data;
    logic         ex_mem_read;
    logic [4:0]  ex_rd;

    logic         reg_write, mem_read, mem_write, mem_to_reg, alu_src, alu_a_pc;
    logic [3:0]  alu_op;
    logic         branch, jal, jalr, mul_en, dsu_en, csr_en;
    logic [2:0]  csr_op;
    logic         is_system, illegal_instr_dec;
    logic [31:0] rs1_data, rs2_data, imm, pc;
    logic [4:0]  rs1_idx, rs2_idx, rd;
    logic [2:0]  funct3;
    logic [31:0] instr;
    logic         fault;
    logic         load_use_stall;
    logic         id_redirect_valid;
    logic [31:0] id_redirect_target;
    logic         predict_taken;
    logic         valid;

    // A1: on a bubble (if_id_valid_i=0), id_stage.v substitutes a NOP for
    //     the fetched instruction so nothing downstream executes garbage
    //     left over from a squashed fetch. The substituted word is
    //     32'h0000_0013 (ADDI x0,x0,0), the canonical RISC-V NOP - its
    //     OP_IMM opcode makes decode_control assert reg_write
    //     unconditionally (it has no rd==0 special case; that's the
    //     regfile's job per Sec. 7.1/regfile.v), so reg_write==1 with
    //     rd==0 on a bubble is expected and architecturally inert (the
    //     write is discarded), not a side effect.
    property p_bubble_forces_inert_bundle;
        @(posedge clk) disable iff (!rst_n)
        !if_id_valid |-> ((!reg_write || (rd == 5'd0)) && !mem_write && !branch && !jal && !jalr &&
                           !csr_en && !dsu_en && !mul_en && !mem_read);
    endproperty
    a_bubble_inert: assert property (p_bubble_forces_inert_bundle)
        else $error("[SVA-FAIL] a NOP bubble produced a side-effecting control signal");

    // A2: fault_o must ride through to CONTROL regardless of
    //     if_id_valid_i (Sec. 6.4/14.1) - unlike every other field, which
    //     is NOP-substituted on a bubble.
    property p_fault_passthrough_always;
        @(posedge clk) disable iff (!rst_n) fault == if_id_fault;
    endproperty
    a_fault_always: assert property (p_fault_passthrough_always)
        else $error("[SVA-FAIL] fault_o did not track if_id_fault_i unconditionally");

    // A3: valid_o is the retire tag consumed by minstret counting
    //     (Sec. 13.2) - a pure passthrough of if_id_valid_i.
    property p_valid_passthrough;
        @(posedge clk) disable iff (!rst_n) valid == if_id_valid;
    endproperty
    a_valid_passthrough: assert property (p_valid_passthrough)
        else $error("[SVA-FAIL] valid_o did not track if_id_valid_i");

    // A4: x0 must read as zero even after crossing the ID-stage's
    //     internal rs1_idx/rs2_idx wiring - a wiring bug between
    //     decode_control and regfile could miswire the index.
    property p_x0_rs1_zero;
        @(posedge clk) disable iff (!rst_n) (rs1_idx == 5'd0) |-> (rs1_data == 32'd0);
    endproperty
    a_x0_rs1: assert property (p_x0_rs1_zero)
        else $error("[SVA-FAIL] rs1_data_o was nonzero while rs1_idx_o==0");

    // A5: JALR must resolve in EX, never redirect from ID (Sec. 12.2) -
    //     this is a wiring-level property (branch_predict.v never sees
    //     jalr_o at all), only checkable once the stage is fully assembled.
    property p_jalr_never_id_redirects;
        @(posedge clk) disable iff (!rst_n) jalr |-> !id_redirect_valid;
    endproperty
    a_jalr_no_redirect: assert property (p_jalr_never_id_redirects)
        else $error("[SVA-FAIL] JALR incorrectly triggered an ID-stage redirect");

    // A6: the hazard unit must see the DECODED rs1/rs2 (post NOP-
    //     substitution on a bubble), not the raw if_id_instr_i.
    property p_load_use_uses_decoded_indices;
        @(posedge clk) disable iff (!rst_n)
        (ex_mem_read && (ex_rd != 5'd0) && ((ex_rd == rs1_idx) || (ex_rd == rs2_idx))) |-> load_use_stall;
    endproperty
    a_load_use_wiring: assert property (p_load_use_uses_decoded_indices)
        else $error("[SVA-FAIL] load_use_stall_o did not track the stage's own decoded rs1_idx_o/rs2_idx_o");

    // A7: X-propagation - every output feeds the id_ex pipeline register
    //     or a hazard/redirect mux directly.
    property p_no_x_propagation;
        @(posedge clk) disable iff (!rst_n)
        (!$isunknown({if_id_instr, if_id_pc, if_id_fault, if_id_valid, wb_reg_write, wb_rd,
                      wb_data, ex_mem_read, ex_rd})) |->
        (!$isunknown({reg_write, mem_read, mem_write, alu_op, branch, jal, jalr, illegal_instr_dec,
                      imm, pc, rs1_idx, rs2_idx, rd, funct3, instr, fault, load_use_stall,
                      id_redirect_valid, predict_taken, valid}));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] an id_stage output went unknown while all inputs were known");

endinterface


// -------------------------------------------------------------
// 3. PER-CYCLE STIMULUS ITEM -- rand + constraint => real CRV
// -------------------------------------------------------------
typedef enum {
    IDK_RESET_BUBBLE, IDK_LEGAL_ALU, IDK_ILLEGAL, IDK_BYPASS_RS1, IDK_BYPASS_RS2, IDK_BYPASS_BOTH,
    IDK_HAZARD_RS1, IDK_HAZARD_RS2, IDK_HAZARD_BOTH, IDK_HAZARD_X0_EXCLUDED,
    IDK_BACKWARD_BRANCH, IDK_FORWARD_BRANCH, IDK_JAL, IDK_JALR, IDK_CSR_OP,
    IDK_BUBBLE_WITH_FAULT, IDK_RANDOM
} id_op_e;

class id_cycle;
    rand id_op_e op;

    rand bit [31:0] instr_val;
    rand bit [31:0] pc_val;
    rand bit         fault_val;
    rand bit         valid_val;
    rand bit         wb_write_val;
    rand bit [4:0]  wb_rd_val;
    rand bit [31:0] wb_data_val;
    rand bit         ex_read_val;
    rand bit [4:0]  ex_rd_val;

    static function bit [31:0] enc_r(bit [6:0] f7, bit [4:0] rs2, bit [4:0] rs1, bit [2:0] f3, bit [4:0] rd, bit [6:0] opc);
        return {f7, rs2, rs1, f3, rd, opc};
    endfunction

    constraint c_defaults { valid_val == 1'b1; pc_val[1:0] == 2'b00; }
    constraint c_ranges   { wb_rd_val inside {[0:31]}; ex_rd_val inside {[0:31]}; }

    constraint c_op_dist {
        op dist {
            IDK_RESET_BUBBLE :/ 4, IDK_LEGAL_ALU :/ 10, IDK_ILLEGAL :/ 8,
            IDK_BYPASS_RS1 :/ 8, IDK_BYPASS_RS2 :/ 6, IDK_BYPASS_BOTH :/ 5,
            IDK_HAZARD_RS1 :/ 8, IDK_HAZARD_RS2 :/ 6, IDK_HAZARD_BOTH :/ 5, IDK_HAZARD_X0_EXCLUDED :/ 4,
            IDK_BACKWARD_BRANCH :/ 6, IDK_FORWARD_BRANCH :/ 6, IDK_JAL :/ 5, IDK_JALR :/ 5,
            IDK_CSR_OP :/ 5, IDK_BUBBLE_WITH_FAULT :/ 4, IDK_RANDOM :/ 15
        };
    }

    constraint c_op_shape {
        (op == IDK_RESET_BUBBLE)      -> (valid_val == 0);
        (op == IDK_BUBBLE_WITH_FAULT) -> (valid_val == 0 && fault_val == 1);
        (op == IDK_HAZARD_RS1)  -> (ex_read_val == 1 && ex_rd_val != 0 && ex_rd_val == instr_val[19:15]);
        (op == IDK_HAZARD_RS2)  -> (ex_read_val == 1 && ex_rd_val != 0 && ex_rd_val == instr_val[24:20]);
        (op == IDK_HAZARD_BOTH) -> (ex_read_val == 1 && ex_rd_val != 0 &&
                                     ex_rd_val == instr_val[19:15] && ex_rd_val == instr_val[24:20]);
        (op == IDK_HAZARD_X0_EXCLUDED) -> (ex_read_val == 1 && ex_rd_val == 0);
        (op == IDK_BYPASS_RS1)  -> (wb_write_val == 1 && wb_rd_val != 0 && wb_rd_val == instr_val[19:15]);
        (op == IDK_BYPASS_RS2)  -> (wb_write_val == 1 && wb_rd_val != 0 && wb_rd_val == instr_val[24:20]);
        (op == IDK_BYPASS_BOTH) -> (wb_write_val == 1 && wb_rd_val != 0 &&
                                     wb_rd_val == instr_val[19:15] && wb_rd_val == instr_val[24:20]);
        (op == IDK_BACKWARD_BRANCH) -> (instr_val[6:0] == 7'b1100011 && instr_val[31] == 1);
        (op == IDK_FORWARD_BRANCH)  -> (instr_val[6:0] == 7'b1100011 && instr_val[31] == 0);
        (op == IDK_JAL)  -> (instr_val[6:0] == 7'b1101111);
        (op == IDK_JALR) -> (instr_val[6:0] == 7'b1100111);
        (op == IDK_CSR_OP) -> (instr_val[6:0] == 7'b1110011 && instr_val[14:12] != 3'b000);
        (op == IDK_ILLEGAL) -> (instr_val[6:0] == 7'b0110011 && instr_val[31:25] == 7'b0000001 && instr_val[14]);
        (op == IDK_LEGAL_ALU) -> (instr_val[6:0] == 7'b0110011 && instr_val[31:25] inside {7'b0000000, 7'b0100000});
    }

    function void fields(output bit [31:0] o_instr, output bit [31:0] o_pc, output bit o_fault, output bit o_valid,
                         output bit o_wr, output bit [4:0] o_wrd, output bit [31:0] o_wdata,
                         output bit o_exr, output bit [4:0] o_exrd);
        o_instr = instr_val; o_pc = pc_val; o_fault = fault_val; o_valid = valid_val;
        o_wr = wb_write_val; o_wrd = wb_rd_val; o_wdata = wb_data_val;
        o_exr = ex_read_val; o_exrd = ex_rd_val;
    endfunction

    function string to_string();
        return $sformatf("op=%-22s instr=0x%08h pc=0x%08h valid=%0b fault=%0b wb_w=%0b wb_rd=%0d ex_r=%0b ex_rd=%0d",
                          op.name(), instr_val, pc_val, valid_val, fault_val, wb_write_val, wb_rd_val, ex_read_val, ex_rd_val);
    endfunction
endclass


// -------------------------------------------------------------
// 4. GENERATOR -- directed sequences + exhaustive sweep + CRV.
//    As in tapeout_regfile.sv, sequence ORDER matters for the register-
//    file-backed fields (rs1_data/rs2_data): later sequences can
//    legitimately observe content written by earlier ones.
// -------------------------------------------------------------
class id_generator;
    id_cycle seq_q[$][$];
    string   seq_name[$];
    int num_random_seqs;
    int random_seq_len;

    function new(int num_random_seqs = 15, int random_seq_len = 200);
        this.num_random_seqs = num_random_seqs;
        this.random_seq_len  = random_seq_len;
    endfunction

    function id_cycle mk(id_op_e op, bit [31:0] instr, bit [31:0] pcv, bit flt, bit vld,
                          bit wbw, bit [4:0] wbr, bit [31:0] wbd, bit exr, bit [4:0] exrd);
        id_cycle c = new();
        c.op=op; c.instr_val=instr; c.pc_val=pcv; c.fault_val=flt; c.valid_val=vld;
        c.wb_write_val=wbw; c.wb_rd_val=wbr; c.wb_data_val=wbd; c.ex_read_val=exr; c.ex_rd_val=exrd;
        return c;
    endfunction

    function void add_seq(string name, id_cycle q[$]);
        seq_name.push_back(name);
        seq_q.push_back(q);
    endfunction

    function void build();
        // 1) Reset/idle bubble
        begin
            id_cycle q[$];
            q.push_back(mk(IDK_RESET_BUBBLE, 32'h0000_0013, 32'h0, 1'b0, 1'b0, 1'b0, 5'd0, 32'h0, 1'b0, 5'd0));
            add_seq("idle_bubble", q);
        end

        // 2) x0 read-only-zero boundary
        begin
            id_cycle q[$];
            q.push_back(mk(IDK_LEGAL_ALU, id_cycle::enc_r(7'h0, 5'd0, 5'd0, 3'h0, 5'd5, 7'b0110011),
                           32'h0, 1'b0, 1'b1, 1'b1, 5'd0, 32'hFFFF_FFFF, 1'b0, 5'd0));
            add_seq("x0_read_only_zero", q);
        end

        // 3) Same-cycle WB->ID bypass matrix - establishes x12 = 0xC001CAFE
        //    for the cross-sequence persistence check later.
        begin
            id_cycle q[$];
            q.push_back(mk(IDK_BYPASS_RS1, id_cycle::enc_r(7'h0, 5'd20, 5'd12, 3'h0, 5'd3, 7'b0110011),
                           32'h0, 1'b0, 1'b1, 1'b1, 5'd12, 32'hC001_CAFE, 1'b0, 5'd0));
            q.push_back(mk(IDK_BYPASS_RS2, id_cycle::enc_r(7'h0, 5'd12, 5'd20, 3'h0, 5'd3, 7'b0110011),
                           32'h0, 1'b0, 1'b1, 1'b1, 5'd12, 32'hC001_CAFE, 1'b0, 5'd0));
            q.push_back(mk(IDK_BYPASS_BOTH, id_cycle::enc_r(7'h0, 5'd12, 5'd12, 3'h0, 5'd3, 7'b0110011),
                           32'h0, 1'b0, 1'b1, 1'b1, 5'd12, 32'hC001_CAFE, 1'b0, 5'd0));
            add_seq("bypass_matrix", q);
        end

        // 4) Load-use hazard matrix (incl. x0 exclusion)
        begin
            id_cycle q[$];
            q.push_back(mk(IDK_HAZARD_RS1, id_cycle::enc_r(7'h0, 5'd5, 5'd10, 3'h0, 5'd11, 7'b0110011),
                           32'h0, 1'b0, 1'b1, 1'b0, 5'd0, 32'h0, 1'b1, 5'd10));
            q.push_back(mk(IDK_HAZARD_RS2, id_cycle::enc_r(7'h0, 5'd10, 5'd5, 3'h0, 5'd11, 7'b0110011),
                           32'h0, 1'b0, 1'b1, 1'b0, 5'd0, 32'h0, 1'b1, 5'd10));
            q.push_back(mk(IDK_HAZARD_BOTH, id_cycle::enc_r(7'h0, 5'd10, 5'd10, 3'h0, 5'd11, 7'b0110011),
                           32'h0, 1'b0, 1'b1, 1'b0, 5'd0, 32'h0, 1'b1, 5'd10));
            q.push_back(mk(IDK_HAZARD_X0_EXCLUDED, id_cycle::enc_r(7'h0, 5'd0, 5'd0, 3'h0, 5'd2, 7'b0110011),
                           32'h0, 1'b0, 1'b1, 1'b0, 5'd0, 32'h0, 1'b1, 5'd0));
            add_seq("hazard_matrix", q);
        end

        // 5) Branch prediction / JAL / JALR matrix
        begin
            id_cycle q[$];
            q.push_back(mk(IDK_BACKWARD_BRANCH, {1'b1, 6'b0, 13'h0, 4'b0, 1'b0, 7'b1100011}, 32'h0000_0004,
                           1'b0, 1'b1, 1'b0, 5'd0, 32'h0, 1'b0, 5'd0));
            q.push_back(mk(IDK_FORWARD_BRANCH, {1'b0, 6'b0, 13'h0, 4'b0, 1'b0, 7'b1100011}, 32'h0000_0004,
                           1'b0, 1'b1, 1'b0, 5'd0, 32'h0, 1'b0, 5'd0));
            q.push_back(mk(IDK_JAL, {1'b0, 20'h0, 5'd1, 7'b1101111}, 32'h0000_0100, 1'b0, 1'b1, 1'b0, 5'd0, 32'h0, 1'b0, 5'd0));
            q.push_back(mk(IDK_JALR, id_cycle::enc_r(7'h0, 5'd0, 5'd3, 3'b000, 5'd1, 7'b1100111), 32'h0000_0100,
                           1'b0, 1'b1, 1'b0, 5'd0, 32'h0, 1'b0, 5'd0)); // must NOT id-redirect
            add_seq("branch_jal_jalr_matrix", q);
        end

        // 6) CSR immediate zero-extension
        begin
            id_cycle q[$];
            q.push_back(mk(IDK_CSR_OP, {12'hABC, 5'd31, 3'b101, 5'd10, 7'b1110011}, 32'h0, 1'b0, 1'b1,
                           1'b0, 5'd0, 32'h0, 1'b0, 5'd0));
            add_seq("csr_immediate_zero_extend", q);
        end

        // 7) Illegal instruction (DIV family)
        begin
            id_cycle q[$];
            q.push_back(mk(IDK_ILLEGAL, id_cycle::enc_r(7'b0000001, 5'd2, 5'd1, 3'b100, 5'd3, 7'b0110011),
                           32'h0, 1'b0, 1'b1, 1'b0, 5'd0, 32'h0, 1'b0, 5'd0));
            add_seq("illegal_div_family", q);
        end

        // 8) Bubble + fault passthrough independence
        begin
            id_cycle q[$];
            q.push_back(mk(IDK_BUBBLE_WITH_FAULT, id_cycle::enc_r(7'h0, 5'd2, 5'd1, 3'h0, 5'd3, 7'b0110011),
                           32'h0, 1'b1, 1'b0, 1'b0, 5'd0, 32'h0, 1'b0, 5'd0));
            add_seq("bubble_with_fault", q);
        end

        // 9) Exhaustive register-address sweep (rs1=rs2=rd=ex_rd)
        begin
            id_cycle q[$];
            for (int r = 0; r < 32; r++) begin
                q.push_back(mk(IDK_RANDOM, id_cycle::enc_r(7'h0, r[4:0], r[4:0], 3'b000, r[4:0], 7'b0110011),
                               32'h0, 1'b0, 1'b1, 1'b0, 5'd0, 32'h0, 1'b0, 5'd0));
            end
            add_seq("exh_reg_addr_sweep", q);
        end

        // 10) Back-to-back repeated hazard (stress)
        begin
            id_cycle q[$];
            repeat (10) q.push_back(mk(IDK_HAZARD_RS1, id_cycle::enc_r(7'h0, 5'd5, 5'd10, 3'h0, 5'd11, 7'b0110011),
                                       32'h0, 1'b0, 1'b1, 1'b0, 5'd0, 32'h0, 1'b1, 5'd10));
            add_seq("stress_repeated_hazard", q);
        end

        // 11) Alternating bubble/valid toggle (stress)
        begin
            id_cycle q[$];
            for (int i = 0; i < 8; i++) begin
                if (i % 2 == 0) q.push_back(mk(IDK_RESET_BUBBLE, 32'h0000_0013, 32'h0, 1'b0, 1'b0, 1'b0, 5'd0, 32'h0, 1'b0, 5'd0));
                else            q.push_back(mk(IDK_LEGAL_ALU, id_cycle::enc_r(7'h0, 5'd2, 5'd1, 3'h0, 5'd3, 7'b0110011),
                                                32'h0, 1'b0, 1'b1, 1'b0, 5'd0, 32'h0, 1'b0, 5'd0));
            end
            add_seq("stress_alternating_bubble_valid", q);
        end

        // 12) *** CROSS-SEQUENCE PERSISTENCE CHECK *** - reads x12, written
        //     by sequence 3 several sequences ago with no intervening
        //     write, exactly mirroring tapeout_regfile.sv's own check
        //     (regfile.v is embedded here two levels down; the same
        //     never-reset-storage contract applies at the stage level).
        begin
            id_cycle q[$];
            q.push_back(mk(IDK_RANDOM, id_cycle::enc_r(7'h0, 5'd12, 5'd12, 3'h0, 5'd15, 7'b0110011),
                           32'h0, 1'b0, 1'b1, 1'b0, 5'd0, 32'h0, 1'b0, 5'd0));
            add_seq("cross_sequence_persistence_check_x12", q);
        end

        // 13) CONSTRAINED-RANDOM sequences
        for (int s = 0; s < num_random_seqs; s++) begin
            id_cycle q[$];
            for (int c = 0; c < random_seq_len; c++) begin
                id_cycle t = new();
                assert (t.randomize()) else $error("[GEN] randomize() failed");
                q.push_back(t);
            end
            add_seq($sformatf("crv_seq_%0d", s), q);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 5. REFERENCE MODEL -- composes the SAME independently-structured
//    per-sub-block models used in this set's standalone unit
//    environments (dispatch-table decoder, generic sign_extend()
//    immediate generator, classify-then-compute branch predictor,
//    classify-then-decide hazard unit) with a sparse-map register file -
//    none of it a transcription of id_stage.v's own dataflow.
//
//    STATEFUL exactly like tapeout_regfile.sv, and for the identical
//    reason: this class's `mem` map is the register file two levels down
//    inside the DUT. See this file's header comment for why it must
//    persist across the whole run rather than being reset per sequence.
// -------------------------------------------------------------
typedef struct packed {
    bit         reg_write, mem_read, mem_write, mem_to_reg, alu_src, alu_a_pc;
    bit [3:0]  alu_op;
    bit         branch, jal, jalr, mul_en, dsu_en, csr_en;
    bit [2:0]  csr_op;
    bit         is_system, illegal;
    bit [2:0]  imm_sel;
} id_decode_t;

class id_stage_ref_model;
    bit [31:0] mem [int]; // sparse register-file shadow: persists for the whole run

    // ---- decode (dispatch-table style) ----
    static function id_decode_t decode(bit [31:0] instr);
        bit [6:0] opcode = instr[6:0];
        bit [2:0] f3     = instr[14:12];
        bit [6:0] f7     = instr[31:25];
        id_decode_t r = '{default: 0};
        r.alu_op = `ALU_ADD; r.imm_sel = `IMM_NONE;

        case (opcode)
            7'b0110111: begin r.reg_write=1; r.alu_src=1; r.alu_op=`ALU_PASSB; r.imm_sel=`IMM_U; end
            7'b0010111: begin r.reg_write=1; r.alu_src=1; r.alu_a_pc=1; r.alu_op=`ALU_ADD; r.imm_sel=`IMM_U; end
            7'b1101111: begin r.reg_write=1; r.jal=1; r.imm_sel=`IMM_J; end
            7'b1100111: begin r.reg_write=1; r.jalr=1; r.imm_sel=`IMM_I; end
            7'b1100011: begin r.branch=1; r.alu_op=`ALU_SUB; r.imm_sel=`IMM_B; end
            7'b0000011: begin r.reg_write=1; r.mem_read=1; r.mem_to_reg=1; r.alu_src=1; r.alu_op=`ALU_ADD; r.imm_sel=`IMM_I; end
            7'b0100011: begin r.mem_write=1; r.alu_src=1; r.alu_op=`ALU_ADD; r.imm_sel=`IMM_S; end
            7'b0010011: begin
                r.reg_write=1; r.alu_src=1; r.imm_sel=`IMM_I;
                case (f3)
                    3'b000: r.alu_op=`ALU_ADD; 3'b010: r.alu_op=`ALU_SLT; 3'b011: r.alu_op=`ALU_SLTU;
                    3'b100: r.alu_op=`ALU_XOR; 3'b110: r.alu_op=`ALU_OR; 3'b111: r.alu_op=`ALU_AND;
                    // ERRATUM C-1: RV32I requires instr[31:25] to be exactly
                    // 0000000 for SLLI/SRLI and 0100000 for SRAI; every other
                    // value is reserved and must trap. This model ignored all
                    // of funct7 but bit 5, matching the RTL as written at the
                    // time. rtl/core/decode_control.v was corrected after
                    // riscv-tests rv32mi/shamt showed Spike trapping where
                    // GARUDA did not.
                    3'b001: if (f7 == 7'b0000000) r.alu_op=`ALU_SLL;
                            else                  r.illegal = 1;
                    3'b101: if      (f7 == 7'b0000000) r.alu_op=`ALU_SRL;
                            else if (f7 == 7'b0100000) r.alu_op=`ALU_SRA;
                            else                       r.illegal = 1;
                    default: r.illegal = 1;
                endcase
            end
            7'b0110011: begin
                bit is_muldiv = (f7 == 7'b0000001);
                bit is_mul = is_muldiv && !f3[2];
                bit is_div = is_muldiv && f3[2];
                if (is_mul) begin r.reg_write=1; r.mul_en=1; end
                else if (is_div) begin r.illegal=1; end
                else if (f7 == 7'b0000000 || f7 == 7'b0100000) begin
                    r.reg_write=1;
                    case (f3)
                        3'b000: r.alu_op = f7[5] ? `ALU_SUB : `ALU_ADD;
                        3'b001: r.alu_op=`ALU_SLL; 3'b010: r.alu_op=`ALU_SLT; 3'b011: r.alu_op=`ALU_SLTU;
                        3'b100: r.alu_op=`ALU_XOR;
                        3'b101: r.alu_op = f7[5] ? `ALU_SRA : `ALU_SRL;
                        3'b110: r.alu_op=`ALU_OR; 3'b111: r.alu_op=`ALU_AND;
                        default: r.illegal=1;
                    endcase
                end else begin r.illegal=1; end
            end
            7'b1110011: begin
                r.is_system=1;
                if (f3 != 3'b000) begin r.csr_en=1; r.csr_op=f3; r.reg_write=1; r.imm_sel=`IMM_CSR; end
            end
            7'b0001011: begin r.dsu_en=1; end
            // ERRATUM C-2: FENCE (MISC-MEM, funct3=000) is a no-op on GARUDA -
            // single hart, no cache, nothing to order - but RV32I does not
            // permit it to TRAP, which is what the missing decode case caused.
            // FENCE.I (funct3=001) stays illegal: it is Zifencei, which misa
            // does not advertise, and the prefetch buffer has no flush path.
            // ERRATUM C-3: FENCE.I (funct3=001) is implemented as a redirect
            // to pc+4, which flushes the prefetch buffer. It is no longer
            // illegal. Any OTHER MISC-MEM funct3 still is.
            // ERRATUM C-3: FENCE (000) is a no-op, FENCE.I (001) is a redirect
            // to pc+4 that flushes the prefetch buffer. Neither is illegal.
            7'b0001111: begin if (f3 != 3'b000 && f3 != 3'b001) r.illegal = 1; end
            default: r.illegal=1;
        endcase
        return r;
    endfunction

    // ---- immediate generation ----
    static function bit [31:0] sign_extend(bit [31:0] raw, int width);
        bit sign = raw[width-1];
        bit [31:0] field_mask = (32'h1 << width) - 32'h1;
        return (raw & field_mask) | (sign ? ~field_mask : 32'b0);
    endfunction
    static function bit [31:0] imm_b(bit [31:0] instr);
        return sign_extend({19'b0, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}, 13);
    endfunction
    static function bit [31:0] imm_j(bit [31:0] instr);
        return sign_extend({11'b0, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0}, 21);
    endfunction
    static function bit [31:0] imm_select(bit [31:0] instr, bit [2:0] sel);
        case (sel)
            `IMM_I:   return sign_extend({20'b0, instr[31:20]}, 12);
            `IMM_S:   return sign_extend({20'b0, instr[31:25], instr[11:7]}, 12);
            `IMM_B:   return imm_b(instr);
            `IMM_U:   return {instr[31:12], 12'b0};
            `IMM_J:   return imm_j(instr);
            `IMM_CSR: return {27'b0, instr[19:15]};
            default:  return 32'b0;
        endcase
    endfunction

    // ---- branch prediction ----
    static function bit predict_taken(bit branch_v, bit [31:0] imm_b_v); return branch_v & imm_b_v[31]; endfunction
    // ERRATUM C-3: FENCE.I redirects to pc+4. The redirect IS the flush -
    // garuda_prefetch_buffer drops everything on any redirect - so it must be
    // modelled here or the DUT looks wrong on every FENCE.I.
    static function bit redirect_valid(bit branch_v, bit jal_v, bit fencei_v, bit [31:0] imm_b_v);
        return fencei_v | jal_v | predict_taken(branch_v, imm_b_v);
    endfunction
    static function bit [31:0] redirect_target(bit jal_v, bit fencei_v, bit [31:0] pc_v,
                                               bit [31:0] imm_b_v, bit [31:0] imm_j_v);
        return fencei_v ? (pc_v + 32'd4) :
               jal_v    ? (pc_v + imm_j_v) : (pc_v + imm_b_v);
    endfunction

    // ---- load-use hazard ----
    static function bit load_use_stall(bit [4:0] rs1, bit [4:0] rs2, bit ex_read, bit [4:0] ex_rd);
        if (!ex_read || ex_rd == 0) return 0;
        return (ex_rd == rs1) || (ex_rd == rs2);
    endfunction

    // ---- register-file read/commit (STATEFUL - see header comment) ----
    function automatic bit [31:0] read_reg(bit [4:0] idx, bit bypass_hit, bit [31:0] bypass_data);
        if (idx == 0) return 32'd0;
        if (bypass_hit) return bypass_data;
        if (mem.exists(idx)) return mem[idx];
        return 32'hxxxx_xxxx;
    endfunction

    function automatic void commit_write(bit wb_write, bit [4:0] wb_rd, bit [31:0] wb_data);
        if (wb_write && (wb_rd != 0)) mem[wb_rd] = wb_data;
    endfunction
endclass

// Bundle of every id_stage output the scoreboard checks, so step() below
// can return one object like every stateless model in this set does.
class id_expected;
    id_decode_t decode;
    bit [31:0] imm, rs1_data, rs2_data, pc, redirect_target, instr;
    bit [4:0]  rs1_idx, rs2_idx, rd;
    bit [2:0]  funct3;
    bit         fault, valid, load_use_stall, redirect_valid, predict_taken;
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class id_driver;
    virtual id_stage_if vif;
    function new(virtual id_stage_if vif); this.vif = vif; endfunction

    task apply_cycle(id_cycle c);
        bit [31:0] instr_v, pc_v, wdata_v; bit flt_v, vld_v, wr_v, exr_v; bit [4:0] wrd_v, exrd_v;
        c.fields(instr_v, pc_v, flt_v, vld_v, wr_v, wrd_v, wdata_v, exr_v, exrd_v);
        @(negedge vif.clk);
        vif.if_id_instr  <= instr_v;
        vif.if_id_pc     <= pc_v;
        vif.if_id_fault  <= flt_v;
        vif.if_id_valid  <= vld_v;
        vif.wb_reg_write <= wr_v;
        vif.wb_rd        <= wrd_v;
        vif.wb_data      <= wdata_v;
        vif.ex_mem_read  <= exr_v;
        vif.ex_rd        <= exrd_v;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class id_result;
    id_decode_t decode_actual;
    bit [31:0] rs1_data, rs2_data, imm, pc, instr;
    bit [4:0]  rs1_idx, rs2_idx, rd;
    bit [2:0]  funct3;
    bit         fault, load_use_stall, redirect_valid, predict_taken, valid;
    bit [31:0] redirect_target;
endclass

class id_monitor;
    virtual id_stage_if vif;
    bit [1:0] hazard_class_cov, bypass_class_cov;

    covergroup cg_id_stage;
        cp_opcode: coverpoint vif.if_id_instr[6:0] {
            bins op_lui={7'b0110111}; bins op_auipc={7'b0010111}; bins op_jal={7'b1101111};
            bins op_jalr={7'b1100111}; bins op_branch={7'b1100011}; bins op_load={7'b0000011};
            bins op_store={7'b0100011}; bins op_imm={7'b0010011}; bins op_reg={7'b0110011};
            bins op_system={7'b1110011}; bins op_custom={7'b0001011}; bins op_reserved={7'b1111111};
        }
        cp_valid: coverpoint vif.if_id_valid;
        cp_fault: coverpoint vif.if_id_fault;
        cross cp_valid, cp_fault;

        cp_hazard_class: coverpoint hazard_class_cov { bins none={0}; bins rs1_only={1}; bins rs2_only={2}; bins both={3}; }
        cp_bypass_class: coverpoint bypass_class_cov { bins none={0}; bins rs1_only={1}; bins rs2_only={2}; bins both={3}; }

        cp_stall: coverpoint vif.load_use_stall;
        cross cp_opcode, cp_stall;

        cp_redirect_valid: coverpoint vif.id_redirect_valid;
        cp_predict_taken: coverpoint vif.predict_taken;

        cp_rs1_full: coverpoint vif.rs1_idx { bins each_reg[] = {[0:31]}; }
        cp_rs2_full: coverpoint vif.rs2_idx { bins each_reg[] = {[0:31]}; }
        cp_rd_full:  coverpoint vif.rd      { bins each_reg[] = {[0:31]}; }
    endgroup

    function new(virtual id_stage_if vif);
        this.vif = vif;
        cg_id_stage = new();
    endfunction

    task sample_one(output id_result r);
        #1; // allow combinational logic to settle after apply_cycle()'s NBA update
        r = new();
        r.decode_actual = '{
            reg_write: vif.reg_write, mem_read: vif.mem_read, mem_write: vif.mem_write,
            mem_to_reg: vif.mem_to_reg, alu_src: vif.alu_src, alu_a_pc: vif.alu_a_pc,
            alu_op: vif.alu_op, branch: vif.branch, jal: vif.jal, jalr: vif.jalr,
            mul_en: vif.mul_en, dsu_en: vif.dsu_en, csr_en: vif.csr_en, csr_op: vif.csr_op,
            is_system: vif.is_system, illegal: vif.illegal_instr_dec, imm_sel: 3'b0
        };
        r.rs1_data = vif.rs1_data; r.rs2_data = vif.rs2_data;
        r.imm = vif.imm; r.pc = vif.pc; r.instr = vif.instr;
        r.rs1_idx = vif.rs1_idx; r.rs2_idx = vif.rs2_idx; r.rd = vif.rd; r.funct3 = vif.funct3;
        r.fault = vif.fault; r.load_use_stall = vif.load_use_stall;
        r.redirect_valid = vif.id_redirect_valid; r.redirect_target = vif.id_redirect_target;
        r.predict_taken = vif.predict_taken; r.valid = vif.valid;

        if (!vif.ex_mem_read || vif.ex_rd == 0) hazard_class_cov = 2'd0;
        else if ((vif.ex_rd == vif.rs1_idx) && (vif.ex_rd == vif.rs2_idx)) hazard_class_cov = 2'd3;
        else if (vif.ex_rd == vif.rs1_idx) hazard_class_cov = 2'd1;
        else if (vif.ex_rd == vif.rs2_idx) hazard_class_cov = 2'd2;
        else hazard_class_cov = 2'd0;

        if (!vif.wb_reg_write || vif.wb_rd == 0) bypass_class_cov = 2'd0;
        else if ((vif.wb_rd == vif.rs1_idx) && (vif.wb_rd == vif.rs2_idx)) bypass_class_cov = 2'd3;
        else if (vif.wb_rd == vif.rs1_idx) bypass_class_cov = 2'd1;
        else if (vif.wb_rd == vif.rs2_idx) bypass_class_cov = 2'd2;
        else bypass_class_cov = 2'd0;

        cg_id_stage.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class id_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;

    task check(string seq_name, int cycle_idx, id_cycle c, bit [31:0] instr, bit [31:0] pc_v, bit fault_v, bit valid_v,
               bit wr_v, bit [4:0] wrd_v, bit [31:0] wdata_v, bit exr_v, bit [4:0] exrd_v,
               id_result actual, ref id_stage_ref_model model);
        bit [31:0] eff_instr;
        id_decode_t exp_decode, exp_decode_cmp;
        bit [31:0] exp_imm, exp_imm_b, exp_imm_j;
        bit [4:0]  exp_rs1_idx, exp_rs2_idx, exp_rd;
        bit [2:0]  exp_funct3;
        bit         exp_predict_taken, exp_redirect_valid, exp_fencei;
        bit [31:0] exp_redirect_target;
        bit         exp_stall;
        bit         bypass_rs1, bypass_rs2;
        bit [31:0] exp_rs1_data, exp_rs2_data;
        bit ok;

        eff_instr   = valid_v ? instr : 32'h0000_0013;
        exp_decode  = model.decode(eff_instr);
        exp_rs1_idx = eff_instr[19:15]; exp_rs2_idx = eff_instr[24:20]; exp_rd = eff_instr[11:7];
        exp_funct3  = eff_instr[14:12];

        exp_imm_b = model.imm_b(eff_instr);
        exp_imm_j = model.imm_j(eff_instr);
        exp_imm   = model.imm_select(eff_instr, exp_decode.imm_sel);

        exp_predict_taken   = model.predict_taken(exp_decode.branch, exp_imm_b);
        // FENCE.I derived straight from the encoding rather than carried in
        // decode_result_t: that struct is built by positional assignment
        // patterns in several places, so widening it breaks them.
        exp_fencei = (eff_instr[6:0] == 7'b0001111) && (eff_instr[14:12] == 3'b001);
        exp_redirect_valid  = model.redirect_valid(exp_decode.branch, exp_decode.jal,
                                                   exp_fencei, exp_imm_b);
        exp_redirect_target = model.redirect_target(exp_decode.jal, exp_fencei,
                                                   pc_v, exp_imm_b, exp_imm_j);

        exp_stall = model.load_use_stall(exp_rs1_idx, exp_rs2_idx, exr_v, exrd_v);

        bypass_rs1 = wr_v && (wrd_v != 0) && (wrd_v == exp_rs1_idx);
        bypass_rs2 = wr_v && (wrd_v != 0) && (wrd_v == exp_rs2_idx);
        exp_rs1_data = model.read_reg(exp_rs1_idx, bypass_rs1, wdata_v);
        exp_rs2_data = model.read_reg(exp_rs2_idx, bypass_rs2, wdata_v);

        // id_stage never exposes imm_sel as a port -- EX only needs the
        // resolved immediate (imm/imm_b/imm_j, checked separately below),
        // not which immediate encoding produced it. decode_actual.imm_sel
        // is therefore an unobservable placeholder (always sampled as 0);
        // exclude it from the equality check by comparing against a
        // same-placeholder copy of the expected struct rather than the
        // real expected imm_sel.
        exp_decode_cmp = exp_decode;
        exp_decode_cmp.imm_sel = 3'b0;

        ok = (actual.decode_actual === exp_decode_cmp) &&
             (actual.rs1_idx === exp_rs1_idx) && (actual.rs2_idx === exp_rs2_idx) && (actual.rd === exp_rd) &&
             (actual.funct3 === exp_funct3) && (actual.instr === eff_instr) &&
             (actual.imm === exp_imm) && (actual.pc === pc_v) &&
             (actual.fault === fault_v) && (actual.valid === valid_v) &&
             (actual.load_use_stall === exp_stall) &&
             (actual.redirect_valid === exp_redirect_valid) && (actual.redirect_target === exp_redirect_target) &&
             (actual.predict_taken === exp_predict_taken) &&
             (actual.rs1_data === exp_rs1_data) && (actual.rs2_data === exp_rs2_data);

        if (ok) begin
            pass_cnt++;
            $display("[PASS] seq=%-38s cyc=%0d %s -> reg_write=%0b illegal=%0b stall=%0b redirect=%0b",
                      seq_name, cycle_idx, c.to_string(), actual.decode_actual.reg_write, actual.decode_actual.illegal,
                      actual.load_use_stall, actual.redirect_valid);
        end else begin
            fail_cnt++;
            $display("[FAIL] seq=%-38s cyc=%0d %s (eff_instr=0x%08h)", seq_name, cycle_idx, c.to_string(), eff_instr);
            $display("       decode expected=%p", exp_decode);
            $display("       decode actual  =%p", actual.decode_actual);
            $display("       imm: exp=0x%08h act=0x%08h | rs1_data: exp=0x%08h act=0x%08h | rs2_data: exp=0x%08h act=0x%08h",
                      exp_imm, actual.imm, exp_rs1_data, actual.rs1_data, exp_rs2_data, actual.rs2_data);
            $display("       stall: exp=%0b act=%0b | redirect_valid: exp=%0b act=%0b | redirect_target: exp=0x%08h act=0x%08h",
                      exp_stall, actual.load_use_stall, exp_redirect_valid, actual.redirect_valid, exp_redirect_target, actual.redirect_target);
        end

        // Commit AFTER comparing - mirrors regfile.v's nonblocking write.
        model.commit_write(wr_v, wrd_v, wdata_v);
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class id_env;
    virtual id_stage_if vif;
    id_generator  gen;
    id_driver     drv;
    id_monitor    mon;
    id_scoreboard sb;

    function new(virtual id_stage_if vif, int num_random_seqs = 15, int random_seq_len = 200);
        this.vif = vif;
        gen = new(num_random_seqs, random_seq_len);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        // ONE reference-model instance for the entire run (see the
        // architectural-finding header comment, inherited from
        // tapeout_regfile.sv) - the embedded register file is never
        // "reset" between sequences, matching the real DUT exactly.
        id_stage_ref_model model = new();
        int total_cycles = 0;

        gen.build();

        foreach (gen.seq_q[s]) begin
            foreach (gen.seq_q[s][i]) begin
                id_cycle c = gen.seq_q[s][i];
                bit [31:0] instr_v, pc_v, wdata_v; bit flt_v, vld_v, wr_v, exr_v; bit [4:0] wrd_v, exrd_v;
                id_result actual;
                c.fields(instr_v, pc_v, flt_v, vld_v, wr_v, wrd_v, wdata_v, exr_v, exrd_v);
                drv.apply_cycle(c);
                mon.sample_one(actual);
                sb.check(gen.seq_name[s], i, c, instr_v, pc_v, flt_v, vld_v, wr_v, wrd_v, wdata_v, exr_v, exrd_v, actual, model);
                total_cycles++;
            end
        end

        $display("\n============ ID_STAGE UNIT TB SUMMARY ============");
        $display(" SEQUENCES=%0d  TOTAL_CYCLES=%0d  PASS=%0d  FAIL=%0d", gen.seq_q.size(), total_cycles, sb.pass_cnt, sb.fail_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_id_stage.get_coverage());
        if (sb.fail_cnt == 0)
            $display(" RESULT: ALL CHECKS PASSED");
        else
            $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        $display(" NOTE: see cross_sequence_persistence_check_x12 above - it only");
        $display("       passes because the embedded register file's shadow model");
        $display("       was never reset between sequences (regfile.v's rst_n_i is");
        $display("       dead wiring - see tapeout_regfile.sv for the full finding).");
        $display("====================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class id_test;
    id_env env;
    function new(virtual id_stage_if vif, int num_random_seqs = 15, int random_seq_len = 200);
        env = new(vif, num_random_seqs, random_seq_len);
    endfunction
    task run(); env.run(); endtask
endclass


// -------------------------------------------------------------
// 11. TB TOP
// -------------------------------------------------------------
module tb_top;
    bit clk = 0;
    always #5 clk = ~clk;

    id_stage_if vif(clk);

    id_stage dut (
        .clk_i                 (clk),
        .rst_n_i               (vif.rst_n),
        .if_id_instr_i         (vif.if_id_instr),
        .if_id_pc_i            (vif.if_id_pc),
        .if_id_fault_i         (vif.if_id_fault),
        .if_id_valid_i         (vif.if_id_valid),
        .wb_reg_write_i        (vif.wb_reg_write),
        .wb_rd_i               (vif.wb_rd),
        .wb_data_i             (vif.wb_data),
        .ex_mem_read_i         (vif.ex_mem_read),
        .ex_rd_i               (vif.ex_rd),
        .reg_write_o           (vif.reg_write),
        .mem_read_o            (vif.mem_read),
        .mem_write_o           (vif.mem_write),
        .mem_to_reg_o          (vif.mem_to_reg),
        .alu_src_o             (vif.alu_src),
        .alu_a_pc_o            (vif.alu_a_pc),
        .alu_op_o              (vif.alu_op),
        .branch_o              (vif.branch),
        .jal_o                 (vif.jal),
        .jalr_o                (vif.jalr),
        .mul_en_o              (vif.mul_en),
        .dsu_en_o              (vif.dsu_en),
        .csr_en_o              (vif.csr_en),
        .csr_op_o              (vif.csr_op),
        .is_system_o           (vif.is_system),
        .illegal_instr_dec_o   (vif.illegal_instr_dec),
        .rs1_data_o            (vif.rs1_data),
        .rs2_data_o            (vif.rs2_data),
        .imm_o                 (vif.imm),
        .pc_o                  (vif.pc),
        .rs1_idx_o             (vif.rs1_idx),
        .rs2_idx_o             (vif.rs2_idx),
        .rd_o                  (vif.rd),
        .funct3_o              (vif.funct3),
        .instr_o               (vif.instr),
        .fault_o               (vif.fault),
        .load_use_stall_o      (vif.load_use_stall),
        .id_redirect_valid_o   (vif.id_redirect_valid),
        .id_redirect_target_o  (vif.id_redirect_target),
        .predict_taken_o       (vif.predict_taken),
        .valid_o               (vif.valid)
    );

    id_test test;

    initial begin
        // rst_n_i pulsed exactly once, purely for interface bring-up (see
        // the architectural-finding header comment - it does not clear
        // the embedded register file).
        vif.rst_n = 1'b0;
        vif.if_id_instr = 32'h0000_0013; vif.if_id_pc = 32'h0; vif.if_id_fault = 1'b0; vif.if_id_valid = 1'b0;
        vif.wb_reg_write = 1'b0; vif.wb_rd = 5'd0; vif.wb_data = 32'h0;
        vif.ex_mem_read = 1'b0; vif.ex_rd = 5'd0;
        repeat (2) @(posedge clk);
        vif.rst_n = 1'b1;
        @(posedge clk);

        test = new(vif, 15, 200);
        test.run();
        $finish;
    end
endmodule
