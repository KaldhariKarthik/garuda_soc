`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 8: AHB-to-APB Bridge
// ahb2apb_decoder.v - PADDR[15:12] -> one-hot PSEL + decode-error flag
//
// Spec reference: GARUDA-BRG-SPEC-001 Rev 2.0, Sec. 6, Sec. 8.5
//
// The interconnect has already consumed the region bits (HADDR[31:28]=0100
// selected this bridge as slave S3), so only the low 16 bits matter here.
// PADDR[15:12] picks one of sixteen 4 KB windows and PADDR[11:0] is the byte
// offset inside the selected peripheral.
//
// THERE IS NO PHYSICAL DEFAULT SLAVE ON THE APB SIDE.
// An access to an unmapped window drives NO select at all - every psel_o bit
// stays low and no APB transfer is launched - and raises dec_err_o instead.
// The hclk FSM turns that into the mandatory two-cycle HRESP=ERROR upstream
// without any APB activity whatsoever (Sec. 8.5).
//
// That is a deliberate asymmetry with the AHB side, where Block 6 DOES
// instantiate a physical default slave. On AHB the default slave exists because
// a master left waiting for HREADY hangs forever; here the bridge itself is
// already the thing that owns HREADY for this region, so it can fault the
// access directly. Adding an APB default slave would mean a peripheral whose
// only job is to be selected and answer PREADY, to produce a response the
// bridge can generate on its own.
//
// Decode is one-hot and mutually exclusive. An address INSIDE a window but
// beyond that peripheral's implemented registers is the PERIPHERAL's business
// to flag via PSLVERR - this block routes by window and nothing finer.
// =============================================================================

`include "ahb2apb_defs.vh"

module ahb2apb_decoder #(
    // Which of the sixteen windows have a peripheral behind them. See
    // ahb2apb_defs.vh: only the DMA window is frozen; the rest are proposed
    // and are adopted by each peripheral's own spec.
    parameter [15:0] WINDOW_MASK = `BRG_WINDOW_MASK_DEFAULT
)(
    input  wire [3:0]  win_i,        // PADDR[15:12]
    output wire [15:0] psel_o,       // one-hot, all-zero on a decode fault
    output wire        dec_err_o
);

    wire [15:0] onehot = 16'h0001 << win_i;

    // A window that is not implemented selects nothing and faults instead.
    assign psel_o    = onehot & WINDOW_MASK;
    assign dec_err_o = ~(|(onehot & WINDOW_MASK));

endmodule

`default_nettype wire
