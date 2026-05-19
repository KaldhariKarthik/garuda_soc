//result_selector.v
//4:1 mux to regfile writeback
//result_src: 00 = none(zero), 01 = rd_lo, 10 = rd_hi, 11 = shift

`timescale 1ns / 1ps

module result_selector (
    input wire [1:0] result_src,
    input wire [31:0] rd_lo_data,
    input wire [31:0] rd_hi_data,
    input wire [31:0] shift_result,
    
    output reg [31:0] dsu_rd_data
);

    always @(*) begin
        case (result_src)
            2'b01: dsu_rd_data = rd_lo_data;
            2'b10: dsu_rd_data = rd_hi_data;
            2'b11: dsu_rd_data = shift_result;
            default: dsu_rd_data = 32'b0;
        endcase
    end
    
endmodule
