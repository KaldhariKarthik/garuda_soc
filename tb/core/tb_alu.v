`timescale 1ns/1ps
//=============================================================================
// tb_alu.v -- unit TB for rtl/core/alu.v
//
// Spec:  AERO-GARUDA-DS-001 Rev 1.1, Sec. 8.1 (32-bit combinational ALU).
// Plan:  supports C01 (RV32I base ISA) and C05 (dependent ALU chains) at the
//        unit level -- every op is checked against an independent golden
//        expression, so an encoding swap in garuda_defs.vh cannot pass here.
//
// Checked, per Sec. 8.1:
//   * All ten named ops ADD SUB AND OR XOR SLL SRL SRA SLT SLTU.
//   * ALU_PASSB (LUI leg) returns op_b untouched -- this is the encoding that
//     "drifted" per the garuda_defs.vh header note, so it is checked by value.
//   * Shift amount is op_b[4:0] ONLY: shifting by 32/33/0xFFFF_FFE1 must give
//     the same result as shifting by 0/1/1. A 32-bit shifter that used the
//     full op_b would return 0 and pass a naive directed test.
//   * SRA is arithmetic (sign replicated), SRL is logical.
//   * SLT is signed, SLTU unsigned -- the -1 vs 1 pair separates them.
//   * default: an unmapped alu_op falls back to ADD (Sec. 8.1 "safe default").
//   * Randomised sweep vs a golden model, all ops, 2000 vectors.
//=============================================================================
`include "garuda_defs.vh"

module tb_alu;

  reg  [31:0] op_a, op_b;
  reg  [3:0]  alu_op;
  wire [31:0] result;
  integer     errors = 0;
  integer     i, j;

  alu dut (.op_a(op_a), .op_b(op_b), .alu_op(alu_op), .result(result));

  // Golden model -- deliberately written from the SPEC text, not copied from
  // the RTL case statement, so a shared typo cannot cancel out.
  function [31:0] golden;
    input [31:0] a, b;
    input [3:0]  op;
    reg   [4:0]  sh;
    begin
      sh = b[4:0];
      case (op)
        `ALU_ADD:   golden = a + b;
        `ALU_SUB:   golden = a - b;
        `ALU_AND:   golden = a & b;
        `ALU_OR:    golden = a | b;
        `ALU_XOR:   golden = a ^ b;
        `ALU_SLL:   golden = a << sh;
        `ALU_SRL:   golden = a >> sh;
        `ALU_SRA:   golden = $signed(a) >>> sh;
        `ALU_SLT:   golden = {31'b0, ($signed(a) <  $signed(b))};
        `ALU_SLTU:  golden = {31'b0, (a < b)};
        `ALU_PASSB: golden = b;
        default:    golden = a + b;
      endcase
    end
  endfunction

  task chk;                       // apply + compare against an explicit value
    input [255:0] name;
    input [31:0]  a, b;
    input [3:0]   op;
    input [31:0]  exp;
    begin
      op_a = a; op_b = b; alu_op = op; #1;
      if (result !== exp) begin
        $display("FAIL %0s: a=%h b=%h op=%h got=%h exp=%h",
                 name, a, b, op, result, exp);
        errors = errors + 1;
      end
    end
  endtask

  task chk_golden;                // apply + compare against the golden model
    input [31:0] a, b;
    input [3:0]  op;
    begin
      op_a = a; op_b = b; alu_op = op; #1;
      if (result !== golden(a, b, op)) begin
        $display("FAIL random: a=%h b=%h op=%h got=%h exp=%h",
                 a, b, op, result, golden(a, b, op));
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    // ---- arithmetic (Sec. 8.1) ----------------------------------------
    chk("add",          32'd7,        32'd5,        `ALU_ADD,   32'd12);
    chk("add_wrap",     32'hFFFF_FFFF,32'd1,        `ALU_ADD,   32'd0);
    chk("sub",          32'd7,        32'd5,        `ALU_SUB,   32'd2);
    chk("sub_borrow",   32'd0,        32'd1,        `ALU_SUB,   32'hFFFF_FFFF);

    // ---- logic --------------------------------------------------------
    chk("and", 32'hF0F0_AAAA, 32'h0FF0_5555, `ALU_AND, 32'h00F0_0000);
    chk("or",  32'hF0F0_AAAA, 32'h0FF0_5555, `ALU_OR,  32'hFFF0_FFFF);
    chk("xor", 32'hF0F0_AAAA, 32'h0FF0_5555, `ALU_XOR, 32'hFF00_FFFF);

    // ---- shifts: amount is op_b[4:0] ONLY -----------------------------
    chk("sll_1",        32'h0000_0001, 32'd1,  `ALU_SLL, 32'h0000_0002);
    chk("sll_31",       32'h0000_0001, 32'd31, `ALU_SLL, 32'h8000_0000);
    chk("sll_mask32",   32'h0000_00FF, 32'd32, `ALU_SLL, 32'h0000_00FF); // shamt=0
    chk("sll_mask33",   32'h0000_00FF, 32'd33, `ALU_SLL, 32'h0000_01FE); // shamt=1
    chk("sll_maskneg",  32'h0000_00FF, 32'hFFFF_FFE1, `ALU_SLL, 32'h0000_01FE);
    chk("srl_logical",  32'h8000_0000, 32'd31, `ALU_SRL, 32'h0000_0001);
    chk("srl_mask32",   32'hDEAD_BEEF, 32'd32, `ALU_SRL, 32'hDEAD_BEEF);
    chk("sra_neg",      32'h8000_0000, 32'd31, `ALU_SRA, 32'hFFFF_FFFF);
    chk("sra_pos",      32'h4000_0000, 32'd30, `ALU_SRA, 32'h0000_0001);
    chk("sra_mask32",   32'hFFFF_0000, 32'd32, `ALU_SRA, 32'hFFFF_0000);

    // ---- comparisons: signed vs unsigned ------------------------------
    chk("slt_neg_lt_pos",  32'hFFFF_FFFF, 32'd1, `ALU_SLT,  32'd1); // -1 < 1
    chk("sltu_neg_gt_pos", 32'hFFFF_FFFF, 32'd1, `ALU_SLTU, 32'd0); // 4G > 1
    chk("slt_equal",       32'd5,         32'd5, `ALU_SLT,  32'd0);
    chk("sltu_equal",      32'd5,         32'd5, `ALU_SLTU, 32'd0);
    chk("slt_pos",         32'd4,         32'd5, `ALU_SLT,  32'd1);

    // ---- LUI leg (Sec. 8.1): result = op_b, op_a ignored ---------------
    chk("passb",        32'hDEAD_BEEF, 32'h1234_5000, `ALU_PASSB, 32'h1234_5000);
    chk("passb_zero_b", 32'hDEAD_BEEF, 32'h0000_0000, `ALU_PASSB, 32'h0000_0000);

    // ---- unmapped encodings fall back to ADD ---------------------------
    chk("default_b", 32'd10, 32'd20, 4'hB, 32'd30);
    chk("default_f", 32'd10, 32'd20, 4'hF, 32'd30);

    // ---- randomised sweep over the 11 defined ops ----------------------
    for (i = 0; i < 2000; i = i + 1) begin
      for (j = 0; j <= 10; j = j + 1)
        chk_golden($random, $random, j[3:0]);
      // shift-heavy vectors: force op_b into the 0..63 range so the
      // [4:0] masking boundary is hit far more often than $random gives.
      chk_golden($random, ($random & 32'd63), `ALU_SLL);
      chk_golden($random, ($random & 32'd63), `ALU_SRL);
      chk_golden($random, ($random & 32'd63), `ALU_SRA);
    end

    if (errors == 0) $display("ALU UNIT: ALL CHECKS PASSED");
    else             $display("ALU UNIT: %0d FAILURE(S)", errors);
    $finish;
  end
endmodule
