
module operand_router
    import garuda_pkg::*;
(
    input wire [WORD_W-1:0] rs1_val,
    input wire [WORD_W-1:0] rs2_val,
    input wire abs_en,
    input wire dot_en,
    output wire [HALF_W-1:0] a_lo,
    output wire [HALF_W-1:0] b_lo,
    output wire [HALF_W-1:0] a_hi,
    output wire [HALF_W-1:0] b_hi
);
    timeunit 1ns;
    timeprecision 1ps;

    function automatic [15:0] abs16;
        input [HALF_W-1:0] x;
        begin
            if (x == 16'h8000) begin
                abs16 = 16'h7FFF;
            end else if (x[15]) begin
                abs16 = HALF_W'((~x) + 16'b0000000000000001);
            end else begin
                abs16 = x;
            end
        end
    endfunction

     wire [HALF_W-1:0] rs1_lo_abs = abs16(rs1_val[15:0]);
     wire [HALF_W-1:0] rs2_lo_abs = abs16(rs2_val[15:0]);
     wire        dot_active = dot_en & ~abs_en;

     assign a_lo = abs_en ? rs1_lo_abs : rs1_val[15:0];
     assign b_lo = abs_en ? rs2_lo_abs : rs2_val[15:0];
     assign a_hi = dot_active ? rs1_val[31:16] : 16'b0000000000000000;
     assign b_hi = dot_active ? rs2_val[31:16] : 16'b0000000000000000;

endmodule
