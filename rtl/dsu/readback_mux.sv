//readback_mux.v
//MACREAD_LO: low 32 bits of acc.
//MACREAD_HI: sign extended high 16b bits of acc (acc[47:32]).

`timescale 1ns / 1ps

module readback_mux (
    input wire [47:0] cluster_out,
    input wire        rd_lo_op,
    input wire        rd_hi_op,
    
    output wire [31:0] rd_lo_data,
    output wire [31:0] rd_hi_data
);

    assign rd_lo_data = cluster_out[31:0];
    assign rd_hi_data = {{16{cluster_out[47]}}, cluster_out[47:32]};
    
endmodule
