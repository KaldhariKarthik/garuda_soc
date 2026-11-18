//=============================================================================
// GARUDA SoC -- Block I: Processor Core
// alu_unit.v -- 32-bit combinational ALU
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Section 8.1.
// Ten operations: ADD SUB AND OR XOR SLL SRL SRA SLT SLTU.
//
// Doubles as the address adder for loads/stores (op_a = rs1_fwd, op_b = imm,
// alu_op = ADD) and the AUIPC / branch-target adder when op_a is muxed to pc
// upstream. It is NOT the JALR target adder -- that lives in branch_unit.v so
// the link/target computation cannot collide with a coincident ALU use.
//=============================================================================

module alu_unit
    import garuda_pkg::*;
    import core_ex_pkg::*;
(
    input wire [WORD_W-1:0] op_a,
    input wire [WORD_W-1:0] op_b,
    input wire [ALU_OP_W-1:0] alu_op,
    output reg [WORD_W-1:0] result
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned SHAMTB_W = 32'd5;

    wire [SHAMTB_W-1:0] shamt = op_b[4:0];
    // the signed results, each converted once and explicitly (HAL IMPDTC,
    // MXUANS)
    wire                signed_lt = $signed(op_a) < $signed(op_b);
    wire                unsign_lt = op_a < op_b;
    // both shift operands signed; the amount is non-negative by its zero top
    wire [WORD_W-1:0]   sra_val
        = $unsigned($signed(op_a) >>> $signed({1'b0, shamt}));

    always_comb begin : c_result
        case (alu_op)
            ALU_ADD: result = op_a + op_b;
            ALU_SUB: result = op_a - op_b;
            ALU_AND: result = op_a & op_b;
            ALU_OR: result = op_a | op_b;
            ALU_XOR: result = op_a ^ op_b;
            ALU_SLL: result = op_a << shamt;
            ALU_SRL: result = op_a >> shamt;
            ALU_SRA: result = sra_val;
            ALU_SLT: result = WORD_W'(signed_lt);
            ALU_SLTU: result = WORD_W'(unsign_lt);
            ALU_PASSB: result = op_b;  // LUI: pass immediate (Sec. 8.1)
            default: result = op_a + op_b;  // safe default: ADD
        endcase
    end

endmodule
