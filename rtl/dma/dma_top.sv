// =============================================================================
// GARUDA SoC - Block 9 : DMA controller, 6 channels
// dma_top.v
//
// Spec: GARUDA-DMA-SPEC-001 Rev 3.0 (Rev 4.0 set); ADR-0008
//       Rulings: Docs/DECISIONS.md D-5 (no CDC), D-16 (R-9 check, ack width)
//
// Rev 3.0 replaces the Rev 2.x controller: the three CDC modules are deleted
// ([N-4.1]); registers follow Sec.6 (CR/SAR/DAR/CNT/STAT/ICLR per channel at
// 0x20*n, GSTAT at 0x100); channel priorities are fixed by the system
// definition; completion and error are separate level interrupts to CLIC IDs
// 1-6 and 8-13 (ID 7 reserved, INT-2). APB is on pclk, everything else on hclk;
// pclk is a synchronous divide of hclk, so no synchroniser exists anywhere in
// the block.
// =============================================================================

module dma_top
    import garuda_pkg::*;
#(
    // ch5..ch0
    parameter [17:0] PRIO       = {3'd0, 3'd4, 3'd2, 3'd1, 3'd3, 3'd5},
    parameter integer ACK_CYCLES = 32'd2
)(
    input wire hclk,
    input wire hreset_n,
    input wire pclk,  // APB side ([N-5.1])
    input wire preset_n,
    // ---- APB slave, window 5 ------------------------------------------------
    input wire psel_i,
    input wire penable_i,
    input wire pwrite_i,
    input wire [PADDR_W-1:0] paddr_i,
    input wire [WORD_W-1:0] pwdata_i,
    output wire [WORD_W-1:0] prdata_o,
    output wire pready_o,
    output wire pslverr_o,
    // ---- AHB-Lite master M3 -------------------------------------------------
    output wire [WORD_W-1:0] haddr_o,
    output wire [HTRANS_W-1:0] htrans_o,
    output wire hwrite_o,
    output wire [HSIZE_W-1:0] hsize_o,
    output wire [HBURST_W-1:0] hburst_o,
    output wire [WORD_W-1:0] hwdata_o,
    input wire [WORD_W-1:0] hrdata_i,
    input wire hready_i,
    input wire hresp_i,
    // ---- peripheral sideband ------------------------------------------------
    input wire [DMA_NCH-1:0] dma_req_i,
    output wire [DMA_NCH-1:0] dma_ack_o,
    // ---- interrupts ---------------------------------------------------------
    output wire [DMA_NCH-1:0] dma_complete_o,  // CLIC IDs 1..6
    // CLIC IDs 8..13 (ID 7 reserved, INT-2)
    output wire [DMA_NCH-1:0] dma_error_o
);
    timeunit 1ns;
    timeprecision 1ps;

    wire [DMA_NCH-1:0] wr_cr;
    wire [DMA_NCH-1:0] wr_sar;
    wire [DMA_NCH-1:0] wr_dar;
    wire [DMA_NCH-1:0] wr_cnt;
    wire [DMA_NCH-1:0] wr_iclr;
    wire [WORD_W-1:0] wdata;
    wire [DMA_NCH*WORD_W-1:0] cr;
    wire [DMA_NCH*WORD_W-1:0] sar;
    wire [DMA_NCH*WORD_W-1:0] dar;
    wire [DMA_NCH*WORD_W-1:0] cnt;
    wire [DMA_NCH*WORD_W-1:0] stat;
    wire [DMA_NCH*DMA_SIZE_W-1:0]  size;
    wire [DMA_NCH-1:0]      m2m;  // CR.MODE == M2M, per channel (DMA-15)
    // a beat of channel n is in flight (DMA-9)
    wire [DMA_NCH-1:0]      inflight;
    genvar m;
    generate for (m = 0; m < 6; m = m + 1) begin : g_m2m
        assign m2m[m] = (cr[32*m + 1 +: 2] == 2'd2);
    end endgenerate
    wire [DMA_NCH-1:0] eligible;
    wire [DMA_NCH-1:0] beat_done;
    wire [DMA_NCH-1:0] beat_err;
    wire [ERR_PHASE_W-1:0]  err_phase;
    wire        grant_valid;
    wire [DMA_CH_W-1:0]  grant_ch;

    dma_apb_slave u_apb (
        .pclk(pclk), .preset_n(preset_n),
        .hclk(hclk), .hreset_n(hreset_n),
        .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i),
        .paddr_i(paddr_i), .pwdata_i(pwdata_i), .prdata_o(prdata_o),
        .pready_o(pready_o), .pslverr_o(pslverr_o),
        .wr_cr_o(wr_cr), .wr_sar_o(wr_sar), .wr_dar_o(wr_dar),
            .wr_cnt_o(wr_cnt),
        .wr_iclr_o(wr_iclr), .wdata_o(wdata),
        .cr_i(cr), .sar_i(sar), .dar_i(dar), .cnt_i(cnt), .stat_i(stat));

    genvar n;
    generate for (n = 0; n < 6; n = n + 1) begin : g_ch
        dma_chan u_ch (
            .hclk(hclk), .hreset_n(hreset_n),
            .wr_cr_i(wr_cr[n]), .wr_sar_i(wr_sar[n]), .wr_dar_i(wr_dar[n]),
            .wr_cnt_i(wr_cnt[n]), .wr_iclr_i(wr_iclr[n]), .wdata_i(wdata),
            .cr_o(cr[32 * n+:32]), .sar_o(sar[32 * n+:32]),
                .dar_o(dar[32 * n+:32]),
            .cnt_o(cnt[32*n +: 32]), .stat_o(stat[32*n +: 32]),
            .req_i(dma_req_i[n]),
            .eligible_o(eligible[n]), .size_o(size[2*n +: 2]),
            .beat_done_i(beat_done[n]), .beat_err_i(beat_err[n]),
                .err_phase_i(err_phase),
            .inflight_i(inflight[n]),
            .complete_irq_o(dma_complete_o[n]), .error_irq_o(dma_error_o[n]));
    end endgenerate

    dma_arbiter #(.PRIO(PRIO)) u_arb (
        .eligible_i(eligible), .grant_valid_o(grant_valid),
            .grant_ch_o(grant_ch));

    dma_engine #(.ACK_CYCLES(ACK_CYCLES)) u_eng (
        .hclk(hclk), .hreset_n(hreset_n),
        .grant_valid_i(grant_valid), .grant_ch_i(grant_ch),
        .sar_i(sar), .dar_i(dar), .size_i(size), .m2m_i(m2m),
        .beat_done_o(beat_done), .beat_err_o(beat_err), .err_phase_o(err_phase),
        .dma_ack_o(dma_ack_o),
        .haddr_o(haddr_o), .htrans_o(htrans_o), .hwrite_o(hwrite_o),
            .hsize_o(hsize_o),
        .hburst_o(hburst_o), .hwdata_o(hwdata_o), .hrdata_i(hrdata_i),
        .hready_i(hready_i), .hresp_i(hresp_i), .busy_o(),
            .inflight_o(inflight));

endmodule
