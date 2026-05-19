`timescale 1ns / 1ps

module kogge_stone_49 (
    input wire  [48:0] a,
    input wire  [48:0] b,
    input wire         cin,
    output wire [48:0] sum
);

    assign sum = a + b + cin;
    
endmodule
