// =============================================================================
// GARUDA SoC - Block 7 : APB fabric
// ahb2apb_fabric.v - return-path collection for the one-hot PSEL fan-out
//
// Spec: GARUDA-AHB2APB-SPEC-001 Sec.4 (apb_fabric), yaml block 7 ("generated
//       inside block 8")
//
// PSEL is one-hot or zero, so the return path is an AND-OR over the windows.
// With no window selected PREADY/PSLVERR read 0 - the FSM only samples them in
// ACCESS, when exactly one PSEL bit is set.
// =============================================================================

module ahb2apb_fabric
    import garuda_pkg::*;
(
    input wire [APB_NWIN-1:0] psel_i,
    input wire [APB_NWIN * WORD_W - 1:0] prdata_i,
    input wire [APB_NWIN-1:0] pready_i,
    input wire [APB_NWIN-1:0] pslverr_i,
    output reg [WORD_W-1:0] prdata_o,
    output wire pready_o,
    output wire pslverr_o
);
    timeunit 1ns;
    timeprecision 1ps;

    integer n;
    always_comb begin : c_prdata
        prdata_o = 32'd0;
        for (n = 0; n < 12; n = n + 1) begin
            prdata_o = prdata_o | ({32{psel_i[n]}} & prdata_i[32 * n+:32]);
        end
    end

    assign pready_o  = |(psel_i & pready_i);
    assign pslverr_o = |(psel_i & pslverr_i);

endmodule
