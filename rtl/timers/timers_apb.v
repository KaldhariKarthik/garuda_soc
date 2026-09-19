`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 11 : timers APB interface (window 11, 0x4000_B000)
// timers_apb.v
//
// Spec: GARUDA-TIMERS-SPEC-001 Rev 2.0 §6, §9 [N-9.1]
//
// Same pattern as the DMA: APB on pclk, registers in hclk, and each APB access
// is edge-detected into ONE hclk strobe (an access phase spans two hclk
// cycles). That matters twice here: a write must apply once, and a READ of
// MTIME_LO has a side effect (latching the shadow) that must happen once, at
// the start of the access, so the LO value returned and the HI value latched
// come from the same cycle.
//
//   0x00 MTIME_LO   0x04 MTIME_HI (shadow)  0x08 MTIMECMP_LO  0x0C MTIMECMP_HI
//   0x10 WDTCTL     0x14 WDTLOAD            0x18 WDTVAL (RO)  0x1C WDTKICK (W)
//   0x20 WDTWARN    other: PSLVERR
// =============================================================================

module timers_apb (
    input  wire        hclk_i,
    input  wire        hreset_n_i,

    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [11:0] paddr_i,
    input  wire [31:0] pwdata_i,
    output reg  [31:0] prdata_o,
    output wire        pready_o,
    output wire        pslverr_o,

    output wire        wr_mtime_lo_o, wr_mtime_hi_o, wr_cmp_lo_o, wr_cmp_hi_o,
    output wire        rd_mtime_lo_o,
    output wire        wr_wdtctl_o, wr_wdtload_o, wr_wdtkick_o, wr_wdtwarn_o,
    output wire [31:0] wdata_o,

    input  wire [31:0] mtime_lo_i,
    input  wire [31:0] mtime_hi_i,
    input  wire [63:0] mtimecmp_i,
    input  wire [31:0] wdtctl_i, wdtload_i, wdtval_i, wdtwarn_i
);

    wire [5:0] w = paddr_i[7:2];
    wire hit = (paddr_i[11:8] == 4'h0) && (paddr_i[1:0] == 2'b00) && (w <= 6'd8);
    wire ro  = (w == 6'd6);                       // WDTVAL

    // one-hclk strobe at the start of each access phase
    wire acc = psel_i & penable_i & hit;
    reg  acc_q;
    always @(posedge hclk_i or negedge hreset_n_i)
        if (!hreset_n_i) acc_q <= 1'b0; else acc_q <= acc;
    wire stb = acc & ~acc_q;
    wire ws  = stb &  pwrite_i;
    wire rs  = stb & ~pwrite_i;

    assign wr_mtime_lo_o = ws && w == 6'd0;
    assign wr_mtime_hi_o = ws && w == 6'd1;
    assign wr_cmp_lo_o   = ws && w == 6'd2;
    assign wr_cmp_hi_o   = ws && w == 6'd3;
    assign wr_wdtctl_o   = ws && w == 6'd4;
    assign wr_wdtload_o  = ws && w == 6'd5;
    assign wr_wdtkick_o  = ws && w == 6'd7;
    assign wr_wdtwarn_o  = ws && w == 6'd8;
    assign rd_mtime_lo_o = rs && w == 6'd0;
    assign wdata_o       = pwdata_i;

    // MTIME_LO is captured at the strobe so the value returned matches the
    // cycle the shadow was latched in.
    reg [31:0] lo_cap;
    always @(posedge hclk_i or negedge hreset_n_i)
        if (!hreset_n_i)            lo_cap <= 32'd0;
        else if (rd_mtime_lo_o)     lo_cap <= mtime_lo_i;

    always @(*) begin
        case (w)
            6'd0: prdata_o = acc_q ? lo_cap : mtime_lo_i;
            6'd1: prdata_o = mtime_hi_i;
            6'd2: prdata_o = mtimecmp_i[31:0];
            6'd3: prdata_o = mtimecmp_i[63:32];
            6'd4: prdata_o = wdtctl_i;
            6'd5: prdata_o = wdtload_i;
            6'd6: prdata_o = wdtval_i;
            6'd8: prdata_o = wdtwarn_i;
            default: prdata_o = 32'd0;             // WDTKICK reads 0
        endcase
    end

    assign pready_o  = 1'b1;
    assign pslverr_o = psel_i & penable_i & (~hit | (pwrite_i & ro));

endmodule

`default_nettype wire
