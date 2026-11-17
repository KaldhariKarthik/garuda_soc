//result_selector.v
//4:1 mux to regfile writeback
//result_src: 00 = none(zero), 01 = rd_lo, 10 = rd_hi, 11 = shift

module result_selector
    import garuda_pkg::*;
(
    input wire [RES_SRC_W-1:0] result_src,
    input wire [WORD_W-1:0] rd_lo_data,
    input wire [WORD_W-1:0] rd_hi_data,
    input wire [WORD_W-1:0] shift_result,
    output reg [WORD_W-1:0] dsu_rd_data
);
    timeunit 1ns;
    timeprecision 1ps;

    always_comb begin : c_dsu_rd_data
        case (result_src)
            2'b01: dsu_rd_data = rd_lo_data;
            2'b10: dsu_rd_data = rd_hi_data;
            2'b11: dsu_rd_data = shift_result;
            default: dsu_rd_data = 32'b00000000000000000000000000000000;
        endcase
    end

endmodule
