`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 9 : bound properties of the DMA controller
// dma_sva.sv
//
// Spec: GARUDA-DMA-SPEC-001 Rev 3.0a, sections 6, 7, 10; decisions D-2, D-16,
// D-21; AUD-13. Plan: tb/dma/GARUDA_DMA_vplan.csv (F01-F51); every property
// names its feature row. Bound to dma_top at the end of this file and listed in
// rtl/dma/filelist.f, so it runs in tb_dma_top, in the DMA environment, in every
// chip simulation and in SBY (tb/dma/formal). Not compiled for synthesis.
//
// Ported 2026-10-12 (Track A, DMA plan D1) from ~/garuda_dv/rtl/dma/dma_sva.sv
// (2026-10-05, never run) into the portable form of Docs/handbook/H4_coding.md:
// yosys-slang rejects |-> and |=>, so every property is a boolean sampled on the
// clock: `A |-> B` is written `!(A) || (B)` and `A |=> B` is written
// `!past_ok || !$past(A) || (B)`. past_ok is 0 in reset and 1 from the second
// edge after it, so $past never looks into reset. Every implication-style
// assert has a cover on its antecedent (c_*), so a property that never triggers
// is visible (H6: VACUOUS is a finding).
//
// Expected values come from the specification and the rulings, not from the
// RTL. White-box signals (engine state and channel, request-taken flags) come
// in through the bind; every property that uses them says so.
//
// Detectors of open defects. They are always on (no waive define): a test that
// reaches the scenario fails, and is declared in its suite with the bug ID
// (xfail or a `known` line count), so the firing is counted, not hidden.
//   a_no_read_before_refusal            DMA-10  source read before a bad DAR is refused
//   a_remaining_complete_consistent[n]  DMA-11  COMPLETE with REMAINING != 0 (R-6)
//   a_no_rem_underflow[n]               DMA-11  a beat completes with REMAINING = 0
//   a_beat_belongs_to_arm[n]            DMA-11  a beat started before the last arm
//   a_haddr_aligned                     DMA-13  a misaligned transfer on the bus (unaligned SAR/DAR)
//   a_beat_size_atomic                  DMA-14  a beat changes size after it was taken (CR write in flight)
// Formal tasks pick their properties with `chformal` in tb/dma/formal/*.toml (no
// ifdefs here), so this file is the same in every simulation and proof.
// a_arm_loads encodes the proposed DMA-9 ruling (arming loads REMAINING from CNT);
// it changes if the ruling is "resume".
// =============================================================================

`ifdef FORMAL
  `define GARUDA_DMA_SVA
`elsif SYNTHESIS
`else
  `define GARUDA_DMA_SVA
`endif

`ifdef GARUDA_DMA_SVA
module dma_sva #(
    parameter [17:0] PRIO       = {3'd0, 3'd4, 3'd2, 3'd1, 3'd3, 3'd5},
    parameter integer ACK_CYCLES = 2
)(
    input wire        hclk_i,
    input wire        hreset_n_i,
    input wire        pclk_i,
    input wire        preset_n_i,
    // APB port
    input wire        psel_i,
    input wire        penable_i,
    input wire        pwrite_i,
    input wire [11:0] paddr_i,
    input wire [31:0] pwdata_i,
    input wire [31:0] prdata_o,
    input wire        pready_o,
    input wire        pslverr_o,
    // AHB-Lite master M3
    input wire [31:0] haddr_o,
    input wire [1:0]  htrans_o,
    input wire        hwrite_o,
    input wire [2:0]  hsize_o,
    input wire [2:0]  hburst_o,
    input wire [31:0] hwdata_o,
    input wire [31:0] hrdata_i,
    input wire        hready_i,
    input wire        hresp_i,
    // sideband and interrupts
    input wire [5:0]  dma_req_i,
    input wire [5:0]  dma_ack_o,
    input wire [5:0]  dma_complete_o,
    input wire [5:0]  dma_error_o,
    // dma_top's own wires between the sub-blocks
    input wire [5:0]  wr_cr, wr_sar, wr_dar, wr_cnt, wr_iclr,
    input wire [31:0] wdata,
    input wire [191:0] cr, sar, dar, cnt, stat,
    input wire [5:0]  eligible, beat_done, beat_err,
    input wire [2:0]  err_phase,
    input wire        grant_valid,
    input wire [2:0]  grant_ch,
    // white-box: engine state and channel, request-taken flags (dma_chan)
    input wire [2:0]  eng_st,
    input wire [2:0]  eng_ch,
    input wire [5:0]  taken
);
    localparam [1:0] T_IDLE = 2'b00, T_NONSEQ = 2'b10;
    localparam [1:0] M_M2M = 2'd2;
    localparam [2:0] E_IDLE = 3'd0, E_RA = 3'd1, E_RD = 3'd2, E_WA = 3'd3, E_WD = 3'd4;   // dma_engine encoding

    // ------------------------------------------------------------------ helpers
    // The register map of spec section 6, written here from the specification,
    // not copied from dma_apb_slave.
    function automatic bit f_chan_reg(input [11:0] a);
        return (a[11:8] == 4'h0) && (a[7:5] < 3'd6) && (a[4:2] <= 3'd5) && (a[1:0] == 2'b00);
    endfunction
    function automatic bit f_mapped(input [11:0] a);
        return f_chan_reg(a) || (a == 12'h100);
    endfunction
    function automatic bit f_read_only(input [11:0] a);       // STAT and GSTAT
        return (a == 12'h100) || (f_chan_reg(a) && a[4:2] == 3'd4);
    endfunction
    function automatic bit f_writable(input [11:0] a);         // CR SAR DAR CNT ICLR
        return f_chan_reg(a) && (a[4:2] != 3'd4);
    endfunction
    function automatic [31:0] f_gstat(input [191:0] s);
        f_gstat = 32'd0;
        for (int n = 0; n < 6; n++) begin
            f_gstat[n]      = s[32*n + 16];
            f_gstat[8 + n]  = s[32*n + 17];
            f_gstat[16 + n] = s[32*n + 18];
        end
    endfunction
    function automatic [31:0] f_read(input [11:0] a, input [191:0] c, s1, d1, n1, s2);
        f_read = 32'd0;                                           // unmapped and ICLR read 0
        if (a == 12'h100) f_read = f_gstat(s2);
        else if (f_chan_reg(a))
            case (a[4:2])
                3'd0: f_read = c [32*a[7:5] +: 32];
                3'd1: f_read = s1[32*a[7:5] +: 32];
                3'd2: f_read = d1[32*a[7:5] +: 32];
                3'd3: f_read = n1[32*a[7:5] +: 32];
                3'd4: f_read = s2[32*a[7:5] +: 32];
                default: f_read = 32'd0;
            endcase
    endfunction
    function automatic [31:0] f_step(input [1:0] size);
        return (size == 2'd0) ? 32'd1 : (size == 2'd1) ? 32'd2 : 32'd4;
    endfunction
    function automatic bit f_r9_bad(input [31:0] a);            // ISRAM 0x0..., Boot ROM 0x1...
        return a[31:29] == 3'b000;                                // region nibble 0 or 1
    endfunction
    function automatic [2:0] f_prio(input [2:0] n);
        return PRIO[3*n +: 3];
    endfunction
    // the destination byte lanes of a sub-word beat carry the source byte lanes
    // (AHB-Lite lane rules; the DMA may drive the other lanes with anything)
    function automatic bit f_lanes_ok(input [2:0] size, input [1:0] ra, input [1:0] wa,
                                      input [31:0] rd, input [31:0] wd);
        case (size)
            3'b000:  return wd[8*wa +: 8]      == rd[8*ra +: 8];
            3'b001:  return wd[16*wa[1] +: 16] == rd[16*ra[1] +: 16];
            default: return wd == rd;
        endcase
    endfunction

    wire any_wr   = |{wr_cr, wr_sar, wr_dar, wr_cnt, wr_iclr};
    // R-9 check of the engine's current channel. Kept out of $past(): Verilator 5.052
    // rejects a variable part-select inside $past ("Selection index is constantly
    // unknown"), TOOL-24.
    wire sar_bad_cur = f_r9_bad(sar[32*eng_ch +: 32]);              // white-box channel
    wire dar_bad_cur = f_r9_bad(dar[32*eng_ch +: 32]);
    wire apb_acc  = psel_i && penable_i;
    wire apb_wacc = psel_i && penable_i && pwrite_i;
    wire rd_addr  = (htrans_o == T_NONSEQ) && !hwrite_o && hready_i;     // read address phase accepted
    wire wr_addr  = (htrans_o == T_NONSEQ) &&  hwrite_o && hready_i;     // write address phase accepted
    // the engine takes a beat (white-box state): it latches the channel here ([N-7.11])
    wire eng_take = (eng_st == E_IDLE) && grant_valid && (beat_done == 6'd0) && (beat_err == 6'd0);

    // ------------------------------------------------------------------ helper state
    reg          past_ok, ppast_ok;         // $past is valid (hclk / pclk): 0 in reset, 1 from the 2nd edge
    reg          live_q;
    reg          dp_rd, dp_wr;              // a read / write data phase is pending
    reg          rd_err_pend;               // the last read ended in ERROR; no write may follow
    reg          beat_open;                 // a read has been accepted and its beat has no result yet
    reg  [2:0]   beat_ch;
    reg  [3:0]   beat_gen;
    reg  [5:0][3:0] arm_gen;                // arm count per channel
    reg  [5:0]   need_low;                  // the request was served and has not dropped since
    reg  [5:0][3:0] ack_len;                // hclk cycles the current ack has been high (saturates)
    reg          acc_q;
    reg  [31:0]  rd_data_q;                 // data of the last successful read
    reg  [1:0]   rd_lane_q, wr_lane_q;      // byte offset of the read and of the write in flight
    reg  [3:0]   wr_hist;                   // any_wr of the last four hclk cycles (back-to-back cover)
    reg  [1:0]   beat_size_q;               // the channel's SIZE when the engine took the beat (white-box)

    wire [5:0] en, comp, err, sinc, dinc, iec, iee, active, arm, hwclr;
    wire [5:0][1:0]  mode, csize;
    wire [5:0][15:0] rem;
    wire [5:0][2:0]  eph;
    genvar g;
    generate for (g = 0; g < 6; g++) begin : g_view
        assign en[g]     = cr[32*g + 0];
        assign mode[g]   = cr[32*g + 1 +: 2];
        assign sinc[g]   = cr[32*g + 3];
        assign dinc[g]   = cr[32*g + 4];
        assign csize[g]  = cr[32*g + 5 +: 2];
        assign iec[g]    = cr[32*g + 7];
        assign iee[g]    = cr[32*g + 8];
        assign rem[g]    = stat[32*g +: 16];
        assign active[g] = stat[32*g + 16];
        assign comp[g]   = stat[32*g + 17];
        assign err[g]    = stat[32*g + 18];
        assign eph[g]    = stat[32*g + 19 +: 3];
        // hardware clears EN on the last successful beat or on an error ([N-7.3], [N-7.13])
        assign hwclr[g]  = (beat_done[g] && rem[g] == 16'd1) || beat_err[g];
        // software arms the channel: EN written 0 -> 1 and hardware is not clearing it
        assign arm[g]    = wr_cr[g] && wdata[0] && !en[g] && !hwclr[g];
    end endgenerate

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            live_q <= 1'b0; past_ok <= 1'b0;
            dp_rd <= 1'b0; dp_wr <= 1'b0; rd_err_pend <= 1'b0;
            beat_open <= 1'b0; beat_ch <= 3'd0; beat_gen <= 4'd0;
            arm_gen <= '0; ack_len <= '0;
            need_low <= 6'd0; acc_q <= 1'b0; wr_hist <= 4'd0; beat_size_q <= 2'd2;
            rd_data_q <= 32'd0; rd_lane_q <= 2'd0; wr_lane_q <= 2'd0;
        end else begin
            live_q  <= 1'b1;
            past_ok <= live_q;
            acc_q   <= apb_wacc;
            wr_hist <= {wr_hist[2:0], any_wr};
            if (eng_take) beat_size_q <= csize[grant_ch];
            // data phases
            if (dp_rd && hready_i) begin dp_rd <= 1'b0; rd_err_pend <= hresp_i; end
            if (dp_wr && hready_i) dp_wr <= 1'b0;
            if (dp_rd && hready_i && !hresp_i) rd_data_q <= hrdata_i;
            if (rd_addr) begin dp_rd <= 1'b1; rd_err_pend <= 1'b0; rd_lane_q <= haddr_o[1:0]; end
            if (wr_addr) begin dp_wr <= 1'b1; rd_err_pend <= 1'b0; wr_lane_q <= haddr_o[1:0]; end
            // the beat in flight and the arm it belongs to
            if (rd_addr) begin beat_open <= 1'b1; beat_ch <= eng_ch; beat_gen <= arm_gen[eng_ch]; end
            else if (|beat_done || |beat_err) beat_open <= 1'b0;
            for (int n = 0; n < 6; n++) begin
                if (arm[n]) arm_gen[n] <= arm_gen[n] + 4'd1;
                // one beat per request assertion ([N-7.10]): served, and not yet dropped
                if (!dma_req_i[n])                                  need_low[n] <= 1'b0;
                else if (beat_done[n] && mode[n] != M_M2M)          need_low[n] <= 1'b1;
                ack_len[n] <= !dma_ack_o[n] ? 4'd0 : (ack_len[n] == 4'hF) ? 4'hF : ack_len[n] + 4'd1;
            end
        end
    end
    reg plive_q;
    always @(posedge pclk_i or negedge preset_n_i)
        if (!preset_n_i) begin plive_q <= 1'b0; ppast_ok <= 1'b0; end
        else             begin plive_q <= 1'b1; ppast_ok <= plive_q; end

    // the first hclk cycle of an ack pulse
    wire [5:0] ack_rise = dma_ack_o & ~{ack_len[5] != 4'd0, ack_len[4] != 4'd0, ack_len[3] != 4'd0,
                                        ack_len[2] != 4'd0, ack_len[1] != 4'd0, ack_len[0] != 4'd0};

`ifndef FORMAL
    // ------------------------------------------------------------------ elaboration
    // F49 / DMA-12: ack_cnt in dma_engine is two bits wide
    initial assert (ACK_CYCLES >= 1 && ACK_CYCLES <= 4)
        else $error("[SVA-FAIL] F49 ACK_CYCLES=%0d is outside 1..4 (dma_engine ack_cnt is 2 bits, DMA-12)", ACK_CYCLES);
`endif

    // ================================================================== reset (F11, F47)
    a_reset_state: assert property (@(posedge hclk_i)
        hreset_n_i || (htrans_o == T_IDLE && dma_ack_o == 6'd0 && dma_complete_o == 6'd0 &&
                       dma_error_o == 6'd0 && en == 6'd0 && beat_done == 6'd0 && beat_err == 6'd0))
        else $error("[SVA-FAIL] a_reset_state: bus, ack, interrupts or EN not quiet in reset (F11)");

    // ================================================================== APB port (F09, F10)
    a_pready: assert property (@(posedge pclk_i) disable iff (!preset_n_i) pready_o)
        else $error("[SVA-FAIL] a_pready (F10)");
    // AUD-13 (2026-10-12): PSLVERR exactly for an access to an offset that is not a
    // register; a write to read-only STAT/GSTAT is ignored without an error (F09.CHK3)
    a_pslverr_rule: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        pslverr_o == (apb_acc && !f_mapped(paddr_i)))
        else $error("[SVA-FAIL] a_pslverr_rule: paddr=%03h write=%0b pslverr=%0b (F09, AUD-13)", paddr_i, pwrite_i, pslverr_o);
    // read data is the register value at the pclk edge that ends the setup phase (OPEN-D1)
    a_read_data: assert property (@(posedge pclk_i) disable iff (!preset_n_i || !hreset_n_i)
        !ppast_ok || !(apb_acc && !pwrite_i && f_mapped(paddr_i) && $past(psel_i && !penable_i)) ||
        (prdata_o == $past(f_read(paddr_i, cr, sar, dar, cnt, stat))))
        else $error("[SVA-FAIL] a_read_data: paddr=%03h prdata=%08h (F10)", paddr_i, prdata_o);
    a_prdata_stable: assert property (@(posedge hclk_i) disable iff (!preset_n_i)
        !past_ok || !(apb_acc && $past(apb_acc)) || $stable(prdata_o))
        else $error("[SVA-FAIL] a_prdata_stable: PRDATA moved during the access phase (F10)");
    // exactly one hclk write strobe per APB write, to the decoded register only (R-3, D-16)
    a_strobe_first_cycle: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(apb_wacc && !acc_q) || (any_wr == f_writable(paddr_i)))
        else $error("[SVA-FAIL] a_strobe_first_cycle: paddr=%03h strobe=%0b (F10)", paddr_i, any_wr);
    a_strobe_once: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(apb_wacc && acc_q) || !any_wr)
        else $error("[SVA-FAIL] a_strobe_once: a second strobe in the same APB write (F10)");
    a_strobe_only_in_write: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !any_wr || apb_wacc)
        else $error("[SVA-FAIL] a_strobe_only_in_write (F10)");
    a_strobe_onehot: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        $onehot0({wr_cr, wr_sar, wr_dar, wr_cnt, wr_iclr}))
        else $error("[SVA-FAIL] a_strobe_onehot (F10)");
    a_strobe_wdata: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !any_wr || (wdata == pwdata_i))
        else $error("[SVA-FAIL] a_strobe_wdata (F10)");
    c_apb_read:      cover property (@(posedge pclk_i) disable iff (!preset_n_i || !hreset_n_i)
        apb_acc && !pwrite_i && f_mapped(paddr_i) && $past(psel_i && !penable_i));
    c_apb_access2:   cover property (@(posedge hclk_i) disable iff (!preset_n_i) apb_acc && $past(apb_acc));
    c_apb_write:     cover property (@(posedge hclk_i) disable iff (!hreset_n_i) apb_wacc && !acc_q);
    c_strobe:        cover property (@(posedge hclk_i) disable iff (!hreset_n_i) any_wr);

    generate for (g = 0; g < 6; g++) begin : g_ch
        // ---- decode: the strobe of channel g goes to the register the address names (F11)
        a_decode_cr:   assert property (@(posedge hclk_i) disable iff (!hreset_n_i) !wr_cr[g]   || (paddr_i[7:5] == g && paddr_i[4:2] == 3'd0))
            else $error("[SVA-FAIL] a_decode_cr[%0d]: paddr=%03h (F11)", g, paddr_i);
        a_decode_sar:  assert property (@(posedge hclk_i) disable iff (!hreset_n_i) !wr_sar[g]  || (paddr_i[7:5] == g && paddr_i[4:2] == 3'd1))
            else $error("[SVA-FAIL] a_decode_sar[%0d]: paddr=%03h (F11)", g, paddr_i);
        a_decode_dar:  assert property (@(posedge hclk_i) disable iff (!hreset_n_i) !wr_dar[g]  || (paddr_i[7:5] == g && paddr_i[4:2] == 3'd2))
            else $error("[SVA-FAIL] a_decode_dar[%0d]: paddr=%03h (F11)", g, paddr_i);
        a_decode_cnt:  assert property (@(posedge hclk_i) disable iff (!hreset_n_i) !wr_cnt[g]  || (paddr_i[7:5] == g && paddr_i[4:2] == 3'd3))
            else $error("[SVA-FAIL] a_decode_cnt[%0d]: paddr=%03h (F11)", g, paddr_i);
        a_decode_iclr: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) !wr_iclr[g] || (paddr_i[7:5] == g && paddr_i[4:2] == 3'd5))
            else $error("[SVA-FAIL] a_decode_iclr[%0d]: paddr=%03h (F11)", g, paddr_i);

        // ============================================================== CR (F01, F02, F03, F34)
        a_mode_legal: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) mode[g] != 2'b11)
            else $error("[SVA-FAIL] a_mode_legal[%0d] (F02)", g);
        a_size_legal: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) csize[g] != 2'b11)
            else $error("[SVA-FAIL] a_size_legal[%0d] (F03)", g);
        a_mode3_rejected: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(wr_cr[g] && wdata[2:1] == 2'b11) || (mode[g] == $past(mode[g])))
            else $error("[SVA-FAIL] a_mode3_rejected[%0d] (F02)", g);
        a_size3_rejected: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(wr_cr[g] && wdata[6:5] == 2'b11) || (csize[g] == $past(csize[g])))
            else $error("[SVA-FAIL] a_size3_rejected[%0d] (F03)", g);
        // the software fields land, also in the cycle hardware clears EN (a_sw_write_lands, [N-7.19])
        a_sw_write_lands: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(wr_cr[g]) ||
            ({iee[g], iec[g], dinc[g], sinc[g]} == $past({wdata[8], wdata[7], wdata[4], wdata[3]}) &&
             ($past(wdata[2:1]) == 2'b11 || mode[g]  == $past(wdata[2:1])) &&
             ($past(wdata[6:5]) == 2'b11 || csize[g] == $past(wdata[6:5]))))
            else $error("[SVA-FAIL] a_sw_write_lands[%0d] (F34)", g);
        a_cr_holds: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || $past(wr_cr[g]) ||
            ({iee[g], iec[g], csize[g], dinc[g], sinc[g], mode[g]} ==
             $past({iee[g], iec[g], csize[g], dinc[g], sinc[g], mode[g]})))
            else $error("[SVA-FAIL] a_cr_holds[%0d]: a software field changed with no write (F01)", g);
        a_cr_reserved: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            cr[32*g + 9 +: 23] == 23'd0)
            else $error("[SVA-FAIL] a_cr_reserved[%0d] (F01)", g);
        // EN: hardware wins ([N-7.17], R-7, erratum D-2)
        a_hw_wins_en: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(hwclr[g] && wr_cr[g]) || !en[g])
            else $error("[SVA-FAIL] a_hw_wins_en[%0d]: EN survived the hardware clear (F34, D-2)", g);
        a_en_follows_write: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(wr_cr[g] && !hwclr[g]) || (en[g] == $past(wdata[0])))
            else $error("[SVA-FAIL] a_en_follows_write[%0d] (F01)", g);
        a_en_cleared_by_hw: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(hwclr[g]) || !en[g])
            else $error("[SVA-FAIL] a_en_cleared_by_hw[%0d] (F19, F29)", g);
        a_en_zero_length: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(en[g] && rem[g] == 16'd0 && !wr_cr[g]) || !en[g])
            else $error("[SVA-FAIL] a_en_zero_length[%0d]: EN held with nothing left (C-27)", g);
        a_en_holds: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(en[g] && rem[g] != 16'd0 && !hwclr[g] && !wr_cr[g]) || en[g])
            else $error("[SVA-FAIL] a_en_holds[%0d]: EN dropped by itself (F20)", g);
        c_mode3:        cover property (@(posedge hclk_i) disable iff (!hreset_n_i) wr_cr[g] && wdata[2:1] == 2'b11);
        c_size3:        cover property (@(posedge hclk_i) disable iff (!hreset_n_i) wr_cr[g] && wdata[6:5] == 2'b11);
        c_cr_write:     cover property (@(posedge hclk_i) disable iff (!hreset_n_i) wr_cr[g]);
        c_collision_en: cover property (@(posedge hclk_i) disable iff (!hreset_n_i) hwclr[g] && wr_cr[g] && wdata[0]);
        c_hwclr:        cover property (@(posedge hclk_i) disable iff (!hreset_n_i) hwclr[g]);
        c_en_zero_left: cover property (@(posedge hclk_i) disable iff (!hreset_n_i) en[g] && rem[g] == 16'd0 && !wr_cr[g]);
        c_en_running:   cover property (@(posedge hclk_i) disable iff (!hreset_n_i) en[g] && rem[g] != 16'd0 && !hwclr[g] && !wr_cr[g]);

        // ============================================================== SAR / DAR / CNT (F04, F05, F29)
        a_sar_write: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(wr_sar[g]) || (sar[32*g +: 32] == $past(wdata)))
            else $error("[SVA-FAIL] a_sar_write[%0d] (F04)", g);
        a_sar_step: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(beat_done[g] && !wr_sar[g]) ||
            (sar[32*g +: 32] == $past(sar[32*g +: 32]) + ($past(sinc[g]) ? f_step($past(csize[g])) : 32'd0)))
            else $error("[SVA-FAIL] a_sar_step[%0d] (F04)", g);
        a_sar_holds: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(!beat_done[g] && !wr_sar[g]) || $stable(sar[32*g +: 32]))
            else $error("[SVA-FAIL] a_sar_holds[%0d]: SAR moved with no beat and no write (N-7.15)", g);
        a_dar_write: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(wr_dar[g]) || (dar[32*g +: 32] == $past(wdata)))
            else $error("[SVA-FAIL] a_dar_write[%0d] (F04)", g);
        a_dar_step: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(beat_done[g] && !wr_dar[g]) ||
            (dar[32*g +: 32] == $past(dar[32*g +: 32]) + ($past(dinc[g]) ? f_step($past(csize[g])) : 32'd0)))
            else $error("[SVA-FAIL] a_dar_step[%0d] (F04)", g);
        a_dar_holds: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(!beat_done[g] && !wr_dar[g]) || $stable(dar[32*g +: 32]))
            else $error("[SVA-FAIL] a_dar_holds[%0d]: DAR moved with no beat and no write (N-7.15)", g);
        a_cnt_write: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(wr_cnt[g]) || (cnt[32*g +: 32] == {16'd0, $past(wdata[15:0])}))
            else $error("[SVA-FAIL] a_cnt_write[%0d] (F05)", g);
        a_cnt_holds: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || $past(wr_cnt[g]) || $stable(cnt[32*g +: 32]))
            else $error("[SVA-FAIL] a_cnt_holds[%0d] (F05)", g);
        c_sar_write:  cover property (@(posedge hclk_i) disable iff (!hreset_n_i) wr_sar[g]);
        c_dar_write:  cover property (@(posedge hclk_i) disable iff (!hreset_n_i) wr_dar[g]);
        c_cnt_write:  cover property (@(posedge hclk_i) disable iff (!hreset_n_i) wr_cnt[g]);
        c_beat_done:  cover property (@(posedge hclk_i) disable iff (!hreset_n_i) beat_done[g]);
        c_step_sinc:  cover property (@(posedge hclk_i) disable iff (!hreset_n_i) beat_done[g] && sinc[g] && !wr_sar[g]);
        c_step_dinc:  cover property (@(posedge hclk_i) disable iff (!hreset_n_i) beat_done[g] && dinc[g] && !wr_dar[g]);

        // ============================================================== STAT (F06, F07, F18, F19, F29)
        a_active_def: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            active[g] == (en[g] && rem[g] != 16'd0))
            else $error("[SVA-FAIL] a_active_def[%0d] (F06)", g);
        a_stat_reserved: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            stat[32*g + 22 +: 10] == 10'd0 && eph[g] inside {3'd0, 3'd1, 3'd2})
            else $error("[SVA-FAIL] a_stat_reserved[%0d] (F06)", g);
        a_rem_step: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(beat_done[g]) || (rem[g] == $past(rem[g]) - 16'd1))
            else $error("[SVA-FAIL] a_rem_step[%0d] (F18)", g);
        a_rem_holds: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(!beat_done[g] && !arm[g]) || $stable(rem[g]))
            else $error("[SVA-FAIL] a_rem_holds[%0d] (F18)", g);
        // arming loads REMAINING from CNT (the proposed DMA-9 ruling; see the header)
        a_arm_loads: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(arm[g] && !beat_done[g]) ||
            (rem[g] == $past(cnt[32*g +: 16]) && comp[g] == ($past(cnt[32*g +: 16]) == 16'd0)))
            else $error("[SVA-FAIL] a_arm_loads[%0d]: arming must load REMAINING from CNT, COMPLETE only if CNT = 0 (F18, F42)", g);
        a_complete_on_last: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(beat_done[g] && rem[g] == 16'd1) || (comp[g] && rem[g] == 16'd0 && !en[g] && !active[g]))
            else $error("[SVA-FAIL] a_complete_on_last[%0d] ([N-7.3], F19)", g);
        a_complete_sticky: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(comp[g] && !(wr_iclr[g] && wdata[0]) && !arm[g]) || comp[g])
            else $error("[SVA-FAIL] a_complete_sticky[%0d] (F07)", g);
        a_complete_only_by_hw: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$rose(comp[g]) ||
            $past(beat_done[g] && rem[g] == 16'd1) || $past(arm[g] && cnt[32*g +: 16] == 16'd0))
            else $error("[SVA-FAIL] a_complete_only_by_hw[%0d] (F19)", g);
        a_error_on_beat_err: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(beat_err[g]) || (err[g] && !en[g] && eph[g] == $past(err_phase)))
            else $error("[SVA-FAIL] a_error_on_beat_err[%0d] ([N-7.13], F29)", g);
        a_error_sticky: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(err[g] && !(wr_iclr[g] && wdata[1]) && !beat_err[g]) || (err[g] && $stable(eph[g])))
            else $error("[SVA-FAIL] a_error_sticky[%0d] (F07, F29)", g);
        a_error_only_by_hw: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$rose(err[g]) || $past(beat_err[g]))
            else $error("[SVA-FAIL] a_error_only_by_hw[%0d] (F29)", g);
        // ICLR (F07): W1C, a hardware set in the same cycle wins ([N-7.19])
        a_iclr_complete: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(wr_iclr[g] && wdata[0] && !(beat_done[g] && rem[g] == 16'd1)) || !comp[g])
            else $error("[SVA-FAIL] a_iclr_complete[%0d] (F07)", g);
        a_iclr_error: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(wr_iclr[g] && wdata[1] && !beat_err[g]) || (!err[g] && eph[g] == 3'd0))
            else $error("[SVA-FAIL] a_iclr_error[%0d]: ERROR or ERRPHASE survived ICLR (F07)", g);
        a_set_beats_clear_complete: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(beat_done[g] && rem[g] == 16'd1 && wr_iclr[g] && wdata[0]) || comp[g])
            else $error("[SVA-FAIL] a_set_beats_clear_complete[%0d] (F07, F35)", g);
        a_set_beats_clear_error: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(beat_err[g] && wr_iclr[g] && wdata[1]) || err[g])
            else $error("[SVA-FAIL] a_set_beats_clear_error[%0d] (F07, F35)", g);
        // freeze at the failing beat ([N-7.15]), except for a software write (row F29 as corrected)
        a_freeze_on_error: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !$past(err[g] && !en[g] && !arm[g] && !beat_done[g]) || $stable(rem[g]))
            else $error("[SVA-FAIL] a_freeze_on_error[%0d] (F29)", g);
        c_arm:               cover property (@(posedge hclk_i) disable iff (!hreset_n_i) arm[g] && !beat_done[g]);
        c_zero_length:       cover property (@(posedge hclk_i) disable iff (!hreset_n_i) arm[g] && cnt[32*g +: 16] == 16'd0);
        c_cnt_max:           cover property (@(posedge hclk_i) disable iff (!hreset_n_i) arm[g] && cnt[32*g +: 16] == 16'hFFFF);
        c_complete:          cover property (@(posedge hclk_i) disable iff (!hreset_n_i) beat_done[g] && rem[g] == 16'd1);
        c_complete_held:     cover property (@(posedge hclk_i) disable iff (!hreset_n_i) comp[g] && !(wr_iclr[g] && wdata[0]) && !arm[g]);
        c_err_held:          cover property (@(posedge hclk_i) disable iff (!hreset_n_i) err[g] && !(wr_iclr[g] && wdata[1]) && !beat_err[g]);
        c_iclr_complete:     cover property (@(posedge hclk_i) disable iff (!hreset_n_i) wr_iclr[g] && wdata[0] && comp[g]);
        c_iclr_error:        cover property (@(posedge hclk_i) disable iff (!hreset_n_i) wr_iclr[g] && wdata[1] && err[g]);
        c_set_beats_clear_c: cover property (@(posedge hclk_i) disable iff (!hreset_n_i) beat_done[g] && rem[g] == 16'd1 && wr_iclr[g] && wdata[0]);
        c_set_beats_clear_e: cover property (@(posedge hclk_i) disable iff (!hreset_n_i) beat_err[g] && wr_iclr[g] && wdata[1]);
        c_frozen:            cover property (@(posedge hclk_i) disable iff (!hreset_n_i) err[g] && !en[g] && !arm[g] && !beat_done[g]);

        // ============================================================== DMA-11 detectors (F06, F19, F44)
        a_remaining_complete_consistent: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !comp[g] || (rem[g] == 16'd0))
            else $error("[SVA-FAIL] a_remaining_complete_consistent[%0d]: COMPLETE with REMAINING=%0d (R-6, DMA-11)", g, rem[g]);
        a_no_rem_underflow: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !beat_done[g] || (rem[g] != 16'd0))
            else $error("[SVA-FAIL] a_no_rem_underflow[%0d]: a beat completed with REMAINING = 0 (DMA-11)", g);
        a_beat_belongs_to_arm: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !beat_done[g] || (beat_open && beat_ch == g && beat_gen == arm_gen[g]))
            else $error("[SVA-FAIL] a_beat_belongs_to_arm[%0d]: a beat started before the last arm was counted in it (DMA-11)", g);
        c_comp:              cover property (@(posedge hclk_i) disable iff (!hreset_n_i) comp[g]);
        c_rearm_in_flight:   cover property (@(posedge hclk_i) disable iff (!hreset_n_i) arm[g] && beat_open && beat_ch == g);   // DMA-11 scenario
        c_restart_after_stop:cover property (@(posedge hclk_i) disable iff (!hreset_n_i) arm[g] && rem[g] != 16'd0);            // DMA-9 scenario

        // ============================================================== interrupts (F33)
        a_irq_level: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            (dma_complete_o[g] == (comp[g] && iec[g])) && (dma_error_o[g] == (err[g] && iee[g])))
            else $error("[SVA-FAIL] a_irq_level[%0d]: complete=%0b error=%0b (F33)", g, dma_complete_o[g], dma_error_o[g]);
        c_irq_complete: cover property (@(posedge hclk_i) disable iff (!hreset_n_i) $rose(dma_complete_o[g]));
        c_irq_error:    cover property (@(posedge hclk_i) disable iff (!hreset_n_i) $rose(dma_error_o[g]));
        c_comp_masked:  cover property (@(posedge hclk_i) disable iff (!hreset_n_i) comp[g] && !iec[g]);
        c_err_masked:   cover property (@(posedge hclk_i) disable iff (!hreset_n_i) err[g] && !iee[g]);

        // ============================================================== request / acknowledge (F21-F25)
        a_eligible_needs_active: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !eligible[g] || active[g])
            else $error("[SVA-FAIL] a_eligible_needs_active[%0d]: a disabled or finished channel asked for a beat (F25)", g);
        a_m2m_runs: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !(active[g] && mode[g] == M_M2M) || eligible[g])
            else $error("[SVA-FAIL] a_m2m_runs[%0d] ([N-7.5], F15)", g);
        a_peripheral_waits: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !(mode[g] != M_M2M && !dma_req_i[g]) || !eligible[g])
            else $error("[SVA-FAIL] a_peripheral_waits[%0d]: P2M/M2P eligible with no request (F23)", g);
        // sound form of spec section 10 a_one_beat_per_req (row F21 as corrected): while
        // the request is served, a P2M/M2P channel is not eligible, so no new beat is
        // taken for it. (Until 2026-10-12 this also forbade beat_done; formal showed that
        // is wrong when MODE changes inside a beat: a beat taken in M2M may complete after
        // software has set MODE back to P2M.)
        a_one_beat_per_req: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !(need_low[g] && mode[g] != M_M2M) || !eligible[g])
            else $error("[SVA-FAIL] a_one_beat_per_req[%0d]: a second beat for one request assertion ([N-7.10], F21)", g);
        a_failed_beat_keeps_request: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)   // white-box
            !past_ok || !$past(beat_err[g] && dma_req_i[g]) || (!taken[g] || !dma_req_i[g] || $past(taken[g])))
            else $error("[SVA-FAIL] a_failed_beat_keeps_request[%0d]: a failed beat consumed the request (DMA-8, F24)", g);
        a_ack_with_done: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !ack_rise[g] || beat_done[g])
            else $error("[SVA-FAIL] a_ack_with_done[%0d]: dma_ack without a successful beat (F22)", g);
        a_done_gives_ack: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !beat_done[g] || ack_rise[g])
            else $error("[SVA-FAIL] a_done_gives_ack[%0d]: a successful beat with no dma_ack (F22)", g);
        // row F22 as corrected: two hclk cycles, seen high by exactly one pclk edge
        a_ack_width: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !past_ok || !(!dma_ack_o[g] && $past(dma_ack_o[g])) || (ack_len[g] == 4'(ACK_CYCLES)))
            else $error("[SVA-FAIL] a_ack_width[%0d]: dma_ack was %0d hclk wide, expected %0d (D-16, F22)", g, ack_len[g], ACK_CYCLES);
        a_ack_one_pclk_edge: assert property (@(posedge pclk_i) disable iff (!hreset_n_i)
            !ppast_ok || !$past(dma_ack_o[g]) || !dma_ack_o[g] || ack_rise[g])
            else $error("[SVA-FAIL] a_ack_one_pclk_edge[%0d]: one ack seen by two pclk edges (F22)", g);
        c_eligible:     cover property (@(posedge hclk_i) disable iff (!hreset_n_i) eligible[g]);
        c_m2m_active:   cover property (@(posedge hclk_i) disable iff (!hreset_n_i) active[g] && mode[g] == M_M2M);
        c_periph_wait:  cover property (@(posedge hclk_i) disable iff (!hreset_n_i) active[g] && mode[g] != M_M2M && !dma_req_i[g]);
        c_held_request: cover property (@(posedge hclk_i) disable iff (!hreset_n_i) need_low[g] && dma_req_i[g] && active[g]);
        c_err_with_req: cover property (@(posedge hclk_i) disable iff (!hreset_n_i) beat_err[g] && dma_req_i[g]);
        c_ack:          cover property (@(posedge hclk_i) disable iff (!hreset_n_i) ack_rise[g]);
        c_ack_fall:     cover property (@(posedge hclk_i) disable iff (!hreset_n_i) !dma_ack_o[g] && $past(dma_ack_o[g]));
        c_ack_pclk:     cover property (@(posedge pclk_i) disable iff (!hreset_n_i) dma_ack_o[g]);

        // ============================================================== error isolation (F30, R-8)
        for (genvar m = 0; m < 6; m++) begin : g_iso
            if (m != g) begin : g_other
                // row F30 as corrected: except through that channel's own software write strobes
                a_error_isolated: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
                    !past_ok ||
                    !$past(beat_err[g] && !(wr_cr[m] || wr_sar[m] || wr_dar[m] || wr_cnt[m] || wr_iclr[m]) &&
                           !(en[m] && rem[m] == 16'd0)) ||
                    ($stable(cr[32*m +: 32]) && $stable(sar[32*m +: 32]) && $stable(dar[32*m +: 32]) &&
                     $stable(cnt[32*m +: 32]) && $stable(stat[32*m +: 32])))
                    else $error("[SVA-FAIL] a_error_isolated[%0d->%0d]: an error on one channel changed another (F30)", g, m);
            end
        end
        c_err_read:         cover property (@(posedge hclk_i) disable iff (!hreset_n_i) beat_err[g] && err_phase == 3'd1);
        c_err_write:        cover property (@(posedge hclk_i) disable iff (!hreset_n_i) beat_err[g] && err_phase == 3'd2);
        c_err_other_active: cover property (@(posedge hclk_i) disable iff (!hreset_n_i) beat_err[g] && |(active & ~(6'd1 << g)));
        // F45, F46
        c_cr_write_active:    cover property (@(posedge hclk_i) disable iff (!hreset_n_i) wr_cr[g] && active[g] && wdata[0]);
        c_dar_write_mid_beat: cover property (@(posedge hclk_i) disable iff (!hreset_n_i) wr_dar[g] && beat_open && beat_ch == g);
    end endgenerate

    // ================================================================== arbitration (F26, F27, R-4)
    a_grant_valid: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        grant_valid == (|eligible))
        else $error("[SVA-FAIL] a_grant_valid: grant_valid=%0b eligible=%06b (F26)", grant_valid, eligible);
    a_grant_eligible: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !grant_valid || eligible[grant_ch])
        else $error("[SVA-FAIL] a_grant_eligible: granted ch%0d, eligible=%06b (F26)", grant_ch, eligible);
    generate for (g = 0; g < 6; g++) begin : g_prio
        a_priority: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
            !(grant_valid && eligible[g]) ||
            ((f_prio(grant_ch) > f_prio(g)) || (f_prio(grant_ch) == f_prio(g) && grant_ch <= g)))
            else $error("[SVA-FAIL] a_priority: granted ch%0d over eligible ch%0d (F26)", grant_ch, g);
        c_contest: cover property (@(posedge hclk_i) disable iff (!hreset_n_i) grant_valid && eligible[g] && grant_ch != g);
    end endgenerate
    c_grant:        cover property (@(posedge hclk_i) disable iff (!hreset_n_i) grant_valid);
    c_all_eligible: cover property (@(posedge hclk_i) disable iff (!hreset_n_i) eligible == 6'h3F);

    // ================================================================== engine and AHB master (F16, F27, F29, F32, F48)
    a_state_legal: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) eng_st <= E_WD)   // white-box; backs the coverage waiver of dma_engine's default arm
        else $error("[SVA-FAIL] a_state_legal: engine state %0d (F27)", eng_st);
    a_takes_grant: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)                 // white-box
        !past_ok || !$past(eng_st == E_IDLE && grant_valid && beat_done == 6'd0 && beat_err == 6'd0) ||
        (eng_st == E_RA && eng_ch == $past(grant_ch)))
        else $error("[SVA-FAIL] a_takes_grant (F27)");
    a_no_grant_while_reporting: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)    // white-box, ENG-1
        !past_ok || !$past(eng_st == E_IDLE && (|beat_done || |beat_err)) || eng_st == E_IDLE)
        else $error("[SVA-FAIL] a_no_grant_while_reporting: a beat began before the last result was counted (ENG-1, F27)");
    a_beat_atomic: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)                  // white-box, [N-7.11]
        !past_ok || !$past(eng_st != E_IDLE) || (eng_st == E_IDLE || eng_ch == $past(eng_ch)))
        else $error("[SVA-FAIL] a_beat_atomic: the engine changed channel inside a beat (F27)");
    // DMA-14 detector (F45, F20): a beat keeps the SIZE it was taken with, for its read
    // and its write. Fails on today's RTL when a CR write (e.g. the stop CR = 0, which
    // also writes SIZE = byte) lands while the beat is in flight: dma_engine reads SIZE live.
    a_beat_size_atomic: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !htrans_o[1] || (hsize_o == {1'b0, beat_size_q}))
        else $error("[SVA-FAIL] a_beat_size_atomic: HSIZE %0d inside a beat taken with SIZE %0d (DMA-14, F45)", hsize_o, beat_size_q);
    c_cr_write_in_beat: cover property (@(posedge hclk_i) disable iff (!hreset_n_i) eng_st != E_IDLE && wr_cr[eng_ch]);
    a_one_result: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        $onehot0(beat_done | beat_err) && ((beat_done & beat_err) == 6'd0))
        else $error("[SVA-FAIL] a_one_result: done=%06b err=%06b (F27)", beat_done, beat_err);
    a_single_only: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        hburst_o == 3'b000 && (htrans_o == T_IDLE || htrans_o == T_NONSEQ))
        else $error("[SVA-FAIL] a_single_only: htrans=%b hburst=%b (F16)", htrans_o, hburst_o);
    a_hsize_legal: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !htrans_o[1] || (hsize_o inside {3'b000, 3'b001, 3'b010}))
        else $error("[SVA-FAIL] a_hsize_legal: hsize=%b (F03)", hsize_o);
    a_addr_hold_in_wait: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)            // AHB-Lite; planted bug M19
        !past_ok || !$past(htrans_o[1] && !hready_i) ||
        ($stable(htrans_o) && $stable(haddr_o) && $stable(hwrite_o) && $stable(hsize_o)))
        else $error("[SVA-FAIL] a_addr_hold_in_wait: address phase changed while HREADY was low (F48)");
    a_wdata_hold_in_wait: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !past_ok || !$past(dp_wr && !hready_i) || $stable(hwdata_o))
        else $error("[SVA-FAIL] a_wdata_hold_in_wait (F48)");
    // F13-F15, F17: what is written is what was read, lane by lane (catches byte-lane faults)
    a_write_data: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(dp_wr && hready_i && !hresp_i) || f_lanes_ok(hsize_o, rd_lane_q, wr_lane_q, rd_data_q, hwdata_o))
        else $error("[SVA-FAIL] a_write_data: wrote %08h (lane %0d), read %08h (lane %0d), hsize=%0d (F17)",
                    hwdata_o, wr_lane_q, rd_data_q, rd_lane_q, hsize_o);
    // AHB-Lite: HADDR is aligned to HSIZE. DMA-13 detector (F17): fails on today's RTL
    // when a halfword or word channel is given an unaligned SAR or DAR.
    a_haddr_aligned: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !htrans_o[1] || (hsize_o == 3'b000) || (hsize_o == 3'b001 && !haddr_o[0]) ||
        (hsize_o == 3'b010 && haddr_o[1:0] == 2'b00))
        else $error("[SVA-FAIL] a_haddr_aligned: HADDR %08h is not aligned to HSIZE %0d (AHB-Lite, DMA-13, F17)", haddr_o, hsize_o);
    a_no_isram: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !htrans_o[1] || !f_r9_bad(haddr_o))
        else $error("[SVA-FAIL] a_no_isram: DMA presented %08h (R-9, F32)", haddr_o);
    a_read_then_write: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !rd_addr || (!dp_rd && !dp_wr && !beat_open))
        else $error("[SVA-FAIL] a_read_then_write: a read began while another beat was open ([N-7.2], F16)");
    a_write_same_beat: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !wr_addr || (beat_open && eng_ch == beat_ch))
        else $error("[SVA-FAIL] a_write_same_beat: a write with no read of the same channel before it (F16)");
    a_no_write_after_read_error: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(rd_err_pend && htrans_o[1]) || !hwrite_o)
        else $error("[SVA-FAIL] a_no_write_after_read_error ([N-7.13], F29)");
    a_errphase_read: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !past_ok || !$past(dp_rd && hready_i && hresp_i) || (beat_err == (6'd1 << $past(eng_ch)) && err_phase == 3'd1))
        else $error("[SVA-FAIL] a_errphase_read (F29)");
    a_errphase_write: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !past_ok || !$past(dp_wr && hready_i && hresp_i) || (beat_err == (6'd1 << $past(eng_ch)) && err_phase == 3'd2))
        else $error("[SVA-FAIL] a_errphase_write (F29)");
    a_refuse_sar: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)                    // white-box state
        !past_ok || !$past(eng_st == E_RA && sar_bad_cur) ||
        (beat_err == (6'd1 << $past(eng_ch)) && err_phase == 3'd1 && htrans_o == T_IDLE))
        else $error("[SVA-FAIL] a_refuse_sar (R-9, F32)");
    a_refuse_dar: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !past_ok || !$past(eng_st == E_WA && dar_bad_cur) ||
        (beat_err == (6'd1 << $past(eng_ch)) && err_phase == 3'd2 && htrans_o == T_IDLE))
        else $error("[SVA-FAIL] a_refuse_dar (R-9, F32)");
    // DMA-10 detector (F43); fails on today's RTL whenever a bad DAR is refused
    a_no_read_before_refusal: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !rd_addr || !dar_bad_cur)
        else $error("[SVA-FAIL] a_no_read_before_refusal: source read for a beat whose DAR %08h will be refused (DMA-10, F43)",
                    dar[32*eng_ch +: 32]);

    // ================================================================== covers, bus and reset
    c_take:          cover property (@(posedge hclk_i) disable iff (!hreset_n_i) eng_st == E_IDLE && grant_valid && beat_done == 6'd0 && beat_err == 6'd0);
    c_take_blocked:  cover property (@(posedge hclk_i) disable iff (!hreset_n_i) eng_st == E_IDLE && grant_valid && (|beat_done || |beat_err));
    c_rd_addr:       cover property (@(posedge hclk_i) disable iff (!hreset_n_i) rd_addr);
    c_wr_addr:       cover property (@(posedge hclk_i) disable iff (!hreset_n_i) wr_addr);
    c_rd_wait:       cover property (@(posedge hclk_i) disable iff (!hreset_n_i) dp_rd && !hready_i);
    c_wr_wait:       cover property (@(posedge hclk_i) disable iff (!hreset_n_i) dp_wr && !hready_i);
    c_addr_stall:    cover property (@(posedge hclk_i) disable iff (!hreset_n_i) htrans_o[1] && !hready_i && !dp_rd && !dp_wr);
    c_wr_done:       cover property (@(posedge hclk_i) disable iff (!hreset_n_i) dp_wr && hready_i && !hresp_i);
    c_rd_error:      cover property (@(posedge hclk_i) disable iff (!hreset_n_i) dp_rd && hready_i && hresp_i);
    c_wr_error:      cover property (@(posedge hclk_i) disable iff (!hreset_n_i) dp_wr && hready_i && hresp_i);
    c_after_rd_err:  cover property (@(posedge hclk_i) disable iff (!hreset_n_i) rd_err_pend && htrans_o[1]);
    c_refuse_sar:    cover property (@(posedge hclk_i) disable iff (!hreset_n_i) eng_st == E_RA && sar_bad_cur);
    c_refuse_dar:    cover property (@(posedge hclk_i) disable iff (!hreset_n_i) eng_st == E_WA && dar_bad_cur);
    c_byte_beat:     cover property (@(posedge hclk_i) disable iff (!hreset_n_i) rd_addr && hsize_o == 3'b000 && haddr_o[1:0] == 2'b11);
    c_half_beat:     cover property (@(posedge hclk_i) disable iff (!hreset_n_i) rd_addr && hsize_o == 3'b001 && haddr_o[1] == 1'b1);
    c_unaligned:     cover property (@(posedge hclk_i) disable iff (!hreset_n_i) htrans_o[1] && hsize_o == 3'b010 && haddr_o[1:0] != 2'b00);
    c_unaligned_half:cover property (@(posedge hclk_i) disable iff (!hreset_n_i) htrans_o[1] && hsize_o == 3'b001 && haddr_o[0]);
    c_gstat_read:    cover property (@(posedge pclk_i) disable iff (!preset_n_i) apb_acc && !pwrite_i && paddr_i == 12'h100);
    c_ro_write:      cover property (@(posedge pclk_i) disable iff (!preset_n_i) apb_acc && pwrite_i && f_read_only(paddr_i));
    c_unmapped:      cover property (@(posedge pclk_i) disable iff (!preset_n_i) apb_acc && !f_mapped(paddr_i));
    c_back_to_back:  cover property (@(posedge hclk_i) disable iff (!hreset_n_i) any_wr && wr_hist[3]);
    c_reset_idle:    cover property (@(posedge hclk_i) $fell(hreset_n_i) && $past(eng_st) == E_IDLE && $past(|active));
    c_reset_ra:      cover property (@(posedge hclk_i) $fell(hreset_n_i) && $past(eng_st) == E_RA);
    c_reset_rd:      cover property (@(posedge hclk_i) $fell(hreset_n_i) && $past(eng_st) == E_RD);
    c_reset_wa:      cover property (@(posedge hclk_i) $fell(hreset_n_i) && $past(eng_st) == E_WA);
    c_reset_wd:      cover property (@(posedge hclk_i) $fell(hreset_n_i) && $past(eng_st) == E_WD);
endmodule

bind dma_top dma_sva #(.PRIO(PRIO), .ACK_CYCLES(ACK_CYCLES)) u_dma_sva (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .pclk_i(pclk_i), .preset_n_i(preset_n_i),
    .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i), .paddr_i(paddr_i),
    .pwdata_i(pwdata_i), .prdata_o(prdata_o), .pready_o(pready_o), .pslverr_o(pslverr_o),
    .haddr_o(haddr_o), .htrans_o(htrans_o), .hwrite_o(hwrite_o), .hsize_o(hsize_o),
    .hburst_o(hburst_o), .hwdata_o(hwdata_o), .hrdata_i(hrdata_i), .hready_i(hready_i),
    .hresp_i(hresp_i),
    .dma_req_i(dma_req_i), .dma_ack_o(dma_ack_o),
    .dma_complete_o(dma_complete_o), .dma_error_o(dma_error_o),
    .wr_cr(wr_cr), .wr_sar(wr_sar), .wr_dar(wr_dar), .wr_cnt(wr_cnt), .wr_iclr(wr_iclr),
    .wdata(wdata), .cr(cr), .sar(sar), .dar(dar), .cnt(cnt), .stat(stat),
    .eligible(eligible), .beat_done(beat_done), .beat_err(beat_err), .err_phase(err_phase),
    .grant_valid(grant_valid), .grant_ch(grant_ch),
    .eng_st(u_eng.st), .eng_ch(u_eng.ch),
    .taken({g_ch[5].u_ch.taken_q, g_ch[4].u_ch.taken_q, g_ch[3].u_ch.taken_q,
            g_ch[2].u_ch.taken_q, g_ch[1].u_ch.taken_q, g_ch[0].u_ch.taken_q}));
`endif
