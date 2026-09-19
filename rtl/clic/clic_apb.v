`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 10 : CLIC register file + APB interface (pclk)
// clic_apb.v
//
// Spec: GARUDA-CLIC-SPEC-001 Rev 2.0 (Rev 4.0 set) §6; window 10, 0x4000_A000
//
//   0x000        CLICINFO        RO   {num_interrupt=32, version=1, CTLBITS=8}
//   0x004        CLICIE          RW   bit n = ID n; IDs outside IE_MASK read 0
//                                     and ignore writes ([N-6.2], [N-6.3])
//   0x008        CLICIP          RO   combinational from the sources ([N-6.4])
//   0x100 + 4n   CLICINTCFG[n]   RW   [7:0] level, n = 0..31 ([N-6.6]..[N-6.8])
//   other        PSLVERR
//
// All registers reset to zero ([N-9.2]): nothing is enabled and every level
// is 0, so an enabled source is still never taken until firmware sets it.
// APB3, zero-wait. The values are read by the hclk selection logic directly:
// pclk is synchronous to hclk (CLIC [N-9.1], DECISIONS D-5).
// =============================================================================

module clic_apb #(
    parameter integer        N       = 32,
    parameter [31:0]         IE_MASK = 32'h007F_9FFE   // IDs 1-12, 15-22
)(
    input  wire          pclk_i,
    input  wire          preset_n_i,

    input  wire          psel_i,
    input  wire          penable_i,
    input  wire          pwrite_i,
    input  wire [11:0]   paddr_i,
    input  wire [31:0]   pwdata_i,
    output reg  [31:0]   prdata_o,
    output wire          pready_o,
    output wire          pslverr_o,

    input  wire [N-1:0]  pending_i,
    output wire [N-1:0]  ie_o,
    output wire [N*8-1:0] level_o
);

    localparam [31:0] CLICINFO = {7'd0, 4'd8, 8'd1, 13'd32};

    wire wr     = psel_i & penable_i & pwrite_i;
    wire is_cfg = (paddr_i[11:8] == 4'h1) && (paddr_i[1:0] == 2'b00) && (paddr_i[7:2] < N);
    wire hit    = (paddr_i == 12'h000) | (paddr_i == 12'h004) | (paddr_i == 12'h008) | is_cfg;
    wire [4:0] cfg_n = paddr_i[6:2];

    reg [N-1:0]  ie_q;
    reg [7:0]    lvl_q [0:N-1];

    integer k;
    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            ie_q <= {N{1'b0}};
            for (k = 0; k < N; k = k + 1) lvl_q[k] <= 8'd0;
        end else if (wr) begin
            if (paddr_i == 12'h004) ie_q <= pwdata_i[N-1:0] & IE_MASK[N-1:0];
            if (is_cfg)             lvl_q[cfg_n] <= pwdata_i[7:0];
        end
    end

    always @(*) begin
        prdata_o = 32'd0;
        if      (paddr_i == 12'h000) prdata_o = CLICINFO;
        else if (paddr_i == 12'h004) prdata_o = ie_q;
        else if (paddr_i == 12'h008) prdata_o = pending_i;
        else if (is_cfg)             prdata_o = {24'd0, lvl_q[cfg_n]};
    end

    assign pready_o  = 1'b1;
    assign pslverr_o = psel_i & penable_i & ~hit;

    assign ie_o = ie_q;
    genvar g;
    generate for (g = 0; g < N; g = g + 1) begin : g_lvl
        assign level_o[8*g +: 8] = lvl_q[g];
    end endgenerate

endmodule

`default_nettype wire
