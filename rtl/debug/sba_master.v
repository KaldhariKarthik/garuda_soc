`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 12 : System Bus Access master, AHB-Lite M2
// sba_master.v
//
// Spec: GARUDA-DEBUG-SPEC-001 Rev 2.0 §7.2 [N-7.2]..[N-7.7]; AHB-SPEC §5.1
//
// One 32-bit SINGLE transfer per start. HPROT is supplied by the interconnect.
// The interconnect raises hmaster_is_sba while this master owns the address
// phase, which is what lets SBA writes bypass MEMCTL.ILOCK ([N-7.7]).
// =============================================================================

module sba_master (
    input  wire        hclk_i,
    input  wire        hrst_n_i,

    input  wire        start_i,
    input  wire        write_i,
    input  wire [31:0] addr_i,
    input  wire [31:0] wdata_i,
    output reg         done_o,          // one-cycle pulse
    output reg         err_o,           // with done_o
    output reg  [31:0] rdata_o,
    output wire        busy_o,

    output reg  [31:0] haddr_o,
    output reg  [1:0]  htrans_o,
    output reg         hwrite_o,
    output wire [2:0]  hsize_o,
    output wire [2:0]  hburst_o,
    output reg  [31:0] hwdata_o,
    input  wire [31:0] hrdata_i,
    input  wire        hready_i,
    input  wire        hresp_i
);

    localparam [1:0] S_IDLE = 2'd0, S_ADDR = 2'd1, S_DATA = 2'd2;
    reg [1:0] st;
    reg [31:0] wbuf;

    assign hsize_o  = 3'b010;
    assign hburst_o = 3'b000;
    assign busy_o   = (st != S_IDLE);

    always @(posedge hclk_i or negedge hrst_n_i) begin
        if (!hrst_n_i) begin
            st <= S_IDLE; haddr_o <= 32'd0; htrans_o <= 2'b00; hwrite_o <= 1'b0;
            hwdata_o <= 32'd0; wbuf <= 32'd0; done_o <= 1'b0; err_o <= 1'b0; rdata_o <= 32'd0;
        end else begin
            done_o <= 1'b0;
            err_o  <= 1'b0;
            case (st)
                S_IDLE: if (start_i) begin
                    haddr_o  <= addr_i;
                    hwrite_o <= write_i;
                    wbuf     <= wdata_i;
                    htrans_o <= 2'b10;
                    st       <= S_ADDR;
                end
                S_ADDR: if (hready_i) begin            // address phase accepted
                    htrans_o <= 2'b00;
                    hwdata_o <= wbuf;
                    st       <= S_DATA;
                end
                default: if (hready_i) begin           // data phase complete
                    if (!hwrite_o) rdata_o <= hrdata_i;
                    done_o   <= 1'b1;
                    err_o    <= hresp_i;
                    hwrite_o <= 1'b0;
                    st       <= S_IDLE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
