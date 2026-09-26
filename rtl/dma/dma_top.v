`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 9 : DMA controller, 6 channels
// dma_top.v
//
// Spec: GARUDA-DMA-SPEC-001 Rev 3.0 (Rev 4.0 set); ADR-0008
//       Rulings: Docs/DECISIONS.md D-5 (no CDC), D-16 (R-9 check, ack width)
//
// Rev 3.0 replaces the Rev 2.x controller: the three CDC modules are deleted
// ([N-4.1]); registers follow §6 (CR/SAR/DAR/CNT/STAT/ICLR per channel at
// 0x20*n, GSTAT at 0x100); channel priorities are fixed by the system
// definition; completion and error are separate level interrupts to CLIC IDs
// 1-6 and 7-12. APB is on pclk, everything else on hclk; pclk is a synchronous
// divide of hclk, so no synchroniser exists anywhere in the block.
// =============================================================================

module dma_top #(
    parameter [17:0] PRIO       = {3'd0, 3'd4, 3'd2, 3'd1, 3'd3, 3'd5},  // ch5..ch0
    parameter integer ACK_CYCLES = 2
)(
    input  wire        hclk_i,
    input  wire        hreset_n_i,
    input  wire        pclk_i,              // APB side ([N-5.1])
    input  wire        preset_n_i,

    // ---- APB slave, window 5 ---------------------------------------------------
    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [11:0] paddr_i,
    input  wire [31:0] pwdata_i,
    output wire [31:0] prdata_o,
    output wire        pready_o,
    output wire        pslverr_o,

    // ---- AHB-Lite master M3 ---------------------------------------------------------
    output wire [31:0] haddr_o,
    output wire [1:0]  htrans_o,
    output wire        hwrite_o,
    output wire [2:0]  hsize_o,
    output wire [2:0]  hburst_o,
    output wire [31:0] hwdata_o,
    input  wire [31:0] hrdata_i,
    input  wire        hready_i,
    input  wire        hresp_i,

    // ---- peripheral sideband -----------------------------------------------------------
    input  wire [5:0]  dma_req_i,
    output wire [5:0]  dma_ack_o,

    // ---- interrupts ------------------------------------------------------------------------
    output wire [5:0]  dma_complete_o,       // CLIC IDs 1..6
    output wire [5:0]  dma_error_o           // CLIC IDs 7..12
);

    wire [5:0]  wr_cr, wr_sar, wr_dar, wr_cnt, wr_iclr;
    wire [31:0] wdata;
    wire [6*32-1:0] cr, sar, dar, cnt, stat;
    wire [6*2-1:0]  size;
    wire [5:0]  eligible, beat_done, beat_err;
    wire [2:0]  err_phase;
    wire        grant_valid;
    wire [2:0]  grant_ch;

    dma_apb_slave u_apb (
        .pclk_i(pclk_i), .preset_n_i(preset_n_i),
        .hclk_i(hclk_i), .hreset_n_i(hreset_n_i),
        .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i),
        .paddr_i(paddr_i), .pwdata_i(pwdata_i), .prdata_o(prdata_o),
        .pready_o(pready_o), .pslverr_o(pslverr_o),
        .wr_cr_o(wr_cr), .wr_sar_o(wr_sar), .wr_dar_o(wr_dar), .wr_cnt_o(wr_cnt),
        .wr_iclr_o(wr_iclr), .wdata_o(wdata),
        .cr_i(cr), .sar_i(sar), .dar_i(dar), .cnt_i(cnt), .stat_i(stat));

    genvar n;
    generate for (n = 0; n < 6; n = n + 1) begin : g_ch
        dma_chan u_ch (
            .hclk_i(hclk_i), .hreset_n_i(hreset_n_i),
            .wr_cr_i(wr_cr[n]), .wr_sar_i(wr_sar[n]), .wr_dar_i(wr_dar[n]),
            .wr_cnt_i(wr_cnt[n]), .wr_iclr_i(wr_iclr[n]), .wdata_i(wdata),
            .cr_o(cr[32*n +: 32]), .sar_o(sar[32*n +: 32]), .dar_o(dar[32*n +: 32]),
            .cnt_o(cnt[32*n +: 32]), .stat_o(stat[32*n +: 32]),
            .req_i(dma_req_i[n]),
            .eligible_o(eligible[n]), .size_o(size[2*n +: 2]),
            .beat_done_i(beat_done[n]), .beat_err_i(beat_err[n]), .err_phase_i(err_phase),
            .complete_irq_o(dma_complete_o[n]), .error_irq_o(dma_error_o[n]));
    end endgenerate

    dma_arbiter #(.PRIO(PRIO)) u_arb (
        .eligible_i(eligible), .grant_valid_o(grant_valid), .grant_ch_o(grant_ch));

    dma_engine #(.ACK_CYCLES(ACK_CYCLES)) u_eng (
        .hclk_i(hclk_i), .hreset_n_i(hreset_n_i),
        .grant_valid_i(grant_valid), .grant_ch_i(grant_ch),
        .sar_i(sar), .dar_i(dar), .size_i(size),
        .beat_done_o(beat_done), .beat_err_o(beat_err), .err_phase_o(err_phase),
        .dma_ack_o(dma_ack_o),
        .haddr_o(haddr_o), .htrans_o(htrans_o), .hwrite_o(hwrite_o), .hsize_o(hsize_o),
        .hburst_o(hburst_o), .hwdata_o(hwdata_o), .hrdata_i(hrdata_i),
        .hready_i(hready_i), .hresp_i(hresp_i), .busy_o());


endmodule

`default_nettype wire
