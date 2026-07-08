`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block I: Processor Core - ID Stage, Sub-block 2/5
// Immediate Generator  (Verilog)
//
// Spec reference: AERO-GARUDA-DS-001 Rev 1.0, Sec. 7.3
//
// A single combinational immediate generator selects the I/S/B/U/J form
// from opcode and sign-extends to 32 bits. B- and J-immediates are
// pre-shifted (LSB zero); U-immediate is {instr[31:12], 12'b0}.
// The CSR-immediate case (CSRRWI/SI/CI) is a 5-bit zero-extended field
// from rs1, per Sec. 13.3, not a sign-extended form.
// =============================================================================
// -----------------------------------------------------------------------
// ID-stage shared constants (inlined; guarded so this file is safe to
// compile together with other files that also inline this same block)
// -----------------------------------------------------------------------
`ifndef GARUDA_ID_DEFS_VH
`define GARUDA_ID_DEFS_VH

// ALU operation encoding (consumed by EX-stage ALU, Sec. 8.1)
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
`define ALU_PASSB 4'hA   // LUI: result = operand B (immediate)

// Immediate-form select (Sec. 7.3)
`define IMM_I    3'h0
`define IMM_S    3'h1
`define IMM_B    3'h2
`define IMM_U    3'h3
`define IMM_J    3'h4
`define IMM_CSR  3'h5   // 5-bit zero-extended rs1, CSRRWI/SI/CI (Sec. 13.3)
`define IMM_NONE 3'h6

`endif // GARUDA_ID_DEFS_VH

module imm_gen (
    input  wire [31:0] instr_i,
    input  wire [2:0]  imm_sel_i,

    output reg  [31:0] imm_o,
    // B/J target-adder feeds (also needed standalone by Branch-Predict)
    output wire [31:0] imm_b_o,
    output wire [31:0] imm_j_o
);

    wire [31:0] imm_i_f, imm_s_f, imm_b_f, imm_u_f, imm_j_f, imm_csr_f;

    assign imm_i_f   = {{20{instr_i[31]}}, instr_i[31:20]};
    assign imm_s_f   = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
    assign imm_b_f   = {{19{instr_i[31]}}, instr_i[31], instr_i[7],
                         instr_i[30:25], instr_i[11:8], 1'b0};
    assign imm_u_f   = {instr_i[31:12], 12'b0};
    assign imm_j_f   = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12],
                         instr_i[20], instr_i[30:21], 1'b0};
    assign imm_csr_f = {27'b0, instr_i[19:15]};   // zero-extended rs1 field (Sec. 13.3)

    assign imm_b_o = imm_b_f;
    assign imm_j_o = imm_j_f;

    always @(*) begin
        case (imm_sel_i)
            `IMM_I:   imm_o = imm_i_f;
            `IMM_S:   imm_o = imm_s_f;
            `IMM_B:   imm_o = imm_b_f;
            `IMM_U:   imm_o = imm_u_f;
            `IMM_J:   imm_o = imm_j_f;
            `IMM_CSR: imm_o = imm_csr_f;
            default:  imm_o = 32'b0;
        endcase
    end

endmodule
