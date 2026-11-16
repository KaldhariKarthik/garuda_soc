`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 7 : APB fabric
// ahb2apb_fabric.v - return-path collection for the one-hot PSEL fan-out
//
// Spec: GARUDA-AHB2APB-SPEC-001 §4 (apb_fabric), yaml block 7 ("generated
//       inside block 8")
//
// PSEL is one-hot or zero, so the return path is an AND-OR over the windows.
// With no window selected PREADY/PSLVERR read 0 - the FSM only samples them in
// ACCESS, when exactly one PSEL bit is set.
// =============================================================================

module ahb2apb_fabric (
    input  wire [11:0]      psel_i,
    input  wire [12*32-1:0] prdata_i,
    input  wire [11:0]      pready_i,
    input  wire [11:0]      pslverr_i,
    output reg  [31:0]      prdata_o,
    output wire             pready_o,
    output wire             pslverr_o
);

    integer n;
    always @(*) begin
        prdata_o = 32'd0;
        for (n = 0; n < 12; n = n + 1)
            prdata_o = prdata_o | ({32{psel_i[n]}} & prdata_i[32*n +: 32]);
    end

    assign pready_o  = |(psel_i & pready_i);
    assign pslverr_o = |(psel_i & pslverr_i);

endmodule

`default_nettype wire
