// =============================================================================
// GARUDA SoC - one pad input synchroniser (two flops, pclk)
// garuda_sync_bit.sv
//
// Every asynchronous pad input the peripherals sample goes through two pclk
// flops. The reset value is the line's idle level, so a released reset does
// not look like an edge. Split out of garuda_apb_shim in F4 (2026-11-18):
// only the wrappers with pads have synchronisers.
// =============================================================================

module garuda_sync_bit #(
    parameter bit IDLE = 1'b0  // the line's idle level
) (
    input wire pclk,
    input wire preset_n,
    input wire pad_i,
    output wire sync_o
);
    timeunit 1ns;
    timeprecision 1ps;

    (* ASYNC_REG = "TRUE" *) reg meta_q;
    (* ASYNC_REG = "TRUE" *) reg sync_q;
    always_ff @(posedge pclk or negedge preset_n) begin : p_sync
        if (!preset_n) begin
            meta_q <= IDLE;
            sync_q <= IDLE;
        end else begin
            meta_q <= pad_i;
            sync_q <= meta_q;
        end
    end
    assign sync_o = sync_q;

endmodule
