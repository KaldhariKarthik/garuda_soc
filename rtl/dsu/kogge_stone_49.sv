
module kogge_stone_49
    import garuda_pkg::*;
(
    input wire [ACC_W:0] a,
    input wire [ACC_W:0] b,
    output wire [ACC_W:0] sum
);
    timeunit 1ns;
    timeprecision 1ps;

    // F4: the carry-in was tied to 0 by its one user, so it is gone
    assign sum = a + b;

endmodule
