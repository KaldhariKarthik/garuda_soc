// ahb_pkg.sv - constants of the former ahb_defs.vh
// (zero-waiver F4, 2026-11-16: compiler directives leave the RTL, HAL CDNOTE;
// only the constants the chip uses are here, HAL USEPAR).
package ahb_pkg;
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned AHB_NMASTERS = 32'd4;
    localparam AHB_M_IPORT = 2'd0;  // M0 - CPU I-Port   (lowest priority)
    localparam AHB_M_DPORT = 2'd1;  // M1 - CPU D-Port
    localparam AHB_M_SBA = 2'd2;  // M2 - Debug SBA    (Rev 4.0, ADR-0004/0012)
    localparam AHB_M_DMA = 2'd3;  // M3 - DMA          (highest priority)
    localparam int unsigned AHB_S_ISRAM = 32'd0;  // 0x0000_0000, 64 KB
    // 0x1000_0000, 4 KB (reset vector)
    localparam int unsigned AHB_S_ROM = 32'd1;
    localparam int unsigned AHB_S_DSRAM = 32'd2;  // 0x2000_0000, 64 KB
    // 0x4000_0000, APB peripherals
    localparam int unsigned AHB_S_BRIDGE = 32'd3;
    localparam int unsigned AHB_S_DEFAULT = 32'd4;  // everything else
    // width of the one-hot select vector
    localparam int unsigned AHB_SEL_W = 32'd5;
    localparam AHB_RGN_ISRAM = 4'h0;
    localparam AHB_RGN_ROM = 4'h1;
    localparam AHB_RGN_DSRAM = 4'h2;
    localparam AHB_RGN_BRIDGE = 4'h4;
    localparam AHB_TRANS_NONSEQ = 2'b10;
    localparam AHB_TRANS_SEQ = 2'b11;
    localparam AHB_RESP_OKAY = 1'b0;
    localparam AHB_RESP_ERROR = 1'b1;
    localparam int unsigned AHB_RGN_W = 32'd4;  // HADDR[31:28], the region
endpackage
