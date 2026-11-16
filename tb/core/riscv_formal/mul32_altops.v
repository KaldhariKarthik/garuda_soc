// mul32_altops.v -- FORMAL ONLY: mul32 replaced by riscv-formal's
// RISCV_FORMAL_ALTOPS functions (riscv-formal/insns/insn_mul*.v, low 32 bits of
// each mask), the standard way riscv-formal checks a multiplier's integration
// without bit-blasting a 32x32 product. The real mul32 arithmetic is verified
// by its unit bench (tb_mul32) and in simulation against Spike.
`timescale 1ns/1ps
module mul32 (
    input  wire [31:0] rs1_val,
    input  wire [31:0] rs2_val,
    input  wire [2:0]  funct3_fld,
    output wire [31:0] result
);
    assign result = (funct3_fld[1:0] == 2'd0) ? ((rs1_val + rs2_val) ^ 32'h5876063e) :   // MUL
                    (funct3_fld[1:0] == 2'd1) ? ((rs1_val + rs2_val) ^ 32'hf6583fb7) :   // MULH
                    (funct3_fld[1:0] == 2'd2) ? ((rs1_val - rs2_val) ^ 32'hecfbe137) :   // MULHSU
                                            ((rs1_val + rs2_val) ^ 32'h949ce5e8);    // MULHU
endmodule
