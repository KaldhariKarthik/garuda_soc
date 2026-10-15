// =============================================================================
// dma_cov_sva.sv -- formal evidence for the DMA coverage exclusions (Track A, DMA
// plan D7; H5 waiver rule).
//
// Every point that tb/dma/cov/dma_waivers.toml excludes as "unreachable" or
// "constant" in a REGISTER or a DERIVED signal is asserted here and proven on
// dma_top under the D2 environment (tb/dma/formal/cov_unreach.toml). A literal
// constant in the RTL (assign x = {16'd0, ..}) needs no proof: its waiver cites
// the line. The engine's state range (default arm of dma_engine's case) is
// dma_sva's a_state_legal, proven in the same run. If a property here FAILS, the
// point is reachable: it gets a test, never a waiver.
// Portable SVA subset (H4): boolean asserts, no |->.
// =============================================================================
`timescale 1ns/1ps

`ifdef FORMAL
  `define GARUDA_DMA_COV_SVA
`elsif SYNTHESIS
`else
  `define GARUDA_DMA_COV_SVA
`endif

`ifdef GARUDA_DMA_COV_SVA
module dma_cov_sva #(
    parameter [17:0] PRIO = {3'd0, 3'd4, 3'd2, 3'd1, 3'd3, 3'd5}
)(
    input wire         hclk_i, hreset_n_i,
    input wire [5:0]   eligible,
    input wire         grant_valid,
    input wire [2:0]   grant_ch,
    input wire [2:0]   err_phase,
    input wire [191:0] stat,
    input wire [1:0]   ack_cnt
);
    function automatic int ones(input logic [5:0] v);
        int k = 0;
        for (int i = 0; i < 6; i++) k += v[i];
        return k;
    endfunction
    // the shipped priorities, as the waivers state them (a different map changes the
    // reachable cg_dma_arb bins, and this check fails first)
    a_cov_prio_map: assert property (@(posedge hclk_i)
        PRIO == {3'd0, 3'd4, 3'd2, 3'd1, 3'd3, 3'd5});
    // cg_dma_arb x_nw: channel 5 (priority 0, the lowest) never wins a contest; channel 2
    // (priority 1) beats only channel 5, so never wins a contest of three or more
    a_cov_arb_c5_alone: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(grant_valid && grant_ch == 3'd5 && ones(eligible) >= 2));
    a_cov_arb_c2_le2: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(grant_valid && grant_ch == 3'd2 && ones(eligible) >= 3));
    // the boundary is tight (not vacuous): channel 5 wins alone, channel 2 wins against one
    c_cov_c5_alone: cover property (@(posedge hclk_i) disable iff (!hreset_n_i)
        grant_valid && grant_ch == 3'd5 && ones(eligible) == 1);
    c_cov_c2_two:   cover property (@(posedge hclk_i) disable iff (!hreset_n_i)
        grant_valid && grant_ch == 3'd2 && ones(eligible) == 2);
    c_cov_errph_wr: cover property (@(posedge hclk_i) disable iff (!hreset_n_i) err_phase == 3'd2);
    c_cov_ackcnt1:  cover property (@(posedge hclk_i) disable iff (!hreset_n_i) ack_cnt == 2'd1);
    // toggle: ERRPHASE takes only 0, 1 (read) and 2 (write): bit 2 is never set, in the
    // engine's output nor in any channel's STAT[21]
    a_cov_errph_bit2: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !err_phase[2] && !stat[21] && !stat[53] && !stat[85] && !stat[117] && !stat[149] && !stat[181]);
    // toggle: with ACK_CYCLES = 2 the ack stretch counter loads 1 at most: bit 1 stays 0
    a_cov_ackcnt_bit1: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !ack_cnt[1]);
endmodule

bind dma_top dma_cov_sva #(.PRIO(PRIO)) u_dma_cov_sva (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .eligible(eligible), .grant_valid(grant_valid),
    .grant_ch(grant_ch), .err_phase(err_phase), .stat(stat), .ack_cnt(u_eng.ack_cnt));
`endif
