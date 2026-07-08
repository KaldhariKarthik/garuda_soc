`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block I: Processor Core
// ID Stage (top level) - instantiates the 5 sub-blocks shown on the core
// block diagram: Decode/Control, Immediate Gen, Register File,
// Branch Predict, Hazard/Forwarding.  (Verilog)
//
// Spec reference: AERO-GARUDA-DS-001 Rev 1.0, Sec. 5, Sec. 7, Sec. 11.1-11.2, Sec. 12.1-12.2
// =============================================================================

module id_stage (
    input  wire         clk_i,
    input  wire         rst_n_i,

    // -------------------------------------------------------------------
    // From IF/ID pipeline register (Sec. 5.2 - instr, pc, fault, valid)
    // -------------------------------------------------------------------
    input  wire [31:0] if_id_instr_i,
    input  wire [31:0] if_id_pc_i,
    input  wire         if_id_fault_i,   // I-port access-fault tag, carried through
    input  wire         if_id_valid_i,

    // -------------------------------------------------------------------
    // Register-file write port (from WB stage)
    // -------------------------------------------------------------------
    input  wire         wb_reg_write_i,
    input  wire [4:0]  wb_rd_i,
    input  wire [31:0] wb_data_i,

    // -------------------------------------------------------------------
    // Load-use hazard inputs: instruction currently in EX (Sec. 11.2)
    // -------------------------------------------------------------------
    input  wire         ex_mem_read_i,
    input  wire [4:0]  ex_rd_i,

    // -------------------------------------------------------------------
    // Outputs to id_ex pipeline register (Sec. 5.2 field list)
    // -------------------------------------------------------------------
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
    output wire         illegal_instr_dec_o,   // decode-side illegal (combined below)

    output wire [31:0] rs1_data_o,
    output wire [31:0] rs2_data_o,
    output wire [31:0] imm_o,
    output wire [31:0] pc_o,
    output wire [4:0]  rs1_idx_o,
    output wire [4:0]  rs2_idx_o,
    output wire [4:0]  rd_o,
    output wire [2:0]  funct3_o,
    output wire [31:0] instr_o,
    output wire         fault_o,        // propagate I-port fault tag to CONTROL (Sec. 6.4/Sec. 14.1)

    // -------------------------------------------------------------------
    // Load-use hazard output (Sec. 11.2) - raw signal; hold/flush composition
    // is done downstream per Sec. 11.4
    // -------------------------------------------------------------------
    output wire         load_use_stall_o,

    // -------------------------------------------------------------------
    // ID-stage redirect: static-predicted-taken branch, or JAL (Sec. 12.1/12.2)
    // -------------------------------------------------------------------
    output wire         id_redirect_valid_o,
    output wire [31:0] id_redirect_target_o,

    // -------------------------------------------------------------------
    // Static prediction bit -> id_ex register (Sec. 5.2 field list).
    // EX resolves the actual branch condition and compares against this
    // to detect a misprediction (predicted-taken backward branch that
    // falls through, or predicted-not-taken forward branch that is taken)
    // and drive its own 2-bubble EX redirect. Previously this bit was
    // computed in branch_predict but dropped here; it must ride id_ex.
    // -------------------------------------------------------------------
    output wire         predict_taken_o
);

    // -----------------------------------------------------------------------
    // Sub-block 1: Decode / Control
    // -----------------------------------------------------------------------
    wire [6:0] opcode_w;
    wire [4:0] rd_w, rs1_idx_w, rs2_idx_w;
    wire [2:0] funct3_w;
    wire [2:0] imm_sel_w;

    decode_control u_decode_control (
        .instr_i          (if_id_instr_i),

        .opcode_o          (opcode_w),
        .rd_o              (rd_w),
        .funct3_o          (funct3_w),
        .rs1_o             (rs1_idx_w),
        .rs2_o             (rs2_idx_w),

        .reg_write_o       (reg_write_o),
        .mem_read_o        (mem_read_o),
        .mem_write_o       (mem_write_o),
        .mem_to_reg_o      (mem_to_reg_o),
        .alu_src_o         (alu_src_o),
        .alu_a_pc_o        (alu_a_pc_o),
        .alu_op_o          (alu_op_o),
        .branch_o          (branch_o),
        .jal_o             (jal_o),
        .jalr_o            (jalr_o),
        .mul_en_o          (mul_en_o),
        .dsu_en_o          (dsu_en_o),
        .csr_en_o          (csr_en_o),
        .csr_op_o          (csr_op_o),
        .is_system_o       (is_system_o),
        .illegal_instr_o   (illegal_instr_dec_o),
        .imm_sel_o         (imm_sel_w)
    );

    // -----------------------------------------------------------------------
    // Sub-block 2: Immediate Generator
    // -----------------------------------------------------------------------
    wire [31:0] imm_w;
    wire [31:0] imm_b_w, imm_j_w;

    imm_gen u_imm_gen (
        .instr_i    (if_id_instr_i),
        .imm_sel_i  (imm_sel_w),

        .imm_o      (imm_w),
        .imm_b_o    (imm_b_w),
        .imm_j_o    (imm_j_w)
    );

    // -----------------------------------------------------------------------
    // Sub-block 3: Register File
    // -----------------------------------------------------------------------
    wire [31:0] rs1_data_w, rs2_data_w;

    regfile u_regfile (
        .clk_i           (clk_i),
        .rst_n_i         (rst_n_i),

        .rs1_idx_i       (rs1_idx_w),
        .rs2_idx_i       (rs2_idx_w),

        .wb_reg_write_i  (wb_reg_write_i),
        .wb_rd_i         (wb_rd_i),
        .wb_data_i       (wb_data_i),

        .rs1_data_o      (rs1_data_w),
        .rs2_data_o      (rs2_data_w)
    );

    // -----------------------------------------------------------------------
    // Sub-block 4: Branch Predict
    // -----------------------------------------------------------------------
    branch_predict u_branch_predict (
        .pc_i                    (if_id_pc_i),
        .imm_b_i                 (imm_b_w),
        .imm_j_i                 (imm_j_w),
        .branch_i                (branch_o),
        .jal_i                   (jal_o),

        .predict_taken_o         (predict_taken_o),   // -> id_ex (Sec. 5.2)
        .id_redirect_valid_o     (id_redirect_valid_o),
        .id_redirect_target_o    (id_redirect_target_o)
    );

    // -----------------------------------------------------------------------
    // Sub-block 5: Hazard / Forwarding unit (ID-side load-use detection)
    // -----------------------------------------------------------------------
    hazard_forward_unit u_hazard_forward_unit (
        .id_rs1_idx_i     (rs1_idx_w),
        .id_rs2_idx_i     (rs2_idx_w),

        .ex_mem_read_i    (ex_mem_read_i),
        .ex_rd_i          (ex_rd_i),

        .load_use_stall_o (load_use_stall_o)
    );

    // -----------------------------------------------------------------------
    // Pass-through / bundle outputs to id_ex pipeline register
    // -----------------------------------------------------------------------
    assign rs1_data_o = rs1_data_w;
    assign rs2_data_o = rs2_data_w;
    assign imm_o        = imm_w;
    assign pc_o         = if_id_pc_i;
    assign rs1_idx_o    = rs1_idx_w;
    assign rs2_idx_o    = rs2_idx_w;
    assign rd_o         = rd_w;
    assign funct3_o     = funct3_w;
    assign instr_o      = if_id_instr_i;
    assign fault_o      = if_id_fault_i;

endmodule
