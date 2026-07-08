//=============================================================================
// GARUDA SoC -- Block I: Processor Core
// alu.v -- 32-bit combinational ALU
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Section 8.1.
// Ten operations: ADD SUB AND OR XOR SLL SRL SRA SLT SLTU.
//
// Doubles as the address adder for loads/stores (op_a = rs1_fwd, op_b = imm,
// alu_op = ADD) and the AUIPC / branch-target adder when op_a is muxed to pc
// upstream. It is NOT the JALR target adder -- that lives in branch_unit.v so
// the link/target computation cannot collide with a coincident ALU use.
//=============================================================================

`include "core_ex_defs.vh"

module alu (
    input  wire [31:0] op_a,
    input  wire [31:0] op_b,
    input  wire [3:0]  alu_op,
    output reg  [31:0] result
);

    wire [4:0] shamt = op_b[4:0];

    always @(*) begin
        case (alu_op)
            `ALU_ADD:  result = op_a + op_b;
            `ALU_SUB:  result = op_a - op_b;
            `ALU_AND:  result = op_a & op_b;
            `ALU_OR:   result = op_a | op_b;
            `ALU_XOR:  result = op_a ^ op_b;
            `ALU_SLL:  result = op_a << shamt;
            `ALU_SRL:  result = op_a >> shamt;
            `ALU_SRA:  result = $signed(op_a) >>> shamt;
            `ALU_SLT:  result = {31'b0, ($signed(op_a) < $signed(op_b))};
            `ALU_SLTU: result = {31'b0, (op_a < op_b)};
            `ALU_PASSB: result = op_b;                    // LUI: pass immediate (Sec. 8.1)
            default:   result = op_a + op_b;   // safe default: ADD
        endcase
    end

endmodule
