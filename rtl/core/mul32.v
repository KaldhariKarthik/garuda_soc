`timescale 1ns/1ps
`default_nettype none
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
// generation): at 200 MHz / 28 nm a synthesized Booth/Wallace tree from the
// '*' operator is the expected implementation and the critical path is the
// full EX cone (multiplier in series with the EX result mux), measured at
// synthesis -- not asserted here. Fallback per Section 8.2 timing note is the
// TRM 100 MHz clock, no RTL change. Do NOT hand-instantiate a multiplier
// macro here.
//
// This module has no pipeline registers (Section 8.2: "no internal pipeline
// registers").
//=============================================================================

`include "core_ex_defs.vh"

module mul32 (
    input  wire [31:0] rs1,
    input  wire [31:0] rs2,
    input  wire [2:0]  funct3,
    output wire [31:0] result
);

    // Operand signedness per funct3:
    //   rs1 is signed for MUL, MULH, MULHSU; unsigned for MULHU.
    //   rs2 is signed for MUL, MULH;         unsigned for MULHSU, MULHU.
    wire a_signed = (funct3 == `MUL_MUL) | (funct3 == `MUL_MULH) |
                    (funct3 == `MUL_MULHSU);
    wire b_signed = (funct3 == `MUL_MUL) | (funct3 == `MUL_MULH);

    wire signed [32:0] a_ext = {a_signed & rs1[31], rs1};
    wire signed [32:0] b_ext = {b_signed & rs2[31], rs2};

    wire signed [65:0] product = a_ext * b_ext;

    assign result = (funct3 == `MUL_MUL) ? product[31:0]
                                         : product[63:32];

endmodule

`default_nettype wire
