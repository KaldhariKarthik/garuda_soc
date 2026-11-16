// garuda_pkg.sv - constants of the former garuda_defs.vh
// (zero-waiver F4, 2026-11-16: compiler directives leave the RTL, HAL CDNOTE; only the
// constants the chip uses are here, HAL USEPAR).
package garuda_pkg;
    localparam ALU_ADD = 4'h0;
    localparam ALU_SUB = 4'h1;
    localparam ALU_AND = 4'h2;
    localparam ALU_OR = 4'h3;
    localparam ALU_XOR = 4'h4;
    localparam ALU_SLL = 4'h5;
    localparam ALU_SRL = 4'h6;
    localparam ALU_SRA = 4'h7;
    localparam ALU_SLT = 4'h8;
    localparam ALU_SLTU = 4'h9;
    localparam ALU_PASSB = 4'hA;  // LUI: result = operand B (immediate)
    localparam IMM_I = 3'h0;
    localparam IMM_S = 3'h1;
    localparam IMM_B = 3'h2;
    localparam IMM_U = 3'h3;
    localparam IMM_J = 3'h4;
    localparam IMM_CSR = 3'h5;  // 5-bit zero-extended rs1, CSRRWI/SI/CI (Sec. 13.3)
    localparam IMM_NONE = 3'h6;
endpackage
