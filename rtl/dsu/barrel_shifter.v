//barrel_shifter.v
//MACSHIFT: shifts cluster_out by shift_amt, produces 32-bit result for regfile
//shift_dir: 0: arithematic right shift, 1 = logical left shift
//Operates on full 48-bit acc, returns low 32 bits

`timescale 1ns / 1ps

module barrel_shifter (
    input wire [47:0] cluster_out,
    input wire [5:0]  shift_amt,
    input wire        shift_dir,
    
    output wire [31:0] shift_result
);

    wire signed [47:0] acc_signed = cluster_out;
    wire [47:0] shifted = shift_dir ? (cluster_out << shift_amt) : (acc_signed >>> shift_amt);
    
    assign shift_result = shifted[31:0];

endmodule
