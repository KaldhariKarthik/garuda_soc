
module kogge_stone_49
    import garuda_pkg::*;
(
    input wire [ACC_W:0] a,
    input wire [ACC_W:0] b,
    input wire cin,
    output wire [ACC_W:0] sum
);
    timeunit 1ns;
    timeprecision 1ps;

    assign sum = a + b + cin;

endmodule
