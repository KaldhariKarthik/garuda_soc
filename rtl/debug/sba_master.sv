// =============================================================================
// GARUDA SoC - Block 12 : System Bus Access master, AHB-Lite M2
// sba_master.v
//
// Spec: GARUDA-DEBUG-SPEC-001 Rev 2.0 Sec.7.2 [N-7.2]..[N-7.7]; AHB-SPEC
// Sec.5.1
//
// One 32-bit SINGLE transfer per start. HPROT is supplied by the interconnect.
// The interconnect raises hmaster_is_sba while this master owns the address
// phase, which is what lets SBA writes bypass MEMCTL.ILOCK ([N-7.7]).
// =============================================================================

module sba_master
    import garuda_pkg::*;
(
    input wire hclk,
    input wire dm_rst_n,
    input wire start_i,
    input wire write_i,
    input wire [WORD_W-1:0] addr_i,
    input wire [WORD_W-1:0] wdata_i,
    output reg done_o,  // one-cycle pulse
    output reg err_o,  // with done_o
    output reg [WORD_W-1:0] rdata_o,
    output wire busy_o,
    output reg [WORD_W-1:0] haddr_o,
    output reg [HTRANS_W-1:0] htrans_o,
    output reg hwrite_o,
    output wire [HSIZE_W-1:0] hsize_o,
    output wire [HBURST_W-1:0] hburst_o,
    output reg [WORD_W-1:0] hwdata_o,
    input wire [WORD_W-1:0] hrdata_i,
    input wire hready_i,
    input wire hresp_i
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned ST_W = 32'd2;

    localparam [1:0] S_IDLE = 2'd0, S_ADDR = 2'd1, S_DATA = 2'd2;
    reg [ST_W-1:0] st;
    reg [WORD_W-1:0] wbuf;

    assign hsize_o  = 3'b010;
    assign hburst_o = 3'b000;
    assign busy_o   = (st != S_IDLE);

    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_st
        if (!dm_rst_n) begin
            st <= S_IDLE;
            haddr_o <= 32'd0;
            htrans_o <= 2'b00;
            hwrite_o <= 1'b0;
            hwdata_o <= 32'd0;
            wbuf <= 32'd0;
            done_o <= 1'b0;
            err_o <= 1'b0;
            rdata_o <= 32'd0;
        end else begin
            done_o <= 1'b0;
            err_o <= 1'b0;
            case (st)
                S_IDLE: begin
                    if (start_i) begin
                        haddr_o <= addr_i;
                        hwrite_o <= write_i;
                        wbuf <= wdata_i;
                        htrans_o <= 2'b10;
                        st <= S_ADDR;
                    end
                end
                S_ADDR: begin
                    if (hready_i) begin  // address phase accepted
                        htrans_o <= 2'b00;
                        hwdata_o <= wbuf;
                        st <= S_DATA;
                    end
                end
                default: begin
                    if (hready_i) begin  // data phase complete
                        if (!hwrite_o) begin
                            rdata_o <= hrdata_i;
                        end
                        done_o <= 1'b1;
                        err_o <= hresp_i;
                        hwrite_o <= 1'b0;
                        st <= S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
