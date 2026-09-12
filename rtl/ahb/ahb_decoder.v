`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 6: AHB-Lite Interconnect
// ahb_decoder.v - combinational address decode -> one-hot slave select
//
// Spec reference: GARUDA-AHB-SPEC-001 Rev 2.0, Sec. 3.1, Sec. 6, Sec. 8.1
//
// HADDR[31:28] selects one of four regions; anything else selects the default
// slave. The default slave shares the same one-hot vector rather than sitting
// on a separate "no match" wire, so that
//
//     $onehot(hsel_o)   is true for EVERY address, with no exceptions
//
// is an invariant both the RTL downstream and the testbench can rely on. A
// decoder whose output is legal "unless nothing matched" needs the exception
// handled at every consumer; this one does not.
//
// This block is purely combinational and has no notion of transfers. HSEL is
// driven from HADDR alone, per AMBA - qualifying it with HTRANS here would be
// wrong, because a slave is required to sample HSEL together with HTRANS and
// HREADY itself, and some slaves use HSEL with HTRANS=IDLE to pre-charge.
//
// NOT DECODED HERE: whether the address is inside the slave's physical size.
// Sec. 6 is explicit that "addresses inside a region but beyond a slave's
// physical size are the slave's responsibility to flag; the interconnect only
// routes by region." A 64 KB ISRAM sits in a 256 MB region; the ISRAM raises
// the error for the other 255.9 MB, not this block.
// =============================================================================

`include "ahb_defs.vh"

module ahb_decoder (
    input  wire [31:0]            haddr_i,
    output reg  [`AHB_SEL_W-1:0]  hsel_o     // one-hot, bit 4 = default slave
);

    always @(*) begin
        hsel_o = {`AHB_SEL_W{1'b0}};
        case (haddr_i[31:28])
            `AHB_RGN_ISRAM : hsel_o[`AHB_S_ISRAM ] = 1'b1;
            `AHB_RGN_ROM   : hsel_o[`AHB_S_ROM   ] = 1'b1;
            `AHB_RGN_DSRAM : hsel_o[`AHB_S_DSRAM ] = 1'b1;
            `AHB_RGN_BRIDGE: hsel_o[`AHB_S_BRIDGE] = 1'b1;
            default        : hsel_o[`AHB_S_DEFAULT] = 1'b1;
        endcase
    end

endmodule

`default_nettype wire
