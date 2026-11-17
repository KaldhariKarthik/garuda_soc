// mem_pkg.sv - constants of the former mem_defs.vh
// (zero-waiver F4, 2026-11-16: compiler directives leave the RTL, HAL CDNOTE;
// only the constants the chip uses are here, HAL USEPAR).
package mem_pkg;
    localparam int unsigned MEM_ISRAM_WORDS = 32'd16384;  // 64 KB / 4
    localparam int unsigned MEM_BROM_WORDS = 32'd1024;  //  4 KB / 4
    localparam int unsigned MEM_DSRAM_BANK_WORDS = 32'd4096;  // 16 KB per bank
    localparam MEM_SIZE_BYTE = 3'b000;
    localparam MEM_SIZE_HALF = 3'b001;
    localparam MEM_SIZE_WORD = 3'b010;
endpackage
