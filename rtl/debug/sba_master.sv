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
    output reg [WORD_W-1:0] hwdata_o,
    input wire [WORD_W-1:0] hrdata_i,
    input wire hready_i,
    input wire hresp_i
);
    timeunit 1ns;
    timeprecision 1ps;
    reg [WORD_W-1:0] wbuf;

    assign hsize_o  = 3'b010;

    // the transfer's state machine (sba_fsm)
    wire idle;
    wire issue;   // the address goes out
    wire acc;     // the address phase is accepted
    wire xfer_end;  // the data phase completes
    sba_fsm u_fsm (
        .hclk(hclk), .dm_rst_n(dm_rst_n), .start_i(start_i),
        .hready_i(hready_i), .idle_o(idle), .issue_o(issue), .acc_o(acc),
        .end_o(xfer_end)
    );
    assign busy_o = !idle;

    // F4 (2026-11-17): one process per register (HAL MULNBA)
    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_addr
        if (!dm_rst_n) begin
            haddr_o <= 32'd0;
            wbuf <= 32'd0;
        end else if (issue) begin
            haddr_o <= addr_i;
            wbuf <= wdata_i;
        end
    end

    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_hwrite
        if (!dm_rst_n) begin
            hwrite_o <= 1'b0;
        end else if (issue) begin
            hwrite_o <= write_i;
        end else if (xfer_end) begin
            hwrite_o <= 1'b0;
        end
    end

    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_htrans
        if (!dm_rst_n) begin
            htrans_o <= 2'b00;
        end else if (issue) begin
            htrans_o <= 2'b10;  // NONSEQ
        end else if (acc) begin
            htrans_o <= 2'b00;
        end
    end

    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_hwdata
        if (!dm_rst_n) begin
            hwdata_o <= 32'd0;
        end else if (acc) begin
            hwdata_o <= wbuf;
        end
    end

    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_result
        if (!dm_rst_n) begin
            rdata_o <= 32'd0;
            done_o <= 1'b0;
            err_o <= 1'b0;
        end else begin
            if (xfer_end && !hwrite_o) begin
                rdata_o <= hrdata_i;
            end
            done_o <= xfer_end;
            err_o <= xfer_end && hresp_i;
        end
    end

endmodule
