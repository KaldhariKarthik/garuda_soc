// =============================================================================
// GARUDA SoC - Block 10 : CLIC register file + APB interface (pclk)
// clic_apb.v
//
// Spec: GARUDA-CLIC-SPEC-001 Rev 2.0 (Rev 4.0 set) Sec.6; window 10,
// 0x4000_A000
//
//   0x000        CLICINFO        RO   {num_interrupt=32, version=1, CTLBITS=8}
//   0x004        CLICIE          RW   bit n = ID n; IDs outside IE_MASK read 0
//                                     and ignore writes ([N-6.2], [N-6.3])
//   0x008        CLICIP          RO   combinational from the sources ([N-6.4])
// 0x00C CLICSWI RW [0] the software interrupt, source of ID 23
//                                     ([N-6.9]; 1-TOPS item 3.6, 2026-11-03)
//   0x100 + 4n   CLICINTCFG[n]   RW   [7:0] level, n = 0..31 ([N-6.6]..[N-6.8])
//   other        PSLVERR
//
// All registers reset to zero ([N-9.2]): nothing is enabled and every level
// is 0, so an enabled source is still never taken until firmware sets it.
// APB3, zero-wait. The values are read by the hclk selection logic directly:
// pclk is synchronous to hclk (CLIC [N-9.1], DECISIONS D-5).
// =============================================================================

module clic_apb
    import garuda_pkg::*;
#(
    parameter integer        NUM_SRC       = 32'd32,
    // IDs 1-6, 8-23 = GARUDA_CLIC_ID_MASK (BUGS_HISTORY.md INT-2, INT-3)
    parameter [31:0]         IE_MASK = 32'h00FF_FF7E
)(
    input wire pclk,
    input wire preset_n,
    input wire psel_i,
    input wire penable_i,
    input wire pwrite_i,
    input wire [PADDR_W-1:0] paddr_i,
    input wire [WORD_W-1:0] pwdata_i,
    output reg [WORD_W-1:0] prdata_o,
    output wire pready_o,
    output wire pslverr_o,
    input wire [NUM_SRC - 1:0] pending_i,
    output wire [NUM_SRC - 1:0] ie_o,
    output wire [NUM_SRC * CLIC_LVL_W - 1:0] level_o,
    // CLICSWI[0]: the software interrupt source
    output wire swi_o
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned CFG_W = 32'd5;

    localparam [31:0] CLICINFO = {7'd0, 4'd8, 8'd1, 13'd32};

    wire wr     = psel_i & penable_i & pwrite_i;
    wire is_cfg = (paddr_i[11:8] == 4'h1) && (paddr_i[1:0] == 2'b00)
        && ({1'b0, paddr_i[7:2]} < 7'(NUM_SRC));  // NUM_SRC <= 64
    wire hit = at12(paddr_i, 12'h000) |at12(paddr_i, 12'h004) |at12(paddr_i, 12'h008)
        |
                  at12(paddr_i, 12'h00C) | is_cfg;
    wire [CFG_W-1:0] cfg_n = paddr_i[6:2];

    reg [NUM_SRC-1:0]  ie_q;
    reg          swi_q;
    reg [BYTE_W-1:0]    lvl_q [0:NUM_SRC-1];

    integer k;
    always_ff @(posedge pclk or negedge preset_n) begin : p_ie
        if (!preset_n) begin
            ie_q <= {NUM_SRC {1'b0}};
            swi_q <= 1'b0;
            for (k = 0; k < NUM_SRC; k = k + 1) begin
                lvl_q[k] <= 8'd0;
            end
        end else if (wr) begin
            if (at12(paddr_i, 12'h004)) begin
                ie_q <= pwdata_i[NUM_SRC - 1:0] & IE_MASK[NUM_SRC - 1:0];
            end
            if (at12(paddr_i, 12'h00C)) begin
                swi_q <= pwdata_i[0];
            end
            if (is_cfg) begin
                lvl_q[cfg_n] <= pwdata_i[7:0];
            end
        end
    end

    always_comb begin : c_prdata
        prdata_o = 32'd0;
        if (at12(paddr_i, 12'h000)) begin
            prdata_o = CLICINFO;
        end else if (at12(paddr_i, 12'h004)) begin
            prdata_o = ie_q;
        end else if (at12(paddr_i, 12'h008)) begin
            prdata_o = pending_i;
        end else if (at12(paddr_i, 12'h00C)) begin
            prdata_o = {31'd0, swi_q};
        end else if (is_cfg) begin
            prdata_o = {24'd0, lvl_q[cfg_n]};
        end
    end

    assign pready_o  = 1'b1;
    assign pslverr_o = psel_i & penable_i & ~hit;

    assign ie_o  = ie_q;
    assign swi_o = swi_q;
    genvar g;
    generate for (g = 0; g < NUM_SRC; g = g + 1) begin : g_lvl
        assign level_o[8*g +: 8] = lvl_q[g];
    end endgenerate

endmodule
