//mult16x16.v
//16 bit signed multiplier

module mult_16x16
    import garuda_pkg::*;
(
    input wire signed [HALF_W-1:0] a,
    input wire signed [HALF_W-1:0] b,
    output wire signed [WORD_W-1:0] p
);
    timeunit 1ns;
    timeprecision 1ps;
    assign p = a*b;

endmodule
