`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 9 : one DMA channel - registers, status, request tracking
// dma_chan.v
//
// Spec: GARUDA-DMA-SPEC-001 Rev 3.0 §6, §7.1, §7.3, §7.5, §7.6
//
// All channel state is in hclk. Software writes arrive as one-hclk strobes
// (dma_apb_slave edge-detects the pclk access), so every write is applied
// exactly once.
//
//   CR    [0] EN  [2:1] MODE  [3] SINC  [4] DINC  [6:5] SIZE  [7] IE_COMP
//         [8] IE_ERR. MODE=3 leaves MODE unchanged ([N-6.1]). Hardware wins
//         EN on a collision with a software write; the rest lands (D-2,
//         [N-7.17]..[N-7.19]).
//   SAR/DAR  advance only on a successful beat, so they freeze at the
//         failure point ([N-7.15]).
//   CNT   beats to move. Setting EN (0 -> 1) loads REMAINING from CNT.
//   STAT  [15:0] REMAINING [16] ACTIVE [17] COMPLETE [18] ERROR [21:19] ERRPHASE
//         REMAINING and COMPLETE change on the same edge (R-6, D-1).
//   ICLR  W1C: [0] COMPLETE, [1] ERROR (and ERRPHASE).
//
// A channel is ACTIVE while EN && REMAINING != 0. It is ELIGIBLE for the
// arbiter when active and either M2M or its peripheral request is asserted
// and has not already been served ([N-7.10]: one beat per assertion - the
// taken flag clears only when the request drops).
// =============================================================================

module dma_chan (
    input  wire        hclk_i,
    input  wire        hreset_n_i,

    // ---- register writes (one-hclk strobes) ----------------------------------
    input  wire        wr_cr_i,
    input  wire        wr_sar_i,
    input  wire        wr_dar_i,
    input  wire        wr_cnt_i,
    input  wire        wr_iclr_i,
    input  wire [31:0] wdata_i,

    // ---- register views ------------------------------------------------------
    output wire [31:0] cr_o,
    output wire [31:0] sar_o,
    output wire [31:0] dar_o,
    output wire [31:0] cnt_o,
    output wire [31:0] stat_o,

    // ---- peripheral handshake ---------------------------------------------
    input  wire        req_i,

    // ---- to / from the engine ---------------------------------------------
    output wire        eligible_o,
    output wire [1:0]  size_o,
    input  wire        beat_done_i,        // this channel's beat completed OK
    input  wire        beat_err_i,         // this channel's beat failed
    input  wire [2:0]  err_phase_i,        // 1 = read, 2 = write

    // ---- interrupts ------------------------------------------------------------
    output wire        complete_irq_o,
    output wire        error_irq_o
);

    localparam [1:0] M_P2M = 2'd0, M_M2P = 2'd1, M_M2M = 2'd2;

    reg        en_q, sinc_q, dinc_q, iec_q, iee_q;
    reg [1:0]  mode_q, size_q;
    reg [31:0] sar_q, dar_q;
    reg [15:0] cnt_q, rem_q;
    reg        comp_q, err_q;
    reg [2:0]  errph_q;
    reg        taken_q;

    wire active   = en_q && (rem_q != 16'd0);
    wire last     = (rem_q == 16'd1);
    wire [31:0] step = (size_q == 2'd0) ? 32'd1 : (size_q == 2'd1) ? 32'd2 : 32'd4;

    // hardware-owned EN clear: completion or error ([N-7.3], [N-7.13])
    wire hw_clr_en = (beat_done_i && last) || beat_err_i;

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            en_q <= 1'b0; mode_q <= M_P2M; sinc_q <= 1'b0; dinc_q <= 1'b0;
            size_q <= 2'd2; iec_q <= 1'b0; iee_q <= 1'b0;
            sar_q <= 32'd0; dar_q <= 32'd0; cnt_q <= 16'd0; rem_q <= 16'd0;
            comp_q <= 1'b0; err_q <= 1'b0; errph_q <= 3'd0; taken_q <= 1'b0;
        end else begin
            // ---- CR: software fields ------------------------------------------
            if (wr_cr_i) begin
                if (wdata_i[2:1] != 2'b11) mode_q <= wdata_i[2:1];
                sinc_q <= wdata_i[3];
                dinc_q <= wdata_i[4];
                size_q <= (wdata_i[6:5] == 2'b11) ? size_q : wdata_i[6:5];
                iec_q  <= wdata_i[7];
                iee_q  <= wdata_i[8];
            end
            // ---- EN: hardware wins ------------------------------------------------
            // A channel enabled with nothing left (zero-length transfer)
            // completes at once and drops EN the following cycle.
            if (hw_clr_en || (en_q && rem_q == 16'd0 && !wr_cr_i))
                en_q <= 1'b0;
            else if (wr_cr_i) begin
                en_q <= wdata_i[0];
                if (wdata_i[0] && !en_q) rem_q <= cnt_q;       // arm
            end
            // ---- address / count registers -------------------------------------------
            if (wr_sar_i) sar_q <= wdata_i;
            else if (beat_done_i && sinc_q) sar_q <= sar_q + step;
            if (wr_dar_i) dar_q <= wdata_i;
            else if (beat_done_i && dinc_q) dar_q <= dar_q + step;
            if (wr_cnt_i) cnt_q <= wdata_i[15:0];

            // ---- progress / status (same edge: R-6) -----------------------------------
            if (beat_done_i) begin
                rem_q <= rem_q - 16'd1;
                if (last) comp_q <= 1'b1;
            end else if (wr_cr_i && wdata_i[0] && !en_q && !hw_clr_en) begin
                // arming: a zero-length transfer completes at once; a real one
                // starts with COMPLETE clear so COMPLETE => REMAINING == 0
                // always holds (a_remaining_complete_consistent).
                comp_q <= (cnt_q == 16'd0);
            end
            if (beat_err_i) begin
                err_q   <= 1'b1;
                errph_q <= err_phase_i;
            end
            if (wr_iclr_i) begin
                if (wdata_i[0] && !(beat_done_i && last)) comp_q <= 1'b0;
                if (wdata_i[1] && !beat_err_i) begin err_q <= 1'b0; errph_q <= 3'd0; end
            end

            // ---- one beat per request assertion ([N-7.10]) -----------------------------
            if (!req_i)          taken_q <= 1'b0;
            else if (beat_done_i || beat_err_i) taken_q <= 1'b1;
        end
    end

    assign eligible_o = active && ((mode_q == M_M2M) || (req_i && !taken_q));
    assign size_o     = size_q;

    assign cr_o   = {23'd0, iee_q, iec_q, size_q, dinc_q, sinc_q, mode_q, en_q};
    assign sar_o  = sar_q;
    assign dar_o  = dar_q;
    assign cnt_o  = {16'd0, cnt_q};
    assign stat_o = {10'd0, errph_q, err_q, comp_q, active, rem_q};

    assign complete_irq_o = comp_q & iec_q;
    assign error_irq_o    = err_q  & iee_q;

endmodule

`default_nettype wire
