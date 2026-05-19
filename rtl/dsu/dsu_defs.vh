`ifndef DSU_DEFS_VH
`define DSU_DEFS_VH

`define ACC_FX  2'b00
`define ACC_FY  2'b01
`define ACC_MAG 2'b10 

`define MAC_CTRL_W      7
`define MAC_CTRL_EN     6
`define MAC_CTRL_ADDSUB 5
`define MAC_CTRL_CLEAR  4
`define MAC_CTRL_LOAD   3
`define MAC_CTRL_ABS    2
`define MAC_CTRL_DOT    1
`define MAC_CTRL_FLUSH  0 

`define FUNCT5_MAC_SEL  5'd0
`define FUNCT5_MACSUB   5'd1
`define FUNCT5_MACABS   5'd2
`define FUNCT5_MACDOT   5'd3
`define FUNCT5_MACLOAD  5'd4
`define FUNCT5_MACCLEAR 5'd5
`define FUNCT5_MACSAT   5'd6
`define FUNCT5_MACRD_LO 5'd7
`define FUNCT5_MACRD_HI 5'd8
`define FUNCT5_MACSHIFT 5'd9

`endif
