// dsu_pkg.sv - constants of the former dsu_defs.vh
// (zero-waiver F4, 2026-11-16: compiler directives leave the RTL, HAL CDNOTE; only the
// constants the chip uses are here, HAL USEPAR).
package dsu_pkg;
    localparam ACC_FX = 2'b00;
    localparam ACC_FY = 2'b01;
    localparam ACC_MAG = 2'b10;
    localparam int unsigned MAC_CTRL_W = 32'd7;
    localparam int unsigned MAC_CTRL_EN = 32'd6;
    localparam int unsigned MAC_CTRL_ADDSUB = 32'd5;
    localparam int unsigned MAC_CTRL_CLEAR = 32'd4;
    localparam int unsigned MAC_CTRL_LOAD = 32'd3;
    localparam int unsigned MAC_CTRL_ABS = 32'd2;
    localparam int unsigned MAC_CTRL_DOT = 32'd1;
    localparam int unsigned MAC_CTRL_FLUSH = 32'd0;
    localparam FUNCT5_MAC_SEL = 5'd0;
    localparam FUNCT5_MACSUB = 5'd1;
    localparam FUNCT5_MACABS = 5'd2;
    localparam FUNCT5_MACDOT = 5'd3;
    localparam FUNCT5_MACLOAD = 5'd4;
    localparam FUNCT5_MACCLEAR = 5'd5;
    localparam FUNCT5_MACSAT = 5'd6;
    localparam FUNCT5_MACRD_LO = 5'd7;
    localparam FUNCT5_MACRD_HI = 5'd8;
endpackage
