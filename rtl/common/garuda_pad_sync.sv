// =============================================================================
// GARUDA SoC - pad input synchronisers, several lines
// garuda_pad_sync.sv
//
// WIDTH garuda_sync_bit instances; bit n idles at IDLE[n]. A wrapper with one
// pad uses garuda_sync_bit itself (F4, 2026-11-18).
// =============================================================================

module garuda_pad_sync #(
    parameter int unsigned WIDTH = 32'd2,
    parameter [7:0] IDLE = 8'h00  // the idle level of each line
) (
    input wire pclk,
    input wire preset_n,
    input wire [WIDTH-1:0] pad_i,
    output wire [WIDTH-1:0] sync_o
);
    timeunit 1ns;
    timeprecision 1ps;

    genvar k;
    generate for (k = 0; k < WIDTH; k = k + 1) begin : g_line
        garuda_sync_bit #(.IDLE(IDLE[k])) u_sync (
            .pclk(pclk), .preset_n(preset_n), .pad_i(pad_i[k]),
            .sync_o(sync_o[k])
        );
    end endgenerate

endmodule
