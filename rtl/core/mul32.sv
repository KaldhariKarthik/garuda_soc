//=============================================================================
// GARUDA SoC -- Block I: Processor Core
// mul32.v -- single-cycle 32x32 multiplier (MUL / MULH / MULHSU / MULHU)
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Section 8.2.
//
// Implementation: ONE shared multiplier, not three. Both operands are
// sign-or-zero extended to 33 bits according to funct3, and a single signed
// 33x33 multiply covers all four signedness combinations:
//
//   MUL     (000): result = product[31:0]   (signedness irrelevant for low)
//   MULH    (001): s x s  -> product[63:32]
//   MULHSU  (010): s x u  -> product[63:32]
//   MULHU   (011): u x u  -> product[63:32]
//
// The behavioral '*' is intentional (same policy as the DSU partial-product
// generation): at 250 MHz / 28 nm a synthesized Booth/Wallace tree from the
// '*' operator is the expected implementation and the critical path is the
// full EX cone (multiplier in series with the EX result mux), measured at
// synthesis -- not asserted here. The timing fallback is DIVSEL = 4, i.e.
// hclk 125 MHz (ADR-0001), with no RTL change. Do NOT hand-instantiate a
// multiplier macro here.
// (Was "200 MHz / TRM 100 MHz clock" - stale since ADR-0001.)
//
// This module has no pipeline registers (Section 8.2: "no internal pipeline
// registers").
//=============================================================================

module mul32
    import garuda_pkg::*;
    import core_ex_pkg::*;
(
    input wire [WORD_W-1:0] rs1_val,
    input wire [WORD_W-1:0] rs2_val,
    input wire [FUNCT3_W-1:0] funct3_fld,
    output wire [WORD_W-1:0] result
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned A_EXT_W = 32'd33;
    localparam int unsigned B_EXT_W = 32'd33;
    localparam int unsigned PRODUCT_W = 32'd66;

    // Operand signedness per funct3_fld:
    //   rs1_val is signed for MUL, MULH, MULHSU; unsigned for MULHU.
    //   rs2_val is signed for MUL, MULH;         unsigned for MULHSU, MULHU.
    wire a_signed = (funct3_fld == MUL_MUL) | (funct3_fld == MUL_MULH) |
                    (funct3_fld == MUL_MULHSU);
    wire b_signed = (funct3_fld == MUL_MUL) | (funct3_fld == MUL_MULH);

    wire signed [A_EXT_W-1:0] a_ext = {a_signed & rs1_val[31], rs1_val};
    wire signed [B_EXT_W-1:0] b_ext = {b_signed & rs2_val[31], rs2_val};

    wire signed [PRODUCT_W-1:0] product = a_ext * b_ext;

    assign result = (funct3_fld == MUL_MUL) ? product[31:0]
                                         : product[63:32];

endmodule
