`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 9 : functional coverage of the DMA
// dma_cov.sv
//
// From GARUDA-DMA-SPEC-001 sections 6 and 7. Bound to dma_top.
//   cg_beat  one sample per finished beat: channel, mode, size, alignment,
//            increment, outcome, how many channels wanted the bus
//   cg_ctrl  firmware actions on a channel and the cycles they collide with
// Not for synthesis, not under Icarus or Verilator.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
`ifndef VERILATOR
module dma_cov (
    input wire        hclk_i, hreset_n_i,
    input wire [2:0]  st, ch,
    input wire [5:0]  eligible, beat_done, beat_err,
    input wire [2:0]  err_phase,
    input wire [6*32-1:0] cr, sar, dar, stat,
    input wire [5:0]  wr_cr, wr_iclr, wr_cnt, dma_req_i,
    input wire [31:0] wdata,
    input wire        hready_i
);
    localparam [2:0] E_IDLE = 3'd0, E_RA = 3'd1, E_RD = 3'd2, E_WA = 3'd3, E_WD = 3'd4;
    typedef enum {OK, ERR_FORBIDDEN_SRC, ERR_BUS_READ, ERR_FORBIDDEN_DST, ERR_BUS_WRITE} out_e;
    out_e outcome; reg [2:0] st_d; integer contenders, waits;
    reg [31:0] c_cr, c_sar, c_dar;
    always @(posedge hclk_i) begin
        st_d <= st;
        if (st == E_IDLE) contenders <= $countones(eligible);
        if (st == E_IDLE) waits <= 0; else if (!hready_i && waits < 15) waits <= waits + 1;
    end
    wire result = |(beat_done | beat_err);
    always @(*) begin
        c_cr = cr[32*ch +: 32]; c_sar = sar[32*ch +: 32]; c_dar = dar[32*ch +: 32];
        outcome = (|beat_done) ? OK :
                  (st_d == E_RA) ? ERR_FORBIDDEN_SRC : (st_d == E_RD) ? ERR_BUS_READ :
                  (st_d == E_WA) ? ERR_FORBIDDEN_DST : ERR_BUS_WRITE;
    end
    covergroup cg_beat @(posedge hclk_i iff (hreset_n_i && result));
        option.per_instance = 1;
        cp_channel: coverpoint ch { bins c[] = {[0:5]}; }
        cp_mode: coverpoint c_cr[2:1] { bins p2m = {0}; bins m2p = {1}; bins m2m = {2}; }
        cp_size: coverpoint c_cr[6:5] { bins byte_ = {0}; bins half = {1}; bins word = {2}; }
        cp_sinc: coverpoint c_cr[3]; cp_dinc: coverpoint c_cr[4];
        cp_src_lane: coverpoint c_sar[1:0]; cp_dst_lane: coverpoint c_dar[1:0];
        cp_outcome: coverpoint outcome;
        cp_contenders: coverpoint contenders { bins alone = {1}; bins two = {2}; bins more = {[3:6]}; }
        cp_waits: coverpoint waits { bins none = {0}; bins some = {[1:3]}; bins many = {[4:15]}; }
        x_channel_mode: cross cp_channel, cp_mode;
        x_channel_outcome: cross cp_channel, cp_outcome;
        // sub-word beats from every source lane to every destination lane
        x_size_lanes: cross cp_size, cp_src_lane, cp_dst_lane {
            ignore_bins word_unaligned = binsof(cp_size.word) && (!binsof(cp_src_lane) intersect {0} || !binsof(cp_dst_lane) intersect {0});
            ignore_bins half_odd = binsof(cp_size.half) && (binsof(cp_src_lane) intersect {1,3} || binsof(cp_dst_lane) intersect {1,3});
        }
        x_inc: cross cp_sinc, cp_dinc, cp_mode;
        x_channel_contended: cross cp_channel, cp_contenders;
    endgroup

    // firmware actions, per channel, and the collisions of [N-7.17] to [N-7.19]
    integer k; reg [2:0] wch; reg wr_any, cr_en, cr_collide, iclr_collide, cr_active;
    always @(*) begin
        wch = 0; for (k = 0; k < 6; k++) if (wr_cr[k] | wr_iclr[k] | wr_cnt[k]) wch = k;
        wr_any = |(wr_cr | wr_iclr | wr_cnt);
        cr_en = wdata[0];
        cr_active = stat[32*wch + 16];
        cr_collide = wr_cr[wch] && (beat_done[wch] || beat_err[wch]);
        iclr_collide = wr_iclr[wch] && (beat_done[wch] || beat_err[wch]);
    end
    covergroup cg_ctrl @(posedge hclk_i iff (hreset_n_i && wr_any));
        option.per_instance = 1;
        cp_reg: coverpoint {wr_cr[wch], wr_cnt[wch], wr_iclr[wch]} { bins cr = {3'b100}; bins cnt = {3'b010}; bins iclr = {3'b001}; }
        cp_en: coverpoint cr_en;
        cp_while_active: coverpoint cr_active;
        cp_cr_collides_with_result: coverpoint cr_collide { bins no = {0}; bins yes = {1}; }
        cp_iclr_collides_with_result: coverpoint iclr_collide { bins no = {0}; bins yes = {1}; }
        cp_in_beat: coverpoint (st != E_IDLE && ch == wch) { bins between = {0}; bins inside_own_beat = {1}; }
        x_reg_active: cross cp_reg, cp_while_active;
        x_en_in_beat: cross cp_en, cp_in_beat, cp_while_active;
    endgroup
    cg_beat cb = new();
    cg_ctrl cc = new();
endmodule

bind dma_top dma_cov u_dma_cov (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .st(u_eng.st), .ch(u_eng.ch),
    .eligible(eligible), .beat_done(beat_done), .beat_err(beat_err), .err_phase(err_phase),
    .cr(cr), .sar(sar), .dar(dar), .stat(stat), .wr_cr(wr_cr), .wr_iclr(wr_iclr), .wr_cnt(wr_cnt),
    .dma_req_i(dma_req_i), .wdata(wdata), .hready_i(hready_i));
`endif
`endif
`endif
