`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 9 : DMA APB register interface (window 5, 0x4000_5000)
// dma_apb_slave.v
//
// Spec: GARUDA-DMA-SPEC-001 Rev 3.0 §6, §9 ([N-5.1]: pclk port, NO CDC)//
// *** CLOCK GAP - READ BEFORE STA (open item DMA OPEN-D1) ***
// This module is clocked ENTIRELY BY hclk. ADR-0002 Rev 2, GARUDA-SYS-001
// (`apb.clock: pclk`) and GARUDA-DMA-SPEC-001 [N-5.1] all specify the APB side on pclk;
// that migration has not been done. It is not a functional bug - pclk edges
// are a subset of hclk edges (D-5), so sampling is synchronous and every test
// passes - but it has two consequences that matter:
//
//   1. PRDATA is combinational out of hclk-domain registers, so it can change
//      at the hclk edge in the MIDDLE of a pclk access phase. The bridge
//      samples it at the pclk edge, so the effective setup window is half a
//      pclk period (4 ns), not 8 ns. STA must be told.
//   2. These flops toggle at 250 MHz, which is exactly the dynamic power
//      ADR-0002 Rev 2 restored pclk to avoid.
//
//
// The APB protocol is SPECIFIED on pclk. The registers themselves live in the hclk
// channel logic (dma_chan), because hardware updates them at hclk rate. A
// write is presented as a one-hclk strobe: the access phase (psel & penable &
// pwrite, one pclk = two hclk cycles) is edge-detected in hclk, so each APB
// write is applied exactly once - which is what keeps the D-2 "hardware wins
// EN" rule from being undone by a second application of the same write.
// Every path here is synchronous: pclk edges are hclk edges (D-5).
//
//   0x20*n + 0x00 CR, 0x04 SAR, 0x08 DAR, 0x0C CNT, 0x10 STAT (RO), 0x14 ICLR (W1C)
//   0x100 GSTAT (RO): [5:0] ACTIVE, [13:8] COMPLETE, [21:16] ERROR
//   anything else: PSLVERR
// =============================================================================

module dma_apb_slave (
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

    // one-hclk write strobes, per channel
    output wire [5:0]  wr_cr_o,
    output wire [5:0]  wr_sar_o,
    output wire [5:0]  wr_dar_o,
    output wire [5:0]  wr_cnt_o,
    output wire [5:0]  wr_iclr_o,
    output wire [31:0] wdata_o,

    // register views
    input  wire [6*32-1:0] cr_i,
    input  wire [6*32-1:0] sar_i,
    input  wire [6*32-1:0] dar_i,
    input  wire [6*32-1:0] cnt_i,
    input  wire [6*32-1:0] stat_i
);

    wire [2:0] ch  = paddr_i[7:5];
    wire [2:0] reg_ = paddr_i[4:2];
    wire chan_rgn  = (paddr_i[11:8] == 4'h0) && (ch < 3'd6) && (paddr_i[1:0] == 2'b00) &&
                     (reg_ <= 3'd5);
    wire gstat     = (paddr_i == 12'h100);
    wire hit       = chan_rgn | gstat;

    // edge-detected write strobe in hclk
    wire acc_wr = psel_i & penable_i & pwrite_i & chan_rgn;
    reg  acc_wr_q;
    always @(posedge hclk_i or negedge hreset_n_i)
        if (!hreset_n_i) acc_wr_q <= 1'b0;
        else             acc_wr_q <= acc_wr;
    wire wstb = acc_wr & ~acc_wr_q;

    wire [5:0] chsel = 6'd1 << ch;
    assign wr_cr_o   = {6{wstb && reg_ == 3'd0}} & chsel;
    assign wr_sar_o  = {6{wstb && reg_ == 3'd1}} & chsel;
    assign wr_dar_o  = {6{wstb && reg_ == 3'd2}} & chsel;
    assign wr_cnt_o  = {6{wstb && reg_ == 3'd3}} & chsel;
    assign wr_iclr_o = {6{wstb && reg_ == 3'd5}} & chsel;
    assign wdata_o   = pwdata_i;

    // GSTAT
    reg [31:0] gstat_v;
    integer n;
    always @(*) begin
        gstat_v = 32'd0;
        for (n = 0; n < 6; n = n + 1) begin
            gstat_v[n]      = stat_i[32*n + 16];
            gstat_v[8 + n]  = stat_i[32*n + 17];
            gstat_v[16 + n] = stat_i[32*n + 18];
        end
    end

    always @(*) begin
        prdata_o = 32'd0;
        if (gstat) prdata_o = gstat_v;
        else if (chan_rgn) begin
            case (reg_)
                3'd0: prdata_o = cr_i  [32*ch +: 32];
                3'd1: prdata_o = sar_i [32*ch +: 32];
                3'd2: prdata_o = dar_i [32*ch +: 32];
                3'd3: prdata_o = cnt_i [32*ch +: 32];
                3'd4: prdata_o = stat_i[32*ch +: 32];
                default: prdata_o = 32'd0;           // ICLR reads 0
            endcase
        end
    end

    assign pready_o  = 1'b1;
    // STAT is read-only: a write to it is refused like an unmapped offset
    assign pslverr_o = psel_i & penable_i & (~hit | (pwrite_i & (gstat | (chan_rgn & reg_ == 3'd4))));

endmodule

`default_nettype wire
