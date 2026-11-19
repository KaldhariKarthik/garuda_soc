// MUTANT P14 (bus plan B2): fabric: PSLVERR from any window, not the selected one
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
    output wire [WORD_W-1:0] prdata_o,
    output wire pready_o,
    output wire pslverr_o
);
    timeunit 1ns;
    timeprecision 1ps;

    // AND-OR of the selected window's read data, as a generated chain
    // (F4: no loop over a running variable, HAL LOOPTM / RPTVAR)
    wire [WORD_W-1:0] acc [0:APB_NWIN];
    assign acc[0] = 32'd0;
    genvar n;
    generate for (n = 0; n < APB_NWIN; n = n + 1) begin : g_win
        assign acc[n + 1] = acc[n] | ({WORD_W{psel_i[n]}}
                                      & prdata_i[WORD_W*n +: WORD_W]);
    end endgenerate
    assign prdata_o = acc[APB_NWIN];

    assign pready_o  = |(psel_i & pready_i);
    assign pslverr_o = |pslverr_i;

endmodule
