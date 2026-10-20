`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 9 : properties for the DMA
// dma_sva.sv
//
// Spec: GARUDA-DMA-SPEC-001 Rev 3.0, sections 6 and 7 (the [N-x] numbers), and
// the AHB-Lite master rules. Two checkers:
//   dma_top_sva   bound to dma_top: the beat engine, the arbiter, the APB slave
//   dma_chan_sva  bound to every dma_chan: one channel's registers and status
// They run in the block bench and in every chip simulation, and are the
// property set of flow/formal/dma/dma_fpv.tcl. The assume_* describe the AHB
// slave (a two-cycle ERROR) and the APB master (a legal transfer).
// Not compiled for synthesis or lint, and not under Icarus (TOOL-B2).
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module dma_top_sva #(
    parameter [17:0] PRIO = {3'd0, 3'd4, 3'd2, 3'd1, 3'd3, 3'd5},
    parameter integer ACK_CYCLES = 2
)(
    input wire        hclk_i, hreset_n_i, pclk_i, preset_n_i,
    input wire        psel_i, penable_i, pwrite_i,
    input wire [11:0] paddr_i,
    input wire        pready_o, pslverr_o,
    input wire [31:0] prdata_o,
    input wire [31:0] haddr_o, hwdata_o,
    input wire [1:0]  htrans_o,
    input wire        hwrite_o, hready_i, hresp_i,
    input wire [2:0]  hsize_o, hburst_o,
    input wire [5:0]  dma_req_i, dma_ack_o,
    // internals
    input wire [2:0]  st, ch,
    input wire [5:0]  eligible, beat_done, beat_err,
    input wire [2:0]  err_phase,
    input wire        grant_valid,
    input wire [2:0]  grant_ch
);
    localparam [2:0] E_IDLE = 3'd0, E_RA = 3'd1, E_RD = 3'd2, E_WA = 3'd3, E_WD = 3'd4;

    // ---- surroundings (assumed in formal, checked in simulation) ------------
    assume_slave_error2: assume property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hresp_i && !hready_i) |=> (hresp_i && hready_i) );
    assume_slave_okay_idle: assume property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (!$past(htrans_o[1]) && st == E_IDLE) |-> !hresp_i );
    assume_apb_legal: assume property (@(posedge pclk_i) disable iff (!preset_n_i)
        (psel_i && !penable_i) |=> (psel_i && penable_i && $stable(paddr_i) && $stable(pwrite_i)) );

    // ---- AHB master ----------------------------------------------------------
    // [N-7.2] SINGLE transfers only
    a_single: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) hburst_o == 3'b000 )
        else $error("[SVA-FAIL] a_single: HBURST is not SINGLE");
    a_no_seq: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) htrans_o != 2'b11 && htrans_o != 2'b01 )
        else $error("[SVA-FAIL] a_no_seq: the DMA issued SEQ or BUSY");
    // AHB-Lite: the address phase holds until accepted
    a_addr_stable: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (htrans_o[1] && !hready_i) |=> ($stable({haddr_o, htrans_o, hwrite_o, hsize_o})) )
        else $error("[SVA-FAIL] a_addr_stable: the address phase changed before it was accepted");
    // [N-7.20] no transfer to ISRAM (0x0) or the Boot ROM (0x1)
    a_no_forbidden: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        htrans_o[1] |-> (haddr_o[31:28] != 4'h0 && haddr_o[31:28] != 4'h1) )
        else $error("[SVA-FAIL] a_no_forbidden: the DMA addressed ISRAM or the Boot ROM");
    // [N-7.2] a beat is one read, then one write: a write address only after a successful read
    a_read_before_write: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (htrans_o[1] && hwrite_o) |-> st == E_WD )
        else $error("[SVA-FAIL] a_read_before_write: a write outside the write phase of a beat");
    // sub-word transfers are naturally aligned
    a_aligned: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        htrans_o[1] |-> ((hsize_o == 3'd1) ? !haddr_o[0] : (hsize_o == 3'd2) ? (haddr_o[1:0] == 2'b00) : 1'b1) )
        else $error("[SVA-FAIL] a_aligned: an unaligned transfer");
    // [N-7.11] the channel cannot change inside a beat (a_beat_atomic)
    a_beat_atomic: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (st != E_IDLE && $past(st) != E_IDLE) |-> $stable(ch) )
        else $error("[SVA-FAIL] a_beat_atomic: the channel changed inside a beat");
    // [N-7.11] the arbiter grants the eligible channel of the highest priority
    a_priority: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        grant_valid |-> (eligible[grant_ch] &&
            (!eligible[0] || PRIO[3*grant_ch +: 3] >= PRIO[ 2: 0]) && (!eligible[1] || PRIO[3*grant_ch +: 3] >= PRIO[ 5: 3]) &&
            (!eligible[2] || PRIO[3*grant_ch +: 3] >= PRIO[ 8: 6]) && (!eligible[3] || PRIO[3*grant_ch +: 3] >= PRIO[11: 9]) &&
            (!eligible[4] || PRIO[3*grant_ch +: 3] >= PRIO[14:12]) && (!eligible[5] || PRIO[3*grant_ch +: 3] >= PRIO[17:15])) )
        else $error("[SVA-FAIL] a_priority: a lower-priority channel was granted");
    a_grant_iff_eligible: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) grant_valid == (|eligible) )
        else $error("[SVA-FAIL] a_grant_iff_eligible: grant without an eligible channel, or the reverse");
    // one result per beat, for one channel, and never both
    a_one_result: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        $onehot0(beat_done | beat_err) && ((beat_done & beat_err) == 6'd0) )
        else $error("[SVA-FAIL] a_one_result: two results in one cycle");
    // [N-6.3] an error says which phase failed
    a_err_phase: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (|beat_err) |-> (err_phase == 3'd1 || err_phase == 3'd2) )
        else $error("[SVA-FAIL] a_err_phase: ERRPHASE is neither read nor write");
    // [N-7.8] an acknowledge only for a completed beat, of ACK_CYCLES hclk, on that channel only
    a_ack_with_done: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (|beat_done) |-> (dma_ack_o == beat_done) )
        else $error("[SVA-FAIL] a_ack_with_done: the acknowledge is not on the completed channel");
    a_ack_onehot: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) $onehot0(dma_ack_o) )
        else $error("[SVA-FAIL] a_ack_onehot: two acknowledges");
    a_ack_only_after_done: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        $rose(|dma_ack_o) |-> (|beat_done) )
        else $error("[SVA-FAIL] a_ack_only_after_done: an acknowledge without a completed beat");
    // the width is the spec's (one pclk = 2 hclk, D-16), not the RTL parameter
    a_ack_width: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        ((|beat_done) && !$past(|dma_ack_o)) |-> (|dma_ack_o) [*2] ##1 (!(|dma_ack_o) || (|beat_done)) )
        else $error("[SVA-FAIL] a_ack_width: the acknowledge is not ACK_CYCLES long");
    // no error result for a beat that never left idle
    a_idle_quiet: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        ($past(st) == E_IDLE) |-> (beat_done == 6'd0 && beat_err == 6'd0) )
        else $error("[SVA-FAIL] a_idle_quiet: a result while the engine was idle");

    // ---- APB slave -----------------------------------------------------------
    a_apb_ready: assert property (@(posedge pclk_i) disable iff (!preset_n_i) pready_o )
        else $error("[SVA-FAIL] a_apb_ready: the DMA stalled the APB");
    // channels 6 and 7 do not exist: an access there is refused
    a_apb_no_ch67: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (psel_i && penable_i && paddr_i[11:8] == 4'h0 && paddr_i[7:5] >= 3'd6) |-> pslverr_o )
        else $error("[SVA-FAIL] a_apb_no_ch67: an access to channel 6 or 7 was accepted");
    // AUD-13 (track A ruling, merged 2026-10-21): a write to a read-only register
    // (STAT, GSTAT) is ignored without PSLVERR. This property required PSLVERR
    // until then and contradicted the merged RTL (dma_apb_slave.v ERRATUM AUD-13).
    a_apb_stat_ro: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (psel_i && penable_i && pwrite_i && (paddr_i == 12'h100 ||
         (paddr_i[11:8] == 4'h0 && paddr_i[7:5] < 3'd6 && paddr_i[4:2] == 3'd4))) |-> !pslverr_o )
        else $error("[SVA-FAIL] a_apb_stat_ro: a write to STAT or GSTAT raised PSLVERR (AUD-13)");
    a_apb_err_only_access: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        pslverr_o |-> (psel_i && penable_i) )
        else $error("[SVA-FAIL] a_apb_err_only_access: PSLVERR outside an access phase");
    // PRDATA is captured at the edge that ends SETUP and changes nowhere else
    a_prdata_stable: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        $changed(prdata_o) |-> $past(psel_i && !penable_i) )
        else $error("[SVA-FAIL] a_prdata_stable: PRDATA moved inside the access phase");

    // ---- reachability --------------------------------------------------------
    genvar n;
    for (n = 0; n < 6; n++) begin : g_c
        c_beat_done: cover property (@(posedge hclk_i) beat_done[n]);
        c_beat_err:  cover property (@(posedge hclk_i) beat_err[n]);
    end
    c_err_read_bus:   cover property (@(posedge hclk_i) (|beat_err) && err_phase == 3'd1 && $past(st) == E_RD);
    c_err_write_bus:  cover property (@(posedge hclk_i) (|beat_err) && err_phase == 3'd2 && $past(st) == E_WD);
    c_forbidden_src:  cover property (@(posedge hclk_i) (|beat_err) && $past(st) == E_RA);
    c_forbidden_dst:  cover property (@(posedge hclk_i) (|beat_err) && $past(st) == E_WA);
    c_contended:      cover property (@(posedge hclk_i) st == E_IDLE && $countones(eligible) >= 2);
    c_byte_beat:      cover property (@(posedge hclk_i) htrans_o[1] && hsize_o == 3'd0);
    c_half_beat:      cover property (@(posedge hclk_i) htrans_o[1] && hsize_o == 3'd1);
    c_wait_state:     cover property (@(posedge hclk_i) st == E_RD && !hready_i);
    c_apb_refused:    cover property (@(posedge pclk_i) pslverr_o);
endmodule

module dma_chan_sva (
    input wire        hclk_i, hreset_n_i,
    input wire        wr_cr_i, wr_sar_i, wr_dar_i, wr_iclr_i,
    input wire [31:0] wdata_i,
    input wire        req_i, eligible_o, beat_done_i, beat_err_i,
    input wire        complete_irq_o, error_irq_o,
    input wire        en_q, iec_q, iee_q, comp_q, err_q, taken_q,
    input wire [1:0]  mode_q,
    input wire [15:0] rem_q, cnt_q,
    input wire [31:0] sar_q, dar_q
);
    // [N-7.3] REMAINING never counts below zero: a beat completes only with something left
    a_rem_no_underflow: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        beat_done_i |-> rem_q != 16'd0 )
        else $error("[SVA-FAIL] a_rem_no_underflow: a beat completed with REMAINING = 0");
    // [N-6.2], R-6: COMPLETE implies nothing remains (a_remaining_complete_consistent)
    a_complete_consistent: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        comp_q |-> rem_q == 16'd0 )
        else $error("[SVA-FAIL] a_complete_consistent: COMPLETE set with beats remaining");
    // [N-7.3], [N-7.13], [N-7.17] hardware clears EN on the last beat and on an error, whatever software writes
    a_hw_clears_en_err: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        beat_err_i |=> !en_q )
        else $error("[SVA-FAIL] a_hw_clears_en_err: EN still set after an error");
    a_hw_clears_en_last: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (beat_done_i && rem_q == 16'd1) |=> (!en_q && comp_q && rem_q == 16'd0) )
        else $error("[SVA-FAIL] a_hw_clears_en_last: the last beat did not complete the channel");
    // [N-7.15] the addresses freeze at the failure point
    a_freeze_on_error: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (beat_err_i && !wr_sar_i && !wr_dar_i) |=> ($stable(sar_q) && $stable(dar_q)) )
        else $error("[SVA-FAIL] a_freeze_on_error: an address moved on a failed beat");
    a_rem_freeze_on_error: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (beat_err_i && !wr_cr_i) |=> $stable(rem_q) )
        else $error("[SVA-FAIL] a_rem_freeze_on_error: REMAINING moved on a failed beat");
    // [N-6.1] MODE = 3 is not stored
    a_mode_not_3: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) mode_q != 2'b11 )
        else $error("[SVA-FAIL] a_mode_not_3: the reserved MODE was stored");
    // [N-7.10] one beat per request assertion, in the peripheral modes
    // a shadow of "this request has been served", independent of the RTL's taken flag;
    // only a successful beat consumes a request (DMA-8)
    reg served = 1'b0;
    always @(posedge hclk_i or negedge hreset_n_i)
        if (!hreset_n_i) served <= 1'b0;
        else if (!req_i) served <= 1'b0;
        else if (beat_done_i && mode_q != 2'd2) served <= 1'b1;
    a_one_beat_per_req: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (served && req_i && mode_q != 2'd2) |-> !eligible_o )
        else $error("[SVA-FAIL] a_one_beat_per_req: a second beat for one request");
    a_eligible_needs_active: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        eligible_o |-> (en_q && rem_q != 16'd0) )
        else $error("[SVA-FAIL] a_eligible_needs_active: an inactive channel asked for a beat");
    // [N-7.4] the interrupts are the status bits gated by their enables, level
    a_irq_complete: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) complete_irq_o == (comp_q && iec_q) )
        else $error("[SVA-FAIL] a_irq_complete: dma_complete does not follow COMPLETE and IE_COMP");
    a_irq_error: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) error_irq_o == (err_q && iee_q) )
        else $error("[SVA-FAIL] a_irq_error: dma_error does not follow ERROR and IE_ERR");
    // ICLR clears COMPLETE unless the last beat completes in the same cycle ([N-7.19])
    a_iclr_complete: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (wr_iclr_i && wdata_i[0] && !beat_done_i && !(wr_cr_i)) |=> !comp_q )
        else $error("[SVA-FAIL] a_iclr_complete: ICLR did not clear COMPLETE");

    c_complete:      cover property (@(posedge hclk_i) $rose(comp_q));
    c_zero_length:   cover property (@(posedge hclk_i) wr_cr_i && wdata_i[0] && !en_q && cnt_q == 16'd0);
    c_collision:     cover property (@(posedge hclk_i) wr_cr_i && beat_done_i && rem_q == 16'd1);
    c_rearm_in_beat: cover property (@(posedge hclk_i) wr_cr_i && wdata_i[0] && !en_q && rem_q != 16'd0);
    c_m2m:           cover property (@(posedge hclk_i) beat_done_i && mode_q == 2'd2);
    c_p2m_req_held:  cover property (@(posedge hclk_i) taken_q && req_i && en_q && rem_q != 16'd0);
endmodule

bind dma_top dma_top_sva #(.PRIO(PRIO), .ACK_CYCLES(ACK_CYCLES)) u_dma_sva (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .pclk_i(pclk_i), .preset_n_i(preset_n_i),
    .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i), .paddr_i(paddr_i),
    .pready_o(pready_o), .pslverr_o(pslverr_o), .prdata_o(prdata_o),
    .haddr_o(haddr_o), .hwdata_o(hwdata_o), .htrans_o(htrans_o), .hwrite_o(hwrite_o),
    .hready_i(hready_i), .hresp_i(hresp_i), .hsize_o(hsize_o), .hburst_o(hburst_o),
    .dma_req_i(dma_req_i), .dma_ack_o(dma_ack_o),
    .st(u_eng.st), .ch(u_eng.ch), .eligible(eligible), .beat_done(beat_done), .beat_err(beat_err),
    .err_phase(err_phase), .grant_valid(grant_valid), .grant_ch(grant_ch));

bind dma_chan dma_chan_sva u_chan_sva (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i),
    .wr_cr_i(wr_cr_i), .wr_sar_i(wr_sar_i), .wr_dar_i(wr_dar_i), .wr_iclr_i(wr_iclr_i), .wdata_i(wdata_i),
    .req_i(req_i), .eligible_o(eligible_o), .beat_done_i(beat_done_i), .beat_err_i(beat_err_i),
    .complete_irq_o(complete_irq_o), .error_irq_o(error_irq_o),
    .en_q(en_q), .iec_q(iec_q), .iee_q(iee_q), .comp_q(comp_q), .err_q(err_q), .taken_q(taken_q),
    .mode_q(mode_q), .rem_q(rem_q), .cnt_q(cnt_q), .sar_q(sar_q), .dar_q(dar_q));
`endif
`endif
