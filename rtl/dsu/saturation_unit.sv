//saturation_unit.v
//MACSAT: clamps 48-bit acc to int32 range, sign_extends back to 48-bits.

module saturation_unit
    import garuda_pkg::*;
(
    input wire [ACC_W-1:0] cluster_out,
    input wire sat_op,
    output wire [ACC_W-1:0] sat_writeback,
    output wire sat_writeback_en,
    output wire sat_overflow
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned UPPER_W = 32'd17;

    wire [UPPER_W-1:0] upper    = cluster_out[47:31];
    wire        in_range = (upper == 17'h00000) | (upper == 17'h1FFFF);
    wire        is_neg   = cluster_out[47];

    wire [ACC_W-1:0] sat_pos = 48'sh0000_7FFFFFFF;
    wire [ACC_W-1:0] sat_neg = 48'shFFFF_80000000;

    reg [ACC_W-1:0] sat_result;
    always_comb begin : c_sat_result
        if (in_range) begin
            sat_result = {{16{cluster_out[31]}}, cluster_out[31:0]};
        end else if (is_neg) begin
            sat_result = sat_neg;
        end else begin
            sat_result = sat_pos;
        end
    end

    assign sat_writeback    = sat_result;
    assign sat_writeback_en = sat_op;
    assign sat_overflow     = sat_op & ~in_range;

endmodule
