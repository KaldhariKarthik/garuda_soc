//saturation_unit.v
//MACSAT: clamps 48-bit acc to int32 range, sign_extends back to 48-bits.

`timescale 1ns / 1ps

module saturation_unit (
    input wire [47:0] cluster_out,
    input wire        sat_op,
    
    output wire [47:0] sat_writeback,
    output wire        sat_writeback_en,
    output wire        sat_overflow
);

    wire [16:0] upper    = cluster_out[47:31];
    wire        in_range = (upper == 17'h00000) | (upper == 17'h1FFFF);
    wire        is_neg   = cluster_out[47];
    
    wire [47:0] sat_pos = 48'sh0000_7FFFFFFF;
    wire [47:0] sat_neg = 48'shFFFF_80000000;
    
    reg [47:0] sat_result;
    always @(*) begin
        if      (in_range) sat_result = {{16{cluster_out[31]}}, cluster_out[31:0]};
        else if (is_neg)   sat_result = sat_neg;
        else               sat_result = sat_pos;
    end
    
    assign sat_writeback    = sat_result;
    assign sat_writeback_en = sat_op;
    assign sat_overflow     = sat_op & ~in_range;
    
endmodule        
