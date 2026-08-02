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

    // -----------------------------------------------------------------------
    // ERRATUM DSU-5 -- the arithmetic right shift was actually LOGICAL
    // -----------------------------------------------------------------------
    // This was written as one conditional expression:
    //
    //   wire [47:0] shifted = shift_dir ? (cluster_out << shift_amt)
    //                                   : (acc_signed  >>> shift_amt);
    //
    // Verilog determines the signedness of a conditional expression from BOTH
    // arms: if either operand is unsigned, the whole expression is evaluated
    // unsigned. `cluster_out << shift_amt` is unsigned, so the `>>>` lost its
    // signed context and performed a plain logical shift. Sign extension
    // simply never happened.
    //
    // With acc = 0xffff_ffff_f440 and shift_amt = 45, MACSHIFT returned
    // 0x0000_0007 - the top three bits, unextended - where the architectural
    // answer is 0xffff_ffff. Note 45 is inside the DEFINED 0..47 range, so
    // this is not FLAG-D; it is a straightforward wrong answer.
    //
    // It stayed hidden because nothing had put a negative value into an
    // accumulator that was then shifted: DSU_gen.py drove rs1=rs2=0 for
    // clear/load, and ERRATUM DSU-2 (FLAG-A) changed which values reach the
    // accumulators at all.
    //
    // Each shift now has its own wire, so the signed operand keeps its signed
    // context and `>>>` means what it says.
    // -----------------------------------------------------------------------
    wire signed [47:0] acc_signed    = cluster_out;
    wire        [47:0] left_shifted  = cluster_out << shift_amt;
    wire        [47:0] right_shifted = acc_signed >>> shift_amt;

    wire [47:0] shifted = shift_dir ? left_shifted : right_shifted;

    assign shift_result = shifted[31:0];

endmodule
