
module csa_3to2 #(parameter int unsigned WIDTH = 32'd48) (
    input wire [WIDTH - 1:0] a,
    input wire [WIDTH - 1:0] b,
    input wire [WIDTH - 1:0] c,
    output wire [WIDTH - 1:0] sum,
    output wire [WIDTH - 1:0] carry
);
    timeunit 1ns;
    timeprecision 1ps;

    assign sum = a^b^c;
    // the majority, one place up: bit 0 of a carry vector is 0 and the top
    // majority bit leaves the word (carry-save)
    assign carry = ((a & b) | (b & c) | (a & c)) << 1;

endmodule
