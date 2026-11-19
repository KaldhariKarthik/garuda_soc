// MUTANT mut_eng1: rtl/dma/dma_engine.sv with ONE fix reverted (ENG-1: a beat is taken in the cycle a result is reported).
// Regenerated 2026-11-16 from the current RTL; it differs from it by this change only. Formal negative control: must FAIL. (tb/dma/formal/dma.toml mut_eng1, a_no_grant_while_reporting)
// =============================================================================
// GARUDA SoC - Block 9 : beat engine and AHB-Lite master M3
// dma_engine.v
//
// Spec: GARUDA-DMA-SPEC-001 Rev 3.0 Sec.7.1, Sec.7.2, Sec.7.5, Sec.7.7;
// AHB-SPEC Sec.5.1
//
// One beat = a SINGLE read at SAR then a SINGLE write at DAR ([N-7.2]). The
// channel is latched at the start of the read and cannot change until the
// write completes ([N-7.11], a_beat_atomic).
//
//   E_IDLE -> E_RA (read address) -> E_RD (read data) -> E_WA -> E_WD -> E_IDLE
//
// Sub-word beats: the read data is taken from the lanes selected by SAR[1:0]
// and replicated across all four write lanes; the slave picks the lanes that
// DAR[1:0] and HSIZE select, so any source/destination alignment works.
//
// R-9 / [N-7.20]: the DMA checks its own addresses - a SAR or DAR in the ISRAM
// (0x0) or Boot ROM (0x1) region aborts the beat with ERRPHASE = read/write
// and issues no AHB transfer. The interconnect stays unrestricted (ADR-0005);
// this is the DMA refusing, not the fabric blocking (DECISIONS D-16).
//
// Rulings of 2026-11-03 (DECISIONS D-32):
//   DMA-12  both addresses are checked in E_RA, before any bus access: a bad
//           DAR no longer costs a source read (a P2M FIFO item).
//   DMA-10  a SAR or DAR not aligned to SIZE is refused the same way.
//   DMA-14  SIZE is taken once, at the grant (size_l), so a CR write during the
// beat (CR = 0 stops a channel) cannot change the beat's size. SAR and
//           DAR are taken at the grant too (sar_l, dar_l): the beat is atomic
//           ([N-7.11]), so a DAR rewritten during the read can no longer turn a
//           checked beat into a refused one after its source read (DMA-12).
//   DMA-15  a memory-to-memory beat raises no dma_ack.
//   DMA-13  ACK_CYCLES outside 1..4 stops elaboration (ack_cnt is 2 bits).
//
// An AHB ERROR is taken on the data-phase cycle where HREADY is high with
// HRESP = ERROR (the second cycle of the two-cycle response). The engine has
// no second transfer queued at that point, so nothing needs cancelling.
// =============================================================================

module dma_engine
    import garuda_pkg::*;
#(
    parameter int unsigned ACK_CYCLES = 32'd2  // dma_ack width in hclk (D-16)
)(
    input wire hclk,
    input wire hreset_n,
    // ---- arbiter ------------------------------------------------------------
    input wire grant_valid_i,
    input wire [DMA_CH_W-1:0] grant_ch_i,
    // ---- selected channel's registers ---------------------------------------
    input wire [DMA_NCH * WORD_W - 1:0] sar_i,
    input wire [DMA_NCH * WORD_W - 1:0] dar_i,
    input wire [DMA_NCH * DMA_SIZE_W - 1:0] size_i,
    input wire [DMA_NCH-1:0] m2m_i,  // channel n is in memory-to-memory mode
    // ---- per-channel results ------------------------------------------------
    output reg [DMA_NCH-1:0] beat_done_o,
    output reg [DMA_NCH-1:0] beat_err_o,
    output reg [ERR_PHASE_W-1:0] err_phase_o,
    output wire [DMA_NCH-1:0] dma_ack_o,
    // ---- AHB-Lite master ----------------------------------------------------
    output reg [WORD_W-1:0] haddr_o,
    output reg [HTRANS_W-1:0] htrans_o,
    output reg hwrite_o,
    output reg [HSIZE_W-1:0] hsize_o,
    output reg [WORD_W-1:0] hwdata_o,
    input wire [WORD_W-1:0] hrdata_i,
    input wire hready_i,
    input wire hresp_i,
    // channel n has a beat from its grant to its result (DMA-9)
    output wire [DMA_NCH-1:0] inflight_o
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned CH_W = 32'd3;
    localparam int unsigned ACK_W = 32'd6;
    localparam int unsigned SZ_W = 32'd2;


    reg  [CH_W-1:0]  ch;
    reg  [WORD_W-1:0] data_q;
    // DMA-14: the beat's SIZE, taken at the grant
    reg  [DMA_SIZE_W-1:0]  size_l;
    // the beat's addresses, taken at the grant
    reg [WORD_W-1:0] sar_l;
    reg [WORD_W-1:0] dar_l;
    reg         m2m_l;  // DMA-15: the beat's channel is M2M

    wire [WORD_W-1:0] sar  = sar_l;
    wire [WORD_W-1:0] dar  = dar_l;
    wire [DMA_SIZE_W-1:0]  size = size_l;

    // DMA-10: an address must be aligned to the beat size (only its two low
    // bits matter)
    function automatic misaligned(input [BYTE_OFF_W-1:0] lo,
                                  input [SZ_W-1:0] sz);
        misaligned = (sz == 2'd1 && lo[0]) || (sz == 2'd2 && lo != 2'b00);
    endfunction
    wire sar_bad = (sar[31:28] == 4'h0) || (sar[31:28] == 4'h1)
        || misaligned(sar[1:0], size);
    wire dar_bad = (dar[31:28] == 4'h0) || (dar[31:28] == 4'h1)
        || misaligned(dar[1:0], size);

    // DMA-13: ACK_CYCLES is 1..4
    generate if (ACK_CYCLES < 1 || ACK_CYCLES > 4) begin
        : g_ack_cycles_out_of_range
        // no such module: elaboration stops here
        dma_ACK_CYCLES_must_be_1_to_4 u_stop ();
    end endgenerate

    // lane extraction and replication for sub-word beats
    function automatic [BYTE_W-1:0] pick_byte(input [BYTE_OFF_W-1:0] off,
                                              input [WORD_W-1:0] d);
        case (off)
            2'b00: pick_byte = d[7:0];
            2'b01: pick_byte = d[15:8];
            2'b10: pick_byte = d[23:16];
            default: pick_byte = d[31:24];
        endcase
    endfunction
    wire [BYTE_W-1:0]  rd_byte = pick_byte(sar[1:0], hrdata_i);
    wire [HALF_W-1:0] rd_half = sar[1] ? hrdata_i[31:16] : hrdata_i[15:0];
    wire [WORD_W-1:0] rd_repl = (size == 2'd0) ? {4{rd_byte}} :
                          (size == 2'd1) ? {2{rd_half}} : hrdata_i;

    // F4 (2026-11-17): the channels' registers as arrays and the channel as a
    // one-hot vector, so nothing is indexed by a product or past the last
    // channel (HAL INDXOP, POOBID). The slots past DMA_NCH read 0 and are
    // never granted.
    localparam int unsigned CH_SLOTS = 32'd8;  // 2**DMA_CH_W
    wire [DMA_SIZE_W-1:0] size_a [0:CH_SLOTS-1];
    wire [WORD_W-1:0] sar_a [0:CH_SLOTS-1];
    wire [WORD_W-1:0] dar_a [0:CH_SLOTS-1];
    wire [CH_SLOTS-1:0] m2m_a = {{(CH_SLOTS - DMA_NCH){1'b0}}, m2m_i};
    wire [DMA_NCH-1:0] ch_hot;    // the beat's channel
    wire [DMA_NCH-1:0] grant_hot; // the granted channel
    genvar k;
    generate for (k = 0; k < CH_SLOTS; k = k + 1) begin : g_slot
        if (k < DMA_NCH) begin : g_ch
            assign size_a[k] = size_i[DMA_SIZE_W*k +: DMA_SIZE_W];
            assign sar_a[k]  = sar_i[WORD_W*k +: WORD_W];
            assign dar_a[k]  = dar_i[WORD_W*k +: WORD_W];
            assign ch_hot[k]    = (ch == CH_W'(k));
            assign grant_hot[k] = (grant_ch_i == CH_W'(k));
        end else begin : g_none
            assign size_a[k] = '0;
            assign sar_a[k]  = '0;
            assign dar_a[k]  = '0;
        end
    end endgenerate

    // dma_ack stretch
    reg [ACK_W-1:0] ack_q;

    // ---- the beat's state machine (dma_eng_fsm) -----------------------------
    wire idle;
    wire addr_ok;    // RA: the read address goes out
    wire ra_rd_err;  // RA: bad source
    wire ra_wr_err;  // RA: bad destination
    wire wa;         // WA: the write address goes out
    wire rd_acc;     // an address phase is accepted
    wire wd_acc;
    wire rd_end;     // a data phase ends
    wire wd_end;
    wire take = idle && grant_valid_i;  // MUTANT: ENG-1 guard removed

    dma_eng_fsm u_fsm (
        .hclk(hclk), .hreset_n(hreset_n),
        .take_i(take), .sar_bad_i(sar_bad), .dar_bad_i(dar_bad),
        .addr_pend_i(htrans_o[1]), .hready_i(hready_i), .hresp_i(hresp_i),
        .idle_o(idle), .addr_ok_o(addr_ok), .ra_rd_err_o(ra_rd_err),
        .ra_wr_err_o(ra_wr_err), .wa_o(wa), .rd_acc_o(rd_acc),
        .wd_acc_o(wd_acc), .rd_end_o(rd_end), .wd_end_o(wd_end)
    );

    assign inflight_o = !idle ? ch_hot : (take ? grant_hot : 6'd0);
    assign dma_ack_o = ack_q;

    wire rd_err    = rd_end && hresp_i;
    wire wr_err    = wd_end && hresp_i;
    wire beat_ok   = wd_end && !hresp_i;
    wire any_err   = ra_rd_err || ra_wr_err || rd_err || wr_err;
    wire ack_fire  = beat_ok && !m2m_l;                       // DMA-15

    // the beat's channel and registers, taken at the grant (DMA-14, DMA-15)
    always_ff @(posedge hclk or negedge hreset_n) begin : p_grant
        if (!hreset_n) begin
            ch <= 3'd0;
            size_l <= 2'd2;
            m2m_l <= 1'b0;
            sar_l <= 32'd0;
            dar_l <= 32'd0;
        end else if (take) begin
            ch <= grant_ch_i;
            size_l <= size_a[grant_ch_i];
            sar_l <= sar_a[grant_ch_i];
            dar_l <= dar_a[grant_ch_i];
            m2m_l <= m2m_a[grant_ch_i];
        end
    end

    // the word read, replicated to the beat's lanes
    always_ff @(posedge hclk or negedge hreset_n) begin : p_data
        if (!hreset_n) begin
            data_q <= 32'd0;
        end else if (rd_end && !hresp_i) begin
            data_q <= rd_repl;
        end
    end

    // ---- AHB-Lite address phase ---------------------------------------------
    always_ff @(posedge hclk or negedge hreset_n) begin : p_addr
        if (!hreset_n) begin
            haddr_o <= 32'd0;
            hsize_o <= 3'b010;
        end else if (addr_ok) begin
            haddr_o <= sar;
            hsize_o <= {1'b0, size};
        end else if (wa) begin
            haddr_o <= dar;
            hsize_o <= {1'b0, size};
        end
    end

    always_ff @(posedge hclk or negedge hreset_n) begin : p_htrans
        if (!hreset_n) begin
            htrans_o <= 2'b00;
        end else if (addr_ok || wa) begin
            htrans_o <= 2'b10;  // NONSEQ
        end else if (rd_acc || wd_acc) begin
            htrans_o <= 2'b00;  // address accepted
        end
    end

    always_ff @(posedge hclk or negedge hreset_n) begin : p_hwrite
        if (!hreset_n) begin
            hwrite_o <= 1'b0;
        end else if (addr_ok || wd_end) begin
            hwrite_o <= 1'b0;
        end else if (wa) begin
            hwrite_o <= 1'b1;
        end
    end

    // the write data, for the data phase after the accepted address
    always_ff @(posedge hclk or negedge hreset_n) begin : p_hwdata
        if (!hreset_n) begin
            hwdata_o <= 32'd0;
        end else if (wd_acc) begin
            hwdata_o <= data_q;
        end
    end

    // ---- per-channel results: one-cycle strobes -----------------------------
    always_ff @(posedge hclk or negedge hreset_n) begin : p_result
        if (!hreset_n) begin
            beat_done_o <= 6'd0;
            beat_err_o <= 6'd0;
        end else begin
            beat_done_o <= beat_ok ? ch_hot : 6'd0;
            beat_err_o <= any_err ? ch_hot : 6'd0;
        end
    end

    // ERRPHASE: 1 read, 2 write; held between errors
    always_ff @(posedge hclk or negedge hreset_n) begin : p_errph
        if (!hreset_n) begin
            err_phase_o <= 2'd0;
        end else if (ra_rd_err || rd_err) begin
            err_phase_o <= 2'd1;
        end else if (ra_wr_err || wr_err) begin
            err_phase_o <= 2'd2;
        end
    end

    // ---- dma_ack: ACK_CYCLES cycles per completed peripheral beat -----------
    // A completing beat sets its channel's bit; the bits stay set for the
    // next ACK_CYCLES - 1 cycles (F4: the hold is sized to the parameter, no
    // counter bit that cannot change).
    wire ack_hold;
    generate if (ACK_CYCLES == 1) begin : g_ack1
        assign ack_hold = 1'b0;
    end else if (ACK_CYCLES == 2) begin : g_ack2
        reg fire_q;
        always_ff @(posedge hclk or negedge hreset_n) begin : p_fire
            if (!hreset_n) begin
                fire_q <= 1'b0;
            end else begin
                fire_q <= ack_fire;
            end
        end
        assign ack_hold = fire_q;
    end else begin : g_ackn
        // ACK_CYCLES 3 or 4: count the cycles left after the first
        localparam int unsigned CNT_W = 32'd2;
        reg [CNT_W-1:0] ack_cnt;
        always_ff @(posedge hclk or negedge hreset_n) begin : p_ack_cnt
            if (!hreset_n) begin
                ack_cnt <= '0;
            end else if (ack_fire) begin
                ack_cnt <= CNT_W'(ACK_CYCLES - 32'd1);
            end else if (ack_cnt != '0) begin
                ack_cnt <= CNT_W'(ack_cnt - 1'b1);
            end
        end
        assign ack_hold = (ack_cnt != '0);
    end endgenerate

    wire [ACK_W-1:0] ack_keep = ack_hold ? ack_q : 6'd0;

    always_ff @(posedge hclk or negedge hreset_n) begin : p_ack
        if (!hreset_n) begin
            ack_q <= 6'd0;
        end else begin
            ack_q <= ack_keep | (ack_fire ? ch_hot : 6'd0);
        end
    end

endmodule
