//readback_mux.v
//MACREAD_LO: low 32 bits of acc.
//MACREAD_HI: sign extended high 16b bits of acc (acc[47:32]).

module readback_mux
    import garuda_pkg::*;
(
    input wire [ACC_W-1:0] cluster_out,
    output wire [WORD_W-1:0] rd_lo_data,
    output wire [WORD_W-1:0] rd_hi_data
);
    timeunit 1ns;
    timeprecision 1ps;

    assign rd_lo_data = cluster_out[31:0];
    assign rd_hi_data = {{16{cluster_out[47]}}, cluster_out[47:32]};

endmodule
