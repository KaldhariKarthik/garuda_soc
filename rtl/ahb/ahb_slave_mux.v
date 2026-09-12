`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 6: AHB-Lite Interconnect
// ahb_slave_mux.v - data-phase slave-select register + return-path muxes
//
// Spec reference: GARUDA-AHB-SPEC-001 Rev 2.0, Sec. 3.1, Sec. 7.4, Sec. 7.5,
//                 Sec. 8.2, Sec. 8.3
//
// This is the block's one registered datapath element (Sec. 3.1, "teal" in
// Figure 1): a one-cycle-delayed copy of the one-hot HSEL. Read data, HREADY
// and HRESP are all data-phase signals, so all three must be selected on the
// slave that was addressed LAST cycle, never on whatever the current address
// phase happens to point at. Getting this wrong is invisible while every
// transfer goes to the same slave and appears the instant two slaves are used
// back to back - which is exactly the traffic pattern of a CPU fetching from
// ROM while the DMA moves data in DSRAM.
//
// dph_valid_i comes from ahb_arbiter, which already has to track "is a data
// phase in flight" to decide whether the bus may change owner. Importing it
// rather than re-deriving it keeps the two answers from ever disagreeing:
// two registers with the same intended update rule are two registers that can
// drift when one of the rules is edited.
//
// -----------------------------------------------------------------------------
// THE IDLE-BUS HREADY DEFAULT
// -----------------------------------------------------------------------------
// With no data phase in flight there is no slave whose HREADYOUT is meaningful,
// so the shared HREADY is driven high. That is not just a convenience:
//   - AMBA requires a slave to hold HREADYOUT high when it is not selected,
//     but this interconnect must come up correctly against slaves that have
//     just left reset and may be one cycle late to that;
//   - out of reset dph_valid_i is low and hready_o must be high, or the first
//     I-Port fetch from the reset vector never gets its address phase accepted
//     and the SoC hangs with no error anywhere (Sec. 10).
// Keying the default off dph_valid_i rather than off "all HREADYOUTs high"
// makes the idle bus independent of slave behaviour entirely.
//
// No combinational loop is created by hready_o feeding back into the arbiter:
// dph_valid_i and dph_sel_o are both registers, so the path is
// register -> combinational -> register enable.
//
// -----------------------------------------------------------------------------
// ERROR RESPONSE PASS-THROUGH
// -----------------------------------------------------------------------------
// Nothing here shortens or lengthens a response. The two-cycle ERROR that
// Sec. 1.4 makes mandatory arrives as HREADYOUT=0/HRESP=1 then
// HREADYOUT=1/HRESP=1, and both cycles reach the owning master unchanged. That
// first cycle is what dma_ahb_master uses to retract its already-pipelined
// write address phase; an interconnect that registered or merged the response
// would break the cancel while still looking correct on a data-only test.
// =============================================================================

`include "ahb_defs.vh"

module ahb_slave_mux (
    input  wire        hclk_i,
    input  wire        hreset_n_i,

    // Address-phase one-hot select from the decoder.
    input  wire [`AHB_SEL_W-1:0] hsel_i,
    // "A data phase is in flight", from ahb_arbiter.
    input  wire        dph_valid_i,

    // Per-slave return paths. Index order matches `AHB_S_* in ahb_defs.vh;
    // the default slave occupies the top position.
    input  wire [31:0] hrdata_s0_i,  input wire hreadyout_s0_i, input wire hresp_s0_i,
    input  wire [31:0] hrdata_s1_i,  input wire hreadyout_s1_i, input wire hresp_s1_i,
    input  wire [31:0] hrdata_s2_i,  input wire hreadyout_s2_i, input wire hresp_s2_i,
    input  wire [31:0] hrdata_s3_i,  input wire hreadyout_s3_i, input wire hresp_s3_i,
    input  wire [31:0] hrdata_df_i,  input wire hreadyout_df_i, input wire hresp_df_i,

    // Shared return to the master side.
    output reg  [31:0] hrdata_o,
    output reg         hresp_o,
    output wire        hready_o,     // also the global HREADY driven to slaves

    // Registered data-phase select, exported for coverage / assertions.
    output reg  [`AHB_SEL_W-1:0] dph_sel_o
);

    // -----------------------------------------------------------------------
    // Data-phase select register (Sec. 7.5). Updated on every accepted address
    // phase, i.e. every cycle HREADY is high.
    // -----------------------------------------------------------------------
    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i)
            dph_sel_o <= {`AHB_SEL_W{1'b0}};
        else if (hready_o)
            dph_sel_o <= hsel_i;
    end

    // -----------------------------------------------------------------------
    // HREADY: from the data-phase slave, or high on an idle bus (see header).
    // -----------------------------------------------------------------------
    reg hreadyout_sel;
    always @(*) begin
        case (1'b1)
            dph_sel_o[`AHB_S_ISRAM  ]: hreadyout_sel = hreadyout_s0_i;
            dph_sel_o[`AHB_S_ROM    ]: hreadyout_sel = hreadyout_s1_i;
            dph_sel_o[`AHB_S_DSRAM  ]: hreadyout_sel = hreadyout_s2_i;
            dph_sel_o[`AHB_S_BRIDGE ]: hreadyout_sel = hreadyout_s3_i;
            dph_sel_o[`AHB_S_DEFAULT]: hreadyout_sel = hreadyout_df_i;
            default:                   hreadyout_sel = 1'b1;
        endcase
    end

    assign hready_o = dph_valid_i ? hreadyout_sel : 1'b1;

    // -----------------------------------------------------------------------
    // Read data and response: from the data-phase slave only. With no data
    // phase in flight the returns are forced to a defined idle value rather
    // than left to whatever a deselected slave happens to drive - an X here
    // propagates straight into a master's data path and shows up three blocks
    // away looking like a decode failure.
    // -----------------------------------------------------------------------
    always @(*) begin
        if (!dph_valid_i) begin
            hrdata_o = 32'h0000_0000;
            hresp_o  = `AHB_RESP_OKAY;
        end else begin
            case (1'b1)
                dph_sel_o[`AHB_S_ISRAM  ]: begin hrdata_o = hrdata_s0_i; hresp_o = hresp_s0_i; end
                dph_sel_o[`AHB_S_ROM    ]: begin hrdata_o = hrdata_s1_i; hresp_o = hresp_s1_i; end
                dph_sel_o[`AHB_S_DSRAM  ]: begin hrdata_o = hrdata_s2_i; hresp_o = hresp_s2_i; end
                dph_sel_o[`AHB_S_BRIDGE ]: begin hrdata_o = hrdata_s3_i; hresp_o = hresp_s3_i; end
                dph_sel_o[`AHB_S_DEFAULT]: begin hrdata_o = hrdata_df_i; hresp_o = hresp_df_i; end
                default:                   begin hrdata_o = 32'h0000_0000; hresp_o = `AHB_RESP_OKAY; end
            endcase
        end
    end

endmodule

`default_nettype wire
