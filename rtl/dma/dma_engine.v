`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 9 : beat engine and AHB-Lite master M3
// dma_engine.v
//
// Spec: GARUDA-DMA-SPEC-001 Rev 3.0 §7.1, §7.2, §7.5, §7.7; AHB-SPEC §5.1
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
// An AHB ERROR is taken on the data-phase cycle where HREADY is high with
// HRESP = ERROR (the second cycle of the two-cycle response). The engine has
// no second transfer queued at that point, so nothing needs cancelling.
// =============================================================================

module dma_engine #(
    parameter integer ACK_CYCLES = 2           // dma_ack width in hclk (D-16)
)(
    input  wire        hclk_i,
    input  wire        hreset_n_i,

    // ---- arbiter -----------------------------------------------------------------
    input  wire        grant_valid_i,
    input  wire [2:0]  grant_ch_i,

    // ---- selected channel's registers ------------------------------------------
    input  wire [6*32-1:0] sar_i,
    input  wire [6*32-1:0] dar_i,
    input  wire [6*2-1:0]  size_i,

    // ---- per-channel results -------------------------------------------------------
    output reg  [5:0]  beat_done_o,
    output reg  [5:0]  beat_err_o,
    output reg  [2:0]  err_phase_o,
    output wire [5:0]  dma_ack_o,

    // ---- AHB-Lite master ---------------------------------------------------------------
    output reg  [31:0] haddr_o,
    output reg  [1:0]  htrans_o,
    output reg         hwrite_o,
    output reg  [2:0]  hsize_o,
    output wire [2:0]  hburst_o,
    output reg  [31:0] hwdata_o,
    input  wire [31:0] hrdata_i,
    input  wire        hready_i,
    input  wire        hresp_i,

    output wire        busy_o
);

    localparam [2:0] E_IDLE = 3'd0, E_RA = 3'd1, E_RD = 3'd2, E_WA = 3'd3, E_WD = 3'd4;

    reg  [2:0]  st;
    reg  [2:0]  ch;
    reg  [31:0] data_q;

    wire [31:0] sar  = sar_i[32*ch +: 32];
    wire [31:0] dar  = dar_i[32*ch +: 32];
    wire [1:0]  size = size_i[2*ch +: 2];

    wire sar_bad = (sar[31:28] == 4'h0) || (sar[31:28] == 4'h1);
    wire dar_bad = (dar[31:28] == 4'h0) || (dar[31:28] == 4'h1);

    // lane extraction and replication for sub-word beats
    wire [7:0]  rd_byte = hrdata_i >> (8 * sar[1:0]);
    wire [15:0] rd_half = sar[1] ? hrdata_i[31:16] : hrdata_i[15:0];
    wire [31:0] rd_repl = (size == 2'd0) ? {4{rd_byte}} :
                          (size == 2'd1) ? {2{rd_half}} : hrdata_i;

    // dma_ack stretch
    reg [5:0] ack_q;
    reg [1:0] ack_cnt;

    assign hburst_o = 3'b000;                  // SINGLE only
    assign busy_o   = (st != E_IDLE);
    assign dma_ack_o = ack_q;

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            st <= E_IDLE; ch <= 3'd0; data_q <= 32'd0;
            haddr_o <= 32'd0; htrans_o <= 2'b00; hwrite_o <= 1'b0;
            hsize_o <= 3'b010; hwdata_o <= 32'd0;
            beat_done_o <= 6'd0; beat_err_o <= 6'd0; err_phase_o <= 3'd0;
            ack_q <= 6'd0; ack_cnt <= 2'd0;
        end else begin
            beat_done_o <= 6'd0;
            beat_err_o  <= 6'd0;

            if (ack_cnt != 2'd0) ack_cnt <= ack_cnt - 2'd1;
            else                 ack_q   <= 6'd0;

            case (st)
                E_IDLE: begin
                    // Not in the cycle a result is being reported: the channel
                    // has not yet decremented REMAINING / set its taken flag,
                    // so its eligibility is stale (would duplicate a beat).
                    if (grant_valid_i && beat_done_o == 6'd0 && beat_err_o == 6'd0) begin
                        ch <= grant_ch_i;
                        st <= E_RA;
                    end
                end
                E_RA: begin
                    // present the read (or refuse a forbidden source)
                    if (sar_bad) begin
                        beat_err_o[ch] <= 1'b1; err_phase_o <= 3'd1;
                        st <= E_IDLE;
                    end else begin
                        haddr_o  <= sar;
                        htrans_o <= 2'b10;      // NONSEQ
                        hwrite_o <= 1'b0;
                        hsize_o  <= {1'b0, size};
                        st       <= E_RD;
                    end
                end
                E_RD: begin
                    if (htrans_o[1] && hready_i) htrans_o <= 2'b00;    // address accepted
                    else if (!htrans_o[1] && hready_i) begin           // data phase done
                        if (hresp_i) begin
                            beat_err_o[ch] <= 1'b1; err_phase_o <= 3'd1;
                            st <= E_IDLE;
                        end else begin
                            data_q <= rd_repl;
                            st     <= E_WA;
                        end
                    end
                end
                E_WA: begin
                    if (dar_bad) begin
                        beat_err_o[ch] <= 1'b1; err_phase_o <= 3'd2;
                        st <= E_IDLE;
                    end else begin
                        haddr_o  <= dar;
                        htrans_o <= 2'b10;
                        hwrite_o <= 1'b1;
                        hsize_o  <= {1'b0, size};
                        st       <= E_WD;
                    end
                end
                E_WD: begin
                    if (htrans_o[1] && hready_i) begin                 // address accepted
                        htrans_o <= 2'b00;
                        hwdata_o <= data_q;                            // data phase next
                    end else if (!htrans_o[1] && hready_i) begin      // data phase done
                        hwrite_o <= 1'b0;
                        if (hresp_i) begin
                            beat_err_o[ch] <= 1'b1; err_phase_o <= 3'd2;
                        end else begin
                            beat_done_o[ch] <= 1'b1;
                            ack_q[ch]       <= 1'b1;
                            ack_cnt         <= ACK_CYCLES - 1;
                        end
                        st <= E_IDLE;
                    end
                end
                default: st <= E_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
