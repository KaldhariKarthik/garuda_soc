`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 9 : DMA APB register interface (window 5, 0x4000_5000)
// dma_apb_slave.v
//
// Spec: GARUDA-DMA-SPEC-001 Rev 3.0 §6, §9 ([N-5.1]: pclk port, NO CDC);
//       ADR-0002 Rev 2.
//
// TWO CLOCKS. The APB protocol side runs on pclk; the registers themselves
// live in the hclk channel logic (dma_chan), because hardware updates them at
// hclk rate. That is the split ADR-0002 Rev 2 asks for, and there is no CDC:
// every pclk edge is an hclk edge (D-5), so a pclk pulse edge-detected in
// hclk gives exactly one hclk write strobe.
//
// PRDATA is REGISTERED on pclk, captured at the setup-to-access edge and held
// stable for the whole access phase. It used to be combinational out of the
// hclk register views, which meant STAT and CNT - both updated by the engine
// at hclk - could move at the hclk edge in the middle of the access phase.
// The bridge captures PRDATA at the pclk edge that ends the access, so that
// path launched 4 ns before capture rather than 8, across the chip. Now the
// only 4 ns hop is local (channel register to this module's prdata flop) and
// what crosses to the bridge is pclk-to-pclk.
//
// Reads here have no side effect, so unlike timers_apb the capture can happen
// at the setup-to-access edge with nothing to arrange beforehand.
//
// =============================================================================

module dma_apb_slave (
    input  wire        hclk_i,
    input  wire        hreset_n_i,
    input  wire        pclk_i,          // APB side (ADR-0002 Rev 2)
    input  wire        preset_n_i,

    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [11:0] paddr_i,
    input  wire [31:0] pwdata_i,
    output wire [31:0] prdata_o,
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

    // A write request is one pclk cycle (the access phase); edge-detecting it
    // in hclk yields exactly one hclk strobe, in the first of the two hclk
    // cycles that phase spans.
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

    reg [31:0] rd_mux;
    always @(*) begin
        rd_mux = 32'd0;
        if (gstat) rd_mux = gstat_v;
        else if (chan_rgn) begin
            case (reg_)
                3'd0: rd_mux = cr_i  [32*ch +: 32];
                3'd1: rd_mux = sar_i [32*ch +: 32];
                3'd2: rd_mux = dar_i [32*ch +: 32];
                3'd3: rd_mux = cnt_i [32*ch +: 32];
                3'd4: rd_mux = stat_i[32*ch +: 32];
                default: rd_mux = 32'd0;             // ICLR reads 0
            endcase
        end
    end

    // Registered on pclk at the setup-to-access edge: stable for the whole
    // access phase, so what leaves for the bridge is a pclk-to-pclk path.
    reg [31:0] prdata_q;
    always @(posedge pclk_i or negedge preset_n_i)
        if (!preset_n_i)              prdata_q <= 32'd0;
        else if (psel_i & ~penable_i) prdata_q <= rd_mux;
    assign prdata_o = prdata_q;

    assign pready_o  = 1'b1;
    // STAT is read-only: a write to it is refused like an unmapped offset
    assign pslverr_o = psel_i & penable_i & (~hit | (pwrite_i & (gstat | (chan_rgn & reg_ == 3'd4))));

endmodule

`default_nettype wire
