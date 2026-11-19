// MUTANT decode (bus plan B1 A2 negative control): decode slip: DSRAM decoded at nibble 3
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
// The interconnect only routes by region. Inside a region, an address past the
// memory's size aliases down: the memories ignore the high bits, by design
// (GARUDA-MEM-SPEC-001 [N-7.2]; checked by sw/chip/t_chip_integ.c step 7). Only
// an address outside the four regions gets an ERROR, from the default slave.
// =============================================================================

module ahb_decoder
    import garuda_pkg::*;
    import ahb_pkg::*;
(
    // HADDR[31:28]: the decoder needs nothing else (F4: no unused port bits)
    input wire [AHB_RGN_W-1:0] rgn_i,
    // one-hot, bit 4 = default slave
    output reg [AHB_SEL_W - 1:0] hsel_o
);
    timeunit 1ns;
    timeprecision 1ps;

    always_comb begin : c_hsel
        hsel_o = {AHB_SEL_W {1'b0}};
        case (rgn_i)
            AHB_RGN_ISRAM: hsel_o[AHB_S_ISRAM] = 1'b1;
            AHB_RGN_ROM: hsel_o[AHB_S_ROM] = 1'b1;
            4'h3           : hsel_o[AHB_S_DSRAM ] = 1'b1;
            AHB_RGN_BRIDGE: hsel_o[AHB_S_BRIDGE] = 1'b1;
            default: hsel_o[AHB_S_DEFAULT] = 1'b1;
        endcase
    end

endmodule
