module operand_router (
    input wire  [31:0] rs1,
    input wire  [31:0] rs2,
    input wire         abs_en,
    input wire         dot_en,
    output wire [15:0] a0,
    output wire [15:0] b0,
    output wire [15:0] a1,
    output wire [15:0] b1
);

    function [15:0] abs16;
        input [15:0] x;
        begin 
            if      (x == 16'h8000) abs16 = 16'h7FFF;
            else if (x[15])         abs16 = (~x) + 16'b1;
            else                    abs16 = x;
        end
     endfunction
     
     wire [15:0] rs1_lo_abs = abs16(rs1[15:0]);
     wire [15:0] rs2_lo_abs = abs16(rs2[15:0]);
     wire        dot_active = dot_en & ~abs_en;
     
     assign a0 = abs_en ? rs1_lo_abs : rs1[15:0];
     assign b0 = abs_en ? rs2_lo_abs : rs2[15:0];
     assign a1 = dot_active ? rs1[31:16] : 16'b0;
     assign b1 = dot_active ? rs2[31:16] : 16'b0;
     
endmodule
