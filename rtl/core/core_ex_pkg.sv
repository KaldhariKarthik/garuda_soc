// core_ex_pkg.sv - constants of the former core_ex_defs.vh
// (zero-waiver F4, 2026-11-16: compiler directives leave the RTL, HAL CDNOTE; only the
// constants the chip uses are here, HAL USEPAR).
package core_ex_pkg;
    localparam FWD_NONE = 2'b00;  // register-file value (no hazard)
    localparam FWD_EXMEM = 2'b01;  // EX/MEM result  (EX->EX,  distance 1)
    localparam FWD_MEMWB = 2'b10;  // MEM/WB result  (MEM->EX, distance 2)
    localparam BR_BEQ = 3'b000;
    localparam BR_BNE = 3'b001;
    localparam BR_BLT = 3'b100;
    localparam BR_BGE = 3'b101;
    localparam BR_BLTU = 3'b110;
    localparam BR_BGEU = 3'b111;
    localparam MUL_MUL = 3'b000;
    localparam MUL_MULH = 3'b001;
    localparam MUL_MULHSU = 3'b010;
    localparam CSR_RW = 2'b01;
    localparam CSR_RS = 2'b10;
    localparam CSR_RC = 2'b11;
endpackage
