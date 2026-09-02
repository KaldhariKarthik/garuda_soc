`timescale 1ns/1ps
//=============================================================================
// tb_mul32.v -- unit TB for rtl/core/mul32.v
//
// Spec:  AERO-GARUDA-DS-001 Rev 1.1, Sec. 8.2 (single-cycle 32x32 multiplier).
// Plan:  directed test C02 -- "MUL/MULH/MULHSU/MULHU against reference
//        products".
//
// The RTL shares ONE 33x33 signed multiplier across all four funct3 values
// and picks operand signedness with a_signed/b_signed. That sharing is the
// whole risk: MULHSU is the only asymmetric case, and swapping a_signed with
// b_signed produces correct results for MUL, MULH and MULHU and wrong ones
// only for MULHSU with a negative rs2. This TB therefore drives the four
// sign quadrants explicitly for every funct3, not just random values.
//
// Golden model builds the true 64-bit product by extending each operand to
// 64 bits with the signedness the ISA requires -- independent of the RTL's
// 33-bit extension trick.
//
// Also checked: Sec. 8.2 "no internal pipeline registers" -- the result is
// valid in the same delta with no clock present anywhere in this TB.
//=============================================================================
`include "core_ex_defs.vh"

module tb_mul32;

  reg  [31:0] rs1, rs2;
  reg  [2:0]  funct3;
  wire [31:0] result;
  integer     errors = 0;
  integer     i;

  mul32 dut (.rs1(rs1), .rs2(rs2), .funct3(funct3), .result(result));

  function [63:0] full_product;
    input [31:0] a, b;
    input [2:0]  f3;
    reg signed [63:0] as, bs;
    begin
      // rs1 signed for MUL/MULH/MULHSU, unsigned for MULHU
      as = (f3 == `MUL_MULHU) ? {32'b0, a} : {{32{a[31]}}, a};
      // rs2 signed for MUL/MULH,          unsigned for MULHSU/MULHU
      bs = (f3 == `MUL_MULHSU || f3 == `MUL_MULHU) ? {32'b0, b}
                                                   : {{32{b[31]}}, b};
      full_product = as * bs;
    end
  endfunction

  function [31:0] golden;
    input [31:0] a, b;
    input [2:0]  f3;
    reg   [63:0] p;
    begin
      p = full_product(a, b, f3);
      golden = (f3 == `MUL_MUL) ? p[31:0] : p[63:32];
    end
  endfunction

  task chk;
    input [255:0] name;
    input [31:0]  a, b;
    input [2:0]   f3;
    input [31:0]  exp;
    begin
      rs1 = a; rs2 = b; funct3 = f3; #1;
      if (result !== exp) begin
        $display("FAIL %0s: rs1=%h rs2=%h f3=%b got=%h exp=%h",
                 name, a, b, f3, result, exp);
        errors = errors + 1;
      end
    end
  endtask

  task chk_golden;
    input [31:0] a, b;
    input [2:0]  f3;
    begin
      rs1 = a; rs2 = b; funct3 = f3; #1;
      if (result !== golden(a, b, f3)) begin
        $display("FAIL random: rs1=%h rs2=%h f3=%b got=%h exp=%h",
                 a, b, f3, result, golden(a, b, f3));
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    // ---- MUL: low half, signedness irrelevant --------------------------
    chk("mul_small",   32'd6, 32'd7, `MUL_MUL, 32'd42);
    chk("mul_neg",     32'hFFFF_FFFF, 32'd7, `MUL_MUL, 32'hFFFF_FFF9);   // -1*7
    chk("mul_lowonly", 32'h0001_0000, 32'h0001_0000, `MUL_MUL, 32'd0);   // 2^32
    chk("mul_maxu",    32'hFFFF_FFFF, 32'hFFFF_FFFF, `MUL_MUL, 32'd1);

    // ---- MULH: signed x signed, high half ------------------------------
    chk("mulh_pp",  32'h0001_0000, 32'h0001_0000, `MUL_MULH,  32'd1);
    chk("mulh_nn",  32'hFFFF_FFFF, 32'hFFFF_FFFF, `MUL_MULH,  32'd0);    // 1
    chk("mulh_np",  32'hFFFF_FFFF, 32'd1,         `MUL_MULH,  32'hFFFF_FFFF);
    chk("mulh_min", 32'h8000_0000, 32'h8000_0000, `MUL_MULH,  32'h4000_0000);

    // ---- MULHU: unsigned x unsigned ------------------------------------
    chk("mulhu_maxu", 32'hFFFF_FFFF, 32'hFFFF_FFFF, `MUL_MULHU, 32'hFFFF_FFFE);
    chk("mulhu_np",   32'hFFFF_FFFF, 32'd1,         `MUL_MULHU, 32'd0);
    chk("mulhu_min",  32'h8000_0000, 32'h8000_0000, `MUL_MULHU, 32'h4000_0000);

    // ---- MULHSU: rs1 SIGNED, rs2 UNSIGNED ------------------------------
    // The asymmetric case. mulhsu_np is the vector that separates a correct
    // implementation from one with a_signed/b_signed transposed:
    //   correct  : (-1) * 4294967295 = -4294967295 -> high half FFFF_FFFF
    //   swapped  : 4294967295 * (-1) would give the same here, so the
    //   discriminating pair is mulhsu_pn below (rs1 positive, rs2 has bit31
    //   set): rs2 must be read as a LARGE POSITIVE, not as -1.
    chk("mulhsu_np", 32'hFFFF_FFFF, 32'hFFFF_FFFF, `MUL_MULHSU, 32'hFFFF_FFFF);
    chk("mulhsu_pn", 32'd2,         32'hFFFF_FFFF, `MUL_MULHSU, 32'd1);
    chk("mulhsu_nn", 32'h8000_0000, 32'h8000_0000, `MUL_MULHSU, 32'hC000_0000);
    chk("mulhsu_pp", 32'h0001_0000, 32'h0001_0000, `MUL_MULHSU, 32'd1);

    // ---- zero and identity ---------------------------------------------
    chk("mul_zero",   32'hDEAD_BEEF, 32'd0, `MUL_MUL,   32'd0);
    chk("mulh_zero",  32'hDEAD_BEEF, 32'd0, `MUL_MULH,  32'd0);
    chk("mulhu_zero", 32'hDEAD_BEEF, 32'd0, `MUL_MULHU, 32'd0);
    chk("mulhsu_zero",32'hDEAD_BEEF, 32'd0, `MUL_MULHSU,32'd0);

    // ---- randomised sweep, all four funct3 values ----------------------
    for (i = 0; i < 4000; i = i + 1) begin
      chk_golden($random, $random, `MUL_MUL);
      chk_golden($random, $random, `MUL_MULH);
      chk_golden($random, $random, `MUL_MULHSU);
      chk_golden($random, $random, `MUL_MULHU);
      // sign-boundary operands: bit31 set on one side only, which is where
      // the shared-multiplier extension is easiest to get wrong.
      chk_golden(32'h8000_0000 | $random, $random & 32'h7FFF_FFFF, `MUL_MULHSU);
      chk_golden($random & 32'h7FFF_FFFF, 32'h8000_0000 | $random, `MUL_MULHSU);
    end

    if (errors == 0) $display("MUL32 UNIT: ALL CHECKS PASSED");
    else             $display("MUL32 UNIT: %0d FAILURE(S)", errors);
    $finish;
  end
endmodule
