module csa_3to2 #(parameter WIDTH = 48) (
    input wire [WIDTH-1:0] a,
    input wire [WIDTH-1:0] b,
    input wire [WIDTH-1:0] c,
    output wire [WIDTH-1:0] sum,
    output wire [WIDTH-1:0] carry
);

    assign sum = a^b^c;
    assign carry = ((a & b) | (b&c) | (a&c)) << 1;
    
endmodule
