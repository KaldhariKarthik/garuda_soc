`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block I: Processor Core
// id_ex.v - ID/EX Pipeline Register (Sec. 5.2)  [FROZEN FIELD LIST]
// Document: AERO-GARUDA-DS-001 Rev 1.1
//
// Carries the full ID->EX contract. Corrections vs the original Sec. 5.2 table:
//   - pc            : carried through (AUIPC/branch base AND mepc; flows to ex_mem)
//   - predicted_taken: added (was absent) - EX misprediction resolve (Sec.12.3)
//   - csr_op[1:0]/csr_imm : the funct3 split (csr_op=funct3[1:0], csr_imm=funct3[2])
// is_system / illegal_instr_dec / fault ride here around EX to CONTROL (Sec.14).
//
// CONTROL (Sec. 11.3 / 11.4):
//   stall_i - hold contents (DSU hold retains the in-flight DSU op; also the
//             PC/IF-ID/ID-EX hold leg of a D-port wait).
//   flush_i - bubble (all write-enables low; canonical NOP 0x13). Load-use,
//             branch mispredict, trap/MRET.
//   Priority: flush strictly wins over stall (Sec. 11.4) - a squashed op is
//   discarded anyway. Reset => bubble.
// =============================================================================
module id_ex (
    input  wire        clk_i,
    input  wire        rst_n_i,
    input  wire        stall_i,        // hold (DSU hold / D-port wait leg)
    input  wire        flush_i,        // bubble (load-use / mispredict / trap)

    // ---- data ----
    input  wire [31:0] pc_i,
    input  wire [31:0] instr_i,
    input  wire [31:0] rs1_data_i,
    input  wire [31:0] rs2_data_i,
    input  wire [31:0] imm_i,
    input  wire [4:0]  rs1_idx_i,
    input  wire [4:0]  rs2_idx_i,
    input  wire [4:0]  rd_i,
    input  wire [2:0]  funct3_i,
    // ---- ctrl (to EX) ----
    input  wire        reg_write_i,
    input  wire        mem_read_i,
    input  wire        mem_write_i,
    input  wire        mem_to_reg_i,
    input  wire        alu_src_i,
    input  wire        pc_op_a_i,       // <- id_stage.alu_a_pc_o
    input  wire [3:0]  alu_op_i,
    input  wire        branch_i,
    input  wire        jal_i,
    input  wire        jalr_i,
    input  wire        predicted_taken_i,
    input  wire        mul_en_i,
    input  wire        dsu_en_i,
    input  wire        csr_en_i,
    input  wire        csr_imm_i,       // <- id_stage.csr_op_o[2]
    input  wire [1:0]  csr_op_i,        // <- id_stage.csr_op_o[1:0]
    // ---- ctrl (around EX, to CONTROL) ----
    input  wire        is_system_i,
    input  wire        illegal_instr_dec_i,
    input  wire        fault_i,

    // ---- outputs (same names, _o) ----
    output reg  [31:0] pc_o,
    output reg  [31:0] instr_o,
    output reg  [31:0] rs1_data_o,
    output reg  [31:0] rs2_data_o,
    output reg  [31:0] imm_o,
    output reg  [4:0]  rs1_idx_o,
    output reg  [4:0]  rs2_idx_o,
    output reg  [4:0]  rd_o,
    output reg  [2:0]  funct3_o,
    output reg         reg_write_o,
    output reg         mem_read_o,
    output reg         mem_write_o,
    output reg         mem_to_reg_o,
    output reg         alu_src_o,
    output reg         pc_op_a_o,
    output reg  [3:0]  alu_op_o,
    output reg         branch_o,
    output reg         jal_o,
    output reg         jalr_o,
    output reg         predicted_taken_o,
    output reg         mul_en_o,
    output reg         dsu_en_o,
    output reg         csr_en_o,
    output reg         csr_imm_o,
    output reg  [1:0]  csr_op_o,
    output reg         is_system_o,
    output reg         illegal_instr_dec_o,
    output reg         fault_o
);
    // Control fields that must be NOP-safe in a bubble.
    task set_bubble;
        begin
            reg_write_o<=1'b0; mem_read_o<=1'b0; mem_write_o<=1'b0; mem_to_reg_o<=1'b0;
            branch_o<=1'b0; jal_o<=1'b0; jalr_o<=1'b0; predicted_taken_o<=1'b0;
            mul_en_o<=1'b0; dsu_en_o<=1'b0; csr_en_o<=1'b0;
            is_system_o<=1'b0; illegal_instr_dec_o<=1'b0; fault_o<=1'b0;
            // data + benign ctrl -> NOP (addi x0,x0,0)
            instr_o<=32'h0000_0013; alu_op_o<=4'h0; alu_src_o<=1'b0; pc_op_a_o<=1'b0;
            csr_imm_o<=1'b0; csr_op_o<=2'b00;
            rd_o<=5'd0; rs1_idx_o<=5'd0; rs2_idx_o<=5'd0; funct3_o<=3'd0;
            pc_o<=32'd0; rs1_data_o<=32'd0; rs2_data_o<=32'd0; imm_o<=32'd0;
        end
    endtask

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i)      set_bubble;
        else if (flush_i)  set_bubble;          // flush strictly > stall (Sec.11.4)
        else if (stall_i)  ;                     // hold: retain all outputs
        else begin
            pc_o<=pc_i; instr_o<=instr_i; rs1_data_o<=rs1_data_i; rs2_data_o<=rs2_data_i;
            imm_o<=imm_i; rs1_idx_o<=rs1_idx_i; rs2_idx_o<=rs2_idx_i; rd_o<=rd_i; funct3_o<=funct3_i;
            reg_write_o<=reg_write_i; mem_read_o<=mem_read_i; mem_write_o<=mem_write_i;
            mem_to_reg_o<=mem_to_reg_i; alu_src_o<=alu_src_i; pc_op_a_o<=pc_op_a_i;
            alu_op_o<=alu_op_i; branch_o<=branch_i; jal_o<=jal_i; jalr_o<=jalr_i;
            predicted_taken_o<=predicted_taken_i; mul_en_o<=mul_en_i; dsu_en_o<=dsu_en_i;
            csr_en_o<=csr_en_i; csr_imm_o<=csr_imm_i; csr_op_o<=csr_op_i;
            is_system_o<=is_system_i; illegal_instr_dec_o<=illegal_instr_dec_i; fault_o<=fault_i;
        end
    end
endmodule
`default_nettype wire
