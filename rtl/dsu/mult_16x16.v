//mult16x16.v
//16 bit signed multiplier

`timescale 1ns / 1ps

module mult_16x16 (
    input wire signed [15:0] a,
    input wire signed [15:0] b,
    output wire signed [31:0] p
);
    assign p = a*b;
    
endmodule   
