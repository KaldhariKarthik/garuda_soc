// MUTANT dma_apb_slave_mut_aud13: rtl/dma/dma_apb_slave.sv with ONE change. Formal negative control: must FAIL.
// =============================================================================
// GARUDA SoC - Block 9 : DMA APB register interface (window 5, 0x4000_5000)
// dma_apb_slave.v
//
// Spec: GARUDA-DMA-SPEC-001 Rev 3.0 Sec.6, Sec.9 ([N-5.1]: pclk port, NO CDC);
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

module dma_apb_slave
    import garuda_pkg::*;
(
    input wire hclk,
    input wire hreset_n,
    input wire pclk,  // APB side (ADR-0002 Rev 2)
    input wire preset_n,
    input wire psel_i,
    input wire penable_i,
    input wire pwrite_i,
    input wire [PADDR_W-1:0] paddr_i,
    output wire [WORD_W-1:0] prdata_o,
    output wire pready_o,
    output wire pslverr_o,
    // one-hclk write strobes, per channel
    output wire [DMA_NCH-1:0] wr_cr_o,
    output wire [DMA_NCH-1:0] wr_sar_o,
    output wire [DMA_NCH-1:0] wr_dar_o,
    output wire [DMA_NCH-1:0] wr_cnt_o,
    output wire [DMA_NCH-1:0] wr_iclr_o,
    // register views
    input wire [DMA_NCH * WORD_W - 1:0] cr_i,
    input wire [DMA_NCH * WORD_W - 1:0] sar_i,
    input wire [DMA_NCH * WORD_W - 1:0] dar_i,
    input wire [DMA_NCH * WORD_W - 1:0] cnt_i,
    input wire [DMA_NCH * WORD_W - 1:0] stat_i
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned CH_W = 32'd3;
    localparam int unsigned REG_W = 32'd3;

    wire [CH_W-1:0] ch  = paddr_i[7:5];
    wire [REG_W-1:0] reg_ = paddr_i[4:2];
    wire chan_rgn = (paddr_i[11:8] == 4'h0) && (ch < 3'd6)
        && (paddr_i[1:0] == 2'b00) &&
                     (reg_ <= 3'd5);
    wire gstat     = at12(paddr_i, 12'h100);
    wire hit       = chan_rgn | gstat;

    // A write request is one pclk cycle (the access phase); edge-detecting it
    // in hclk yields exactly one hclk strobe, in the first of the two hclk
    // cycles that phase spans.
    wire acc_wr = psel_i & penable_i & pwrite_i & chan_rgn;
    reg  acc_wr_q;
    always_ff @(posedge hclk or negedge hreset_n) begin : p_acc_wr
        if (!hreset_n) begin
            acc_wr_q <= 1'b0;
        end else begin
            acc_wr_q <= acc_wr;
        end
    end
    wire wstb = acc_wr & ~acc_wr_q;

    // F4 (2026-11-17): the channel select is a compare per channel and the
    // channels' registers are arrays, so nothing is shifted by or indexed with
    // a product of the address (HAL SHFTNC, INDXOP, POOBID). The slots past
    // DMA_NCH read 0 and are outside chan_rgn.
    localparam int unsigned CH_SLOTS = 32'd8;  // 2**CH_W
    wire [DMA_NCH-1:0] chsel;
    wire [WORD_W-1:0] cr_a [0:CH_SLOTS-1];
    wire [WORD_W-1:0] sar_a [0:CH_SLOTS-1];
    wire [WORD_W-1:0] dar_a [0:CH_SLOTS-1];
    wire [WORD_W-1:0] cnt_a [0:CH_SLOTS-1];
    wire [WORD_W-1:0] stat_a [0:CH_SLOTS-1];
    // GSTAT: ACTIVE [5:0], COMPLETE [13:8], ERROR [21:16]
    wire [WORD_W-1:0] gstat_v;
    genvar k;
    generate for (k = 0; k < CH_SLOTS; k = k + 1) begin : g_slot
        if (k < DMA_NCH) begin : g_ch
            assign chsel[k]  = (ch == CH_W'(k));
            assign cr_a[k]   = cr_i[WORD_W*k +: WORD_W];
            assign sar_a[k]  = sar_i[WORD_W*k +: WORD_W];
            assign dar_a[k]  = dar_i[WORD_W*k +: WORD_W];
            assign cnt_a[k]  = cnt_i[WORD_W*k +: WORD_W];
            assign stat_a[k] = stat_i[WORD_W*k +: WORD_W];
            assign gstat_v[k]      = stat_a[k][16];
            assign gstat_v[8 + k]  = stat_a[k][17];
            assign gstat_v[16 + k] = stat_a[k][18];
        end else begin : g_none
            assign cr_a[k]   = '0;
            assign sar_a[k]  = '0;
            assign dar_a[k]  = '0;
            assign cnt_a[k]  = '0;
            assign stat_a[k] = '0;
            assign gstat_v[k]      = 1'b0;
            assign gstat_v[8 + k]  = 1'b0;
            assign gstat_v[16 + k] = 1'b0;
        end
    end endgenerate
    assign gstat_v[31:24] = 8'd0;

    assign wr_cr_o   = {6{wstb && reg_ == 3'd0}} & chsel;
    assign wr_sar_o  = {6{wstb && reg_ == 3'd1}} & chsel;
    assign wr_dar_o  = {6{wstb && reg_ == 3'd2}} & chsel;
    assign wr_cnt_o  = {6{wstb && reg_ == 3'd3}} & chsel;
    assign wr_iclr_o = {6{wstb && reg_ == 3'd5}} & chsel;

    // the addressed channel register; ICLR (5) reads 0
    wire [WORD_W-1:0] ch_word = (reg_ == 3'd0) ? cr_a[ch]  :
                                (reg_ == 3'd1) ? sar_a[ch] :
                                (reg_ == 3'd2) ? dar_a[ch] :
                                (reg_ == 3'd3) ? cnt_a[ch] :
                                (reg_ == 3'd4) ? stat_a[ch] : 32'd0;
    wire [WORD_W-1:0] rd_mux  = gstat ? gstat_v : chan_rgn ? ch_word : 32'd0;

    reg [WORD_W-1:0] prdata_q;
    always_ff @(posedge pclk or negedge preset_n) begin : p_prdata
        if (!preset_n) begin
            prdata_q <= 32'd0;
        end else if (psel_i && !penable_i) begin
            prdata_q <= rd_mux;
        end
    end
    assign prdata_o = prdata_q;

    assign pready_o  = 1'b1;
    // ERRATUM AUD-13 (2026-10-12, Karthik's plan task 0.5): PSLVERR only for an
    // offset that is not a register. A write to a read-only register (STAT,
    // GSTAT) is ignored without an error: no write strobe exists for it, so
    // nothing changes. Until this fix such a write answered PSLVERR like an
    // unmapped offset.
    assign pslverr_o = psel_i & penable_i & (~hit | (pwrite_i & (gstat | (chan_rgn & reg_ == 3'd4))));   // MUTANT: AUD-13 reverted

endmodule
